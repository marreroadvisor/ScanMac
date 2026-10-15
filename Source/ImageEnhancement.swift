import SwiftUI
import AppKit
import PDFKit
import CoreImage

private enum ScanEnhancementError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case let .failed(message) = self { return message }; return nil }
}

enum ScanEnhancementEngine {
    static let modes = ["Corregir sombras", "Blanco y negro adaptativo", "Enfocar", "Reducir ruido", "Invertir", "Ajustes manuales"]

    static func filtered(_ image: CIImage, mode: String, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) throws -> CIImage {
        let extent = image.extent
        let output: CIImage
        switch mode {
        case "Corregir sombras", "Blanco y negro adaptativo":
            let radius = max(8, min(extent.width, extent.height) * 0.025)
            let background = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            // Foreground / low-frequency illumination estimates a flat page background.
            output = image.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: background])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: mode == "Corregir sombras" ? 1.15 : 1.35, kCIInputSaturationKey: mode == "Corregir sombras" ? 1 : 0])
            if mode == "Blanco y negro adaptativo" {
                guard let threshold = CIFilter(name: "CIColorThreshold") else { throw ScanEnhancementError.failed(tr("Este macOS no ofrece el filtro de umbral necesario para blanco y negro adaptativo.")) }
                threshold.setValue(output, forKey: kCIInputImageKey); threshold.setValue(0.76, forKey: "inputThreshold")
                guard let result = threshold.outputImage else { throw ScanEnhancementError.failed(tr("No se pudo calcular el umbral de la imagen.")) }
                return result.cropped(to: extent)
            }
        case "Enfocar":
            output = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.65])
        case "Reducir ruido":
            output = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.035, "inputSharpness": 0.4])
        case "Invertir": output = image.applyingFilter("CIColorInvert")
        case "Ajustes manuales":
            guard brightness.isFinite, contrast.isFinite, saturation.isFinite else { throw ScanEnhancementError.failed(tr("Los ajustes de imagen no son válidos.")) }
            output = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: min(0.5, max(-0.5, brightness)), kCIInputContrastKey: min(3, max(0.25, contrast)), kCIInputSaturationKey: min(2, max(0, saturation))])
        default: throw ScanEnhancementError.failed(tr("Selecciona una mejora válida."))
        }
        return output.cropped(to: extent)
    }

    static func renderPage(_ page: PDFPage) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { throw ScanEnhancementError.failed(tr("La página tiene dimensiones inválidas.")) }
        let rotated = abs(page.rotation % 180) == 90
        let displayed = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(2, 3000 / max(displayed.width, displayed.height))
        let thumbnail = page.thumbnail(of: CGSize(width: displayed.width * scale, height: displayed.height * scale), for: .cropBox)
        var bounds = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { throw ScanEnhancementError.failed(tr("No se pudo leer la imagen de la página.")) }
        return image
    }

    static func replacement(image: CGImage, source: PDFPage) throws -> PDFPage {
        let crop = source.bounds(for: .cropBox)
        let rotated = abs(source.rotation % 180) == 90
        var box = CGRect(origin: .zero, size: rotated ? CGSize(width: crop.height, height: crop.width) : crop.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ScanEnhancementError.failed(tr("No se pudo crear el PDF de la imagen."))
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(box)
        context.interpolationQuality = .high; context.draw(image, in: box)
        context.endPDFPage(); context.closePDF()
        guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0)?.copy() as? PDFPage else {
            throw ScanEnhancementError.failed(tr("No se pudo guardar la página mejorada."))
        }
        return page
    }
}

@MainActor extension Library {
    func enhanceAdvanced(mode: String, allPages: Bool = false, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
        guard !busy, let document, let sourceData = document.dataRepresentation() else { return }
        let targetID = selected; let targetRevision = revision; let targetPage = page
        busy = true; message = allPages ? tr("Mejorando todas las páginas…") : tr("Mejorando página…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let working = PDFDocument(data: sourceData) else { throw ScanEnhancementError.failed(tr("No se pudo preparar una copia del documento.")) }
                let indexes = allPages ? Array(0..<working.pageCount) : [targetPage]
                let context = CIContext()
                for index in indexes {
                    try autoreleasepool {
                        guard let source = working.page(at: index) else { throw ScanEnhancementError.failed(tr("No se encontró la página {0}.", String(describing: index + 1))) }
                        let original = try ScanEnhancementEngine.renderPage(source)
                        let filtered = try ScanEnhancementEngine.filtered(CIImage(cgImage: original), mode: mode, brightness: brightness, contrast: contrast, saturation: saturation)
                        guard let output = context.createCGImage(filtered, from: filtered.extent) else { throw ScanEnhancementError.failed(tr("No se pudo procesar la página {0}.", String(describing: index + 1))) }
                        let replacement = try ScanEnhancementEngine.replacement(image: output, source: source)
                        working.removePage(at: index); working.insert(replacement, at: index)
                    }
                }
                guard let resultData = working.dataRepresentation() else { throw ScanEnhancementError.failed(tr("No se pudo generar el documento mejorado.")) }
                DispatchQueue.main.async {
                    self.busy = false
                    guard self.selected == targetID, self.revision == targetRevision else { self.message = tr("El documento cambió; la mejora no se aplicó."); return }
                    guard let result = PDFDocument(data: resultData) else { self.error = tr("No se pudo abrir el resultado."); return }
                    self.snapshot(); self.document = result; self.invalidateText(); self.persist()
                    self.message = tr("{0} aplicado a {1} página(s) · Páginas convertidas en imagen", String(describing: mode), String(describing: indexes.count))
                }
            } catch {
                let reason = error.localizedDescription
                DispatchQueue.main.async { self.busy = false; self.error = reason; self.message = tr("La mejora no se aplicó") }
            }
        }
    }
}

struct EnhancementPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "Corregir sombras"
    @State private var allPages = false
    @State private var brightness = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0
    @State private var original: CGImage?
    @State private var preview: CGImage?
    @State private var problem: String?

    private func updatePreview() {
        guard let original else { return }
        do {
            let filtered = try ScanEnhancementEngine.filtered(CIImage(cgImage: original), mode: mode, brightness: brightness, contrast: contrast, saturation: saturation)
            guard let result = CIContext().createCGImage(filtered, from: filtered.extent) else { throw ScanEnhancementError.failed(tr("No se pudo crear la vista previa.")) }
            preview = result; problem = nil
        } catch { preview = nil; problem = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(tr("Mejorar documento")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() } }
            Picker(tr("Mejora"), selection: $mode) { ForEach(ScanEnhancementEngine.modes, id: \.self) { Text(tr($0)).tag($0) } }
            HStack(spacing: 14) {
                VStack { Text(tr("Original")).font(.caption); if let original { Image(decorative: original, scale: 1).resizable().scaledToFit() } }.frame(width: 300, height: 310)
                VStack { Text(tr("Vista previa")).font(.caption); if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit() } }.frame(width: 300, height: 310)
            }.background(Color.gray.opacity(0.08))
            if mode == "Ajustes manuales" {
                HStack { Text(tr("Brillo")).frame(width: 80, alignment: .leading); Slider(value: $brightness, in: -0.5...0.5); Text(brightness.formatted(.number.precision(.fractionLength(2)).locale(appLanguage.locale))).monospacedDigit().frame(width: 45) }
                HStack { Text(tr("Contraste")).frame(width: 80, alignment: .leading); Slider(value: $contrast, in: 0.25...3); Text(contrast.formatted(.number.precision(.fractionLength(2)).locale(appLanguage.locale))).monospacedDigit().frame(width: 45) }
                HStack { Text(tr("Saturación")).frame(width: 80, alignment: .leading); Slider(value: $saturation, in: 0...2); Text(saturation.formatted(.number.precision(.fractionLength(2)).locale(appLanguage.locale))).monospacedDigit().frame(width: 45) }
            }
            Toggle(tr("Aplicar a todas las páginas"), isOn: $allPages)
            Text(tr("La mejora convierte las páginas afectadas en imagen, conservando el tamaño físico visible. El OCR se borra; puedes volver a reconocerlo. Puedes deshacer la edición.")).font(.caption).foregroundStyle(.secondary)
            if let problem { Text(trStatus(problem)).foregroundStyle(.red) }
            if let error = lib.error { Text(trStatus(error)).foregroundStyle(.red) }
            HStack { if lib.busy { ProgressView().controlSize(.small) }; Text(trStatus(lib.message)).font(.caption); Spacer(); Button(tr("Aplicar mejora")) { lib.enhanceAdvanced(mode: mode, allPages: allPages, brightness: brightness, contrast: contrast, saturation: saturation) }.buttonStyle(.borderedProminent).disabled(lib.busy || preview == nil) }
        }.padding(24).frame(width: 670)
        .onAppear {
            do { if let page = lib.document?.page(at: lib.page) { original = try ScanEnhancementEngine.renderPage(page); updatePreview() } }
            catch { problem = error.localizedDescription }
        }
        .onChange(of: mode) { _, _ in updatePreview() }
        .onChange(of: brightness) { _, _ in updatePreview() }
        .onChange(of: contrast) { _, _ in updatePreview() }
        .onChange(of: saturation) { _, _ in updatePreview() }
    }
}

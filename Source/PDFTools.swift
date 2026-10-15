import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum AdvancedPDFError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

enum AdvancedWatermarkPlacement: String, CaseIterable, Identifiable {
    case center = "Centro", top = "Arriba", bottom = "Abajo"
    var id: String { rawValue }
}

@MainActor extension Library {
    func advancedExportProtected(password: String) {
        guard let document else { return }
        guard !password.isEmpty else { error = tr("Escribe una contraseña para proteger la copia."); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (current?.name ?? "Documento") + "-protegido.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let owner = UUID().uuidString + UUID().uuidString
            guard let data = document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: password, PDFDocumentWriteOption.ownerPasswordOption: owner]) else {
                throw AdvancedPDFError.invalid(tr("No se pudo cifrar el PDF."))
            }
            guard let check = PDFDocument(data: data), check.isLocked, check.unlock(withPassword: password), check.pageCount == document.pageCount else {
                throw AdvancedPDFError.invalid(tr("No se pudo verificar la protección del PDF; no se exportó."))
            }
            try data.write(to: destination, options: .atomic)
            message = tr("Copia PDF protegida exportada · Guarda tu contraseña")
        } catch { self.error = error.localizedDescription }
    }

    func advancedWatermark(text: String, placement: AdvancedWatermarkPlacement, opacity: Double, allPages: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !text.isEmpty else { error = tr("Escribe el texto de la marca de agua."); return }
        guard text.count <= 200 else { error = tr("La marca admite hasta 200 caracteres."); return }
        let indexes = allPages ? Array(0..<document.pageCount) : [page]
        snapshot()
        for index in indexes {
            guard let target = document.page(at: index) else { continue }
            let box = target.bounds(for: .cropBox)
            let height = min(100, box.height * 0.25)
            let y: CGFloat
            switch placement {
            case .center: y = box.midY - height / 2
            case .top: y = box.maxY - height - 15
            case .bottom: y = box.minY + 15
            }
            let annotation = PDFAnnotation(bounds: CGRect(x: box.minX + 15, y: y, width: max(1, box.width - 30), height: height), forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.boldSystemFont(ofSize: min(32, max(8, box.width / CGFloat(max(text.count, 15)) * 1.4)))
            annotation.fontColor = NSColor.darkGray.withAlphaComponent(CGFloat(min(1, max(0.05, opacity))))
            annotation.color = .clear; annotation.alignment = .center
            annotation.shouldPrint = true
            target.addAnnotation(annotation)
        }
        persist(); message = tr("Marca de agua añadida · Puedes deshacerla")
    }

    func advancedCrop(left: Double, right: Double, top: Double, bottom: Double, allPages: Bool) {
        guard let document else { return }
        guard [left, right, top, bottom].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 100 }), left + right < 95, top + bottom < 95 else {
            error = tr("Los márgenes deben ser positivos y dejar al menos un 5 % de la página visible."); return
        }
        let indexes = allPages ? Array(0..<document.pageCount) : [page]
        snapshot()
        for index in indexes {
            guard let target = document.page(at: index) else { continue }
            let box = target.bounds(for: .mediaBox)
            target.setBounds(CGRect(x: box.minX + box.width * left / 100, y: box.minY + box.height * bottom / 100,
                                    width: box.width * (100 - left - right) / 100, height: box.height * (100 - top - bottom) / 100), for: .cropBox)
        }
        persist(); message = tr("Recorte visual aplicado · El contenido original se conserva")
    }

    static func advancedPageIndexes(_ input: String, pageCount: Int) throws -> [Int] {
        var result: [Int] = []; var seen = Set<Int>()
        for item in input.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let first = Int(parts[0].trimmingCharacters(in: .whitespaces)), first >= 1, first <= pageCount else {
                throw AdvancedPDFError.invalid(tr("Rango inválido. Usa páginas entre 1 y {0}, por ejemplo 1,3-5.", String(describing: pageCount)))
            }
            let last: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)), parsed >= first, parsed <= pageCount else {
                    throw AdvancedPDFError.invalid(tr("El final del rango debe ser mayor o igual al inicio y no superar {0}.", String(describing: pageCount)))
                }; last = parsed
            } else { last = first }
            for index in (first - 1)...(last - 1) where seen.insert(index).inserted { result.append(index) }
        }
        guard !result.isEmpty else { throw AdvancedPDFError.invalid(tr("Escribe las páginas que quieres extraer.")) }
        return result
    }

    func advancedExtract(range: String) {
        guard let document else { return }
        do {
            let indexes = try Self.advancedPageIndexes(range, pageCount: document.pageCount)
            let output = PDFDocument()
            for index in indexes {
                guard let copy = document.page(at: index)?.copy() as? PDFPage else { throw AdvancedPDFError.invalid(tr("No se pudo copiar la página {0}.", String(describing: index + 1))) }
                output.insert(copy, at: output.pageCount)
            }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = (current?.name ?? "Documento") + "-extraído.pdf"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            guard let data = output.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: destination, options: .atomic); message = tr("{0} páginas extraídas a un nuevo PDF", String(describing: indexes.count))
        } catch { self.error = error.localizedDescription }
    }

    func advancedExportImages() {
        guard let document else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = tr("Exportar aquí")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var count = 0
        do {
            let folder = directory.appendingPathComponent("ScanMac-PNG-" + UUID().uuidString.prefix(8), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    guard let target = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
                    let box = target.bounds(for: .cropBox)
                    let scale = min(2, 3000 / max(1, max(box.width, box.height)))
                    let image = target.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
                    var rect = CGRect(origin: .zero, size: image.size)
                    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: folder.appendingPathComponent(String(format: "Página-%04d.png", index + 1)), options: .atomic)
                }
                count += 1
            }
            message = tr("{0} páginas exportadas como PNG", String(describing: count)); NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { self.error = tr("Se exportaron {0} páginas. ", String(describing: count)) + error.localizedDescription }
    }

    func advancedPrint() {
        guard let document, let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
            error = tr("No se pudo preparar la impresión."); return
        }
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        if operation.run() { message = tr("Documento enviado a impresión") }
    }
}

struct AdvancedPDFPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var watermark = ""
    @State private var placement = AdvancedWatermarkPlacement.center
    @State private var opacity = 0.25
    @State private var watermarkAll = true
    @State private var cropAll = false
    @State private var left = 0.0
    @State private var right = 0.0
    @State private var top = 0.0
    @State private var bottom = 0.0
    @State private var range = "1"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(tr("Herramientas PDF")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() } }
            ScrollView {
                Form {
                    Section(tr("Proteger una copia")) {
                        SecureField(tr("Contraseña de apertura"), text: $password)
                        Button(tr("Exportar PDF con contraseña…")) { lib.advancedExportProtected(password: password) }.disabled(password.isEmpty)
                    }
                    Section(tr("Marca de agua de texto")) {
                        TextField(tr("Texto (hasta 200 caracteres)"), text: $watermark)
                        Picker(tr("Posición"), selection: $placement) { ForEach(AdvancedWatermarkPlacement.allCases) { Text(tr($0.rawValue)).tag($0) } }
                        Slider(value: $opacity, in: 0.05...1) { Text(tr("Opacidad")) }
                        Toggle(tr("Aplicar a todas las páginas"), isOn: $watermarkAll)
                        Button(tr("Añadir marca de agua")) { lib.advancedWatermark(text: watermark, placement: placement, opacity: opacity, allPages: watermarkAll) }.disabled(watermark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section(tr("Recorte por márgenes (%)")) {
                        Text(tr("Porcentajes sobre la página original. Recorte visual: no elimina información confidencial.")).font(.caption).foregroundStyle(.secondary)
                        HStack { TextField(tr("Izquierda"), value: $left, format: .number); TextField(tr("Derecha"), value: $right, format: .number) }
                        HStack { TextField(tr("Arriba"), value: $top, format: .number); TextField(tr("Abajo"), value: $bottom, format: .number) }
                        Toggle(tr("Recortar todas las páginas"), isOn: $cropAll)
                        Button(tr("Aplicar recorte")) { lib.advancedCrop(left: left, right: right, top: top, bottom: bottom, allPages: cropAll) }
                        Button(tr("Restaurar página completa")) { lib.advancedCrop(left: 0, right: 0, top: 0, bottom: 0, allPages: cropAll) }
                    }
                    Section(tr("Extraer y exportar")) {
                        TextField(tr("Páginas, por ejemplo 1,3-5"), text: $range)
                        Button(tr("Extraer páginas a PDF…")) { lib.advancedExtract(range: range) }
                        Button(tr("Exportar todas las páginas como PNG…")) { lib.advancedExportImages() }
                        Button(tr("Imprimir…")) { lib.advancedPrint() }
                    }
                }.formStyle(.grouped)
            }
            if let error = lib.error { Text(trStatus(error)).foregroundStyle(.red).textSelection(.enabled); Button(tr("Descartar error")) { lib.error = nil } }
            Text(trStatus(lib.message)).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 560, height: 700).disabled(lib.document == nil || lib.busy)
    }
}

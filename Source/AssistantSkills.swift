import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// Stable dispatch IDs: titles may be translated without changing behavior.
enum AssistantSkill: Int, CaseIterable, Identifiable {
    case enhance, word, pdf, text, edit, erase, handwriting, translate, watermark, images, formulas, aiImage, tamper, excel, ppt, markdown, office, html, research
    var id: Int { rawValue }
    var prompt: String {
        switch self {
        case .edit, .office: return "Edit the supplied document text for clarity. Preserve names, dates and figures. Return the revised text and a short change log. Follow any additional user instructions."
        case .translate: return "Translate the supplied document into the target language requested by the user (Spanish by default). Preserve headings, names, numbers and tables. Identify unreadable passages instead of guessing."
        case .formulas: return "Extract mathematical formulas from the supplied OCR text as LaTeX. Explain symbols using only the source. List page references and ambiguous OCR symbols. Do not solve an unreadable expression by guessing."
        case .markdown: return "Convert the supplied document text to Markdown, preserving headings, lists and tables. Return the Markdown source, without an enclosing code fence. Do not add facts."
        case .html: return "Create a self-contained HTML document visualizing only the supplied information. Use semantic HTML, inline CSS and accessible tables. No scripts, iframes, remote URLs, forms, embedded media or external resources. Return only HTML without a code fence."
        case .research: return "Research the user's question exclusively within the supplied local documents. Provide findings, a comparison, source filenames and page references, contradictions, gaps and follow-up questions. You have no internet access: do not invent links, current facts, citations or pretend to search the web."
        default: return "Analyze only the supplied document and follow the user's request."
        }
    }
    var note: String {
        switch self {
        case .formulas: return "Extracción desde OCR: revisa símbolos y fórmulas complejas con el original."
        case .research: return "Investiga fuentes locales y, si lo activas, páginas web públicas con referencias."
        case .html: return "Genera código HTML para guardar. No se ejecuta dentro de ScanMac."
        case .edit, .office: return "Edita y exporta una copia del texto. No reemplaza el diseño original del PDF."
        default: return "Elige un documento o escribe el texto. Revisa el resultado antes de exportarlo."
        }
    }
}

/// Technical inspection is deliberately separated from unsupported authenticity claims.
enum LocalDocumentInspection {
    static func report(_ document: PDFDocument, name: String, ai: Bool) -> String {
        var rows = ["ScanMac — \(ai ? "Revisión de procedencia de imagen" : "Inspección técnica de PDF")", "Documento: \(name)", "Páginas: \(document.pageCount)", "Cifrado: \(document.isEncrypted ? "sí" : "no")"]
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .creatorAttribute, .producerAttribute, .creationDateAttribute, .modificationDateAttribute] {
            if let value = document.documentAttributes?[key] { rows.append("\(key.rawValue): \(value)") }
        }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            rows.append("Página \(i+1): \(Int(box.width)) × \(Int(box.height)) pt; giro \(page.rotation)°; \(page.annotations.count) anotaciones; \((page.string ?? "").count) caracteres de texto.")
            for annotation in page.annotations { rows.append("  Anotación: \(annotation.type ?? "desconocida")") }
        }
        rows.append(ai ? "Metadatos: procedencia IA indeterminada. Este apartado no clasifica imágenes; la puntuación del modelo se muestra por separado." : "Resultado: autenticidad indeterminada. Metadatos y anotaciones pueden cambiar legítimamente o eliminarse. No se validan firmas digitales, historial de edición ni integridad frente a un original.")
        return rows.joined(separator: "\n")
    }
}

struct AssistantInspectionView: View {
    @EnvironmentObject var lib: Library
    let ai: Bool
    @State private var report = ""
    @State private var external: Data?
    @State private var reference: Data?
    @State private var visual: Data?
    @State private var secondary: Data?
    @State private var difference: Data?
    @State private var busy = false
    @State private var pageIndex = 0
    @State private var request: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ai ? "Detector local de imágenes IA" : "Análisis local de alteraciones").font(.title2.bold())
            AssistantDocumentPicker().disabled(busy)
            HStack {
                Button("Abrir imagen original…") { external = choose(); clear() }.disabled(busy)
                Button("Usar página del PDF") { external = nil; clear() }.disabled(busy || lib.document == nil)
                if !ai { Button("Comparar con original…") { reference = choose() }.disabled(busy); if reference != nil { Button("Quitar comparación") { reference = nil } } }
                if external == nil { Stepper("Página \(pageIndex+1)", value: $pageIndex, in: 0...max(0,(lib.document?.pageCount ?? 1)-1)).disabled(busy) }
            }
            Text(ai ? "Community Forensics: puntuación experimental de clase sintética. Usa la imagen original; los escaneos y capturas pueden dar falsos resultados. No certifica autenticidad." : "Mapas ELA, patrones repetidos y comparación de píxeles con un original opcional. Son indicios; texto, compresión y motivos repetidos pueden producir falsas alarmas.").font(.callout).foregroundStyle(.secondary)
            HStack { Button(ai ? "Analizar imagen con detector" : "Analizar alteraciones") { analyze() }.disabled(busy || (external == nil && lib.document == nil)); if busy { ProgressView().controlSize(.small); Button("Cancelar") { request?.cancel() } }; Text(LocalImageEngines.available ? "Motores locales disponibles" : "Faltan motores · MOTORES-LOCALES.txt").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading) {
                    Text(report).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let visual, let image = NSImage(data: visual) { Text("Mapa ELA · intensidad relativa").font(.headline); Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 330) }
                    if let secondary, let image = NSImage(data: secondary) { Text("Patrones repetidos").font(.headline); Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 330) }
                    if let difference, let image = NSImage(data: difference) { Text("Diferencias frente al original").font(.headline); Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 330) }
                }
            }
            Button("Guardar informe…") { AssistantExport.save(report, ext: "txt") }.disabled(report.isEmpty || busy)
        }.padding(30).onChange(of: lib.selected) { _, _ in request?.cancel(); external = nil; pageIndex = 0; clear() }.onDisappear { request?.cancel() }
    }
    private func clear() { report = ""; visual = nil; secondary = nil; difference = nil }
    private func choose() -> Data? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; guard panel.runModal() == .OK, let url = panel.url else { return nil }; return try? Data(contentsOf: url)
    }
    private func analyze() {
        do {
            let data: Data
            if let external { data = external }
            else if let page = lib.document?.page(at: pageIndex) { data = try LocalImageEngines.png(ScanEnhancementEngine.renderPage(page)) }
            else { return }
            let metadata = external == nil ? LocalDocumentInspection.report(lib.document!, name: lib.current?.name ?? "Documento", ai: ai) + "\n\nResultado del motor de imagen:\n" : "Imagen externa original · procesamiento local\n"
            clear(); busy = true
            request = Task { @MainActor in
                defer { busy = false }
                do { let result = try await LocalImageEngines.run(operation: ai ? "ai" : "tamper", image: data, reference: reference); try Task.checkCancellation(); report = metadata + result.report; visual = result.image; secondary = result.secondary; difference = result.difference }
                catch is CancellationError { report = "Análisis cancelado." }
                catch { report = error.localizedDescription }
            }
        } catch { report = error.localizedDescription }
    }
}

struct AssistantDocumentPicker: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        Picker("Documento", selection: Binding<UUID?>(get: { lib.selected }, set: { if let id = $0 { lib.select(id) } })) {
            Text("Elige un documento").tag(Optional<UUID>.none)
            ForEach(lib.records.filter { $0.trashedAt == nil }) { record in Text(record.name).tag(Optional(record.id)) }
        }.disabled(lib.busy)
    }
}

enum AssistantExport {
    @MainActor static func save(_ text: String, ext: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ScanMac-resultado." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if ext == "docx" { try DocumentConversions.docx(text, to: url) }
            else { try text.write(to: url, atomically: true, encoding: .utf8) }
        } catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}

/// Manual visual cleanup exports a flattened copy; original library document is untouched.
struct AssistantCleanupView: View {
    @EnvironmentObject var lib: Library
    let handwriting: Bool
    @State private var pageIndex = 0
    @State private var masks: [Int: [CGRect]] = [:]
    @State private var drag: CGRect?
    @State private var message = ""
    @State private var prepared: [Int: Data] = [:]
    @State private var showResult = false
    @State private var processing = false
    @State private var request: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(handwriting ? "Quitar escritura a mano" : "Borrar marcas").font(.title2.bold())
            AssistantDocumentPicker().disabled(processing)
            Text("Propón zonas con la IA local o selecciónalas arrastrando. LaMa reconstruye el fondo; revisa antes de exportar. No recupera texto oculto con certeza y puede afectar contenido superpuesto.").foregroundStyle(.secondary)
            HStack {
                Button("Proponer zonas con IA local") { propose() }.disabled(processing || lib.document == nil)
                Button("Limpiar tinta de color") { reconstruct(color: true) }.disabled(processing || lib.document == nil)
                Button("Reconstruir fondo de zonas") { reconstruct(color: false) }.disabled(processing || (masks[pageIndex] ?? []).isEmpty)
                Toggle("Ver resultado", isOn: $showResult).disabled(prepared[pageIndex] == nil)
                if processing { ProgressView().controlSize(.small); Button("Cancelar") { request?.cancel() } }
            }
            if let doc = lib.document, let page = doc.page(at: pageIndex) {
                HStack { Button("Anterior") { pageIndex -= 1 }.disabled(pageIndex == 0 || processing); Text("\(pageIndex+1) / \(doc.pageCount)"); Button("Siguiente") { pageIndex += 1 }.disabled(pageIndex+1 >= doc.pageCount || processing); Spacer(); Button("Deshacer zona") { if !(masks[pageIndex] ?? []).isEmpty { masks[pageIndex]?.removeLast(); prepared[pageIndex] = nil; showResult = false } }; Button("Restablecer") { masks = [:]; prepared = [:]; showResult = false }.disabled(processing) }
                GeometryReader { geo in
                    let box = page.bounds(for: .cropBox)
                    let rotated = abs(page.rotation % 180) == 90
                    let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
                    let scale = min(geo.size.width / max(1, size.width), geo.size.height / max(1, size.height))
                    let shown = CGSize(width: size.width * scale, height: size.height * scale)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: (showResult ? prepared[pageIndex].flatMap { NSImage(data: $0) } : nil) ?? page.thumbnail(of: CGSize(width: shown.width*2, height: shown.height*2), for: .cropBox)).resizable()
                        ForEach(Array((showResult ? [] : (masks[pageIndex] ?? [])).enumerated()), id: \.offset) { _, r in Rectangle().fill(.teal.opacity(0.35)).frame(width: r.width*shown.width, height: r.height*shown.height).offset(x: r.minX*shown.width, y: r.minY*shown.height) }
                        if let r = drag { Rectangle().fill(.white.opacity(0.65)).border(.teal).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY) }
                    }.frame(width: shown.width, height: shown.height).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 2).onChanged { value in drag = rect(value.startLocation, value.location, size: shown) }.onEnded { value in
                        let r = rect(value.startLocation, value.location, size: shown); drag = nil
                        if !processing && !showResult && r.width > 2 && r.height > 2 { prepared[pageIndex] = nil; masks[pageIndex, default: []].append(CGRect(x: r.minX/shown.width, y: r.minY/shown.height, width: r.width/shown.width, height: r.height/shown.height)) }
                    })
                }
                HStack { Button("Exportar copia PDF…") { export(doc) }.disabled(prepared.isEmpty || processing); Text(message).font(.caption) }
            } else { Text("Elige un documento para comenzar."); Spacer() }
        }.padding(24).onChange(of: lib.selected) { _, _ in pageIndex = 0; masks = [:]; prepared = [:]; message = ""; request?.cancel() }.onDisappear { request?.cancel() }
    }
    private func propose() {
        guard let page = lib.document?.page(at: pageIndex), let image = try? ScanEnhancementEngine.renderPage(page) else { return }
        let index = pageIndex; processing = true; message = "Buscando trazos con el modelo de visión local…"
        request = Task { @MainActor in
            defer { processing = false }
            do { let zones = try await LocalImageEngines.proposeZones(image, handwriting: handwriting); try Task.checkCancellation(); masks[index] = zones; prepared[index] = nil; showResult = false; message = zones.isEmpty ? "La IA no encontró trazos con suficiente claridad. Puedes marcarlos manualmente." : "\(zones.count) zonas propuestas. Revísalas y pulsa Reconstruir fondo." }
            catch is CancellationError { message = "Cancelado." }
            catch { message = error.localizedDescription }
        }
    }
    private func reconstruct(color: Bool) {
        guard let page = lib.document?.page(at: pageIndex) else { return }
        do {
            let input = try LocalImageEngines.png(ScanEnhancementEngine.renderPage(page)), index = pageIndex, zones = masks[pageIndex] ?? []
            processing = true; message = "Reconstruyendo fondo con LaMa local…"
            request = Task { @MainActor in
                defer { processing = false }
                do { let result = try await LocalImageEngines.run(operation: "cleanup", image: input, zones: zones, colorMask: color); try Task.checkCancellation(); prepared[index] = result.image; showResult = true; message = result.report }
                catch is CancellationError { message = "Cancelado." }
                catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
    private func rect(_ a: CGPoint, _ b: CGPoint, size: CGSize) -> CGRect {
        let x1 = min(size.width,max(0,a.x)), x2 = min(size.width,max(0,b.x)), y1 = min(size.height,max(0,a.y)), y2 = min(size.height,max(0,b.y))
        return CGRect(x: min(x1,x2), y: min(y1,y2), width: abs(x2-x1), height: abs(y2-y1))
    }
    private func export(_ doc: PDFDocument) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "ScanMac-limpio.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let output = PDFDocument()
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { throw CocoaError(.fileReadCorruptFile) }
                if let data = prepared[i], let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    output.insert(try ScanEnhancementEngine.replacement(image: image, source: page), at: output.pageCount)
                } else {
                    guard (masks[i] ?? []).isEmpty else { throw LocalImageEngines.failure("Hay zonas sin reconstruir en la página \(i+1). Procesa la vista previa antes de exportar.") }
                    if let copy = page.copy() as? PDFPage { output.insert(copy, at: output.pageCount) }
                }
            }
            guard let data = output.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: url, options: .atomic)
            message = "Copia exportada. Original conservado."
        } catch { message = error.localizedDescription }
    }
}

struct AssistantHTMLPreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'; form-action 'none'; frame-src 'none'; base-uri 'none'\">" + html, baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

enum AssistantCleanupEngine {
    static func page(_ page: PDFPage, zones: [CGRect]) throws -> PDFPage {
        let image = try ScanEnhancementEngine.renderPage(page)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); ctx.setFillColor(NSColor.white.cgColor)
        for zone in zones { ctx.fill(CGRect(x: zone.minX*w, y: (1-zone.maxY)*h, width: zone.width*w, height: zone.height*h)) }
        guard let flattened = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return try ScanEnhancementEngine.replacement(image: flattened, source: page)
    }
}

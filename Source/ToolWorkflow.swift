import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor final class ToolSession: ObservableObject {
    let source: UUID
    let name: String
    @Published var document: PDFDocument
    @Published var selected: Set<Int> = []
    @Published var range = ""
    @Published var revision = UUID()
    @Published var running = false
    @Published var started = false
    @Published var text = ""
    @Published var textEdited = false
    @Published var recognitionNote = ""
    @Published var result: URL?
    @Published var error: String?
    @Published var saved = false
    var history: [Data] = []
    init(source: UUID, name: String, document: PDFDocument) { self.source = source; self.name = name; self.document = document }
    func checkpoint() { if let data = document.dataRepresentation() { history.append(data) }; saved = false }
    func rotate() { guard !selected.isEmpty else { return }; checkpoint(); for i in selected { if let page = document.page(at: i) { page.rotation = (page.rotation + 90) % 360 } }; revision = UUID() }
    func delete() { guard !selected.isEmpty, selected.count < document.pageCount else { return }; checkpoint(); for i in selected.sorted(by: >) { document.removePage(at: i) }; selected = []; revision = UUID() }
    func reorder(from: Int, to: Int) { guard from != to, let page = document.page(at: from), (0..<document.pageCount).contains(to) else { return }; checkpoint(); document.removePage(at: from); document.insert(page, at: to); selected = []; revision = UUID() }
    func undo() { guard let data = history.popLast(), let previous = PDFDocument(data: data) else { return }; document = previous; selected = []; revision = UUID(); saved = false }
    func selectRange() { do { selected = Set(try Library.advancedPageIndexes(range, pageCount: document.pageCount)) } catch { self.error = error.localizedDescription } }
    func convert(_ tool: LandingTool, configuration: OCRConfiguration) {
        guard !started, let data = document.dataRepresentation() else { return }; started = true; running = true
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) { () -> (URL, String, String) in
                    guard let snapshot = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                    let pages = try LayoutDocumentConverter.recognize(document: snapshot, configuration: configuration)
                    let text = pages.map { LayoutDocumentConverter.rows($0.boxes).map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n") }.joined(separator: "\n\n")
                    let ext = tool == .word ? "docx" : tool == .excel ? "xlsx" : tool == .ppt ? "pptx" : "txt"
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScanMac-Result-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("Result." + ext)
                    switch tool { case .word: try LayoutDocumentConverter.docx(pages: pages, to: url); case .excel: try LayoutDocumentConverter.xlsx(pages: pages, to: url); case .ppt: try LayoutDocumentConverter.pptx(pages: pages, to: url); default: try text.write(to: url, atomically: true, encoding: .utf8) }
                    let native = pages.filter(\.usedNativeText).count
                    let uncertain = pages.filter { !$0.usedNativeText && $0.meanConfidence < 0.75 }.count
                    let note = "Texto digital conservado: \(native)/\(pages.count) páginas. OCR: \(pages.count-native)." + (uncertain > 0 ? " Revisa \(uncertain) páginas con confianza OCR baja." : "")
                    return (url, text, note)
                }.value
                result = output.0; text = output.1; recognitionNote = output.2; textEdited = false
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
    func saveResult(tool: LandingTool) {
        guard let result else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name + "." + result.pathExtension; panel.allowedContentTypes = [UTType(filenameExtension: result.pathExtension) ?? .data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { if textEdited && tool == .word { try DocumentConversions.docx(text, to: target) } else if textEdited && tool == .text { try text.write(to: target, atomically: true, encoding: .utf8) } else { try Data(contentsOf: result).write(to: target, options: .atomic) }; saved = true } catch { self.error = error.localizedDescription }
    }
    func exportPDF(extract: Bool = false) {
        let targetDoc: PDFDocument
        if extract { targetDoc = PDFDocument(); for i in selected.sorted() { if let page = document.page(at: i)?.copy() as? PDFPage { targetDoc.insert(page, at: targetDoc.pageCount) } } }
        else { targetDoc = document }
        guard targetDoc.pageCount > 0 else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = name + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { guard let data = targetDoc.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: url, options: .atomic); saved = true; result = url } catch { self.error = error.localizedDescription }
    }
    func appendFiles(_ urls: [URL]) {
        var added: [PDFPage] = []
        for url in urls {
            if let pdf = PDFDocument(url: url), !pdf.isLocked { for i in 0..<pdf.pageCount { if let page = pdf.page(at: i)?.copy() as? PDFPage { added.append(page) } } }
            else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) { added.append(page) }
            else { error = tr("No se encontraron páginas compatibles. ") + url.lastPathComponent; return }
        }
        guard !added.isEmpty else { return }; checkpoint()
        for page in added { document.insert(page, at: document.pageCount) }; revision = UUID()
    }
    func exportImages() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = tr("Exportar aquí")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let folder = directory.appendingPathComponent("ScanMac-PNG-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for i in 0..<document.pageCount { try autoreleasepool {
                guard let page = document.page(at: i) else { throw CocoaError(.fileReadCorruptFile) }
                let box = page.bounds(for: .cropBox); let scale = min(2, 3000 / max(1, max(box.width, box.height)))
                let image = page.thumbnail(of: CGSize(width: box.width*scale, height: box.height*scale), for: .cropBox)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: folder.appendingPathComponent(String(format: "Page-%04d.png", i+1)), options: .atomic)
            } }
            result = folder; saved = true
        } catch { self.error = error.localizedDescription }
    }
}

struct ToolWorkflowView: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    let tool: LandingTool
    @ObservedObject var session: ToolSession
    private var conversion: Bool { [.word, .excel, .ppt, .text].contains(tool) }
    var body: some View {
        Group {
            if conversion { conversionView }
            else { pagesView }
        }.padding(24).background(Color(red: 0.985, green: 0.985, blue: 0.993))
        .task { if conversion { session.convert(tool, configuration: lib.ocrConfiguration) } }
        .alert(tr("ScanMac"), isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) { Button(tr("OK")) { session.error = nil } } message: { Text(session.error ?? "") }
    }
    private var conversionView: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Label(session.name, systemImage: "doc.richtext.fill").font(.headline)
                ToolPDFPreview(document: session.document)
            }.padding(18).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 16) {
                HStack { Label(session.name, systemImage: tool.symbol).font(.headline).foregroundStyle(tool.color); Spacer(); Button { session.saveResult(tool: tool) } label: { Image(systemName: "arrow.down.to.line") }.disabled(session.result == nil); Button(tr("Abrir")) { if let result = session.result { NSWorkspace.shared.open(result) } }.buttonStyle(.borderedProminent).disabled(session.result == nil) }
                Divider()
                if session.running { Spacer(); ProgressView(tr("Reconociendo y reconstruyendo…")).frame(maxWidth: .infinity); Spacer() }
                else {
                    if [.word, .text].contains(tool) { TextEditor(text: Binding(get: { session.text }, set: { session.text = $0; session.textEdited = true })).font(.system(size: 15)).padding(10) }
                    else { ScrollView { Text(session.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) } }
                    HStack {
                        Button(tr("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.text, forType: .string) }.disabled(session.text.isEmpty)
                        if tool == .text { Button(tr("Word (.docx)")) { saveEditedWord() }.disabled(session.text.isEmpty) }
                        Spacer(); Button(tr("Convertir")) { session.started = false; session.convert(tool, configuration: lib.ocrConfiguration) }
                    }
                    Text(session.recognitionNote).font(.caption).foregroundStyle(.secondary)
                    Text(tr("Reconstrucción local aproximada")).font(.caption).foregroundStyle(.secondary)
                }
                Button(tr("Choose a document")) { ui.toolSessions.removeValue(forKey: tool) }.buttonStyle(.plain).foregroundStyle(scanGreen)
            }.padding(18).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 20))
        }
    }
    private var pagesView: some View {
        VStack(spacing: 20) {
            HStack { Label(tr(tool.rawValue), systemImage: tool.symbol).font(.title2.weight(.semibold)).foregroundStyle(tool.color); Spacer(); Button(tr("Choose a document")) { ui.toolSessions.removeValue(forKey: tool) } }
            Text(tr(tool == .reorder ? "Drag to rearrange pages. Hold Command or Shift to select multiple pages." : tool.subtitle)).font(.system(size: 16)).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190))], spacing: 26) {
                    ForEach(0..<session.document.pageCount, id: \.self) { i in
                        Button { if session.selected.contains(i) { session.selected.remove(i) } else { session.selected.insert(i) } } label: {
                            VStack(spacing: 8) {
                                if let page = session.document.page(at: i) { Image(nsImage: page.thumbnail(of: NSSize(width: 150, height: 195), for: .cropBox)).resizable().scaledToFit().frame(height: 195).shadow(color: .black.opacity(0.06), radius: 3) }
                                Text(String(i+1)).foregroundStyle(.secondary)
                            }.padding(10).overlay(RoundedRectangle(cornerRadius: 4).stroke(session.selected.contains(i) ? scanGreen : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).draggable(String(i)).dropDestination(for: String.self) { values, _ in guard [.reorder, .merge].contains(tool), let value = values.first, let from = Int(value) else { return false }; session.reorder(from: from, to: i); return true }
                    }
                }.padding(26)
            }.id(session.revision)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                if tool == .merge { Button(tr("Añadir archivo")) { let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf, .image]; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { session.appendFiles(panel.urls) } } }
                if [.reorder, .extract].contains(tool) {
                    TextField(tr("Seleccionar rango: 1,3-5"), text: $session.range).frame(width: 190).textFieldStyle(.roundedBorder).onSubmit { session.selectRange() }
                    Button(tr("Seleccionar")) { session.selectRange() }
                    Button(tr("Todas")) { session.selected = Set(0..<session.document.pageCount) }
                }
                if tool == .reorder {
                    Button { session.rotate() } label: { Image(systemName: "rotate.right") }.help(tr("Girar selección")).disabled(session.selected.isEmpty)
                    Button { session.delete() } label: { Image(systemName: "trash") }.help(tr("Eliminar selección")).disabled(session.selected.isEmpty || session.selected.count >= session.document.pageCount)
                    Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help(tr("Deshacer")).disabled(session.history.isEmpty)
                }
                Spacer()
                if session.saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(scanGreen) }
                if tool == .images { Button(tr("Exportar todas las páginas como PNG…")) { session.exportImages() }.buttonStyle(.borderedProminent) }
                else if tool == .extract { Button(tr("Extraer páginas a PDF…")) { session.exportPDF(extract: true) }.buttonStyle(.borderedProminent).disabled(session.selected.isEmpty) }
                else { Button(tr("Save")) { session.exportPDF() }.buttonStyle(.borderedProminent) }
            }
        }.padding(28).background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 20)).frame(maxWidth: 1200).frame(maxWidth: .infinity)
    }
    private func saveEditedWord() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.name + ".docx"; panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DocumentConversions.docx(session.text, to: url) } catch { session.error = error.localizedDescription }
    }
}
struct ToolPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.backgroundColor = .white; view.document = document; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

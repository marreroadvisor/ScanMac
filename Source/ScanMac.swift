import SwiftUI
import AppKit
import PDFKit
import Vision
import CoreImage
import UniformTypeIdentifiers

struct DocumentState { let data: Data; let text: String; let signed: Bool? }
struct DocumentSession { let history: [DocumentState]; let redo: [DocumentState]; let page: Int }

struct Record: Codable, Identifiable {
    var id: UUID
    var name: String
    var date: Date
    var starred: Bool = false
    var text: String = ""
    var folder: String?
    var tags: [String]?
    var trashedAt: Date?
    var signed: Bool?
    var updatedAt: Date?
    var sourceType: String?
    var passwordProtected: Bool?
}

@MainActor final class Library: ObservableObject {
    @Published var records: [Record] = []
    @Published var selected: UUID?
    @Published var document: PDFDocument?
    @Published var page = 0
    @Published var query = ""
    @Published var starredOnly = false
    @Published var busy = false
    @Published var message = tr("Listo · Tus documentos se guardan en este Mac")
    @Published var error: String?
    @Published var revision = UUID()
    @Published var history: [DocumentState] = []
    @Published var redoHistory: [DocumentState] = []
    @Published var rootFolderOnly = false
    @Published var folderFilter: String?
    @Published var trashOnly = false
    @Published var signedOnly = false
    @Published var sortByName = false
    @Published var folders: [String] = []
    @Published var librarySort = LibrarySort.editedNewest
    @Published var typeFilter = "All"
    @Published var tagFilter: Set<String> = []
    @Published var tagCatalog: [String] = []
    @Published var trashedFolders: [String] = []
    @Published var clipboard: LibraryClipboard?
    var unlockedPasswords: [UUID: String] = [:]
    @Published var ocrLanguages: [String] { didSet { let valid = OCRLanguageCatalog.validated(ocrLanguages); if ocrLanguages != valid { ocrLanguages = valid }; saveOCRConfiguration() } }
    @Published var ocrAutomaticallyDetectsLanguage: Bool { didSet { saveOCRConfiguration() } }
    private let ocrDefaults: UserDefaults
    var ocrConfiguration: OCRConfiguration {
        OCRConfiguration(languages: OCRLanguageCatalog.validated(ocrLanguages), automaticallyDetectsLanguage: ocrAutomaticallyDetectsLanguage)
    }
    private func saveOCRConfiguration() { OCRLanguageCatalog.save(ocrConfiguration, to: ocrDefaults) }
    @Published var zoom: Double = 1
    @Published var annotationMode = "Seleccionar"
    @Published var pendingInk: [[CGPoint]] = []
    @Published var stampWidth: Double = 180
    @Published var annotationText = "Texto"
    @Published var syncFolder: URL?
    weak var preview: PDFView?
    var sessions: [UUID: DocumentSession] = [:]
    let root: URL
    init(rootOverride: URL? = nil, ocrDefaults: UserDefaults = .standard) {
        self.ocrDefaults = ocrDefaults
        let configuration = OCRLanguageCatalog.load(from: ocrDefaults)
        ocrLanguages = configuration.languages
        ocrAutomaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
        root = rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScanMac", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let index = root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: index.path) {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: index))
            }
            let folderURL = root.appendingPathComponent("folders.json")
            if FileManager.default.fileExists(atPath: folderURL.path) { folders = try JSONDecoder().decode([String].self, from: Data(contentsOf: folderURL)) }
            if let data = try? Data(contentsOf: root.appendingPathComponent("trashed-folders.json")), let names = try? JSONDecoder().decode([String].self, from: data) { trashedFolders = names }
            folders = Array(Set(folders + records.filter { $0.trashedAt == nil }.compactMap { $0.folder })).filter { !trashedFolders.contains($0) }.sorted()
            if let data = try? Data(contentsOf: root.appendingPathComponent("tags.json")), let tags = try? JSONDecoder().decode([String].self, from: data) { tagCatalog = tags }
            for tag in records.flatMap({ $0.tags ?? [] }) where !tagCatalog.contains(tag) { tagCatalog.append(tag) }
        } catch { self.error = error.localizedDescription }
    }
    var current: Record? { records.first { $0.id == selected } }
    var filtered: [Record] { libraryRecords() }
    func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".pdf") }
    func saveIndex() throws { try JSONEncoder().encode(records).write(to: root.appendingPathComponent("library.json"), options: .atomic) }
    func storeSession() { if let id = selected { sessions[id] = DocumentSession(history: history, redo: redoHistory, page: page) } }
    func select(_ id: UUID) {
        if selected == id, document != nil { return }
        storeSession()
        guard let doc = PDFDocument(url: url(id)) else { error = tr("No se pudo abrir el documento."); return }
        if doc.isLocked {
            let alert = NSAlert(); alert.messageText = tr("PDF protegido")
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); alert.accessoryView = password
            alert.addButton(withTitle: tr("Abrir")); alert.addButton(withTitle: tr("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard doc.unlock(withPassword: password.stringValue) else { error = tr("Incorrect password"); return }
            unlockedPasswords[id] = password.stringValue
        }
        selected = id; document = doc; let saved = sessions[id]; page = min(saved?.page ?? 0, max(0, doc.pageCount - 1)); history = saved?.history ?? []; redoHistory = saved?.redo ?? []; revision = UUID()
    }
    func persist() {
        guard let id = selected, let data = document?.dataRepresentation(options: writeOptions(for: id)) else { error = tr("No se pudo guardar el PDF."); return }
        do { try data.write(to: url(id), options: .atomic); if let i = records.firstIndex(where: { $0.id == id }) { records[i].updatedAt = Date() }; try saveIndex(); revision = UUID() }
        catch { self.error = error.localizedDescription }
    }
    func update(_ action: (inout Record) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == selected }) else { return }
        action(&records[i]); records[i].updatedAt = Date(); do { try saveIndex() } catch { self.error = error.localizedDescription }
    }
    func chooseImport(append: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf, .image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, append: append)
    }
    func importFiles(_ urls: [URL], append: Bool = false) {
        let result = PDFDocument(); var failures: [String] = []
        for source in urls {
            if let pdf = PDFDocument(url: source), pdf.pageCount > 0 {
                if pdf.isLocked {
                    let alert = NSAlert(); alert.messageText = tr("PDF protegido"); alert.informativeText = tr("Contraseña para abrir ") + source.lastPathComponent
                    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); alert.accessoryView = password; alert.addButton(withTitle: tr("Abrir")); alert.addButton(withTitle: tr("Omitir"))
                    guard alert.runModal() == .alertFirstButtonReturn, pdf.unlock(withPassword: password.stringValue) else { failures.append(source.lastPathComponent + " (no desbloqueado)"); continue }
                }
                for n in 0..<pdf.pageCount { if let p = pdf.page(at: n)?.copy() as? PDFPage { result.insert(p, at: result.pageCount) } }
            } else if let image = NSImage(contentsOf: source), let p = PDFPage(image: image) { result.insert(p, at: result.pageCount) }
            else { failures.append(source.lastPathComponent) }
        }
        guard result.pageCount > 0 else { error = tr("No se encontraron páginas compatibles. ") + failures.joined(separator: ", "); return }
        if append, let doc = document {
            snapshot()
            for n in 0..<result.pageCount { if let p = result.page(at: n)?.copy() as? PDFPage { doc.insert(p, at: doc.pageCount) } }; invalidateText(); persist()
        } else {
            let id = UUID(); let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Documento \(Date().formatted(date: .abbreviated, time: .shortened))"
            guard let data = result.dataRepresentation() else { error = tr("No se pudo crear el PDF."); return }
            do {
                try data.write(to: url(id), options: .atomic)
                records.append(Record(id: id, name: name, date: Date(), folder: folderFilter, sourceType: urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" } ? "PDF" : "Scans")); try saveIndex(); select(id)
            } catch { self.error = error.localizedDescription }
        }
        message = tr("Se importaron {0} páginas", String(describing: result.pageCount))
        if !failures.isEmpty { error = tr("Algunos archivos no se importaron: ") + failures.joined(separator: ", ") }
    }
    func invalidateText() { update { $0.text = "" } }
    func exportPDF() {
        guard let doc = document else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = (current?.name ?? "Documento") + ".pdf"
        if panel.runModal() == .OK, let dest = panel.url {
            do { guard let data = doc.dataRepresentation(options: selected.map { writeOptions(for: $0) } ?? [:]) else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: dest, options: .atomic); message = tr("PDF exportado") }
            catch { self.error = error.localizedDescription }
        }
    }
    func exportText() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = (current?.name ?? "Documento") + ".txt"
        if panel.runModal() == .OK, let dest = panel.url {
            do { try (current?.text ?? "").write(to: dest, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
        }
    }
    func removeDocument() { storeSession(); update { $0.trashedAt = Date() }; selected = nil; document = nil; message = tr("Documento movido a la papelera") }
    func restoreDocument(_ id: UUID) { guard let i = records.firstIndex(where: { $0.id == id }) else { return }; records[i].trashedAt = nil; records[i].updatedAt = Date(); do { try saveIndex() } catch { self.error = error.localizedDescription } }
    func snapshot() { redoHistory = []; if let data = document?.dataRepresentation() { history.append(DocumentState(data: data, text: current?.text ?? "", signed: current?.signed)); if history.count > 12 { history.removeFirst() } } }
    func undo() { guard let state = history.popLast(), let doc = PDFDocument(data: state.data) else { return }; if let data = document?.dataRepresentation() { redoHistory.append(DocumentState(data: data, text: current?.text ?? "", signed: current?.signed)) }; document = doc; page = min(page, doc.pageCount - 1); update { $0.text = state.text; $0.signed = state.signed }; persist() }
    func redo() { guard let state = redoHistory.popLast(), let doc = PDFDocument(data: state.data) else { return }; if let data = document?.dataRepresentation() { history.append(DocumentState(data: data, text: current?.text ?? "", signed: current?.signed)) }; document = doc; page = min(page, doc.pageCount - 1); update { $0.text = state.text; $0.signed = state.signed }; persist() }
    func exportPage(image: Bool) {
        guard let p = document?.page(at: page) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = image ? [.png] : [.pdf]; panel.nameFieldStringValue = "Página-\(page + 1)." + (image ? "png" : "pdf")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if image { guard let cg = imageOfPage(p), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: destination, options: .atomic) }
            else { let doc = PDFDocument(); guard let copy = p.copy() as? PDFPage else { throw CocoaError(.fileWriteUnknown) }; doc.insert(copy, at: 0); guard let data = doc.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: destination, options: .atomic) }
            message = tr("Página exportada")
        } catch { self.error = error.localizedDescription }
    }
    func rotate() { guard let p = document?.page(at: page) else { return }; snapshot(); p.rotation = (p.rotation + 90) % 360; invalidateText(); persist() }
    func deletePage() {
        guard let doc = document, doc.pageCount > 1 else { return }; snapshot(); doc.removePage(at: page); page = min(page, doc.pageCount - 1); invalidateText(); persist()
    }
    func movePage(_ delta: Int) {
        guard let doc = document, let p = doc.page(at: page), (0..<doc.pageCount).contains(page + delta) else { return }
        snapshot(); doc.removePage(at: page); page += delta; doc.insert(p, at: page); invalidateText(); persist()
    }
    func annotate(_ text: String) {
        guard !text.isEmpty, let p = document?.page(at: page) else { return }
        snapshot()
        let b = p.bounds(for: .mediaBox)
        let a = PDFAnnotation(bounds: CGRect(x: b.minX + 30, y: b.minY + 30, width: max(30, b.width - 60), height: 55), forType: .freeText, withProperties: nil)
        a.contents = text; a.font = NSFont.systemFont(ofSize: 16); a.fontColor = .systemBlue; a.color = .clear; p.addAnnotation(a); persist()
    }
    func addSignature(_ image: NSImage) {
        guard let p = document?.page(at: page), let copy = p.copy() as? PDFPage else { return }
        let b = p.bounds(for: .mediaBox)
        let merged = NSImage(size: b.size)
        merged.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            NSColor.white.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: b.size)).fill()
            copy.draw(with: .mediaBox, to: context)
            image.draw(in: CGRect(x: 30, y: 25, width: min(220, b.width - 60), height: 75))
        }
        merged.unlockFocus()
        if let replacement = PDFPage(image: merged) { snapshot(); document?.removePage(at: page); document?.insert(replacement, at: page); invalidateText(); persist() }
    }
    func imageOfPage(_ p: PDFPage) -> CGImage? {
        let bounds = p.bounds(for: .mediaBox)
        let scale = min(2.0, 2400 / max(bounds.width, bounds.height))
        let image = p.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    func process(_ mode: String) {
        guard !busy, let p = document?.page(at: page), let cg = imageOfPage(p) else { return }
        let targetID = selected; let targetPage = page; let originalData = p.dataRepresentation; busy = true; message = tr("Procesando página…")
        DispatchQueue.global(qos: .userInitiated).async {
            var input = CIImage(cgImage: cg)
            var problem: String?
            if mode == "Recorte automático" {
                let request = VNDetectRectanglesRequest(); request.maximumObservations = 1; request.minimumConfidence = 0.6; request.minimumAspectRatio = 0.2
                do {
                    try VNImageRequestHandler(cgImage: cg).perform([request])
                    if let r = request.results?.first {
                        let s = input.extent.size
                        func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x * s.width, y: p.y * s.height) }
                        input = input.applyingFilter("CIPerspectiveCorrection", parameters: ["inputTopLeft": v(r.topLeft), "inputTopRight": v(r.topRight), "inputBottomLeft": v(r.bottomLeft), "inputBottomRight": v(r.bottomRight)])
                    } else { problem = tr("No se detectó un borde de documento. La página no cambió.") }
                } catch { problem = error.localizedDescription }
            } else {
                input = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: mode == "Color mejorado" ? 1.1 : 0, kCIInputContrastKey: mode == "Blanco y negro" ? 2.4 : 1.25, kCIInputBrightnessKey: 0.025])
            }
            let output = CIContext().createCGImage(input, from: input.extent)
            DispatchQueue.main.async {
                defer { self.busy = false }
                guard self.selected == targetID else { return }
                if let problem { self.error = problem; self.message = tr("Listo"); return }
                guard let output, let originalData, let original = PDFDocument(data: originalData)?.page(at: 0), let replacement = try? ScanEnhancementEngine.replacement(image: output, source: original) else { self.error = tr("No se pudo procesar la imagen."); return }
                self.snapshot(); self.document?.removePage(at: targetPage); self.document?.insert(replacement, at: targetPage); self.invalidateText(); self.persist(); self.message = tr("{0} aplicado · La página se convirtió en imagen", String(describing: mode))
            }
        }
    }
    func recognize() { recognizeSearchable() }

}

final class SignatureModel: ObservableObject { @Published var paths: [[CGPoint]] = [] }
struct SignaturePad: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @ObservedObject var model: SignatureModel
    var body: some View {
        Canvas { context, _ in
            for points in model.paths { var path = Path(); if let first = points.first { path.move(to: first); for p in points.dropFirst() { path.addLine(to: p) } }; context.stroke(path, with: .color(.black), lineWidth: 3) }
        }.background(.white).gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if value.translation == .zero { model.paths.append([value.location]) } else if !model.paths.isEmpty { model.paths[model.paths.count - 1].append(value.location) }
        })
    }
}
@main struct ScanMacApp: App {
    @StateObject private var appLanguage = AppLanguageSettings.shared
    @StateObject var lib = Library(rootOverride: DemoLibrary.root)
    var body: some Scene {
        WindowGroup { MainView().environmentObject(lib).environmentObject(appLanguage).environment(\.locale, appLanguage.locale).environment(\.layoutDirection, appLanguage.language.isRightToLeft ? .rightToLeft : .leftToRight).onAppear { lib.restoreSyncLocation() }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appLanguage.refreshSystemLanguage() }.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in LocalCloudServer.shared.stop(); DemoLibrary.cleanup() }.onOpenURL { lib.importFiles([$0]) } }
        .windowStyle(.hiddenTitleBar).defaultSize(width: 1440, height: 900)
        .commands {
            CommandMenu(tr("Languages")) {
                Button(tr("Interface language")) { NotificationCenter.default.post(name: Notification.Name("ScanMac.languageSettings"), object: "interface") }.disabled(lib.busy)
                Button(tr("OCR languages")) { NotificationCenter.default.post(name: Notification.Name("ScanMac.languageSettings"), object: "ocr") }.disabled(lib.busy)
            }
            CommandGroup(replacing: .newItem) {
                Button(tr("Importar documento…")) { lib.chooseImport() }.keyboardShortcut("o")
                Button(tr("Exportar PDF…")) { lib.exportPDF() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(lib.document == nil)
            }
        }
    }
}

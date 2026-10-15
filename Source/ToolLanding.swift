import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import WebKit

enum LandingTool: String, CaseIterable, Identifiable {
    case word = "To Word", excel = "To Excel", ppt = "To PPT", images = "To Images", pdf = "To PDF", text = "Extract Text", merge = "Merge Files", extract = "Extract Pages", reorder = "Reorder Pages"
    var id: String { rawValue }
    var demoKey: String { switch self { case .word: return "word"; case .excel: return "excel"; case .ppt: return "ppt"; case .pdf: return "pdf"; case .images: return "images"; case .text: return "text"; case .merge: return "merge"; case .extract: return "extract"; case .reorder: return "reorder" } }
    var symbol: String {
        switch self { case .word: return "doc.text.fill"; case .excel: return "tablecells.fill"; case .ppt: return "rectangle.stack.fill"; case .images: return "photo.on.rectangle.fill"; case .pdf: return "doc.richtext.fill"; case .text: return "text.viewfinder"; case .merge: return "arrow.down.right.and.arrow.up.left"; case .extract: return "doc.badge.arrow.up"; case .reorder: return "arrow.up.arrow.down" }
    }
    var color: Color { switch self { case .excel: return .green; case .ppt: return Color(red: 1, green: 0.48, blue: 0.38); case .pdf, .merge: return .orange; case .text: return scanGreen; default: return .blue } }
    var acceptsImages: Bool { ![.images, .merge, .extract, .reorder].contains(self) }
    var subtitle: String {
        switch self {
        case .word: return "Convert recognized text to an editable Word document."
        case .excel: return "Reconstruct rows and columns using local OCR."
        case .ppt: return "Reconstruct editable text boxes in PowerPoint."
        case .images: return "Export PDF pages as images."
        case .pdf: return "To PDF · Import text or Word"
        case .text: return "Recognize and copy text from scanned documents."
        case .merge: return "Merge multiple documents into one."
        case .extract: return "Create a new document from selected pages."
        case .reorder: return "Reorder, delete, duplicate or rotate pages."
        }
    }
}

struct ToolLandingView: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    let tool: LandingTool
    @State private var choosing = false
    @State private var hovering = false
    @State private var search = ""
    @State private var selection: UUID?
    var body: some View {
        Group { if let session = ui.toolSessions[tool] { ToolWorkflowView(tool: tool, session: session) } else { landingView } }.id(tool)
    }
    private var landingView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 16) { ToolIcon(tool: tool, size: 32); Text(tr(tool.rawValue)).fontWeight(.semibold) }.font(.system(size: 28)).padding(.top, 28)
                    Text(tr(tool.subtitle)).font(.system(size: 18)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 12)
                    HStack(spacing: 32) {
                        ToolTutorial(tool: tool).frame(width: 293, height: 480)
                        importArea.frame(maxWidth: .infinity).frame(height: 480)
                    }.padding(.top, 34)
                    Label(tr("Local"), systemImage: "checkmark.shield").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 14)
                    Spacer(minLength: 36)
                }.frame(maxWidth: 1200).padding(.horizontal, 32).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height, alignment: .top)
            }
        }.background(Color(red: 0.985, green: 0.985, blue: 0.993))
        .sheet(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(tr("Choose a document")).font(.title2.bold()); Spacer(); Button(tr("Cancel")) { choosing = false } }
                TextField(tr("Search my files…"), text: $search).textFieldStyle(.roundedBorder)
                List(lib.records.filter { $0.trashedAt == nil && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { record in
                    Button { selection = record.id } label: { HStack { Image(systemName: selection == record.id ? "checkmark.circle.fill" : "doc.fill").foregroundStyle(scanGreen); Text(record.name); Spacer() }.padding(6).contentShape(Rectangle()) }.buttonStyle(.plain)
                }
                HStack { Spacer(); Button(tr("OK")) { if let id = selection { lib.select(id); choosing = false; ui.finishLanding(tool, library: lib) } }.buttonStyle(.borderedProminent).disabled(selection == nil) }
            }.padding(24).frame(width: 560, height: 420)
        }
    }
    private var importArea: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(scanGreen.opacity(0.5))
                .frame(width: 160, height: 156).padding(.bottom, 28)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { importButtons }
                VStack(spacing: 12) { importButtons }
            }.padding(.horizontal, 24)
            Text(tr("Drag files here, or click to import")).font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 26)
            Spacer()
        }.frame(maxWidth: .infinity).background(hovering ? scanGreen.opacity(0.05) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(scanGreen.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .dropDestination(for: URL.self) { urls, _ in importURLs(urls); return !urls.isEmpty } isTargeted: { hovering = $0 }
    }
    @ViewBuilder private var importButtons: some View {
        if tool.acceptsImages { importButton(tr("Import Images"), primary: true) { pick(images: true) } }
        importButton(tr("Import Files"), primary: !tool.acceptsImages) { pick(images: false) }
        importButton(tr("Choose a document"), primary: false) { choosing = true }
    }
    private func importButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center).frame(width: 200, height: 44).foregroundStyle(primary ? Color.white : Color.primary).background(primary ? scanGreen : .white, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
    }
    private func pick(images: Bool) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = images ? [.image] : (tool == .pdf ? [.pdf, .plainText, .rtf, .html, UTType(filenameExtension: "docx")!] : [.pdf])
        guard panel.runModal() == .OK else { return }; importURLs(panel.urls)
    }
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let previous = lib.selected
        if tool == .pdf, urls.contains(where: { !["pdf", "png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif"].contains($0.pathExtension.lowercased()) }) {
            // Rich text uses the same import engine as the existing To PDF action.
            guard urls.count == 1 else { lib.error = tr("Selecciona un documento"); return }
            lib.importRichText(source: urls[0])
        } else { lib.importFiles(urls) }
        if lib.document != nil && lib.selected != previous { ui.finishLanding(tool, library: lib) }
    }
}

extension WorkspaceState {
    func openLanding(_ tool: LandingTool) { assistantWorkspace = false; landing = tool; if !toolTabs.contains(tool) { toolTabs.append(tool) } }
    func finishLanding(_ tool: LandingTool, library: Library) {
        guard library.document != nil else { return }
        guard let id = library.selected, let name = library.current?.name, let data = library.document?.dataRepresentation(), let copy = PDFDocument(data: data) else { return }
        toolSessions[tool] = ToolSession(source: id, name: name, document: copy)
    }
}

// The tool-specific animation is rendered offline, with all network access blocked by CSP.
struct ToolTutorial: NSViewRepresentable {
    let tool: LandingTool
    var key: String { tool.demoKey }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration); view.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: key, withExtension: "html", subdirectory: "Demos") { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if let url = Bundle.main.url(forResource: key, withExtension: "html", subdirectory: "Demos"), view.url != url { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
    }
}

struct ToolIcon: View {
    let tool: LandingTool
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: tool.symbol).resizable().scaledToFit().foregroundStyle(tool.color)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

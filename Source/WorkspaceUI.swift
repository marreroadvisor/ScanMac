import SwiftUI
import AppKit
import PDFKit

let scanGreen = Color(red: 0.0, green: 0.70, blue: 0.58)
let scanCanvas = Color(red: 0.96, green: 0.96, blue: 0.97)

enum WorkspacePanel: String, Identifiable {
    case languages, ocrLanguages, assistant, pages, organize, pdf, convert, enhance, camera, scanner, idcard, folderSync, account, signature, chooseDocument, reconstruction
    var id: String { rawValue }
}
@MainActor final class WorkspaceState: ObservableObject {
    @Published var section = "Home"
    @Published var landing: LandingTool?
    @Published var toolTabs: [LandingTool] = []
    @Published var toolSessions: [LandingTool: ToolSession] = [:]
    @Published var editorTab = "View"
    @Published var tabs: [UUID] = []
    @Published var panel: WorkspacePanel?
    @Published var pendingPanel: WorkspacePanel?
    @Published var assistantWorkspace = false
    @Published var assistantTab = false
    func openAssistant() { assistantTab = true; assistantWorkspace = true; landing = nil }
    @Published var showAssistant = false
    @Published var showOCR = false
    @Published var showThumbnails = true
    @Published var outline = false
    @Published var grid = false
    @Published var pageSelection: Set<Int> = []
    @Published var range = ""
    @Published var rename = false
    @Published var note = false
    @Published var deletion = false
    @Published var input = ""
    @Published var documentSearch = ""
    @Published var searching = false
    @Published var showNotice = false
    func completeDocumentChoice() {
        if pendingPanel == .pages { editorTab = "Page"; panel = nil }
        else if pendingPanel == .assistant { editorTab = "View"; showAssistant = true; panel = nil }
        else { panel = pendingPanel }
        pendingPanel = nil
    }
    func require(_ panel: WorkspacePanel, library: Library) {
        if library.document != nil { if panel == .assistant { showAssistant = true; editorTab = "View" } else if panel == .pages { editorTab = "Page" } else { self.panel = panel } }
        else { pendingPanel = panel; self.panel = .chooseDocument }
    }
}

extension View {
    func scanCardShadow(radius: CGFloat = 12, enabled: Bool = true) -> some View {
        background {
            if enabled {
                RoundedRectangle(cornerRadius: radius).fill(Color.white)
                    .shadow(color: .black.opacity(0.055), radius: 4, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.035), radius: 1, x: 0, y: 1)
            }
        }
    }
}

struct ScanIconButton: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(width: 31, height: 30).background(active ? Color.black.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
struct ScanToolButton: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(tr(title), systemImage: symbol).font(.system(size: 14)).padding(.horizontal, 12).frame(height: 33).background(active ? Color.black.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? Color.black.opacity(0.08) : .clear)) }.buttonStyle(.plain)
    }
}
struct ScanBrand: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    var small = false
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .bottom) { RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.02, green: 0.11, blue: 0.15)); RoundedRectangle(cornerRadius: 3).fill(scanGreen).frame(height: 5); Text(tr("SM")).font(.system(size: small ? 10 : 12, weight: .heavy)).foregroundStyle(.white).padding(.bottom, 3) }
                .frame(width: small ? 22 : 27, height: small ? 22 : 27)
                // Scale the title-tab badge artwork and its layout footprint together.
                .scaleEffect(small ? 1 : 15.0 / 27.0)
                .frame(width: small ? 22 : 15, height: small ? 22 : 15)
            if !small { Text(tr("ScanMac")).font(.system(size: 16, weight: .medium)) }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @StateObject var ui = WorkspaceState()
    @StateObject var signature = SignatureModel()
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabs().environmentObject(ui)
            if ui.assistantWorkspace { AssistantWorkspaceView().environmentObject(ui) }
            else if let tool = ui.landing { ToolLandingView(tool: tool).environmentObject(ui) }
            else if lib.document != nil { DocumentWorkspace().environmentObject(ui) }
            else { HStack(spacing: 0) { WorkspaceSidebar().environmentObject(ui); LibraryWorkspace().environmentObject(ui) }.padding(.top, 10) }
            if lib.busy { HStack { ProgressView().controlSize(.small); Text(trStatus(lib.message)).font(.caption); Spacer() }.padding(8).background(.white) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(scanCanvas).foregroundStyle(Color(red: 0.13, green: 0.14, blue: 0.15)).tint(scanGreen)
        .frame(minWidth: 1120, minHeight: 740).preferredColorScheme(.light)
        .onChange(of: lib.selected) { _, id in if let id, !ui.tabs.contains(id) { ui.tabs.append(id) }; ui.pageSelection = []; ui.range = "" }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ScanMac.languageSettings"))) { notification in guard ui.panel == nil else { return }; ui.panel = notification.object as? String == "ocr" ? .ocrLanguages : .languages }
        .disabled(lib.busy)
        .sheet(item: $ui.panel) { panel in panelView(panel).environmentObject(lib).environmentObject(ui).environmentObject(appLanguage).environment(\.locale, appLanguage.locale).environment(\.layoutDirection, appLanguage.language.isRightToLeft ? .rightToLeft : .leftToRight) }
        .alert(tr("ScanMac"), isPresented: Binding(get: { lib.error != nil }, set: { if !$0 { lib.error = nil } })) { Button(tr("OK")) { lib.error = nil } } message: { Text(trStatus(lib.error ?? "")) }
        .alert(tr("Rename document"), isPresented: $ui.rename) { TextField(tr("Name"), text: $ui.input); Button(tr("Cancel"), role: .cancel) {}; Button(tr("Save")) { if !ui.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lib.update { $0.name = ui.input } } } }
        .alert(tr("Add text"), isPresented: $ui.note) { TextField(tr("Text"), text: $ui.input); Button(tr("Cancel"), role: .cancel) {}; Button(tr("Place text")) { lib.annotationText = ui.input; lib.annotationMode = "Texto"; lib.message = tr("Click the page to place text") } }
        .alert(tr("Move document to Trash?"), isPresented: $ui.deletion) { Button(tr("Cancel"), role: .cancel) {}; Button(tr("Move to Trash"), role: .destructive) { lib.removeDocument() } } message: { Text(tr("You can recover it from Trash.")) }
        .alert(tr("Local activity"), isPresented: $ui.showNotice) { Button(tr("OK")) {} } message: { Text(trStatus(lib.message)) }
    }
    @ViewBuilder func panelView(_ panel: WorkspacePanel) -> some View {
        switch panel {
        case .languages: InterfaceLanguageSettingsView()
        case .ocrLanguages: OCRLanguageSettingsView()
        case .assistant: LocalAssistantView().frame(width: 340, height: 620)
        case .pages: PageOrganizerPanel()
        case .organize: OrganizePanel()
        case .pdf: AdvancedPDFPanel()
        case .convert: ConversionPanel()
        case .enhance: EnhancementPanel()
        case .camera: CameraPanel()
        case .scanner: ScannerPanel()
        case .idcard: IDCardPanel()
        case .folderSync: SyncPanel()
        case .account: CloudAccountPanel()
        case .reconstruction: LayoutConversionPanel()
        case .signature:
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(tr("Electronic signature")).font(.title2.bold()); Spacer(); Button(tr("Close")) { ui.panel = nil } }
                Text(tr("Draw a signature, then click the document to place it.")).foregroundStyle(.secondary)
                SignaturePad(model: signature).frame(width: 520, height: 180).background(.white).border(Color.gray.opacity(0.2))
                HStack { Button(tr("Clear")) { signature.paths = [] }; Button(tr("Import signature image…")) { lib.chooseImageSignature(); ui.panel = nil }; Spacer(); Button(tr("Use signature")) { lib.pendingInk = signature.paths; lib.annotationMode = "Firma"; ui.panel = nil }.buttonStyle(.borderedProminent).disabled(signature.paths.allSatisfy { $0.count < 2 }) }
            }.padding(24).onAppear { signature.paths = [] }
        case .chooseDocument: ChooseDocumentPanel()
        }
    }
}

struct WorkspaceTabs: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 72)
            Button { ui.assistantWorkspace = false; ui.landing = nil; lib.browse("Inicio"); ui.section = "Home" } label: { ScanBrand().padding(.horizontal, 12).frame(height: 34).background(lib.document == nil ? .white : Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain)
            ScrollViewReader { tabsProxy in ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
            if ui.assistantTab {
                HStack(spacing: 12) {
                    Button { ui.openAssistant() } label: { HStack(spacing: 7) { Image(systemName: "sparkles").foregroundStyle(scanGreen).frame(width: 16, height: 16).background(Color(red: 0.02, green: 0.11, blue: 0.15), in: RoundedRectangle(cornerRadius: 3)); Text(tr("AI Assistant")).font(.system(size: 15)) } }.buttonStyle(.plain)
                    Spacer()
                    Button { ui.assistantTab = false; ui.assistantWorkspace = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(tr("Close"))
                }.padding(.horizontal, 12).frame(width: 216, height: 34).background(ui.assistantWorkspace ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(ui.toolTabs) { tool in
                HStack(spacing: 12) {
                    Button { ui.assistantWorkspace = false; ui.landing = tool } label: { HStack(spacing: 6) { ToolIcon(tool: tool, size: 20); Text(tr(tool.rawValue)).foregroundStyle(.primary) } }.buttonStyle(.plain)
                    Spacer(minLength: 12)
                    Button { ui.toolTabs.removeAll { $0 == tool }; ui.toolSessions.removeValue(forKey: tool); if ui.landing == tool { ui.landing = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(tr("Close"))
                }.padding(.horizontal, 12).frame(width: 216, height: 34).background(ui.landing == tool ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(ui.tabs.filter { id in lib.records.contains { $0.id == id } }, id: \.self) { id in
                HStack(spacing: 8) {
                    Button { ui.assistantWorkspace = false; ui.landing = nil; if lib.selected != id { lib.select(id) } } label: { HStack { Image(systemName: "doc.fill").foregroundStyle(.orange); Text((lib.records.first { $0.id == id }?.name ?? "Document") + ".pdf").lineLimit(1).frame(maxWidth: 210) } }.buttonStyle(.plain)
                    Button { ui.tabs.removeAll { $0 == id }; if lib.selected == id { lib.selected = nil; lib.document = nil } } label: { Image(systemName: "xmark").font(.system(size: 12)) }.buttonStyle(.plain).accessibilityLabel(tr("Close document tab"))
                }.padding(.horizontal, 12).frame(height: 34).background(lib.selected == id ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
            } }.frame(maxWidth: .infinity).onChange(of: ui.landing) { _, tool in if let tool { tabsProxy.scrollTo(tool.id, anchor: .trailing) } } }
            Spacer()
        }.padding(.vertical, 4).frame(height: 42).background(scanCanvas)
    }
}

struct WorkspaceSidebar: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    @State var foldersOpen = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            nav("Home", symbol: "house") { lib.browse("Inicio") }
            HStack(spacing: 6) {
                Button { foldersOpen.toggle() } label: { Image(systemName: foldersOpen ? "chevron.down" : "chevron.right").font(.system(size: 10)) }.buttonStyle(.plain)
                Button { ui.section = "My document"; lib.browse("Todos") } label: { Label(tr("My document"), systemImage: "doc.text").font(.system(size: 14, weight: .medium)).lineLimit(2) }.buttonStyle(.plain)
                Spacer()
                Menu { Button(tr("New folder")) { ui.panel = .organize }; Button(tr("Import documents")) { lib.chooseImport() } } label: { Image(systemName: "plus").font(.caption) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.padding(.horizontal, 8).frame(height: 43)
            if foldersOpen {
                nav("Signed Documents", symbol: nil, indented: true) { lib.browse("Firmados") }
                ForEach(lib.childFolders(of: nil), id: \.self) { folder in nav(folder, symbol: nil, indented: true, localized: false) { lib.browse("Carpeta", folder: folder) } }
            }
            nav("Tools", symbol: "case") { lib.browse("Todos") }
            Spacer()
            Menu {
                Button(tr("Favorites")) { ui.section = "Favorites"; lib.browse("Favoritos") }
                Button(tr("Trash")) { ui.section = "Trash"; lib.browse("Papelera") }
                Button(tr("Manage folders and tags")) { ui.panel = .organize }
                Button(tr("Sync folder")) { ui.panel = .folderSync }
                Button(tr("Private local account")) { ui.panel = .account }
            } label: { Label(tr("More"), systemImage: "ellipsis.circle") }.menuStyle(.borderlessButton).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(Color.gray.opacity(0.17)).frame(height: 5).overlay(alignment: .leading) { Capsule().fill(scanGreen).frame(width: min(170, max(4, CGFloat(lib.records.count) * 3)), height: 5) }
                HStack { Text(tr("Documents: {0}", String(describing: lib.records.filter { $0.trashedAt == nil }.count))).foregroundStyle(.secondary); Spacer(); Button(tr("Local")) { ui.panel = .account }.foregroundStyle(scanGreen).buttonStyle(.plain) }.font(.system(size: 12))
            }.padding(12).padding(.top, 10)
        }.padding(12).frame(width: 212).background(Color(red: 0.975, green: 0.975, blue: 0.975), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.08))).shadow(color: .black.opacity(0.04), radius: 5).padding(.leading, 12).padding(.bottom, 12)
    }
    func nav(_ title: String, symbol: String?, indented: Bool = false, localized: Bool = true, action: @escaping () -> Void) -> some View {
        Button { ui.section = title; action() } label: {
            HStack(spacing: 10) { if let symbol { Image(systemName: symbol).font(.system(size: 18)).frame(width: 22) }; Text(localized ? tr(title) : title).font(.system(size: 14, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading).layoutPriority(1); Spacer() }.padding(.leading, indented ? 38 : 12).padding(.trailing, 8).frame(height: 40).foregroundStyle(ui.section == title ? scanGreen : Color.primary).background(ui.section == title ? scanGreen.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

struct LibraryWorkspace: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    @State var grid = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 10) { Image(systemName: "magnifyingglass"); TextField(tr("Search my files…"), text: $lib.query).textFieldStyle(.plain) }.padding(10).frame(maxWidth: 480).background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.04)))
                Spacer()
                Menu { Button(tr("Interface language")) { ui.panel = .languages }; Button(tr("OCR languages")) { ui.panel = .ocrLanguages } } label: { Label(appLanguage.language.nativeName, systemImage: "globe") }.menuStyle(.borderlessButton).fixedSize()
                Text("100%").font(.system(size: 14))
                ScanIconButton(symbol: "icloud", help: tr("Private local cloud")) { ui.panel = .account }
                ScanIconButton(symbol: "bell", help: tr("Activity")) { ui.showNotice = true }
                Menu { Button(tr("Local account")) { ui.panel = .account }; Button(tr("Folder sync")) { ui.panel = .folderSync } } label: { Label(tr("Local account"), systemImage: "person.crop.circle.fill").foregroundStyle(.primary) }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 20)
            if ui.section == "Tools" { ToolsWorkspace() }
            else if ui.section != "Home" { LibraryBrowser().environmentObject(ui) }
            else {
                ScrollView {
                    VStack(spacing: 22) {
                        if ui.section == "Home" && lib.query.isEmpty {
                            ImportHero()
                            HStack(spacing: 18) {
                                Image(systemName: "sparkles").font(.title2).foregroundStyle(.blue)
                                Text(tr("Local AI · Your Document Assistant")).font(.system(size: 15, weight: .semibold))
                                Text(tr("Summarize, translate and understand your documents.")).foregroundStyle(.secondary).font(.system(size: 13))
                                Spacer()
                                Button(tr("Ask AI")) { ui.openAssistant() }.buttonStyle(.bordered).clipShape(Capsule())
                            }.padding(16).background(Color.blue.opacity(0.025), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.blue.opacity(0.12)))
                            HomeToolStrip()
                        }
                        HStack {
                            Text(lib.folderFilter ?? tr(ui.section == "Home" ? "Recent" : ui.section)).font(.system(size: 18, weight: .semibold))
                            Spacer()
                            ScanIconButton(symbol: "list.bullet", help: tr("List view"), active: !grid) { grid = false }
                            ScanIconButton(symbol: "square.grid.2x2", help: tr("Grid view"), active: grid) { grid = true }
                            if ui.section == "Home" { Button(tr("View all documents ›")) { ui.section = "My document"; lib.browse("Todos") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                        }.padding(.top, 10)
                        Divider()
                        if lib.filtered.isEmpty { Text(tr("No file available. Import one and try")).font(.system(size: 17)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 65) }
                        else if grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 18) {
                                ForEach(ui.section == "Home" ? Array(lib.filtered.prefix(12)) : lib.filtered) { record in
                                    Button { lib.select(record.id) } label: { VStack(spacing: 10) { DocumentThumbnail(record: record).frame(height: 150); Text(record.name).font(.system(size: 13)).lineLimit(1); Text(record.date.formatted(.dateTime.year().month(.abbreviated).day().locale(appLanguage.locale))).font(.caption).foregroundStyle(.secondary) }.padding(12).frame(maxWidth: .infinity).background(Color.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.12))).scanCardShadow(radius: 10) }.buttonStyle(.plain)
                                }
                            }
                        } else {
                            ForEach(ui.section == "Home" ? Array(lib.filtered.prefix(12)) : lib.filtered) { record in
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.richtext.fill").font(.system(size: 27)).foregroundStyle(.blue)
                                    Button { lib.select(record.id) } label: { VStack(alignment: .leading, spacing: 5) { Text(record.name).font(.system(size: 14)); Text((record.tags ?? []).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                                    Text(record.date.formatted(.dateTime.year().month(.abbreviated).day().locale(appLanguage.locale))).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 120)
                                    if record.trashedAt != nil { Button(tr("Restore")) { lib.restoreDocument(record.id) } }
                                    else { Button { lib.toggleFavorite(record.id) } label: { Image(systemName: record.starred ? "star.fill" : "star").foregroundStyle(record.starred ? Color.orange : Color.gray.opacity(0.5)) }.buttonStyle(.plain) }
                                    Button { lib.select(record.id); ui.input = record.name; ui.rename = true } label: { Image(systemName: "ellipsis") }.buttonStyle(.plain)
                                }.padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }.frame(maxWidth: ui.section == "Home" ? 1000 : .infinity).padding(.horizontal, 30).padding(.top, 15).padding(.bottom, 30).frame(maxWidth: .infinity)
                }.dropDestination(for: URL.self) { urls, _ in lib.importFiles(urls); return true }
            }
        }.background(.white)
    }
}

struct ImportHero: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Ellipse().fill(scanGreen.opacity(0.12)).frame(width: 155, height: 75).blur(radius: 16).offset(y: 28)
                Image(systemName: "camera").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(scanGreen.opacity(0.25)).offset(x: 35, y: -30)
                ZStack { RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 108, height: 79).shadow(color: .black.opacity(0.07), radius: 5); Rectangle().fill(Color(red: 0.10, green: 0.12, blue: 0.13)).frame(width: 96, height: 65); Image(systemName: "doc.fill").foregroundStyle(.white).font(.system(size: 33)) }.offset(y: 8)
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.blue.opacity(0.8), .blue.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 49, height: 40).overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.65))).offset(x: -62, y: -22)
                Circle().fill(scanGreen).frame(width: 38, height: 38).overlay(Image(systemName: "plus").font(.system(size: 23)).foregroundStyle(.white)).offset(x: 66, y: 45)
            }.frame(height: 112).padding(.top, 10)
            Text(tr("Drag files here, or click to import")).font(.system(size: 19)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                heroButton(tr("Smart Scan"), icon: "camera.fill", color: scanGreen) { ui.panel = .camera }
                heroButton(tr("Import Images"), icon: "photo.fill", color: .blue) { lib.chooseLibraryImport(images: true) }
                heroButton(tr("Import Files"), icon: "doc.text.fill", color: .blue) { lib.chooseImport() }
                HStack(spacing: 8) {
                    Button { lib.captureScreenshot() } label: { Label(tr("Screenshot"), systemImage: "viewfinder").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary) }.buttonStyle(.plain)
                    Menu { Button(tr("Select screen region")) { lib.captureScreenshot() }; Button(tr("Physical scanner")) { ui.panel = .scanner } } label: { Image(systemName: "chevron.down").font(.caption).foregroundStyle(.primary) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }.frame(maxWidth: .infinity).frame(height: 52).background(.white, in: RoundedRectangle(cornerRadius: 13)).scanCardShadow(radius: 13)
            }
        }.padding(25).frame(maxWidth: .infinity).background(Color(red: 0.975, green: 0.975, blue: 0.982), in: RoundedRectangle(cornerRadius: 28))
    }
    func heroButton(_ text: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 11) { Image(systemName: icon).foregroundStyle(color).font(.system(size: 23)); Text(text).font(.system(size: 14, weight: .semibold)) }.frame(maxWidth: .infinity).frame(height: 52).background(.white, in: RoundedRectangle(cornerRadius: 13)).scanCardShadow(radius: 13) }.buttonStyle(.plain)
    }
}

struct HomeToolStrip: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            tool("AI Assistant", "sparkles", .teal) { ui.openAssistant() }
            tool("To Word", "doc.text", .blue) { ui.openLanding(.word) }
            tool("To Excel", "tablecells", .green) { ui.openLanding(.excel) }
            tool("To PPT", "rectangle.stack", .orange) { ui.openLanding(.ppt) }
            tool("To Image", "photo.on.rectangle", .blue) { ui.openLanding(.images) }
            tool("Merge Files", "doc.on.doc", .orange) { ui.openLanding(.merge) }
            tool("Extract Pages", "doc.badge.arrow.up", .blue) { ui.openLanding(.extract) }
            tool("All Tools", "square.grid.2x2.fill", .teal) { ui.section = "Tools" }
        }.padding(.vertical, 12)
    }
    func tool(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 10) { RoundedRectangle(cornerRadius: 18).fill(color.opacity(0.055)).frame(width: 54, height: 54).overlay(Image(systemName: icon).font(.system(size: 25, weight: .medium)).foregroundStyle(color)); Text(tr(title)).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8).frame(height: 32, alignment: .top) }.frame(maxWidth: .infinity) }.buttonStyle(.plain)
    }
}
struct DocumentThumbnail: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    let record: Record
    @State var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit().shadow(color: .black.opacity(0.12), radius: 3) } else { Image(systemName: "doc.richtext").font(.system(size: 45)).foregroundStyle(.blue.opacity(0.7)) } }.onAppear { if image == nil && record.passwordProtected != true { image = PDFDocument(url: lib.url(record.id))?.page(at: 0)?.thumbnail(of: NSSize(width: 180, height: 220), for: .cropBox) } }
    }
}

/// Pointer highlight; no movement or change to the hit area.
private struct ToolCardHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovered ? scanGreen.opacity(0.85) : Color.gray.opacity(0.13), lineWidth: 1))
            .shadow(color: hovered ? scanGreen.opacity(0.16) : .clear, radius: 8, x: 0, y: 3)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
    }
}

struct ToolsWorkspace: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                category("Convert", items: [
                    ("To Word", "Convert recognized text to an editable Word document.", "doc.text", .blue, .convert),
                    ("To Excel", "Reconstruct rows and columns using local OCR.", "tablecells", .green, .reconstruction),
                    ("To PPT", "Reconstruct editable text boxes in PowerPoint.", "rectangle.stack", .orange, .reconstruction),
                    ("To Images", "Export PDF pages as images.", "photo", .blue, .pdf),
                    ("To PDF", "To PDF · Import text or Word", "doc.richtext.fill", .orange, .pdf),
                    ("Extract Text", "Recognize and copy text from scanned documents.", "text.viewfinder", .teal, .convert)])
                category("Organize", items: [
                    ("Merge Files", "Merge multiple documents into one.", "doc.on.doc", .orange, .organize),
                    ("Extract Pages", "Create a new document from selected pages.", "doc.badge.arrow.up", .blue, .pdf),
                    ("Reorder Pages", "Reorder, delete, duplicate or rotate pages.", "square.grid.2x2", .teal, .pages)])
                category("Utilities", items: [
                    ("AI Assistant", "Summarize, translate and ask about your documents.", "sparkles", .teal, .assistant),
                    ("Scan ID Card", "Place front and back on one printable page.", "person.text.rectangle", .blue, .idcard),
                    ("Physical Scanner", "Scan from compatible Image Capture devices.", "scanner", .teal, .scanner)])
                category("Edit", items: [
                    ("Electronic signature", "Draw or import a signature.", "signature", .teal, .signature),
                    ("PDF Watermark", "Add text over your PDF.", "doc.text.image", .blue, .pdf),
                    ("Enhance Scan", "Correct illumination and improve document images.", "slider.horizontal.3", .teal, .enhance)])
            }.padding(30)
        }
    }
    func category(_ name: String, items: [(String, String, String, Color, WorkspacePanel)]) -> some View {
        VStack(alignment: .leading, spacing: 15) { Text(tr(name)).font(.system(size: 18, weight: .semibold)); LazyVGrid(columns: [GridItem(.adaptive(minimum: 260))], spacing: 14) {
            ForEach(items, id: \.0) { item in Button { if let tool = LandingTool(rawValue: item.0) { ui.openLanding(tool) } else if item.4 == .assistant { ui.openAssistant() } else if [.idcard, .scanner, .organize].contains(item.4) { ui.panel = item.4 } else { ui.require(item.4, library: lib) } } label: { HStack(alignment: .top, spacing: 15) { Image(systemName: item.2).font(.system(size: 27)).foregroundStyle(item.3).frame(width: 36); VStack(alignment: .leading, spacing: 8) { Text(tr(item.0)).font(.system(size: 15, weight: .semibold)); Text(tr(item.1)).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.leading) }; Spacer() }.padding(20).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading).background(Color.white, in: RoundedRectangle(cornerRadius: 12)).scanCardShadow().modifier(ToolCardHover()) }.buttonStyle(.plain) }
        } }
    }
}

struct ChooseDocumentPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(tr("Choose a document")).font(.title2.bold()); Spacer(); Button(tr("Cancel")) { ui.panel = nil } }
            List(lib.records.filter { $0.trashedAt == nil }) { record in Button(record.name) { lib.select(record.id); ui.completeDocumentChoice() } }
            Button(tr("Import a file…")) { lib.chooseImport(); if lib.document != nil { ui.completeDocumentChoice() } }
        }.padding(24).frame(width: 520, height: 420)
    }
}

import SwiftUI

/// Full-window assistant. Chat requests remain on the loopback LM Studio endpoint.
struct AssistantWorkspaceView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @State private var selectedSkill: AssistantSkill?
    @State private var skills = false
    @State private var collapsed = false
    @State private var category = "All"
    @State private var search = ""
    @State private var prompt = ""
    @State private var submitted: String?
    @State private var chatID = UUID()
    private let suggestions = ["Summarize a document", "Gather resources on a topic", "Expand an outline into full text", "Convert multiple files at once", "Extract key details", "Draft domain-specific documents", "Convert between formats", "Deep research on industry trends", "Organize data into tables", "Compare solutions side by side", "Compare documents in detail", "Rewrite and polish a document", "Look up policies and regulations", "Translate documents", "Convert PDFs to images", "Extract and combine text"]
    private let skillNames = ["Magic Pro", "To Word", "To PDF", "Extract Text", "Edit Text", "Erase Marks", "Remove Handwriting", "Translate", "Add Watermark", "Pages to Images", "Extract Formulas", "AI Image Detector", "Tamper Detection", "To Excel", "To PPT", "To Markdown", "Office Editing", "Visualize HTML", "Deep Research"]
    private let symbols = ["photo.badge.checkmark", "doc.text", "doc.richtext", "text.viewfinder", "character.cursor.ibeam", "eraser", "pencil.slash", "character.bubble", "seal", "photo.on.rectangle", "function", "sparkles", "magnifyingglass", "tablecells", "rectangle.stack", "text.alignleft", "pencil", "chevron.left.forwardslash.chevron.right", "chart.bar.xaxis"]
    private func color(_ i: Int) -> Color { [Color.blue, .cyan, .orange, scanGreen][i % 4] }
    private func reset() { selectedSkill = nil; submitted = nil; prompt = ""; skills = false; chatID = UUID() }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Spacer(); Button { collapsed.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 19)) }.buttonStyle(.plain).accessibilityLabel(tr("Sidebar")) }.padding(.bottom, 8)
                if !collapsed {
                    side("New Chat", "plus", active: !skills && submitted == nil) { reset() }
                    side("Skills", "books.vertical", active: skills) { selectedSkill = nil; skills = true; category = "All" }
                    if let submitted { Text(tr("Today")).foregroundStyle(.secondary).padding(.top, 25); Button { skills = false } label: { Label(submitted, systemImage: "bubble").lineLimit(2) }.buttonStyle(.plain) }
                    Spacer()
                    Text(tr("Codex + LM Studio · This Mac")).font(.caption).foregroundStyle(.secondary)
                } else { Spacer() }
            }.padding(16).frame(width: collapsed ? 44 : 176).background(Color.black.opacity(0.018), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.black.opacity(0.10))).padding(12)
            ZStack {
                if let selectedSkill {
                    VStack(alignment: .leading) {
                        Button("← Habilidades") { self.selectedSkill = nil; skills = true }
                        if selectedSkill == .erase || selectedSkill == .handwriting {
                            AssistantCleanupView(handwriting: selectedSkill == .handwriting)
                        } else if selectedSkill == .aiImage || selectedSkill == .tamper {
                            AssistantInspectionView(ai: selectedSkill == .aiImage)
                        } else {
                            LocalAssistantView(generalChat: true, skill: selectedSkill)
                        }
                    }.padding(24)
                } else if let submitted {
                    LocalAssistantView(generalChat: true, initialPrompt: submitted).id(chatID).frame(maxWidth: 850).padding(30).frame(maxWidth: .infinity).opacity(skills ? 0 : 1).allowsHitTesting(!skills)
                } else if !skills { home }
                if skills { skillGallery }
            }
        }.background(Color(white: 0.985))

    }
    private func side(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(tr(title), systemImage: symbol).font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(active ? .white : .clear, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.black.opacity(0.10) : .clear)) }.buttonStyle(.plain)
    }
    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 12) { Image(systemName: "sparkles").foregroundStyle(scanGreen); Text(tr("What can I do for you?")) }.font(.system(size: 28, weight: .bold)).padding(.top, max(70, geometry.size.height * 0.24))
                    VStack(alignment: .leading, spacing: 14) {
                        ZStack(alignment: .topLeading) {
                            if prompt.isEmpty { Text(tr("Enter what you want to research, or type / for skills")).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                            TextEditor(text: $prompt).font(.system(size: 15)).scrollContentBackground(.hidden).frame(height: 85).accessibilityLabel(tr("Message")).onChange(of: prompt) { _, value in if value == "/" { skills = true; category = "All" } }
                        }
                        HStack(spacing: 14) {
                            Button { ui.assistantWorkspace = false; ui.require(.assistant, library: lib) } label: { Image(systemName: "plus.circle").font(.system(size: 23)) }.help(tr("Ask about a document"))
                            Button { skills = true; category = "All" } label: { Image(systemName: "slash.circle").font(.system(size: 23)) }.help(tr("Skills"))
                            Spacer()
                            Button { if prompt == "/" { skills = true } else { submitted = prompt } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).foregroundStyle(prompt.isEmpty ? Color.gray.opacity(0.35) : scanGreen) }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel(tr("Send"))
                        }.buttonStyle(.plain)
                    }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(scanGreen.opacity(0.55))).shadow(color: scanGreen.opacity(0.10), radius: 28).frame(maxWidth: 776).padding(.top, 28)
                    filterBar(["All", "Convert", "Analyze", "Write & Translate", "Research"]).padding(.top, 70).padding(.bottom, 22)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(Array(suggestions.enumerated()).filter { matchSuggestion($0.offset) }, id: \.offset) { i, title in
                            Button { prompt = tr(title) } label: {
                                VStack(alignment: .leading) { Text(tr(title)).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.leading).lineLimit(3).fixedSize(horizontal: false, vertical: true); Spacer(); HStack { Spacer(); Image(systemName: symbols[i % symbols.count]).font(.system(size: 34)).foregroundStyle(color(i).opacity(0.35)) } }.padding(22).frame(maxWidth: .infinity).frame(height: 120).background(.white, in: RoundedRectangle(cornerRadius: 20)).shadow(color: .black.opacity(0.025), radius: 12, y: 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 36).padding(.bottom, 30)
            }
        }
    }
    private func matchSuggestion(_ i: Int) -> Bool {
        category == "All" || (category == "Convert" && [3,6,14,15].contains(i)) || (category == "Analyze" && [0,4,8,10].contains(i)) || (category == "Write & Translate" && [2,5,11,13].contains(i)) || (category == "Research" && [1,7,9,12].contains(i))
    }
    private func filterBar(_ names: [String]) -> some View {
        HStack(spacing: 18) { ForEach(names, id: \.self) { name in Button { category = name } label: { Text(tr(name)).font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 10).background(category == name ? Color.black.opacity(0.04) : .clear, in: Capsule()) }.buttonStyle(.plain) } }
    }
    private var skillGallery: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(tr("Skills")).font(.system(size: 21, weight: .bold))
            Text(tr("Available skills for your AI document assistant. Type / in chat to use a skill.")).foregroundStyle(.secondary)
            HStack { filterBar(["All", "Edit", "Convert Format", "Tools", "Make Visual", "Education"]); Spacer(); TextField(tr("Search skills"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 250) }.padding(.top, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 20) {
                    ForEach(Array(skillNames.enumerated()).filter { i, name in (search.isEmpty || tr(name).localizedCaseInsensitiveContains(search)) && (category == "All" || skillCategory(i) == category) }, id: \.offset) { i, name in
                        Button { activate(i) } label: {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 12) { Image(systemName: symbols[i]).font(.system(size: 25)).foregroundStyle(color(i)).frame(width: 48, height: 48).background(color(i).opacity(0.08), in: RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 5) { Text(tr(name)).font(.system(size: 16, weight: .semibold)); Text(tr("ScanMac")).font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(minLength: 0) }
                                Text(tr(skillDescription(i))).font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                            }.padding(20).frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading).background(.white, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.black.opacity(0.025))).shadow(color: .black.opacity(0.025), radius: 10, y: 4)
                        }.buttonStyle(.plain)
                    }
                }.padding(.bottom, 20)
            }
        }.padding(24)
    }
    private func skillCategory(_ i: Int) -> String { if [1,2,9,13,14,15].contains(i) { return "Convert Format" }; if [0,4,5,6,7,8,16].contains(i) { return "Edit" }; if [17].contains(i) { return "Make Visual" }; if [10].contains(i) { return "Education" }; return "Tools" }
    private func skillDescription(_ i: Int) -> String {
        if [5,6].contains(i) { return "Propuestas IA, selección de tinta y reconstrucción local con LaMa." }
        if [11,12].contains(i) { return "Detector local o mapas de alteraciones. Resultados experimentales; revisa los límites." }
        if i == 18 { return "Fuentes locales y búsqueda web opcional con referencias." }
        if i == 0 { return "Corrige sombras, enfoque, ruido y contraste en este Mac." }
        if i == 8 { return "Añade una marca de agua con posición y opacidad ajustables." }
        if [1,2,3,9,13,14].contains(i) { return "Convert documents using the tools on this Mac." }
        return "Texto y OCR local, instrucciones, revisión y exportación del resultado."
    }
    private func activate(_ i: Int) {
        guard let skill = AssistantSkill(rawValue: i) else { return }
        let tools: [Int: LandingTool] = [1: .word, 2: .pdf, 3: .text, 9: .images, 13: .excel, 14: .ppt]
        if let tool = tools[i] { ui.openLanding(tool) }
        else if skill == .enhance || skill == .watermark {
            ui.assistantWorkspace = false
            ui.require(skill == .enhance ? .enhance : .pdf, library: lib)
        } else { selectedSkill = skill; skills = false; submitted = nil; chatID = UUID() }
    }
}

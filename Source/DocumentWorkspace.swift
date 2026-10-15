import SwiftUI
import AppKit
import PDFKit

struct DocumentWorkspace: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        VStack(spacing: 0) {
            DocumentHeader()
            DocumentRibbon().padding(.horizontal, 18).padding(.bottom, 0)
            if ui.editorTab == "Page" { InlinePageGrid() }
            else {
                HStack(spacing: 0) {
                    if ui.showThumbnails { DocumentNavigator().frame(width: 200); Divider() }
                    VStack(spacing: 0) {
                        if ui.searching {
                            HStack { Image(systemName: "magnifyingglass"); TextField(tr("Find text in document"), text: $ui.documentSearch).onSubmit { lib.findDocumentText(ui.documentSearch) }; Button(tr("Find")) { lib.findDocumentText(ui.documentSearch) }; Button { ui.searching = false } label: { Image(systemName: "xmark") } }.textFieldStyle(.roundedBorder).padding(10).background(.white)
                        }
                        InteractivePreview()
                    }
                    if ui.showOCR { OCRWorkspace().frame(width: 300) }
                    if ui.showAssistant { Divider(); LocalAssistantView().id(lib.selected).frame(width: 325) }
                }
            }
            DocumentFooter()
        }.background(scanCanvas)
        .onChange(of: ui.editorTab) { _, tab in if tab == "Page" { ui.showAssistant = false } }
    }
}

struct DocumentHeader: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        HStack(spacing: 12) {
            Menu { Button(tr("Back to Home")) { lib.browse("Inicio"); ui.section = "Home" }; Button(tr("Rename")) { ui.input = lib.current?.name ?? ""; ui.rename = true }; Button(tr("Duplicate")) { if let id = lib.selected { lib.duplicateDocument(id) } }; Button(tr("Move to Trash"), role: .destructive) { ui.deletion = true } } label: { ScanBrand(small: true) }.menuStyle(.borderlessButton).fixedSize()
            Button { ui.input = lib.current?.name ?? ""; ui.rename = true } label: { Text(lib.current?.name ?? "Document").font(.system(size: 19, weight: .semibold)).lineLimit(1).frame(maxWidth: 230, alignment: .leading) }.buttonStyle(.plain)
            Button(tr("+ Tags")) { ui.panel = .organize }.font(.system(size: 12)).buttonStyle(.bordered)
            Spacer(minLength: 10)
            HStack(spacing: 24) { ForEach(["View", "Edit", "Page", "Convert Format"], id: \.self) { tab in
                Button { ui.editorTab = tab } label: { Text(tr(tab)).font(.system(size: 14, weight: ui.editorTab == tab ? .medium : .regular)).foregroundStyle(ui.editorTab == tab ? scanGreen : .primary).padding(.vertical, 14).overlay(alignment: .bottom) { if ui.editorTab == tab { Capsule().fill(scanGreen).frame(height: 2).padding(.horizontal, 2) } } }.buttonStyle(.plain)
            } }
            Spacer(minLength: 10)
            ScanIconButton(symbol: "magnifyingglass", help: tr("Find in document"), active: ui.searching) { ui.searching.toggle() }
            ScanIconButton(symbol: "arrow.down.to.line", help: tr("Download PDF")) { lib.exportPDF() }
            ScanIconButton(symbol: "printer", help: tr("Print")) { lib.advancedPrint() }
            Menu {
                Button(tr("Protect PDF / Watermark")) { ui.panel = .pdf }; Button(tr("Recognize Text")) { lib.recognize(); ui.showOCR = true }
                Button(tr("Enhance scan")) { ui.panel = .enhance }; Button(tr("Local cloud")) { ui.panel = .account }; Button(tr("Folder sync")) { ui.panel = .folderSync }
                Button(tr("Mark as favorite")) { lib.update { $0.starred.toggle() } }
            } label: { Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 25) }.menuStyle(.borderlessButton).fixedSize()
            Button { lib.persist() } label: { Label(tr("Save"), systemImage: "checkmark").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 13).frame(height: 32) }.buttonStyle(.bordered).help(tr("Changes are saved locally as you edit"))
            Button { lib.shareDocument() } label: { Label(tr("Share"), systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12).frame(height: 32).foregroundStyle(.white).background(scanGreen, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
        }.padding(.horizontal, 20).frame(height: 48)
    }
}

struct DocumentRibbon: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    @State var viewMode = "Single Page"
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if ui.editorTab == "View" {
                    ScanIconButton(symbol: "cursorarrow", help: tr("Select"), active: lib.annotationMode == "Seleccionar") { lib.annotationMode = "Seleccionar" }
                    ScanIconButton(symbol: "hand.draw", help: tr("Hand"), active: lib.annotationMode == "Mano") { lib.annotationMode = "Mano" }
                    separator
                    ScanToolButton(title: tr("Continuous Scroll"), symbol: "rectangle.split.1x2", active: viewMode == "Continuous") { viewMode = "Continuous"; lib.viewMode("Continuo") }
                    ScanToolButton(title: tr("Single Page"), symbol: "doc", active: viewMode == "Single Page") { viewMode = "Single Page"; lib.viewMode("Una") }
                    ScanToolButton(title: tr("Double Page"), symbol: "rectangle.split.2x1", active: viewMode == "Double") { viewMode = "Double"; lib.viewMode("Doble") }
                    separator
                    ScanToolButton(title: tr("Play"), symbol: "play.circle") { lib.viewMode("Una"); NSApp.keyWindow?.toggleFullScreen(nil) }
                    separator
                    ScanToolButton(title: tr("AI Assistant"), symbol: "sparkles", active: ui.showAssistant) { ui.showAssistant.toggle() }
                } else if ui.editorTab == "Edit" {
                    ScanIconButton(symbol: "arrow.uturn.backward", help: tr("Undo")) { lib.undo() }.disabled(lib.history.isEmpty)
                    ScanIconButton(symbol: "arrow.uturn.forward", help: tr("Redo")) { lib.redo() }.disabled(lib.redoHistory.isEmpty)
                    separator
                    ScanIconButton(symbol: "cursorarrow", help: tr("Select"), active: lib.annotationMode == "Seleccionar") { lib.annotationMode = "Seleccionar" }
                    ScanIconButton(symbol: "hand.draw", help: tr("Hand"), active: lib.annotationMode == "Mano") { lib.annotationMode = "Mano" }
                    separator
                    ScanToolButton(title: tr("Highlight"), symbol: "highlighter") { lib.highlightSelection() }
                    ScanToolButton(title: tr("Add Text"), symbol: "textformat") { ui.input = ""; ui.note = true }
                    ScanToolButton(title: tr("Pen"), symbol: "pencil.tip", active: lib.annotationMode == "Lápiz") { lib.annotationMode = "Lápiz" }
                    Menu { Button(tr("Draw signature")) { ui.panel = .signature }; Button(tr("Import image signature")) { lib.chooseImageSignature() } } label: { Label(tr("Sign"), systemImage: "signature").font(.system(size: 14)) }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10)
                    separator
                    ScanToolButton(title: tr("Move"), symbol: "arrow.up.and.down.and.arrow.left.and.right", active: lib.annotationMode == "Mover") { lib.annotationMode = "Mover" }
                    ScanIconButton(symbol: "eraser", help: tr("Delete annotation"), active: lib.annotationMode == "Borrar anotación") { lib.annotationMode = "Borrar anotación" }
                    ScanToolButton(title: tr("Enhance"), symbol: "slider.horizontal.3") { ui.panel = .enhance }
                    ScanToolButton(title: tr("Watermark"), symbol: "doc.text.image") { ui.panel = .pdf }
                } else if ui.editorTab == "Page" {
                    ScanIconButton(symbol: "arrow.uturn.backward", help: tr("Undo")) { lib.undo(); ui.pageSelection = [] }.disabled(lib.history.isEmpty)
                    ScanIconButton(symbol: "arrow.uturn.forward", help: tr("Redo")) { lib.redo(); ui.pageSelection = [] }.disabled(lib.redoHistory.isEmpty)
                    separator
                    TextField(tr("Enter page range"), text: $ui.range).textFieldStyle(.roundedBorder).frame(width: 150).onSubmit { chooseRange() }
                    Button(tr("Select")) { chooseRange() }.buttonStyle(.plain)
                    ScanIconButton(symbol: "rotate.right", help: tr("Rotate selected pages")) { lib.rotatePages(ui.pageSelection) }.disabled(ui.pageSelection.isEmpty)
                    ScanIconButton(symbol: "doc.on.doc", help: tr("Duplicate selected pages")) { lib.duplicatePages(ui.pageSelection); ui.pageSelection = [] }.disabled(ui.pageSelection.isEmpty)
                    ScanIconButton(symbol: "trash", help: tr("Delete selected pages")) { lib.deletePages(ui.pageSelection); ui.pageSelection = [] }.disabled(ui.pageSelection.isEmpty || ui.pageSelection.count >= (lib.document?.pageCount ?? 0))
                    separator
                    ScanToolButton(title: tr("Extract"), symbol: "doc.badge.arrow.up") { lib.advancedExtract(range: ui.pageSelection.sorted().map { String($0 + 1) }.joined(separator: ",")) }.disabled(ui.pageSelection.isEmpty)
                    ScanToolButton(title: tr("Split"), symbol: "rectangle.split.2x1") { lib.splitIntoLibrary() }
                    Menu { Button(tr("Import files")) { lib.chooseImport(append: true) }; Button(tr("Blank page")) { lib.insertBlankPage() }; Button(tr("Camera")) { ui.panel = .camera }; Button(tr("Scanner")) { ui.panel = .scanner } } label: { Label(tr("Insert"), systemImage: "plus.rectangle.on.rectangle").font(.system(size: 14)) }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10)
                } else {
                    ScanToolButton(title: tr("To Word"), symbol: "doc.text") { ui.panel = .reconstruction }
                    ScanToolButton(title: tr("To Excel"), symbol: "tablecells") { ui.panel = .reconstruction }
                    ScanToolButton(title: tr("To PPT"), symbol: "rectangle.stack") { ui.panel = .reconstruction }
                    ScanToolButton(title: tr("To Image"), symbol: "photo") { lib.advancedExportImages() }
                    ScanToolButton(title: tr("Extract Text"), symbol: "text.viewfinder") { lib.recognize(); ui.showOCR = true }
                    ScanToolButton(title: tr("More"), symbol: "ellipsis.circle") { ui.panel = .convert }
                }
            }.frame(minWidth: 850).frame(maxWidth: .infinity).padding(.horizontal, 15).frame(height: 48)
        }.background(.white, in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.045), radius: 7, y: 3).padding(.bottom, 0)
    }
    var separator: some View { Divider().frame(height: 17).padding(.horizontal, 3) }
    func chooseRange() { do { ui.pageSelection = Set(try Library.advancedPageIndexes(ui.range, pageCount: lib.document?.pageCount ?? 0)) } catch { lib.error = error.localizedDescription } }
}

struct DocumentNavigator: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { ui.outline = false } label: { Label(tr("Thumbnails"), systemImage: "square.grid.2x2").foregroundStyle(ui.outline ? Color.primary : scanGreen) }.buttonStyle(.plain)
                Button { ui.outline = true } label: { Label(tr("Outline"), systemImage: "bookmark").foregroundStyle(ui.outline ? scanGreen : Color.primary) }.buttonStyle(.plain)
            }.font(.system(size: 12)).frame(height: 42)
            if ui.outline {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let root = lib.document?.outlineRoot, root.numberOfChildren > 0 { ForEach(0..<root.numberOfChildren, id: \.self) { i in if let child = root.child(at: i) { OutlineRow(outline: child, depth: 0) } } }
                        else { Text(tr("No outline")).font(.caption).foregroundStyle(.secondary).padding() }
                        Button(tr("+ Bookmark current page")) { lib.addOutlineBookmark() }.font(.caption).buttonStyle(.plain).padding(10)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(lib.revision)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) { if let doc = lib.document { ForEach(0..<doc.pageCount, id: \.self) { i in
                            Button { lib.page = i } label: {
                                VStack(spacing: 9) {
                                    if let p = doc.page(at: i) { Image(nsImage: p.thumbnail(of: NSSize(width: 108, height: 140), for: .cropBox)).resizable().scaledToFit().frame(width: 104, height: 135).background(.white).overlay(Rectangle().stroke(lib.page == i ? scanGreen : .clear, lineWidth: 1.5)) }
                                    Text("\(i + 1)").font(.system(size: 13, weight: .medium)).foregroundStyle(lib.page == i ? scanGreen : .secondary)
                                }.padding(16).frame(width: 140).background(lib.page == i ? scanGreen.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).id(i)
                        } } }.padding(.vertical, 8)
                    }.onChange(of: lib.page) { _, page in withAnimation { proxy.scrollTo(page, anchor: .center) } }
                }.id(lib.revision)
            }
            Spacer(minLength: 0)
        }.background(scanCanvas)
    }
}
struct OutlineRow: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    let outline: PDFOutline
    let depth: Int
    @State var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if outline.numberOfChildren > 0 { Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption) }.buttonStyle(.plain) }
                Button(outline.label ?? "Bookmark") { if let page = outline.destination?.page, let doc = lib.document { let index = doc.index(for: page); if index != NSNotFound { lib.page = index } } }.buttonStyle(.plain).font(.system(size: 12)).lineLimit(2)
            }.padding(.leading, CGFloat(depth) * 8 + 12).contextMenu { Button(tr("Remove bookmark")) { lib.snapshot(); outline.removeFromParent(); lib.persist() } }
            if expanded { ForEach(0..<outline.numberOfChildren, id: \.self) { i in if let child = outline.child(at: i) { AnyView(OutlineRow(outline: child, depth: depth + 1)) } } }
        }
    }
}

struct InlinePageGrid: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(tr("Drag to rearrange pages. Hold Command or Shift to select multiple pages.")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 16)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 25)], alignment: .leading, spacing: 26) {
                    if let doc = lib.document { ForEach(0..<doc.pageCount, id: \.self) { i in
                        VStack(spacing: 10) {
                            if let p = doc.page(at: i) { Image(nsImage: p.thumbnail(of: NSSize(width: 140, height: 185), for: .cropBox)).resizable().scaledToFit().frame(width: 135, height: 180).background(.white).overlay(Rectangle().stroke(ui.pageSelection.contains(i) ? scanGreen : Color.gray.opacity(0.2), lineWidth: ui.pageSelection.contains(i) ? 2 : 1)).shadow(color: .black.opacity(0.04), radius: 4) }
                            Text("\(i + 1)").font(.system(size: 14)).foregroundStyle(ui.pageSelection.contains(i) ? scanGreen : .primary)
                        }.padding(15).background(ui.pageSelection.contains(i) ? scanGreen.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { let flags = NSEvent.modifierFlags; if flags.contains(.shift), let first = ui.pageSelection.sorted().first { ui.pageSelection.formUnion(min(first, i)...max(first, i)) } else if flags.contains(.command) || flags.contains(.control) { if ui.pageSelection.contains(i) { ui.pageSelection.remove(i) } else { ui.pageSelection.insert(i) } } else { ui.pageSelection = [i] }; lib.page = i }
                        .draggable(String(i)).dropDestination(for: String.self) { items, _ in guard let item = items.first, let source = Int(item) else { return false }; lib.reorderPage(from: source, to: i); ui.pageSelection = [i]; return true }
                    } }
                }.padding(.vertical, 6)
            }.id(lib.revision)
        }.padding(.horizontal, 35).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct DocumentFooter: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    @State var jump = ""
    var body: some View {
        HStack(spacing: 12) {
            ScanIconButton(symbol: "sidebar.left", help: tr("Toggle thumbnails"), active: ui.showThumbnails) { ui.showThumbnails.toggle() }
            Divider().frame(height: 18)
            ScanIconButton(symbol: "chevron.left.to.line", help: tr("First page")) { lib.page = 0 }.disabled(lib.page == 0)
            ScanIconButton(symbol: "chevron.left", help: tr("Previous page")) { lib.page = max(0, lib.page - 1) }.disabled(lib.page == 0)
            HStack(spacing: 3) { TextField(tr("Page"), text: $jump).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 30).onSubmit { if let i = Int(jump), i >= 1, i <= (lib.document?.pageCount ?? 0) { lib.page = i - 1 } else { jump = "\(lib.page + 1)" } }; Text("/ \(lib.document?.pageCount ?? 0)") }.font(.system(size: 13)).frame(width: 66).environment(\.layoutDirection, .leftToRight)
            ScanIconButton(symbol: "chevron.right", help: tr("Next page")) { lib.page = min((lib.document?.pageCount ?? 1) - 1, lib.page + 1) }.disabled(lib.page >= (lib.document?.pageCount ?? 1) - 1)
            ScanIconButton(symbol: "chevron.right.to.line", help: tr("Last page")) { lib.page = (lib.document?.pageCount ?? 1) - 1 }.disabled(lib.page >= (lib.document?.pageCount ?? 1) - 1)
            Spacer()
            Text(lib.annotationMode == "Mover" ? tr("Drag to move · ⌥ drag to resize") : "").font(.caption).foregroundStyle(.secondary)
            ScanIconButton(symbol: "minus.magnifyingglass", help: tr("Zoom out")) { lib.preview?.zoomOut(nil) }
            Slider(value: Binding(get: { lib.zoom }, set: { value in lib.zoom = value; lib.preview?.autoScales = false; lib.preview?.scaleFactor = value }), in: 0.25...3).frame(width: 100)
            Menu("\(Int(lib.zoom * 100))%") { Button(tr("Fit page")) { lib.preview?.autoScales = true }; ForEach([50, 75, 100, 125, 150, 200], id: \.self) { value in Button("\(value)%") { lib.preview?.autoScales = false; lib.preview?.scaleFactor = CGFloat(value) / 100 } } }.menuStyle(.borderlessButton).frame(width: 65)
            ScanIconButton(symbol: "plus.magnifyingglass", help: tr("Zoom in")) { lib.preview?.zoomIn(nil) }
            ScanIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: tr("Fit page")) { lib.preview?.autoScales = true }
            Divider().frame(height: 18)
            ScanIconButton(symbol: "doc", help: tr("Single page")) { lib.viewMode("Una") }
            ScanIconButton(symbol: "rectangle.split.2x1", help: tr("Double page")) { lib.viewMode("Doble") }
            ScanIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: tr("Full screen")) { NSApp.keyWindow?.toggleFullScreen(nil) }
        }.padding(.horizontal, 18).frame(height: 40).overlay(alignment: .top) { Divider() }.background(scanCanvas).onAppear { jump = "\(lib.page + 1)" }.onChange(of: lib.page) { _, page in jump = "\(page + 1)" }
    }
}

struct OCRWorkspace: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    var body: some View {
        VStack(spacing: 12) { HStack { Text(tr("Extract Text")).font(.headline); Spacer(); ScanIconButton(symbol: "xmark", help: tr("Close text")) { ui.showOCR = false } }; TextEditor(text: Binding(get: { lib.current?.text ?? "" }, set: { value in lib.update { $0.text = value } })).font(.system(size: 13)); HStack { Button(tr("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lib.current?.text ?? "", forType: .string) }; Button(tr("Save TXT")) { lib.exportText() }; Button(tr("Recognize")) { lib.recognize() } } }.padding(14).background(.white)
    }
}

extension Library {
    func findDocumentText(_ query: String) {
        guard let doc = document, !query.isEmpty else { return }
        let matches = doc.findString(query, withOptions: .caseInsensitive)
        guard let selection = matches.first, let p = selection.pages.first else { message = tr("No matching text"); return }
        preview?.setCurrentSelection(selection, animate: true); preview?.go(to: selection); let i = doc.index(for: p); if i != NSNotFound { page = i }; message = tr("{0} matches", String(describing: matches.count))
    }
    func addOutlineBookmark() {
        guard let doc = document, let p = doc.page(at: page) else { return }
        snapshot(); let root = doc.outlineRoot ?? PDFOutline(); let item = PDFOutline(); item.label = "Page \(page + 1)"; item.destination = PDFDestination(page: p, at: CGPoint(x: 0, y: p.bounds(for: .cropBox).maxY)); root.insertChild(item, at: root.numberOfChildren); doc.outlineRoot = root; persist()
    }
}

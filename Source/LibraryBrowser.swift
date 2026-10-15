import SwiftUI
import AppKit
import PDFKit

private enum BrowserDialog: String, Identifiable { case tags, manageTags, protect, download, share; var id: String { rawValue } }
struct LibraryBrowser: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var ui: WorkspaceState
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @State private var selection: Set<UUID> = []
    @State private var display = 2
    @State private var draftFolder: String?
    @State private var dialog: BrowserDialog?
    @State private var renameID: UUID?
    @State private var renameFolder: String?
    @State private var renameValue = ""
    @State private var renaming = false
    @State private var deleteFolder: String?
    @State private var deleting = false
    @State private var conflict = false
    @State private var tagSearch = ""
    @State private var tagInput = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var imageDownload = false
    private var shownFolders: [String] {
        if lib.starredOnly || lib.signedOnly || lib.typeFilter != "All" || !lib.tagFilter.isEmpty { return [] }
        return lib.childFolders(of: lib.folderFilter, trashed: lib.trashOnly).filter { lib.query.isEmpty || $0.localizedStandardContains(lib.query) }
    }
    private var selectedRecords: [Record] { lib.records.filter { selection.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView(.horizontal, showsIndicators: false) { actionBar }
            HStack {
                Button(tr("All Docs")) { lib.folderFilter = nil; lib.rootFolderOnly = true; selection = [] }.buttonStyle(.plain)
                if let folder = lib.folderFilter {
                    Image(systemName: "chevron.right"); Text(folder)
                    Button { let parts = folder.split(separator: "/").dropLast(); lib.folderFilter = parts.isEmpty ? nil : parts.joined(separator: "/") } label: { Image(systemName: "arrow.up") }.help(tr("Back"))
                }
                Text("(\(lib.filtered.count))").foregroundStyle(.secondary)
                Spacer()
                typeMenu
                tagMenu
                Menu { ForEach(LibrarySort.allCases, id: \.self) { sort in Button { lib.librarySort = sort; lib.sortByName = false } label: { Label(tr(sort.rawValue), systemImage: lib.librarySort == sort ? "checkmark" : "") } } } label: { Label(tr(lib.librarySort.rawValue), systemImage: "arrow.down") }.menuStyle(.borderlessButton).fixedSize()
                ForEach(0..<3) { mode in ScanIconButton(symbol: ["list.bullet", "square.grid.2x2", "rectangle.grid.2x2"][mode], help: tr(["List view", "Small tiles", "Large previews"][mode]), active: display == mode) { display = mode } }
            }.font(.system(size: 14))
            HStack {
                Toggle(isOn: Binding(get: { !lib.filtered.isEmpty && Set(lib.filtered.map(\.id)).isSubset(of: selection) }, set: { selection = $0 ? Set(lib.filtered.map(\.id)) : [] })) { Text(selection.isEmpty ? tr("{0} folders, {1} documents", String(shownFolders.count), String(lib.filtered.count)) : tr("{0} documents selected", String(selection.count))) }.toggleStyle(.checkbox)
                Spacer()
                if lib.typeFilter != "All" || !lib.tagFilter.isEmpty { Button(tr("Clear filters")) { lib.typeFilter = "All"; lib.tagFilter = [] } }
            }.font(.system(size: 13))
            ScrollView {
                if display == 0 {
                    VStack(spacing: 0) {
                        HStack { Text(tr("Name")); Spacer(); Text(tr("Count")); Text(tr("Modified")).frame(width: 145) }.font(.caption).foregroundStyle(.secondary).padding(12)
                        if draftFolder != nil { folderDraft }
                        ForEach(shownFolders, id: \.self) { folder in folderCard(folder) }
                        ForEach(lib.filtered) { record in documentCard(record) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: display == 1 ? 155 : 250), alignment: .top)], spacing: 18) {
                        if draftFolder != nil { folderDraft }
                        ForEach(shownFolders, id: \.self) { folder in folderCard(folder) }
                        ForEach(lib.filtered) { record in documentCard(record) }
                    }.padding(2)
                }
                if lib.filtered.isEmpty && shownFolders.isEmpty && draftFolder == nil { Text(tr("No file available. Import one and try")).foregroundStyle(.secondary).padding(65) }
            }
            Text(trStatus(lib.message)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(22)
        .dropDestination(for: URL.self) { urls, _ in lib.importFiles(urls); return true }
        .onChange(of: ui.section) { _, _ in selection = [] }
        .onChange(of: lib.folderFilter) { _, _ in selection = [] }
        .onChange(of: lib.trashOnly) { _, _ in selection = [] }
        .onChange(of: lib.query) { _, _ in selection = [] }
        .onChange(of: lib.records.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .sheet(item: $dialog, onDismiss: { password = ""; confirmation = "" }) { value in dialogView(value).environmentObject(appLanguage) }
        .alert(tr("Rename"), isPresented: $renaming) { TextField(tr("Name"), text: $renameValue); Button(tr("Cancel"), role: .cancel) {}; Button(tr("Save")) { perform { if let id = renameID { try lib.renameRecord(id, to: renameValue) }; if let folder = renameFolder { try lib.renameFolder(folder, to: renameValue) } } } }
        .alert(tr("Move document to Trash?"), isPresented: $deleting) { Button(tr("Cancel"), role: .cancel) { deleteFolder = nil }; Button(tr("Move to Trash"), role: .destructive) { perform { if let folder = deleteFolder { try lib.trashFolder(folder) } else { try lib.trashRecords(selection) }; deleteFolder = nil; selection = [] } } } message: { Text(tr("You can recover it from Trash. No automatic deletion.")) }
        .alert(tr("Create a copy?"), isPresented: $conflict) { Button(tr("Cancel"), role: .cancel) {}; Button(tr("Keep Both")) { perform { try lib.pasteRecords() } } } message: { Text(tr("Files with the same name will receive a numbered suffix.")) }
        .background { keyboardActions }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { lib.error = error.localizedDescription } }
    private func paste() { if lib.pasteHasConflict { conflict = true } else { perform { try lib.pasteRecords() } } }
    private var keyboardActions: some View {
        Group {
            Button("") { lib.copyRecords(selection, cut: false) }.keyboardShortcut("c", modifiers: .command).disabled(selection.isEmpty)
            Button("") { lib.copyRecords(selection, cut: true) }.keyboardShortcut("x", modifiers: .command).disabled(selection.isEmpty)
            Button("") { paste() }.keyboardShortcut("v", modifiers: .command).disabled(lib.clipboard == nil)
        }.hidden().accessibilityHidden(true)
    }
    @ViewBuilder private var actionBar: some View {
        HStack(spacing: 8) {
            if selection.isEmpty {
                ScanToolButton(title: "Import Images", symbol: "photo.fill") { lib.chooseLibraryImport(images: true) }
                ScanToolButton(title: "Import Files", symbol: "doc.fill") { lib.chooseLibraryImport(images: false) }
                ScanToolButton(title: "Smart Scan", symbol: "camera.fill") { ui.panel = .camera }
                if !lib.trashOnly { ScanToolButton(title: "New Folder", symbol: "folder.badge.plus") { draftFolder = (lib.folderFilter.map { $0 + "/" } ?? "") + tr("New folder") } }
                if lib.clipboard != nil { ScanToolButton(title: "Paste", symbol: "doc.on.clipboard") { paste() } }
            } else if lib.trashOnly {
                ScanToolButton(title: "Restore", symbol: "arrow.uturn.backward") { perform { try lib.restoreRecords(selection); selection = [] } }
            } else {
                ScanToolButton(title: "Share", symbol: "square.and.arrow.up") { share() }.disabled(selection.count != 1)
                ScanToolButton(title: "Download", symbol: "arrow.down.to.line") { dialog = .download }
                ScanToolButton(title: "Copy", symbol: "plus.square.on.square") { lib.copyRecords(selection, cut: false) }
                ScanToolButton(title: "Cut", symbol: "scissors") { lib.copyRecords(selection, cut: true) }
                ScanToolButton(title: "Paste", symbol: "doc.on.clipboard") { paste() }.disabled(lib.clipboard == nil)
                ScanToolButton(title: "Rename", symbol: "pencil") { if let r = selectedRecords.first { rename(r) } }.disabled(selection.count != 1)
                ScanToolButton(title: "Tags", symbol: "tag") { prepareTags() }
                ScanToolButton(title: "Protect Document", symbol: "lock") { dialog = .protect }
                ScanToolButton(title: "Delete", symbol: "trash") { deleting = true }
            }
            Spacer(minLength: 0)
        }.foregroundStyle(scanGreen).frame(minHeight: 42)
    }
    private var typeMenu: some View {
        Menu {
            ForEach(["All", "Scans", "PDF", "Word", "Excel", "PPT", "Markdown", "HTML"], id: \.self) { type in
                let count = lib.records.filter { $0.trashedAt == nil && (type == "All" || lib.recordType($0) == type) && (lib.folderFilter == nil || $0.folder == lib.folderFilter) }.count
                Button { lib.typeFilter = type; selection = [] } label: { Text(tr(type) + " (\(count))" + (lib.typeFilter == type ? " ✓" : "")) }
            }
        } label: { Label(tr(lib.typeFilter == "All" ? "Document Type" : lib.typeFilter), systemImage: "doc.text") }.menuStyle(.borderlessButton).fixedSize()
    }
    private var tagMenu: some View {
        Menu {
            ForEach(lib.tagCatalog, id: \.self) { tag in Toggle(tag + " (\(lib.records.filter { $0.trashedAt == nil && ($0.tags ?? []).contains(tag) }.count))", isOn: Binding(get: { lib.tagFilter.contains(tag) }, set: { if $0 { lib.tagFilter.insert(tag) } else { lib.tagFilter.remove(tag) }; selection = [] })) }
            Button(tr("Manage Tags")) { dialog = .manageTags }
        } label: { Label(tr("Tags"), systemImage: "tag") }.menuStyle(.borderlessButton).fixedSize()
    }
    private var folderDraft: some View {
        HStack { Image(systemName: "folder.fill").foregroundStyle(scanGreen); TextField(tr("New folder"), text: Binding(get: { draftFolder ?? "" }, set: { draftFolder = $0 })).onSubmit { createFolder() }; Button { createFolder() } label: { Image(systemName: "checkmark").foregroundStyle(scanGreen) }; Button { draftFolder = nil } label: { Image(systemName: "xmark") } }.padding(16).background(scanCanvas, in: RoundedRectangle(cornerRadius: 12))
    }
    private func createFolder() { guard let name = draftFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }; if lib.folders.contains(name) { lib.error = tr("A folder with this name already exists") } else { lib.createFolder(name); if lib.folders.contains(name) { draftFolder = nil } } }
    private func folderCard(_ folder: String) -> some View {
        Button { if lib.trashOnly { perform { try lib.restoreFolder(folder) } } else { lib.folderFilter = folder; selection = [] } } label: {
            HStack { Image(systemName: "folder.fill").font(.system(size: 28)).foregroundStyle(scanGreen); Text(folder.components(separatedBy: "/").last ?? folder).lineLimit(2); Spacer(); Text("\(lib.records.filter { lib.folderContains($0.folder, in: folder) && $0.trashedAt == nil }.count)").foregroundStyle(.secondary) }.padding(16).frame(maxWidth: .infinity, minHeight: 65).background(scanCanvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).scanCardShadow(enabled: display != 0)
        }.buttonStyle(.plain).contextMenu {
            if lib.trashOnly { Button(tr("Restore")) { perform { try lib.restoreFolder(folder) } } } else {
            Button(tr("Open")) { lib.folderFilter = folder }
            Button(tr("Download")) { selection = Set(lib.records.filter { lib.folderContains($0.folder, in: folder) && $0.trashedAt == nil }.map(\.id)); dialog = .download }
            Button(tr("Cut")) { lib.folderFilter = folder; selection = Set(lib.filtered.map(\.id)); lib.copyRecords(selection, cut: true) }
            Button(tr("Paste")) { lib.folderFilter = folder; paste() }.disabled(lib.clipboard == nil)
            Button(tr("Rename")) { renameID = nil; renameFolder = folder; renameValue = folder; renaming = true }
            Button(tr("Protect documents in folder")) { selection = Set(lib.records.filter { lib.folderContains($0.folder, in: folder) && $0.trashedAt == nil }.map(\.id)); dialog = .protect }
            Button(tr("Delete"), role: .destructive) { deleteFolder = folder; deleting = true }
            }
        }
    }
    private func documentCard(_ r: Record) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selection.contains(r.id) }, set: { if $0 { selection.insert(r.id) } else { selection.remove(r.id) } })).labelsHidden().toggleStyle(.checkbox).accessibilityLabel(tr("Select") + " " + r.name)
            Button { if lib.trashOnly { selection = [r.id] } else { lib.select(r.id) } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if display == 2 { if r.passwordProtected == true { Image(systemName: "lock.doc.fill").font(.system(size: 44)).frame(maxWidth: .infinity).frame(height: 150).foregroundStyle(scanGreen) } else { DocumentThumbnail(record: r).id(r.updatedAt ?? r.date).frame(maxWidth: .infinity).frame(height: 150) } }
                    HStack { Image(systemName: r.passwordProtected == true ? "lock.fill" : "doc.fill").foregroundStyle(.orange); Text(r.name).lineLimit(2); if display == 0 { Spacer(); Text("\(PDFDocument(url: lib.url(r.id))?.pageCount ?? 0)").font(.caption); Text((r.updatedAt ?? r.date).formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(appLanguage.locale))).font(.caption).frame(width: 145) } }
                    if display != 0 { Text((r.tags ?? []).joined(separator: " · ")).lineLimit(1).font(.caption).foregroundStyle(scanGreen); Text((r.updatedAt ?? r.date).formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(appLanguage.locale))).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(12).background(selection.contains(r.id) ? scanGreen.opacity(0.08) : .white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(selection.contains(r.id) ? scanGreen : .gray.opacity(0.15))).scanCardShadow(enabled: display != 0).opacity(lib.clipboard?.cut == true && lib.clipboard?.ids.contains(r.id) == true ? 0.5 : 1)
        .contextMenu { recordMenu(r) }
    }
    @ViewBuilder private func recordMenu(_ r: Record) -> some View {
        if lib.trashOnly { Button(tr("Restore")) { perform { try lib.restoreRecords([r.id]) } } }
        else {
            Button(tr("Open")) { lib.select(r.id) }
            Button(tr("Share")) { selection = [r.id]; share() }
            Button(tr("Download")) { selection = [r.id]; dialog = .download }
            Button(tr("Copy")) { lib.copyRecords(selection.contains(r.id) ? selection : [r.id], cut: false) }
            Button(tr("Cut")) { lib.copyRecords(selection.contains(r.id) ? selection : [r.id], cut: true) }
            Button(tr("Paste")) { paste() }.disabled(lib.clipboard == nil)
            Button(tr("Rename")) { rename(r) }
            Button(tr("Protect Document")) { selection = [r.id]; dialog = .protect }
            Button(tr("Tags")) { selection = [r.id]; prepareTags() }
            Button(tr("Delete"), role: .destructive) { if !selection.contains(r.id) { selection = [r.id] }; deleting = true }
        }
    }
    private func rename(_ record: Record) { renameID = record.id; renameFolder = nil; renameValue = record.name; renaming = true }
    private func prepareTags() { tagInput = selectedRecords.count == 1 ? (selectedRecords.first?.tags ?? []).joined(separator: ", ") : ""; dialog = .tags }
    private func share() { dialog = .share }
    private func systemShare() {
        guard let r = selectedRecords.first else { return }
        let picker = NSSharingServicePicker(items: [lib.url(r.id)])
        if let view = NSApp.keyWindow?.contentView { picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY) }
    }
    @ViewBuilder private func dialogView(_ value: BrowserDialog) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(tr(value == .manageTags ? "Manage Tags" : value == .tags ? "Tags" : value == .protect ? "Protect Document" : value == .share ? "Share" : "Download")).font(.title2.bold()); Spacer(); Button(tr("Close")) { dialog = nil } }
            if value == .tags {
                Text(tr("Tags separated by commas. Replaces tags on selected documents."))
                TextField(tr("Tags"), text: $tagInput)
                ScrollView { ForEach(lib.tagCatalog, id: \.self) { tag in Button(tag) { var values = tagInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; if !values.contains(tag) { values.append(tag) }; tagInput = values.joined(separator: ", ") }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(4) } }.frame(height: 150)
                Button(tr("Confirm")) { perform { try lib.setTags(tagInput.split(separator: ",").map(String.init), for: selection); dialog = nil } }.buttonStyle(.borderedProminent)
            } else if value == .manageTags {
                HStack { TextField(tr("Add Tags"), text: $tagInput); Button(tr("Add")) { let tag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines); if !tag.isEmpty && !lib.tagCatalog.contains(tag) { lib.tagCatalog.append(tag); perform { try lib.saveOrganization() } }; tagInput = "" } }
                TextField(tr("Search tags"), text: $tagSearch)
                List { ForEach(lib.tagCatalog.filter { tagSearch.isEmpty || $0.localizedStandardContains(tagSearch) }, id: \.self) { tag in TagEditRow(tag: tag, lib: lib) }.onMove { from, to in guard tagSearch.isEmpty else { return }; lib.tagCatalog.move(fromOffsets: from, toOffset: to); perform { try lib.saveOrganization() } } }.frame(height: 260)
            } else if value == .protect {
                Text(tr("A password will be required to open these PDFs, including exported copies. Keep your password; it cannot be recovered."))
                SecureField(tr("Enter a new password"), text: $password)
                SecureField(tr("Re-enter your new password"), text: $confirmation)
                Button(tr("Confirm")) { perform { try lib.protectRecords(selection, password: password); password = ""; confirmation = ""; selection = []; dialog = nil } }.buttonStyle(.borderedProminent).disabled(password.isEmpty || password != confirmation || selection.isEmpty)
            } else if value == .share {
                Text(selectedRecords.first?.name ?? "")
                Button(tr("Share PDF file")) { dialog = nil; systemShare() }
                Text(tr("Local links work only on this Mac while the private server is running."))
                Button(tr("Create local link…")) { if let id = selection.first { lib.selected = id }; dialog = nil; ui.panel = .account }
            } else {
                Picker(tr("Format"), selection: $imageDownload) { Text("PDF").tag(false); Text("PNG").tag(true) }.pickerStyle(.segmented)
                if selection.count == 1 {
                    HStack { ForEach([LandingTool.word, .excel, .ppt, .text], id: \.self) { tool in Button(tr(tool.rawValue)) { if let id = selection.first { lib.select(id); if lib.document != nil { dialog = nil; ui.openLanding(tool) } } } } }
                }
                Button(tr("Download")) { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = tr("Exportar aquí"); guard panel.runModal() == .OK, let directory = panel.url else { return }; perform { try lib.exportRecords(selection, directory: directory, images: imageDownload); dialog = nil } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 550)
    }
}
private struct TagEditRow: View {
    let tag: String
    @ObservedObject var lib: Library
    @State private var value = ""
    @State private var editing = false
    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            if editing { TextField(tag, text: $value).onSubmit { save() }; Button(tr("Save")) { save() } } else { Text(tag); Spacer(); Button { value = tag; editing = true } label: { Image(systemName: "pencil") } }
            Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(lib.tagCatalog.first == tag)
            Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(lib.tagCatalog.last == tag)
            Button { do { try lib.deleteTag(tag) } catch { lib.error = error.localizedDescription } } label: { Image(systemName: "trash") }.help(tr("Remove tag from all documents"))
        }
    }
    private func move(_ offset: Int) { guard let index = lib.tagCatalog.firstIndex(of: tag), lib.tagCatalog.indices.contains(index + offset) else { return }; lib.tagCatalog.swapAt(index, index + offset); do { try lib.saveOrganization() } catch { lib.error = error.localizedDescription } }
    private func save() { do { try lib.renameTag(tag, to: value); editing = false } catch { lib.error = error.localizedDescription } }
}

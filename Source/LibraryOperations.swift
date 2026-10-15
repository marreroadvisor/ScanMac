import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable {
    case editedNewest = "Date Edited (Newest First)", editedOldest = "Date Edited (Oldest First)", createdNewest = "Date Created (Newest First)", createdOldest = "Date Created (Oldest First)", nameAZ = "Name (A to Z)", nameZA = "Name (Z to A)", type = "Document Type"
}
struct LibraryClipboard { let ids: Set<UUID>; let sourceFolder: String?; let cut: Bool }

@MainActor extension Library {
    func libraryRecords() -> [Record] {
        records.filter { r in
            (trashOnly ? r.trashedAt != nil : r.trashedAt == nil) && (!starredOnly || r.starred) && (!signedOnly || r.signed == true) && (folderFilter == nil || r.folder == folderFilter) && (!rootFolderOnly || folderFilter != nil || !query.isEmpty || typeFilter != "All" || !tagFilter.isEmpty || trashOnly || starredOnly || signedOnly || r.folder == nil) && (typeFilter == "All" || recordType(r) == typeFilter) && (tagFilter.isEmpty || !tagFilter.isDisjoint(with: r.tags ?? [])) && (query.isEmpty || [r.name, r.passwordProtected == true ? "" : r.text, (r.tags ?? []).joined(separator: " ")].contains { $0.localizedStandardContains(query) })
        }.sorted { a, b in
            if sortByName { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            switch librarySort {
            case .editedNewest: return (a.updatedAt ?? a.date) == (b.updatedAt ?? b.date) ? a.id.uuidString < b.id.uuidString : (a.updatedAt ?? a.date) > (b.updatedAt ?? b.date)
            case .editedOldest: return (a.updatedAt ?? a.date) < (b.updatedAt ?? b.date)
            case .createdNewest: return a.date > b.date
            case .createdOldest: return a.date < b.date
            case .nameAZ: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .nameZA: return a.name.localizedStandardCompare(b.name) == .orderedDescending
            case .type: return recordType(a) == recordType(b) ? a.name.localizedStandardCompare(b.name) == .orderedAscending : recordType(a) < recordType(b)
            }
        }
    }
    func recordType(_ record: Record) -> String { record.sourceType ?? "PDF" }
    func writeOptions(for id: UUID) -> [PDFDocumentWriteOption: Any] {
        guard let password = unlockedPasswords[id] else { return [:] }
        return [.userPasswordOption: password, .ownerPasswordOption: password]
    }
    func saveOrganization() throws {
        try JSONEncoder().encode(folders).write(to: root.appendingPathComponent("folders.json"), options: .atomic)
        try JSONEncoder().encode(trashedFolders).write(to: root.appendingPathComponent("trashed-folders.json"), options: .atomic)
        try JSONEncoder().encode(tagCatalog).write(to: root.appendingPathComponent("tags.json"), options: .atomic)
    }
    func mutateRecords(_ action: () throws -> Void) throws {
        let old = records
        do { try action(); try saveIndex() } catch { records = old; throw error }
    }
    func renameRecord(_ id: UUID, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = records.firstIndex(where: { $0.id == id }) else { throw CocoaError(.validationMissingMandatoryProperty) }
        try mutateRecords { records[i].name = clean; records[i].updatedAt = Date() }
    }
    func uniqueName(_ name: String, folder: String?, excluding: UUID? = nil, extra: [String] = []) -> String {
        let names = Set(records.filter { $0.trashedAt == nil && $0.folder == folder && $0.id != excluding }.map(\.name) + extra)
        if !names.contains(name) { return name }
        var n = 1; while names.contains("\(name)(\(n))") { n += 1 }; return "\(name)(\(n))"
    }
    func copyRecords(_ ids: Set<UUID>, cut: Bool) { clipboard = LibraryClipboard(ids: ids, sourceFolder: folderFilter, cut: cut); message = tr(cut ? "Cut to clipboard" : "Copied") }
    var pasteHasConflict: Bool {
        guard let clipboard else { return false }
        return records.filter { clipboard.ids.contains($0.id) && $0.trashedAt == nil }.contains { r in records.contains { $0.trashedAt == nil && $0.folder == folderFilter && $0.name == r.name && (!clipboard.cut || $0.id != r.id) } }
    }
    func pasteRecords() throws {
        guard let clipboard else { return }
        let sources = records.filter { clipboard.ids.contains($0.id) && $0.trashedAt == nil }
        guard !sources.isEmpty else { return }
        if clipboard.cut && sources.allSatisfy({ $0.folder == folderFilter }) { throw AdvancedPDFError.invalid(tr("Can't paste to the same location")) }
        let old = records; var created: [URL] = []; var names: [String] = []
        do {
            for var r in sources {
                let name = uniqueName(r.name, folder: folderFilter, excluding: clipboard.cut ? r.id : nil, extra: names); names.append(name)
                if !clipboard.cut { let id = UUID(); try FileManager.default.copyItem(at: url(r.id), to: url(id)); created.append(url(id)); r.id = id; r.date = Date() }
                r.name = name; r.folder = folderFilter; r.updatedAt = Date()
                if clipboard.cut, let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.append(r) }
            }
            try saveIndex(); if clipboard.cut { self.clipboard = nil }; message = tr("Saved")
        } catch { records = old; for file in created { try? FileManager.default.removeItem(at: file) }; throw error }
    }
    func trashRecords(_ ids: Set<UUID>) throws {
        try mutateRecords { for i in records.indices where ids.contains(records[i].id) { records[i].trashedAt = Date(); records[i].updatedAt = Date(); sessions.removeValue(forKey: records[i].id); unlockedPasswords.removeValue(forKey: records[i].id) } }
        if let selected, ids.contains(selected) { self.selected = nil; document = nil; history = []; redoHistory = [] }
        message = tr("Documento movido a la papelera")
    }
    func restoreRecords(_ ids: Set<UUID>) throws {
        try mutateRecords { for i in records.indices where ids.contains(records[i].id) { records[i].trashedAt = nil; records[i].updatedAt = Date() } }
        let restoredFolders = records.filter { ids.contains($0.id) }.compactMap(\.folder); folders = Array(Set(folders + restoredFolders)).sorted(); trashedFolders.removeAll { restoredFolders.contains($0) }; try saveOrganization()
    }
    func folderContains(_ candidate: String?, in parent: String) -> Bool {
        guard let candidate else { return false }; return candidate == parent || candidate.hasPrefix(parent + "/")
    }
    func childFolders(of parent: String?, trashed: Bool = false) -> [String] {
        let prefix = parent.map { $0 + "/" } ?? ""
        return (trashed ? trashedFolders : folders).filter { path in
            guard path.hasPrefix(prefix) else { return false }
            return !String(path.dropFirst(prefix.count)).contains("/") && path != parent
        }.sorted()
    }
    func renameFolder(_ old: String, to value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean == old || (!clean.hasPrefix(old + "/") && !folders.contains(clean)) else { throw AdvancedPDFError.invalid(tr("A folder with this name already exists")) }
        let before = folders
        func renamed(_ path: String) -> String { path == old ? clean : clean + path.dropFirst(old.count) }
        let moved = folders.filter { folderContains($0, in: old) }
        guard moved.allSatisfy({ path in !folders.filter { !moved.contains($0) }.contains(renamed(path)) }) else { throw AdvancedPDFError.invalid(tr("A folder with this name already exists")) }
        do { try mutateRecords { for i in records.indices where folderContains(records[i].folder, in: old) { records[i].folder = renamed(records[i].folder!); records[i].updatedAt = Date() }; folders = folders.map { folderContains($0, in: old) ? renamed($0) : $0 }; try saveOrganization() }; if let current = folderFilter, folderContains(current, in: old) { folderFilter = renamed(current) } }
        catch { folders = before; try? saveOrganization(); throw error }
    }
    func trashFolder(_ name: String) throws {
        let moved = folders.filter { folderContains($0, in: name) }
        try trashRecords(Set(records.filter { folderContains($0.folder, in: name) && $0.trashedAt == nil }.map(\.id)))
        for folder in moved where !trashedFolders.contains(folder) { trashedFolders.append(folder) }
        folders.removeAll { folderContains($0, in: name) }; try saveOrganization(); if folderContains(folderFilter, in: name) { folderFilter = nil }
    }
    func restoreFolder(_ name: String) throws {
        let moved = trashedFolders.filter { folderContains($0, in: name) }
        try restoreRecords(Set(records.filter { folderContains($0.folder, in: name) && $0.trashedAt != nil }.map(\.id)))
        for folder in moved where !folders.contains(folder) { folders.append(folder) }
        if !folders.contains(name) { folders.append(name) }; folders.sort(); trashedFolders.removeAll { folderContains($0, in: name) }; try saveOrganization()
    }
    func setTags(_ tags: [String], for ids: Set<UUID>) throws {
        let clean = Array(NSOrderedSet(array: tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
        try mutateRecords { for i in records.indices where ids.contains(records[i].id) { records[i].tags = clean; records[i].updatedAt = Date() } }
        for tag in clean where !tagCatalog.contains(tag) { tagCatalog.append(tag) }; try saveOrganization()
    }
    func renameTag(_ old: String, to value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        try mutateRecords { for i in records.indices { records[i].tags = Array(Set((records[i].tags ?? []).map { $0 == old ? clean : $0 })).sorted() } }
        tagCatalog = tagCatalog.map { $0 == old ? clean : $0 }; tagCatalog = Array(NSOrderedSet(array: tagCatalog)) as? [String] ?? []
        if tagFilter.remove(old) != nil { tagFilter.insert(clean) }; try saveOrganization()
    }
    func deleteTag(_ tag: String) throws {
        try mutateRecords { for i in records.indices { records[i].tags?.removeAll { $0 == tag } } }
        tagCatalog.removeAll { $0 == tag }; tagFilter.remove(tag); try saveOrganization()
    }
    func protectRecords(_ ids: Set<UUID>, password: String) throws {
        guard !password.isEmpty else { throw AdvancedPDFError.invalid(tr("Escribe una contraseña para proteger la copia.")) }
        let sources = records.filter { ids.contains($0.id) && $0.trashedAt == nil }
        var outputs: [(UUID, Data, Data)] = []
        for r in sources {
            let original = try Data(contentsOf: url(r.id)); guard let pdf = PDFDocument(data: original) else { throw CocoaError(.fileReadCorruptFile) }; if pdf.isLocked { guard let currentPassword = unlockedPasswords[r.id], pdf.unlock(withPassword: currentPassword) else { throw AdvancedPDFError.invalid(tr("Open the protected document first")) } }
            let owner = UUID().uuidString + UUID().uuidString
            guard let data = pdf.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: password, PDFDocumentWriteOption.ownerPasswordOption: owner]), let check = PDFDocument(data: data), check.isLocked, check.unlock(withPassword: password), check.pageCount == pdf.pageCount else { throw CocoaError(.fileWriteUnknown) }
            outputs.append((r.id, original, data))
        }
        let old = records
        do {
            for (id, _, data) in outputs { try data.write(to: url(id), options: .atomic); if let i = records.firstIndex(where: { $0.id == id }) { records[i].passwordProtected = true; records[i].text = ""; records[i].updatedAt = Date() } }
            try saveIndex()
        } catch { records = old; for (id, data, _) in outputs { try? data.write(to: url(id), options: .atomic) }; throw error }
        for id in ids { sessions.removeValue(forKey: id); unlockedPasswords.removeValue(forKey: id) }
        if let selected, ids.contains(selected) { self.selected = nil; document = nil; history = []; redoHistory = [] }
        revision = UUID(); message = tr("Saved")
    }
    func chooseLibraryImport(images: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = images ? [.image] : [.pdf, .plainText, .rtf, .html, UTType(filenameExtension: "docx")!]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let destination = folderFilter
        for source in panel.urls {
            if !images && source.pathExtension.lowercased() != "pdf" { let priorIDs = Set(records.map(\.id)); importRichText(source: source); if let selected, !priorIDs.contains(selected) { update { $0.folder = destination; $0.sourceType = source.pathExtension.lowercased() == "docx" ? "Word" : source.pathExtension.lowercased() == "html" ? "HTML" : "Markdown" } } }
            else { importFiles([source]) }
        }
    }
    func exportRecords(_ ids: Set<UUID>, directory: URL, images: Bool = false) throws {
        for r in records.filter({ ids.contains($0.id) }) {
            let safe = String(r.name.map { "/:\\".contains($0) ? "_" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = safe.isEmpty || safe == "." || safe == ".." ? r.id.uuidString : safe
            func free(_ stem: String, _ ext: String) -> URL { var n = 0; var dest = directory.appendingPathComponent(stem + "." + ext); while FileManager.default.fileExists(atPath: dest.path) { n += 1; dest = directory.appendingPathComponent("\(stem)(\(n)).\(ext)") }; return dest }
            if images {
                guard let pdf = PDFDocument(url: url(r.id)) else { throw CocoaError(.fileReadCorruptFile) }; if pdf.isLocked { guard let password = unlockedPasswords[r.id], pdf.unlock(withPassword: password) else { throw AdvancedPDFError.invalid(tr("Open the protected document first")) } }
                for i in 0..<pdf.pageCount { guard let p = pdf.page(at: i), let cg = imageOfPage(p), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }; try data.write(to: free(name + "-\(i+1)", "png"), options: .atomic) }
            } else { try FileManager.default.copyItem(at: url(r.id), to: free(name, "pdf")) }
        }
        message = tr("PDF exportado")
    }
}

import AppKit
import PDFKit

@main struct LibraryHarness {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scanmac-library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = Library(rootOverride: root)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        lib.importFiles([fixture]); guard let id = lib.selected else { fatalError("import") }
        precondition(lib.document?.pageCount == 1)
        try lib.renameRecord(id, to: "Alpha")
        lib.copyRecords([id], cut: false); precondition(lib.pasteHasConflict); try lib.pasteRecords()
        precondition(lib.records.count == 2 && lib.records.contains { $0.name == "Alpha(1)" })
        let copy = lib.records.first { $0.id != id }!.id
        lib.createFolder("Destination"); lib.copyRecords([copy], cut: true)
        do { try lib.pasteRecords(); fatalError("same folder paste allowed") } catch {}
        lib.folderFilter = "Destination"; try lib.pasteRecords()
        precondition(lib.records.first { $0.id == copy }?.folder == "Destination" && lib.clipboard == nil)
        try lib.renameFolder("Destination", to: "Renamed"); precondition(lib.records.first { $0.id == copy }?.folder == "Renamed")
        lib.browse("Todos"); precondition(lib.filtered.map(\.id) == [id], "root must hide documents assigned to folders")
        lib.query = "Alpha"; precondition(lib.filtered.count == 2, "global search must include filed documents")
        lib.browse("Carpeta", folder: "Renamed"); precondition(lib.filtered.map(\.id) == [copy])
        lib.browse("Inicio"); precondition(lib.filtered.count == 2, "recents must retain access to filed documents")
        try lib.setTags(["Test", "Second", "Test"], for: [id, copy]); precondition(lib.tagCatalog == ["Test", "Second"])
        try lib.renameTag("Test", to: "Edited"); precondition(lib.records.allSatisfy { ($0.tags ?? []).contains("Edited") })
        lib.folderFilter = nil; lib.tagFilter = ["Edited"]; precondition(lib.filtered.count == 2)
        lib.query = "alpha"; precondition(lib.filtered.count == 2); lib.query = "missing"; precondition(lib.filtered.isEmpty); lib.query = ""; lib.tagFilter = []
        lib.typeFilter = "Scans"; precondition(lib.filtered.isEmpty); lib.typeFilter = "PDF"; precondition(lib.filtered.count == 2); lib.typeFilter = "All"
        for sort in LibrarySort.allCases { lib.librarySort = sort; precondition(lib.filtered.count == 2) }
        lib.librarySort = .nameAZ; precondition(lib.filtered.first?.name == "Alpha")
        lib.librarySort = .nameZA; precondition(lib.filtered.first?.name == "Alpha(1)")
        try lib.deleteTag("Edited"); precondition(lib.records.allSatisfy { !($0.tags ?? []).contains("Edited") })
        let exports = root.appendingPathComponent("export"); try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try lib.exportRecords([id,copy], directory: exports); try lib.exportRecords([id], directory: exports)
        let pdfFiles = try FileManager.default.contentsOfDirectory(atPath: exports.path); precondition(pdfFiles.count == 3)
        try lib.exportRecords([id], directory: exports, images: true)
        let imageFiles = try FileManager.default.contentsOfDirectory(atPath: exports.path); precondition(imageFiles.contains { $0.hasSuffix(".png") })
        try lib.trashFolder("Renamed"); precondition(lib.records.first { $0.id == copy }?.trashedAt != nil && !lib.folders.contains("Renamed"))
        try lib.restoreRecords([copy]); precondition(lib.folders.contains("Renamed") && lib.records.first { $0.id == copy }?.trashedAt == nil)
        lib.createFolder("Empty"); try lib.trashFolder("Empty"); precondition(lib.trashedFolders.contains("Empty") && !lib.folders.contains("Empty"))
        let trashReload = Library(rootOverride: root); precondition(trashReload.trashedFolders.contains("Empty")); try lib.restoreFolder("Empty"); precondition(lib.folders.contains("Empty") && !lib.trashedFolders.contains("Empty"))
        lib.createFolder("Parent"); lib.createFolder("Parent/Child")
        lib.folderFilter = "Parent/Child"; lib.copyRecords([copy], cut: true); try lib.pasteRecords()
        precondition(lib.childFolders(of: "Parent") == ["Parent/Child"])
        try lib.renameFolder("Parent", to: "Group"); precondition(lib.records.first { $0.id == copy }?.folder == "Group/Child")
        try lib.trashFolder("Group"); precondition(!lib.folders.contains("Group/Child")); try lib.restoreFolder("Group")
        precondition(lib.childFolders(of: "Group") == ["Group/Child"] && lib.records.first { $0.id == copy }?.folder == "Group/Child")
        // Synthetic test-only credential, never an account or user secret.
        try lib.protectRecords([id], password: "Fixture-only-42")
        let encrypted = PDFDocument(url: lib.url(id))!; precondition(encrypted.isLocked && !encrypted.unlock(withPassword: "wrong") && encrypted.unlock(withPassword: "Fixture-only-42"))
        precondition(lib.records.first { $0.id == id }?.text == "" && lib.sessions[id] == nil)
        lib.document = encrypted; lib.selected = id; lib.unlockedPasswords[id] = "Fixture-only-42"; lib.persist()
        precondition(PDFDocument(url: lib.url(id))!.isLocked, "editing must retain encryption")
        try lib.exportRecords([id], directory: exports)
        try lib.exportRecords([id], directory: exports, images: true)
        let reload = Library(rootOverride: root); precondition(reload.records.count == 2 && reload.tagCatalog == ["Second"] && reload.folders.contains("Renamed"))
        precondition(reload.records.first { $0.id == id }?.passwordProtected == true)
        print("PASS library: import, rename, conflict copy, cut/move, folder rename/trash/restore, tags persistence/filter/rename/delete, search, 7 sorts, PDF/PNG export without overwrite, encryption and encrypted persistence")
    }
}

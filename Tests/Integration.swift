import Foundation
import AppKit
import PDFKit
import CoreImage

@main struct IntegrationTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scanmac-integration-" + UUID().uuidString)
        let lib = Library(rootOverride: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        lib.importFiles([source]); precondition(lib.document?.pageCount == 1, "import")
        let firstID = lib.selected!
        lib.createFolder("Trabajo"); lib.update { $0.folder = "Trabajo"; $0.tags = ["demo", "factura"] }
        lib.browse("Carpeta", folder: "Trabajo"); precondition(lib.filtered.count == 1)
        lib.query = "factura"; precondition(lib.filtered.count == 1)
        lib.select(firstID); lib.removeDocument(); lib.browse("Papelera"); precondition(lib.filtered.count == 1)
        lib.restoreDocument(firstID); precondition(lib.filtered.isEmpty)
        lib.browse("Todos"); lib.select(firstID)
        lib.duplicateDocument(firstID); precondition(lib.records.count == 2)
        lib.mergeRecords(Set(lib.records.map(\.id))); precondition(lib.document?.pageCount == 2)
        lib.rotate(); let beforeTab = lib.history.count; lib.select(lib.selected!); precondition(lib.history.count == beforeTab, "active tab preserves undo"); lib.undo(); lib.redo(); precondition(lib.document?.page(at: 0)?.rotation == 90); lib.undo(); precondition(lib.document?.page(at: 0)?.rotation == 0)
        lib.advancedCrop(left: 10, right: 10, top: 5, bottom: 5, allPages: false)
        let cropWidth = lib.document!.page(at: 0)!.bounds(for: .cropBox).width
        lib.undo(); precondition(lib.document!.page(at: 0)!.bounds(for: .cropBox).width > cropWidth)
        lib.advancedWatermark(text: "DEMO", placement: .center, opacity: 0.3, allPages: true)
        precondition(lib.document?.page(at: 1)?.annotations.count == 1); lib.undo()
        lib.recognize()
        while lib.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(lib.error == nil, lib.error ?? "")
        precondition(lib.current!.text.contains("SCANMAC"), "OCR text")
        precondition(lib.document!.string?.contains("SCANMAC") == true, "searchable PDF text layer")
        let reloaded = PDFDocument(url: lib.url(lib.selected!))!
        precondition(reloaded.string?.contains("SCANMAC") == true, "persisted text layer")
        lib.snapshot(); lib.update { $0.signed = true }; lib.undo(); precondition(lib.current?.signed != true, "undo signature metadata")
        lib.duplicatePages([0]); precondition(lib.document?.pageCount == 3); lib.undo()
        lib.insertBlankPage(); precondition(lib.document?.pageCount == 3); lib.undo()
        lib.reorderPage(from: 0, to: 1); lib.undo()
        lib.deletePages([0]); precondition(lib.document?.pageCount == 1); lib.undo()
        lib.addOutlineBookmark(); precondition(lib.document?.outlineRoot?.numberOfChildren == 1); lib.undo()
        let pagesBefore = lib.document!.pageCount
        lib.recognize(); while lib.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(lib.document!.pageCount == pagesBefore, "repeat OCR")
        let textBeforeUndo = lib.current!.text
        lib.rotate(); lib.undo(); precondition(lib.current!.text == textBeforeUndo, "undo restores OCR")
        lib.enhanceAdvanced(mode: "Corregir sombras", allPages: true)
        while lib.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(lib.error == nil, lib.error ?? "")
        precondition(lib.document!.pageCount == 2)
        lib.undo()
        let temp = root.appendingPathComponent("exports"); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try DocumentConversions.docx(lib.current!.text, to: temp.appendingPathComponent("demo.docx"))
        try DocumentConversions.xlsx("Item\tCantidad\nPapel\t2", to: temp.appendingPathComponent("demo.xlsx"))
        try DocumentConversions.pptx(lib.document!, to: temp.appendingPathComponent("demo.pptx"))
        let remote = root.deletingLastPathComponent().appendingPathComponent("scanmac-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: remote) }
        let sync = try FolderSync.synchronize(local: root, remote: remote, records: lib.records)
        precondition(sync.exported == lib.records.count)
        let repeatSync = try FolderSync.synchronize(local: root, remote: remote, records: sync.records)
        precondition(repeatSync.imported == 0 && repeatSync.conflicts == 0)
        let reopened = Library(rootOverride: root); precondition(reopened.records.count == 3 && reopened.folders == ["Trabajo"])
        // Decode a v0.1 schema without optional fields.
        let old: [String: Any] = ["id": UUID().uuidString, "name": "Legacy", "date": 0, "starred": false, "text": ""]
        let legacy = try JSONDecoder().decode(Record.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(legacy.folder == nil && legacy.trashedAt == nil)
        print("PASS integration: migration, folders, tags/search, trash/restore, duplicate/merge, undo+OCR, crop, watermark, searchable OCR persisted, repeat OCR, batch shadow correction, DOCX/XLSX/PPTX, sync, reopen")
    }
}

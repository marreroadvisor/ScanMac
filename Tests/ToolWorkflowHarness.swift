import AppKit
import PDFKit

@main struct ToolWorkflowHarness {
    @MainActor static func main() async throws {
        guard let fixture = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])), let first = fixture.page(at: 0), let bytes = fixture.dataRepresentation(), let working = PDFDocument(data: bytes) else { fatalError("fixture") }
        while working.pageCount < 3 { working.insert(first.copy() as! PDFPage, at: working.pageCount) }
        let session = ToolSession(source: UUID(), name: "DEMO", document: working)
        session.selected = [0]; session.rotate()
        precondition(session.document.page(at: 0)!.rotation == 90)
        precondition(fixture.page(at: 0)!.rotation == 0, "working copy must preserve source")
        session.reorder(from: 0, to: 2)
        precondition(session.document.page(at: 2)!.rotation == 90)
        session.undo(); precondition(session.document.page(at: 0)!.rotation == 90)
        session.selected = [0]; session.delete(); precondition(session.document.pageCount == 2)
        session.undo(); precondition(session.document.pageCount == 3)
        session.range = "1,3"; session.selectRange(); precondition(session.selected == [0,2])
        session.range = "99"; session.selectRange(); precondition(session.error != nil)
        let before = session.document.pageCount
        session.appendFiles([URL(fileURLWithPath: CommandLine.arguments[1]),URL(fileURLWithPath: "/private/tmp/scanmac-nonexistent-test.pdf")])
        precondition(session.document.pageCount == before, "invalid append must be atomic")
        session.appendFiles([URL(fileURLWithPath: CommandLine.arguments[1])]); precondition(session.document.pageCount == before+fixture.pageCount)
        session.undo(); precondition(session.document.pageCount == before)
        for tool in [LandingTool.word, .excel, .ppt, .text] {
            let item = ToolSession(source: UUID(), name: "DEMO", document: PDFDocument(data: bytes)!)
            item.convert(tool, configuration: OCRLanguageCatalog.load())
            while item.running { try await Task.sleep(nanoseconds: 50_000_000) }
            precondition(item.error == nil, item.error ?? "error")
            guard let result = item.result else { fatalError("missing result") }
            let output = try Data(contentsOf: result)
            precondition(!output.isEmpty && !item.text.isEmpty, "empty conversion")
            if tool != .text { precondition(output.prefix(2) == Data([0x50,0x4b]), "invalid Office container") }
            try FileManager.default.removeItem(at: result.deletingLastPathComponent())
        }
        print("PASS: isolated rotate/reorder/delete/undo/range; atomic append; Word/Excel/PPT/text conversions with real OCR")
    }
}

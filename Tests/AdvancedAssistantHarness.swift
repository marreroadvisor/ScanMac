import AppKit
import PDFKit
import Foundation

@main struct AdvancedAssistantTests {
    @MainActor static func main() async throws {
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 1000, height: 700)
let boxes = [LayoutTextBox(text:"Producto", bounds:CGRect(x:0.1,y:0.8,width:0.3,height:0.06)), LayoutTextBox(text:"Valor", bounds:CGRect(x:0.6,y:0.8,width:0.2,height:0.06)),LayoutTextBox(text:"España & <uno>", bounds:CGRect(x:0.1,y:0.6,width:0.3,height:0.06)),LayoutTextBox(text:"12.50",bounds:CGRect(x:0.6,y:0.6,width:0.2,height:0.06)),LayoutTextBox(text:"00123",bounds:CGRect(x:0.1,y:0.4,width:0.3,height:0.06)),LayoutTextBox(text:"-42",bounds:CGRect(x:0.6,y:0.4,width:0.2,height:0.06))]
let image = NSImage(size:size); image.lockFocus(); NSColor.white.setFill();CGRect(origin:.zero,size:size).fill()
for box in boxes { NSAttributedString(string:box.text,attributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.black]).draw(at:CGPoint(x:box.bounds.minX*size.width,y:box.bounds.minY*size.height)) }
image.unlockFocus()
let page = LayoutPage(size:size,image:image,boxes:boxes)
assert(LayoutDocumentConverter.rows(boxes).count == 3)
try LayoutDocumentConverter.docx(pages:[page,page],to:output.appendingPathComponent("positioned.docx"))
try LayoutDocumentConverter.xlsx(pages:[page],to:output.appendingPathComponent("geometry.xlsx"))
try LayoutDocumentConverter.pptx(pages:[page],to:output.appendingPathComponent("editable.pptx"))
let doc = PDFDocument();doc.insert(PDFPage(image:image)!,at:0)
let recognized = try LayoutDocumentConverter.recognize(document:doc)
assert(recognized.count == 1 && recognized[0].boxes.count >= 3)
print("Synthetic positional exports and real Vision OCR passed; recognized \(recognized[0].boxes.count) boxes")

for raw in ["http://example.com", "https://127.0.0.1", "https://localhost", "https://secret.local", "file:///etc/passwd", "https://user:pass@example.com", "https://example.com:1234"] {
    precondition(!ResearchWeb.publicURL(URL(string: raw)!), raw)
}
precondition(ResearchWeb.plain("<script>secret()</script><p>Hello &amp; world</p>") == "Hello & world")
let sources = try await ResearchWeb.search("OpenCV SIFT")
precondition(!sources.isEmpty && sources.allSatisfy { $0.url.scheme == "https" && !$0.text.isEmpty })
print("PASS live web research: \(sources.count) public sources; scripts removed; private/non-HTTPS URLs rejected")
try sources.map { $0.evidence }.joined(separator: "\n\n").write(to: output.appendingPathComponent("web-sources.txt"),atomically:true,encoding:.utf8)

    }
}

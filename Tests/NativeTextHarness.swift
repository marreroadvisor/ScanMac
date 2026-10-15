import Foundation
import AppKit
import PDFKit

@main struct NativeTextTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanMac-NativeText-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let bytes = NSMutableData(); var box = CGRect(x:0,y:0,width:612,height:792)
        let context = CGContext(consumer:CGDataConsumer(data:bytes)!,mediaBox:&box,nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont(name:"Helvetica",size:18)!, .foregroundColor:NSColor(calibratedRed:0.1,green:0.2,blue:0.6,alpha:1)]
        ("Identificador" as NSString).draw(at:CGPoint(x:50,y:700),withAttributes:attributes)
        ("00123" as NSString).draw(at:CGPoint(x:340,y:700),withAttributes:attributes)
        ("España Ñ & <valor>" as NSString).draw(at:CGPoint(x:50,y:650),withAttributes:attributes)
        ("12.50" as NSString).draw(at:CGPoint(x:340,y:650),withAttributes:attributes)
        NSGraphicsContext.restoreGraphicsState();context.endPDFPage();context.closePDF()
        let document = PDFDocument(data:bytes as Data)!
        let pages = try LayoutDocumentConverter.recognize(document:document)
        precondition(pages.count==1 && pages[0].usedNativeText,"Digital page unexpectedly sent to OCR")
        let text = pages[0].boxes.map(\.text).joined(separator:"\n")
        precondition(text.contains("00123") && text.contains("España") && text.contains("<valor>") && text.contains("12.50"),text)
        precondition(pages[0].boxes.contains { $0.fontPixels != nil && $0.fontName != nil && $0.colorHex != "000000" },"Native style not preserved")
        precondition(LayoutDocumentConverter.rows(pages[0].boxes).count==2)
        try LayoutDocumentConverter.docx(pages:pages,to:root.appendingPathComponent("native.docx"))
        try LayoutDocumentConverter.xlsx(pages:pages,to:root.appendingPathComponent("native.xlsx"))
        try LayoutDocumentConverter.pptx(pages:pages,to:root.appendingPathComponent("native.pptx"))
        precondition(document.page(at:0)!.string!.contains("00123"),"Original changed")
        print("PASS digital text bypasses OCR; accents, IDs, numeric literals, columns and native font/color preserved; all Office exports generated")
    }
}

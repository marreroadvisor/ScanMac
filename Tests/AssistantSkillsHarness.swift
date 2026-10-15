import Foundation
import AppKit
import PDFKit

@main struct AssistantSkillsHarness {
    @MainActor static func main() throws {
        precondition(AssistantSkill.allCases.count == 19)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.setFillColor(NSColor.black.cgColor); context.fill(box); context.endPDFPage(); context.closePDF()
        let doc = PDFDocument(data: data as Data)!
        doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Synthetic Author"]
        let page = doc.page(at: 0)!
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 30, height: 10), forType: .highlight, withProperties: nil))
        let report = LocalDocumentInspection.report(doc, name: "Synthetic.pdf", ai: false)
        precondition(report.contains("Synthetic Author") && report.contains("1 anotaciones") && report.contains("autenticidad indeterminada"))
        let ai = LocalDocumentInspection.report(doc, name: "Synthetic.pdf", ai: true)
        precondition(ai.contains("procedencia IA indeterminada") && ai.contains("no clasifica imágenes"))
        let cleaned = try AssistantCleanupEngine.page(page, zones: [CGRect(x: 0, y: 0, width: 1, height: 0.5)])
        let cleanedDoc = PDFDocument(); cleanedDoc.insert(cleaned, at: 0)
        let cg = try ScanEnhancementEngine.renderPage(cleanedDoc.page(at: 0)!)
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let c1 = bitmap.colorAt(x: cg.width/2, y: cg.height/4)!.usingColorSpace(.deviceRGB)!
        let c2 = bitmap.colorAt(x: cg.width/2, y: cg.height*3/4)!.usingColorSpace(.deviceRGB)!
        precondition(c1.redComponent > 0.95 && c2.redComponent < 0.05, "Mask orientation or coverage incorrect")
        precondition(page.annotations.count == 1 && page.bounds(for: .cropBox) == box, "Source mutated")
        page.rotation = 90
        let rotated = try AssistantCleanupEngine.page(page, zones: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        precondition(rotated.bounds(for: .cropBox).size == CGSize(width: 300, height: 200))
        print("PASS technical report limits, metadata, cleanup pixels/orientation, rotated dimensions and original preservation")
    }
}

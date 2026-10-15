import Foundation
import AppKit
import PDFKit

@main struct InkResizeTests {
    static func fixture() -> (PDFDocument, PDFAnnotation) {
        let data = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(media); context.endPDFPage(); context.closePDF()
        let document = PDFDocument(data: data as Data)!
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 100, height: 50), forType: .ink, withProperties: nil)
        annotation.color = .black; annotation.userName = "ScanMacSignature"
        let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
        let path = NSBezierPath(); path.move(to: CGPoint(x: 10, y: 10)); path.line(to: CGPoint(x: 90, y: 40)); annotation.add(path)
        document.page(at: 0)!.addAnnotation(annotation)
        return (document, annotation)
    }
    static func pixels(_ document: PDFDocument) -> (CGRect, Int) {
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        document.page(at: 0)!.draw(with: .mediaBox, to: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = 400, minY = 600, maxX = -1, maxY = -1, count = 0
        for y in 0..<600 { for x in 0..<400 {
            let i = (y * 400 + x) * 4
            if bytes[i] < 80, bytes[i + 1] < 80, bytes[i + 2] < 80 { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y); count += 1 }
        } }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), count)
    }
    static func reload(_ document: PDFDocument) -> PDFDocument { PDFDocument(data: document.dataRepresentation()!)! }
    static func close(_ a: CGFloat, _ b: CGFloat) { precondition(abs(a - b) <= 2, "Geometry differs: \(a), \(b)") }
    @MainActor static func main() {
        let (document, annotation) = fixture()
        let baseline = pixels(document)
        let original = InkTransform.capture(annotation)!
        InkTransform.apply(annotation, from: original, to: CGRect(x: 20, y: 20, width: 200, height: 100))
        let scaled = pixels(document)
        close(scaled.0.width, baseline.0.width * 2); close(scaled.0.height, baseline.0.height * 2)
        // Thin antialiased lines quantize differently at 1x and 2x; geometry below is exact.
        precondition(abs(Double(scaled.1) / Double(baseline.1) - 4) < 0.6)
        precondition(annotation.paths!.count == 1)
        precondition(annotation.paths![0].bounds == CGRect(x: 20, y: 20, width: 160, height: 60))
        let saved = reload(document)
        precondition(pixels(saved).0 == scaled.0); precondition(pixels(saved).1 == scaled.1)
        // A later drag update reuses the same mouse-down snapshot instead of scaling cumulatively.
        InkTransform.apply(annotation, from: original, to: CGRect(x: 20, y: 20, width: 150, height: 75))
        precondition(annotation.paths![0].bounds == CGRect(x: 15, y: 15, width: 120, height: 45))
        precondition(abs(annotation.border!.lineWidth - 3) < 0.001)
        // Move without changing size: local path coordinates remain unchanged and pixels translate.
        let beforeMove = pixels(document)
        let moveStart = InkTransform.capture(annotation)!
        InkTransform.apply(annotation, from: moveStart, to: annotation.bounds.offsetBy(dx: 70, dy: 100))
        let moved = pixels(document)
        precondition(moved.1 == beforeMove.1)
        precondition(moved.0.minX == beforeMove.0.minX + 70)
        precondition(moved.0.minY == beforeMove.0.minY - 100)
        precondition(annotation.paths![0].bounds == moveStart.paths[0].bounds)
        let movedReloaded = reload(document)
        precondition(pixels(movedReloaded).0 == moved.0)
        // Capture and scale a reloaded standard annotation, whose paths remain local.
        let loadedAnnotation = movedReloaded.page(at: 0)!.annotations[0]
        let loadedStart = InkTransform.capture(loadedAnnotation)!
        InkTransform.apply(loadedAnnotation, from: loadedStart, to: CGRect(origin: loadedAnnotation.bounds.origin, size: CGSize(width: 75, height: 37.5)))
        let shrunken = pixels(movedReloaded)
        close(shrunken.0.width, moved.0.width / 2); close(shrunken.0.height, moved.0.height / 2)
        precondition(pixels(reload(movedReloaded)).0 == shrunken.0)
        // Curves and multiple strokes retain their element topology under a nonuniform resize.
        let curve = NSBezierPath(); curve.move(to: CGPoint(x: 1, y: 2)); curve.curve(to: CGPoint(x: 30, y: 20), controlPoint1: CGPoint(x: 5, y: 40), controlPoint2: CGPoint(x: 20, y: 1))
        loadedAnnotation.add(curve)
        let curveStart = InkTransform.capture(loadedAnnotation)!
        InkTransform.apply(loadedAnnotation, from: curveStart, to: CGRect(origin: loadedAnnotation.bounds.origin, size: CGSize(width: 150, height: 112.5)))
        precondition(loadedAnnotation.paths!.count == 2)
        precondition(loadedAnnotation.paths![1].elementCount == curve.elementCount)
        precondition(curveStart.paths[1].bounds == curve.bounds)
        print("PASS ink scales geometrically with stroke width; repeated drag is noncumulative; movement translates pixels; save/reload preserves edits; loaded paths and multiple curves remain editable")
    }
}

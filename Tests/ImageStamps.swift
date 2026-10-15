import Foundation
import AppKit
import PDFKit
import CoreText

@main struct ImageStampTests {
    static let pageSize = CGSize(width: 400, height: 600)
    static func fixture() -> PDFDocument {
        let data = NSMutableData(); var box = CGRect(origin: .zero, size: pageSize)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let text = NSAttributedString(string: "Original searchable text", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        context.textPosition = CGPoint(x: 25, y: 550)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        return PDFDocument(data: data as Data)!
    }
    static func signature() -> CGImage {
        let context = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        context.fill(CGRect(x: 80, y: 0, width: 40, height: 60))
        return context.makeImage()!
    }
    static func pixelCounts(_ document: PDFDocument) -> (red: Int, blue: Int) {
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: pageSize))
        document.page(at: 0)!.draw(with: .mediaBox, to: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var red = 0, blue = 0
        for offset in stride(from: 0, to: 400 * 600 * 4, by: 4) {
            if bytes[offset] > 200, bytes[offset + 1] < 40, bytes[offset + 2] < 40 { red += 1 }
            if bytes[offset] < 40, bytes[offset + 1] < 40, bytes[offset + 2] > 200 { blue += 1 }
        }
        return (red, blue)
    }
    static func redBounds(_ document: PDFDocument) -> CGRect {
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: pageSize))
        document.page(at: 0)!.draw(with: .mediaBox, to: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var xs: [Int] = []; var ys: [Int] = []
        for y in 0..<600 { for x in 0..<400 {
            let i = (y * 400 + x) * 4
            if bytes[i] > 200, bytes[i + 1] < 40, bytes[i + 2] < 40 { xs.append(x); ys.append(y) }
        } }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    static func near(_ a: Int, _ b: Int) { precondition(abs(a - b) <= max(30, b / 50), "Pixel count \(a) differs from \(b)") }
    @MainActor static func main() throws {
        let original = fixture()
        let originalText = original.page(at: 0)!.string!
        let stamp = ImageSignatureStamp(image: signature(), bounds: CGRect(x: 50, y: 50, width: 120, height: 60))
        original.page(at: 0)!.addAnnotation(stamp)
        near(pixelCounts(original).red, 4800)
        let firstData = original.dataRepresentation()!
        let first = PDFDocument(data: firstData)!
        precondition(first.page(at: 0)!.annotations.count == 1)
        precondition(first.page(at: 0)!.annotations[0].userName == "ScanMacSignature")
        precondition(first.page(at: 0)!.string == originalText)
        near(pixelCounts(first).red, 4800)
        precondition(redBounds(first).minX == 50 && redBounds(first).width == 120)
        near(pixelCounts(first).blue, 120000 - 4800) // Transparent middle preserves the blue page.
        let loadedStamp = first.page(at: 0)!.annotations[0]
        loadedStamp.bounds = CGRect(x: 120, y: 100, width: 240, height: 120)
        near(pixelCounts(first).red, 19200)
        let second = PDFDocument(data: first.dataRepresentation()!)!
        precondition(second.page(at: 0)!.annotations[0].bounds == loadedStamp.bounds)
        near(pixelCounts(second).red, 19200)
        precondition(redBounds(second).minX == 120 && redBounds(second).width == 240)
        precondition(second.page(at: 0)!.string == originalText)
        let copy = second.page(at: 0)!.copy() as! PDFPage
        let copied = PDFDocument(); copied.insert(copy, at: 0)
        near(pixelCounts(PDFDocument(data: copied.dataRepresentation()!)!).red, 19200)
        let directCopy = original.page(at:0)!.copy() as! PDFPage
        let direct = PDFDocument(); direct.insert(directCopy, at:0)
        near(pixelCounts(PDFDocument(data: direct.dataRepresentation()!)!).red,4800)
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: exported) }
        try second.dataRepresentation()!.write(to: exported)
        near(pixelCounts(PDFDocument(url: exported)!).red, 19200)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanMac-ImageStamp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = Library(rootOverride: root); let id = UUID()
        lib.records = [Record(id: id, name: "Synthetic stamp", date: Date())]; lib.selected = id; lib.document = fixture(); lib.persist()
        let image = NSImage(cgImage: signature(), size: CGSize(width: 120, height: 60))
        precondition(lib.addImageSignature(image, width: 120))
        precondition(lib.current?.signed == true); precondition(lib.history.count == 1)
        precondition(PDFDocument(url: lib.url(id))!.page(at:0)!.annotations.count == 1)
        near(pixelCounts(PDFDocument(url:lib.url(id))!).red,4800)
        lib.undo(); precondition(lib.document!.page(at:0)!.annotations.isEmpty)
        print("PASS image stamp appearance survives save/reload/export/copy; movement and resize survive second reload; transparency and original text preserved; Library persistence and undo verified")
    }
}

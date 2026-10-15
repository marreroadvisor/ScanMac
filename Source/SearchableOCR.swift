import AppKit
import PDFKit
import Vision
import CoreText

struct OCRLine { let text: String; let box: CGRect }

enum SearchablePDF {
    static func page(image: CGImage, size: CGSize, lines: [OCRLine]) throws -> PDFPage {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }
        var bounds = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw CocoaError(.fileWriteUnknown) }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: bounds)
        for line in lines {
            let box = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height, width: line.box.width * size.width, height: line.box.height * size.height)
            guard box.width > 0, box.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, box.height * 0.85), nil)
            let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let text = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(text, nil, nil, nil)
            ctx.saveGState(); ctx.setTextDrawingMode(.invisible)
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
            if width > 0 { ctx.scaleBy(x: box.width / width, y: 1) }
            ctx.textPosition = .zero; CTLineDraw(text, ctx); ctx.restoreGState()
        }
        ctx.endPDFPage(); ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0)?.copy() as? PDFPage else { throw CocoaError(.fileReadCorruptFile) }
        return page
    }
}

extension Library {
    func recognizeSearchable() {
        guard !busy, let data = document?.dataRepresentation() else { return }
        let id = selected; let configuration = ocrConfiguration
        busy = true; message = tr("OCR y PDF con texto seleccionable…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let source = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                let result = PDFDocument(); var chunks: [String] = []
                for i in 0..<source.pageCount {
                    try autoreleasepool {
                        guard let page = source.page(at: i) else { throw CocoaError(.fileReadCorruptFile) }
                        let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !existing.isEmpty, let copy = page.copy() as? PDFPage {
                            result.insert(copy, at: result.pageCount); chunks.append("— Página \(i + 1) —\n\(existing)"); return
                        }
                        let b = page.bounds(for: .cropBox)
                        let rotated = page.rotation % 180 != 0
                        let size = rotated ? CGSize(width: b.height, height: b.width) : b.size
                        let scale = min(3, 2600 / max(size.width, size.height))
                        let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
                        var rect = CGRect(origin: .zero, size: image.size)
                        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw CocoaError(.fileReadCorruptFile) }
                        let request = VNRecognizeTextRequest(); configuration.apply(to: request)
                        try VNImageRequestHandler(cgImage: cg).perform([request])
                        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                            guard let text = observation.topCandidates(1).first?.string else { return nil }
                            return OCRLine(text: text, box: observation.boundingBox)
                        }
                        chunks.append("— Página \(i + 1) —\n" + lines.map(\.text).joined(separator: "\n"))
                        result.insert(try SearchablePDF.page(image: cg, size: size, lines: lines), at: result.pageCount)
                    }
                    DispatchQueue.main.async { if self.selected == id { self.message = tr("OCR: página {0} de {1}", String(describing: i + 1), String(describing: source.pageCount)) } }
                }
                guard let resultData = result.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                DispatchQueue.main.async {
                    defer { self.busy = false }
                    guard self.selected == id else { return }
                    self.snapshot(); self.document = PDFDocument(data: resultData); self.update { $0.text = chunks.joined(separator: "\n\n") }; self.persist()
                    self.message = tr("OCR completado · PDF con texto seleccionable · {0} páginas", String(describing: source.pageCount))
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription; self.message = tr("OCR no completado; documento conservado") }
            }
        }
    }
}

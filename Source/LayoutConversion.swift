import SwiftUI
import AppKit
import PDFKit
import Vision
import UniformTypeIdentifiers

struct LayoutTextBox {
    let text: String
    let bounds: CGRect
}

struct LayoutPage {
    let size: CGSize
    let image: NSImage
    let boxes: [LayoutTextBox]
}

enum LayoutDocumentConverter {
    private static func xml(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func recognize(document: PDFDocument, configuration: OCRConfiguration = OCRLanguageCatalog.load()) throws -> [LayoutPage] {
        try (0..<document.pageCount).map { i in
            guard let page = document.page(at: i) else { throw NSError(domain: "ScanMac", code: 1) }
            let image = page.thumbnail(of: NSSize(width: 2200, height: 2200), for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw NSError(domain: "ScanMac", code: 2) }
            let request = VNRecognizeTextRequest(); configuration.apply(to: request)
            try VNImageRequestHandler(cgImage: cg).perform([request])
            let boxes = (request.results ?? []).compactMap { observation -> LayoutTextBox? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return LayoutTextBox(text: candidate.string, bounds: observation.boundingBox)
            }
            return LayoutPage(size: CGSize(width: cg.width, height: cg.height), image: image, boxes: boxes)
        }
    }
    /// Vision coordinates have origin at bottom-left. Nearby vertical centers form a row.
    static func rows(_ boxes: [LayoutTextBox]) -> [[LayoutTextBox]] {
        var groups: [[LayoutTextBox]] = []
        for box in boxes.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let index = groups.firstIndex(where: { row in
                let average = row.map { $0.bounds.midY }.reduce(0, +) / Double(row.count)
                return abs(average - box.bounds.midY) <= max(0.006, min(row[0].bounds.height, box.bounds.height) * 0.55)
            }) { groups[index].append(box) }
            else { groups.append([box]) }
        }
        return groups.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }
    private static func relationships(_ values: [(String, String, String)]) -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + values.map { "<Relationship Id=\"\($0.0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
    }
    static func xlsx(document: PDFDocument, to destination: URL, configuration: OCRConfiguration = OCRLanguageCatalog.load()) throws { try xlsx(pages: recognize(document: document, configuration: configuration), to: destination) }
    static func xlsx(pages: [LayoutPage], to destination: URL) throws {
        guard !pages.isEmpty else { throw NSError(domain: "ScanMac", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("No hay páginas convertibles.")]) }
        var files: [String: Data] = [:], sheets = "", overrides = ""
        var rels: [(String, String, String)] = []
        for (pageIndex, page) in pages.enumerated() {
            let n = pageIndex + 1
            let grouped = rows(page.boxes)
            // Cluster left edges across rows; do not infer values from their apparent locale.
            var anchors: [Double] = []
            for x in page.boxes.map({ $0.bounds.minX }).sorted() {
                if !anchors.contains(where: { abs($0 - x) < 0.025 }) { anchors.append(x) }
            }
            func column(_ index: Int) -> String {
                var value = index + 1, text = ""
                while value > 0 { value -= 1; text = String(UnicodeScalar(65 + value % 26)!) + text; value /= 26 }
                return text
            }
            var rowXML = ""
            for (rowIndex, row) in grouped.enumerated() {
                var cells: [Int: [String]] = [:]
                for box in row {
                    let c = anchors.indices.min(by: { abs(anchors[$0] - box.bounds.minX) < abs(anchors[$1] - box.bounds.minX) }) ?? 0
                    cells[c, default: []].append(box.text)
                }
                let cellXML = cells.keys.sorted().map { c -> String in
                    let text = cells[c]!.joined(separator: " "), reference = column(c) + String(rowIndex + 1)
                    // Ambiguous separators, leading zero IDs and currency stay literal strings.
                    let pattern = #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$"#
                    if text.range(of: pattern, options: .regularExpression) != nil, let number = Double(text), number.isFinite, text.filter({ $0.isNumber }).count <= 15 {
                        return "<c r=\"\(reference)\" s=\"1\"><v>\(xml(text))</v></c>"
                    }
                    return "<c r=\"\(reference)\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(text))</t></is></c>"
                }.joined()
                rowXML += "<row r=\"\(rowIndex + 1)\" ht=\"\(max(15,(row.map { $0.bounds.height }.max() ?? 0.02)*min(page.size.height,842)*0.9))\" customHeight=\"1\">\(cellXML)</row>"
            }
            let columns = anchors.enumerated().map { i,x in "<col min=\"\(i+1)\" max=\"\(i+1)\" width=\"\(min(70,max(10,((i+1 < anchors.count ? anchors[i+1] : 1)-x)*100)))\" customWidth=\"1\"/>" }.joined()
            if let cg = page.image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                files["xl/media/page\(n).png"] = png
                files["xl/worksheets/_rels/sheet\(n).xml.rels"] = Data(relationships([("imageRef","drawing","../drawings/drawing\(n).xml")]).utf8)
                files["xl/drawings/_rels/drawing\(n).xml.rels"] = Data(relationships([("img","image","../media/page\(n).png")]).utf8)
                let ratio = min(1,600/max(1,page.size.width)); let cx = Int(page.size.width*ratio*9525), cy = Int(page.size.height*ratio*9525)
                files["xl/drawings/drawing\(n).xml"] = Data("<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><xdr:oneCellAnchor><xdr:from><xdr:col>\(anchors.count+2)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx=\"\(cx)\" cy=\"\(cy)\"/><xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"1\" name=\"Original de referencia\"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed=\"img\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor></xdr:wsDr>".utf8)
                overrides += "<Override PartName=\"/xl/drawings/drawing\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
            }
            let drawing = files["xl/media/page\(n).png"] == nil ? "" : "<drawing r:id=\"imageRef\"/>"
            files["xl/worksheets/sheet\(n).xml"] = Data("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><cols>\(columns)</cols><sheetData>\(rowXML)</sheetData>\(drawing)</worksheet>".utf8)
            sheets += "<sheet name=\"Página \(n)\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            rels.append(("rId\(n)", "worksheet", "worksheets/sheet\(n).xml"))
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        files["xl/workbook.xml"] = Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheets)</sheets></workbook>".utf8)
        rels.append(("styles", "styles", "styles.xml"))
        files["xl/styles.xml"] = Data("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf></cellXfs></styleSheet>".utf8)
        files["xl/_rels/workbook.xml.rels"] = Data(relationships(rels).utf8)
        files["_rels/.rels"] = Data(relationships([("rId1", "officeDocument", "xl/workbook.xml")]).utf8)
        files["[Content_Types].xml"] = Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(overrides)</Types>".utf8)
        try DocumentConversions.package(files, to: destination)
    }
    static func pptx(document: PDFDocument, to destination: URL, configuration: OCRConfiguration = OCRLanguageCatalog.load()) throws { try pptx(pages: recognize(document: document, configuration: configuration), to: destination) }
    static func pptx(pages: [LayoutPage], to destination: URL) throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let base = temporary.appendingPathComponent("base.pptx"), extracted = temporary.appendingPathComponent("parts")
        let document = PDFDocument()
        for page in pages { if let pdfPage = PDFPage(image: page.image) { document.insert(pdfPage, at: document.pageCount) } }
        guard document.pageCount == pages.count, !pages.isEmpty else { throw NSError(domain: "ScanMac", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("No hay páginas convertibles.")]) }
        try DocumentConversions.pptx(document, to: base)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); task.arguments = ["-qq", base.path, "-d", extracted.path]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NSError(domain: "ScanMac", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("No se pudo preparar PowerPoint.")]) }
        for (index, page) in pages.enumerated() {
            // Remove raster text before adding editable text. This deliberately clears text
            // regions to white and may simplify colored backgrounds or lines behind text.
            let background = cleanedBackground(page)
            guard let tiff = background.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "ScanMac", code: 3) }
            try png.write(to: extracted.appendingPathComponent("ppt/media/page\(index + 1).png"))
            let ratio = min(9144000.0 / page.size.width, 6858000.0 / page.size.height)
            let width = Int(page.size.width * ratio), height = Int(page.size.height * ratio)
            let offsetX = (9144000 - width) / 2, offsetY = (6858000 - height) / 2
            var shapes = ""
            for (textIndex, box) in page.boxes.enumerated() {
                let x = offsetX + Int(box.bounds.minX * Double(width))
                let y = offsetY + Int((1 - box.bounds.maxY) * Double(height))
                let w = max(1, Int(box.bounds.width * Double(width))), h = max(1, Int(box.bounds.height * Double(height)))
                let font = max(100, min(20000, Int(Double(h) / 12700.0 * 100 * 0.85)))
                shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(textIndex + 3)\" name=\"Texto editable \(textIndex + 1)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap=\"none\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\"><a:noAutofit/></a:bodyPr><a:lstStyle/><a:p><a:pPr><a:buNone/></a:pPr><a:r><a:rPr lang=\"es-ES\" sz=\"\(font)\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:latin typeface=\"Arial\"/></a:rPr><a:t>\(xml(box.text))</a:t></a:r><a:endParaRPr sz=\"\(font)\"/></a:p></p:txBody></p:sp>"
            }
            let slide = extracted.appendingPathComponent("ppt/slides/slide\(index + 1).xml")
            var source = try String(contentsOf: slide, encoding: .utf8)
            source = source.replacingOccurrences(of: "</p:spTree>", with: shapes + "</p:spTree>")
            try source.write(to: slide, atomically: true, encoding: .utf8)
        }
        var files: [String: Data] = [:]
        let enumerator = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(file.resolvingSymlinksInPath().path.dropFirst(extracted.resolvingSymlinksInPath().path.count + 1))] = try Data(contentsOf: file)
            }
        }
        try DocumentConversions.package(files, to: destination)
    }
    /// Retains page geometry and imagery with editable positioned text boxes.
    /// Fonts and background reconstruction are approximate; text never becomes a single raster.
    static func docx(document: PDFDocument, to destination: URL, configuration: OCRConfiguration = OCRLanguageCatalog.load()) throws {
        try docx(pages: recognize(document: document, configuration: configuration), to: destination)
    }
    static func cleanedBackground(_ page: LayoutPage) -> NSImage {
        let output = NSImage(size: page.size)
        let bitmap = page.image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { NSBitmapImageRep(cgImage: $0) }
        output.lockFocus(); page.image.draw(in: CGRect(origin: .zero, size: page.size))
        for box in page.boxes {
            var colors: [NSColor] = []
            if let bitmap {
                for point in [CGPoint(x: box.bounds.minX,y: box.bounds.minY), CGPoint(x: box.bounds.maxX,y: box.bounds.minY), CGPoint(x: box.bounds.minX,y: box.bounds.maxY), CGPoint(x: box.bounds.maxX,y: box.bounds.maxY)] {
                    let x = min(bitmap.pixelsWide-1,max(0,Int(point.x*Double(bitmap.pixelsWide)))), y = min(bitmap.pixelsHigh-1,max(0,Int((1-point.y)*Double(bitmap.pixelsHigh))))
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) { colors.append(color) }
                }
            }
            func median(_ values: [CGFloat]) -> CGFloat { let values = values.sorted(); return values.isEmpty ? 1 : values[values.count/2] }
            NSColor(calibratedRed: median(colors.map(\.redComponent)), green: median(colors.map(\.greenComponent)), blue: median(colors.map(\.blueComponent)), alpha: 1).setFill()
            CGRect(x: box.bounds.minX*page.size.width, y: box.bounds.minY*page.size.height, width: box.bounds.width*page.size.width, height: box.bounds.height*page.size.height).insetBy(dx: -1,dy: -1).fill()
        }
        output.unlockFocus(); return output
    }
    static func docx(pages: [LayoutPage], to destination: URL) throws {
        guard !pages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var files: [String: Data] = [:], body = "", rels: [(String,String,String)] = [], lastSection = ""
        for (index,page) in pages.enumerated() {
            let scale = min(1,842/max(1,page.size.height),1190/max(1,page.size.width))
            let w = page.size.width*scale, h = page.size.height*scale
            let bg = cleanedBackground(page)
            guard let cg = bg.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let id = index+1; files["word/media/page\(id).png"] = png; rels.append(("img\(id)","image","media/page\(id).png"))
            let base = "position:absolute;margin-left:0pt;margin-top:0pt;width:\(w)pt;height:\(h)pt;mso-position-horizontal-relative:page;mso-position-vertical-relative:page"
            body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr><w:r><w:pict><v:rect id=\"background\(id)\" style=\"\(base);z-index:-251654144\" stroked=\"f\"><v:imagedata r:id=\"img\(id)\" o:title=\"Page background\"/></v:rect></w:pict></w:r>"
            for (n,box) in page.boxes.enumerated() {
                let x = box.bounds.minX*w, y = (1-box.bounds.maxY)*h, bw = box.bounds.width*w, bh = box.bounds.height*h
                let font = max(8,min(100,Int(bh*1.55)))
                let style = "position:absolute;margin-left:\(x)pt;margin-top:\(y)pt;width:\(max(1,bw))pt;height:\(max(1,bh+2))pt;mso-position-horizontal-relative:page;mso-position-vertical-relative:page;z-index:1"
                body += "<w:r><w:pict><v:rect id=\"text\(id)_\(n)\" style=\"\(style)\" filled=\"f\" stroked=\"f\"><v:textbox inset=\"0,0,0,0\"><w:txbxContent><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/><w:sz w:val=\"\(font)\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(box.text))</w:t></w:r></w:p></w:txbxContent></v:textbox></v:rect></w:pict></w:r>"
            }
            body += "</w:p>"
            lastSection = "<w:sectPr><w:type w:val=\"nextPage\"/><w:pgSz w:w=\"\(Int(w*20))\" w:h=\"\(Int(h*20))\"/><w:pgMar w:top=\"0\" w:right=\"0\" w:bottom=\"0\" w:left=\"0\" w:header=\"0\" w:footer=\"0\"/></w:sectPr>"
            if index < pages.count-1 { body += "<w:p><w:pPr>" + lastSection + "</w:pPr></w:p>" }
        }
        files["word/document.xml"] = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\"><w:body>" + body + lastSection + "</w:body></w:document>").utf8)
        files["word/_rels/document.xml.rels"] = Data(relationships(rels).utf8)
        files["_rels/.rels"] = Data(relationships([("rId1","officeDocument","word/document.xml")]).utf8)
        files["[Content_Types].xml"] = Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".utf8)
        try DocumentConversions.package(files,to: destination)
    }

}

struct LayoutConversionPanel: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("Reconstrucción local aproximada")).font(.title2.bold()); Spacer(); Button(tr("Cerrar")) { dismiss() }.disabled(running) }
            Text(tr("OCR con los idiomas seleccionados y posiciones de texto. Revisa cada resultado: no reproduce exactamente tipografías, tablas ni diseño."))
            Text(tr("Excel agrupa columnas por alineación y conserva números simples con punto decimal. Los identificadores con ceros iniciales, monedas y separadores ambiguos permanecen como texto. PowerPoint añade cuadros de texto editables sobre la imagen; borra las zonas del texto original con blanco, lo que puede afectar fondos de color y líneas. Word conserva el fondo y coloca cuadros de texto editables en sus posiciones; revisa tipografías y tablas.")).font(.callout).foregroundStyle(.secondary)
            HStack { Button(tr("Excel por posiciones")) { convert("xlsx") }; Button(tr("PowerPoint editable")) { convert("pptx") }; Button(tr("Word con diseño")) { convert("docx") } }.disabled(running || lib.document == nil)
            if running { ProgressView(tr("Reconociendo y reconstruyendo…")) }
            Text(trStatus(status)).font(.callout).textSelection(.enabled)
        }.padding(24).frame(width: 720)
    }
    private func convert(_ format: String) {
        guard let bytes = lib.document?.dataRepresentation(), let snapshot = PDFDocument(data: bytes) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (lib.current?.name ?? "Documento") + "." + format; panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let configuration = lib.ocrConfiguration
        running = true; status = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if format == "xlsx" { try LayoutDocumentConverter.xlsx(document: snapshot, to: destination, configuration: configuration) }
                else if format == "pptx" { try LayoutDocumentConverter.pptx(document: snapshot, to: destination, configuration: configuration) }
                else { try LayoutDocumentConverter.docx(document: snapshot, to: destination, configuration: configuration) }
                DispatchQueue.main.async { running = false; status = tr("Exportación completada. Revisa el documento reconstruido.") }
            } catch { DispatchQueue.main.async { running = false; status = tr("No se pudo reconstruir el documento: ") + error.localizedDescription } }
        }
    }
}

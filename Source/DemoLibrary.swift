import Foundation
import AppKit
import PDFKit

/// Explicit, isolated sample data for documentation. Never reads the real library.
@MainActor enum DemoLibrary {
    static let root: URL? = {
        guard CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey:"ScanMacDemoMode") as? Bool == true else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanMac-PublicDemo-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let names = ["Factura de ejemplo", "Notas de muestra", "Plan del proyecto"]
            var records: [Record] = []
            for (i,name) in names.enumerated() {
                let id = UUID(); let data = NSMutableData(); var bounds = CGRect(x:0,y:0,width:612,height:792)
                guard let consumer = CGDataConsumer(data:data), let context = CGContext(consumer:consumer,mediaBox:&bounds,nil) else { throw CocoaError(.fileWriteUnknown) }
                context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
                (name as NSString).draw(at:CGPoint(x:54,y:700),withAttributes:[.font:NSFont.boldSystemFont(ofSize:26),.foregroundColor:NSColor.black])
                let text = "SCANMAC · DOCUMENTO DE DEMOSTRACIÓN\n\nEjemplo sintético sin datos personales.\n\nConcepto: Organización de documentos\nReferencia: DEMO-00123\nCantidad: 3\nImporte: 35.00\n\nPuedes importar, reconocer texto y exportar una copia.\nLos originales de tu biblioteca no se usan en este modo."
                (text as NSString).draw(in:CGRect(x:54,y:220,width:504,height:420),withAttributes:[.font:NSFont.systemFont(ofSize:17),.foregroundColor:NSColor.black])
                NSGraphicsContext.restoreGraphicsState(); context.endPDFPage();context.closePDF()
                try (data as Data).write(to:root.appendingPathComponent(id.uuidString+".pdf"))
                records.append(Record(id:id,name:name,date:Date(),starred:i==0,text:text,folder:i==2 ? "Proyectos" : "Ejemplos",tags:["demostración"]))
            }
            try JSONEncoder().encode(records).write(to:root.appendingPathComponent("library.json"))
            try JSONEncoder().encode(["Ejemplos","Proyectos"]).write(to:root.appendingPathComponent("folders.json"))
            return root
        } catch { try? FileManager.default.removeItem(at:root); fatalError("Cannot create isolated demo library: \(error.localizedDescription)") }
    }()
    static func cleanup() { if let root { try? FileManager.default.removeItem(at:root) } }
}

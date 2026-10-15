import AppKit
import PDFKit
let image = NSImage(size: NSSize(width: 612, height: 792))
image.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(x:0,y:0,width:612,height:792)).fill()
("SCANMAC DEMO" as NSString).draw(at:NSPoint(x:60,y:680),withAttributes:[.font:NSFont.boldSystemFont(ofSize:30),.foregroundColor:NSColor.black])
("Documento sintetico de prueba\nFactura DEMO-2026\nArticulo,Cantidad,Precio\nPapel,2,10.00\nCarpetas,3,5.00\nTotal: 35.00\nNo contiene datos personales." as NSString).draw(in:NSRect(x:60,y:200,width:490,height:430),withAttributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.black])
image.unlockFocus()
let doc=PDFDocument();doc.insert(PDFPage(image:image)!,at:0);doc.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))

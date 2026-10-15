import SwiftUI
import AppKit
import PDFKit

/// PDFKit ink paths use annotation-local coordinates and do not follow changes to Rect size.
enum InkTransform {
    struct Snapshot {
        let bounds: CGRect
        let paths: [NSBezierPath]
        let lineWidth: CGFloat
    }
    static func capture(_ annotation: PDFAnnotation) -> Snapshot? {
        guard annotation.type == "Ink",
              let paths = annotation.paths, !paths.isEmpty else { return nil }
        return Snapshot(bounds: annotation.bounds, paths: paths.compactMap { $0.copy() as? NSBezierPath }, lineWidth: annotation.border?.lineWidth ?? 1)
    }
    static func apply(_ annotation: PDFAnnotation, from original: Snapshot, to bounds: CGRect) {
        guard original.bounds.width > 0, original.bounds.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let sx = bounds.width / original.bounds.width, sy = bounds.height / original.bounds.height
        guard sx.isFinite, sy.isFinite else { return }
        let transform = AffineTransform(scaleByX: sx, byY: sy)
        let replacements = original.paths.compactMap { path -> NSBezierPath? in
            guard let copy = path.copy() as? NSBezierPath else { return nil }
            copy.transform(using: transform); return copy
        }
        // Use fresh copies of the mouse-down paths on every event, never the previous event's result.
        annotation.bounds = bounds
        for path in annotation.paths ?? [] { annotation.remove(path) }
        for path in replacements { annotation.add(path) }
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = original.lineWidth * sqrt(sx * sy)
        annotation.border = border
    }
}

final class EditingPDFView: PDFView {
    weak var library: Library?
    var drawing: [CGPoint] = []
    var targetPage: PDFPage?
    var moving: PDFAnnotation?
    var originalInk: InkTransform.Snapshot?
    var originalBounds = CGRect.zero
    var dragOrigin = CGPoint.zero
    var panPoint: CGPoint?
    var panScroll = CGPoint.zero
    override func mouseDown(with event: NSEvent) {
        guard let lib = library, !lib.busy else { return }
        if lib.annotationMode == "Mano", let clip = documentView?.enclosingScrollView?.contentView { panPoint = event.locationInWindow; panScroll = clip.bounds.origin; return }
        let location = convert(event.locationInWindow, from: nil)
        guard let p = page(for: location, nearest: false) else { return }
        let point = convert(location, to: p); targetPage = p
        switch lib.annotationMode {
        case "Lápiz": lib.snapshot(); drawing = [point]
        case "Texto":
            lib.snapshot(); let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 30, width: min(280, p.bounds(for: .mediaBox).width * 0.6), height: 45), forType: .freeText, withProperties: nil)
            a.contents = lib.annotationText; a.font = NSFont.systemFont(ofSize: 16); a.fontColor = .systemBlue; a.color = .clear; p.addAnnotation(a); lib.persist()
        case "Firma":
            guard !lib.pendingInk.isEmpty else { lib.message = tr("Dibuja una firma primero"); return }
            lib.snapshot(); let width = CGFloat(lib.stampWidth); let height = width * 180 / 520
            let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - height, width: width, height: height), forType: .ink, withProperties: nil)
            a.color = .black; a.border = PDFBorder(); a.border?.lineWidth = 1.4
            for line in lib.pendingInk {
                let path = NSBezierPath()
                for (i, raw) in line.enumerated() {
                    let mapped = CGPoint(x: raw.x / 520 * width, y: height - raw.y / 180 * height)
                    if i == 0 { path.move(to: mapped) } else { path.line(to: mapped) }
                }; a.add(path)
            }
            a.userName = "ScanMacSignature"; p.addAnnotation(a); lib.update { $0.signed = true }; lib.persist(); lib.annotationMode = "Mover"
        case "Mover":
            if let a = p.annotations.reversed().first(where: { $0.bounds.contains(point) }) { lib.snapshot(); moving = a; originalBounds = a.bounds; originalInk = InkTransform.capture(a); dragOrigin = point }
            else { super.mouseDown(with: event) }
        case "Borrar anotación":
            if let a = p.annotations.reversed().first(where: { $0.bounds.contains(point) }) { lib.snapshot(); p.removeAnnotation(a); lib.refreshSignedFlag(); lib.persist() }
        default: super.mouseDown(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if let start = panPoint, let clip = documentView?.enclosingScrollView?.contentView {
            let current = event.locationInWindow
            let requested = CGRect(origin: CGPoint(x: panScroll.x - current.x + start.x, y: panScroll.y + current.y - start.y), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(requested).origin); clip.enclosingScrollView?.reflectScrolledClipView(clip); return
        }
        guard let lib = library, let p = targetPage else { super.mouseDragged(with: event); return }
        let point = convert(convert(event.locationInWindow, from: nil), to: p)
        if lib.annotationMode == "Lápiz" { drawing.append(point); needsDisplay = true }
        else if let a = moving {
            let bounds: CGRect
            if event.modifierFlags.contains(.option) { bounds = CGRect(origin: originalBounds.origin, size: CGSize(width: max(12, originalBounds.width + point.x - dragOrigin.x), height: max(12, originalBounds.height + point.y - dragOrigin.y))) }
            else { bounds = originalBounds.offsetBy(dx: point.x - dragOrigin.x, dy: point.y - dragOrigin.y) }
            if let originalInk { InkTransform.apply(a, from: originalInk, to: bounds) } else { a.bounds = bounds }
            needsDisplay = true
        } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if panPoint != nil { panPoint = nil; return }
        guard let lib = library else { return }
        if lib.annotationMode == "Lápiz", let p = targetPage, drawing.count > 1 {
            let xs = drawing.map(\.x); let ys = drawing.map(\.y)
            let b = CGRect(x: xs.min()! - 3, y: ys.min()! - 3, width: max(6, xs.max()! - xs.min()! + 6), height: max(6, ys.max()! - ys.min()! + 6)); let path = NSBezierPath()
            path.move(to: CGPoint(x: drawing[0].x - b.minX, y: drawing[0].y - b.minY))
            for point in drawing.dropFirst() { path.line(to: CGPoint(x: point.x - b.minX, y: point.y - b.minY)) }
            let a = PDFAnnotation(bounds: b, forType: .ink, withProperties: nil); a.color = .systemBlue; let border = PDFBorder(); border.lineWidth = 2; a.border = border; a.add(path); p.addAnnotation(a); lib.persist()
        } else if moving != nil { lib.persist() } else { super.mouseUp(with: event) }
        drawing = []; moving = nil; originalInk = nil; targetPage = nil
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let p = targetPage, drawing.count > 1 else { return }
        let path = NSBezierPath(); path.move(to: convert(drawing[0], from: p)); for point in drawing.dropFirst() { path.line(to: convert(point, from: p)) }; NSColor.systemBlue.setStroke(); path.lineWidth = 2; path.stroke()
    }
}

struct InteractivePreview: NSViewRepresentable {
    @EnvironmentObject var lib: Library
    final class Coordinator {
        weak var lib: Library?
        var applying = false
        var observer: NSObjectProtocol?
        var scaleObserver: NSObjectProtocol?
        init(_ lib: Library) { self.lib = lib }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(lib) }
    func makeNSView(context: Context) -> EditingPDFView { let v = EditingPDFView(); v.autoScales = true; v.displayMode = .singlePage; v.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1); v.library = lib; lib.preview = v
        let coordinator = context.coordinator
        coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak coordinator, weak v] _ in
            guard let coordinator, !coordinator.applying, let v, let page = v.currentPage, let doc = v.document else { return }
            let index = doc.index(for: page)
            if index != NSNotFound { DispatchQueue.main.async { if coordinator.lib?.document === doc { coordinator.lib?.page = index } } }
        }
        coordinator.scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: v, queue: .main) { [weak coordinator, weak v] _ in
            guard let v, let coordinator else { return }; let scale = v.scaleFactor
            DispatchQueue.main.async { coordinator.lib?.zoom = scale }
        }
        return v }
    func updateNSView(_ view: EditingPDFView, context: Context) {
        view.library = lib
        context.coordinator.applying = true
        defer { context.coordinator.applying = false }
        if view.document !== lib.document { view.document = lib.document }
        if let p = lib.document?.page(at: lib.page), view.currentPage !== p { view.go(to: p) }
        view.needsDisplay = true
    }
}

extension Library {
    func refreshSignedFlag() {
        guard let doc = document else { return }
        let signed = (0..<doc.pageCount).contains { index in doc.page(at: index)?.annotations.contains { $0.userName == "ScanMacSignature" } == true }
        update { $0.signed = signed }
    }
    func highlightSelection() {
        guard let selection = preview?.currentSelection else { message = tr("Selecciona texto en el PDF primero"); return }
        snapshot()
        for line in selection.selectionsByLine() { for page in line.pages { let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil); a.color = NSColor.systemYellow.withAlphaComponent(0.45); page.addAnnotation(a) } }
        preview?.clearSelection(); persist()
    }
    func viewMode(_ mode: String) {
        guard let view = preview else { return }
        view.displayMode = mode == "Continuo" ? .singlePageContinuous : (mode == "Doble" ? .twoUp : .singlePage)
        view.autoScales = true
    }
}

struct EditorRibbon: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    let tab: String
    @Binding var pages: Bool
    @Binding var advanced: Bool
    @Binding var conversions: Bool
    @Binding var enhancement: Bool
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if tab == "Ver" {
                    Button(tr("Una página")) { lib.viewMode("Una") }; Button(tr("Continuo")) { lib.viewMode("Continuo") }; Button(tr("Doble página")) { lib.viewMode("Doble") }
                    Divider().frame(height: 18)
                    Button { lib.preview?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button(tr("Ajustar")) { lib.preview?.autoScales = true }
                    Button { lib.preview?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button(tr("Imprimir")) { lib.advancedPrint() }
                } else if tab == "Editar" {
                    Picker(tr("Modo"), selection: $lib.annotationMode) { ForEach(["Seleccionar", "Lápiz", "Mover", "Borrar anotación"], id: \.self) { Text(tr($0)).tag($0) } }.frame(width: 180)
                    Button(tr("Resaltar selección")) { lib.highlightSelection() }
                    Button(tr("Mejorar imagen")) { enhancement = true }
                    Button(tr("Marca de agua / Recorte")) { advanced = true }
                    Text(tr("Mover: arrastra · Redimensionar: ⌥ + arrastrar")).font(.caption).foregroundStyle(.secondary)
                } else if tab == "Páginas" {
                    Button(tr("Organizar en cuadrícula")) { pages = true }; Button(tr("Girar")) { lib.rotate() }; Button(tr("Antes")) { lib.movePage(-1) }.disabled(lib.page == 0)
                    Button(tr("Después")) { lib.movePage(1) }.disabled(lib.page >= (lib.document?.pageCount ?? 0) - 1)
                    Button(tr("Eliminar página")) { lib.deletePage() }.disabled((lib.document?.pageCount ?? 0) < 2)
                    Button(tr("Extraer / Proteger / Imágenes")) { advanced = true }
                } else {
                    Button(tr("Word · Excel · PowerPoint · IA")) { conversions = true }
                    Button(tr("PDF con texto seleccionable")) { lib.recognize() }
                    Menu(tr("Idiomas OCR")) { ForEach([("Español + Inglés", ["es", "en"]), ("Francés", ["fr", "en"]), ("Portugués", ["pt", "en"]), ("Alemán", ["de", "en"]), ("Italiano", ["it", "en"])], id: \.0) { item in Button(tr(item.0)) { lib.ocrLanguages = item.1 } } }
                }
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
        }.background(Color.secondary.opacity(0.045))
    }
}

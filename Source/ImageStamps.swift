import AppKit
import PDFKit
import UniformTypeIdentifiers

/// PDFKit serializes this stamp's custom drawing as a standard PDF appearance stream.
/// Reloaded PDFs use ordinary PDFAnnotation objects and retain their editable rectangle.
final class ImageSignatureStamp: PDFAnnotation {
    private let signatureImage: CGImage
    init(image: CGImage, bounds: CGRect) {
        signatureImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        userName = "ScanMacSignature"
        contents = "Firma importada"
        shouldDisplay = true; shouldPrint = true; color = .white
    }
    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "ScanMacSignatureImage") as Data?,
              let image = NSImage(data: data), let cg = Self.preparedImage(image) else { return nil }
        signatureImage = cg
        super.init(coder: coder)
    }
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        if let png = NSBitmapImageRep(cgImage: signatureImage).representation(using: .png, properties: [:]) {
            coder.encode(png as NSData, forKey: "ScanMacSignatureImage")
        }
    }
    override func copy(with zone: NSZone? = nil) -> Any {
        let clone = ImageSignatureStamp(image: signatureImage, bounds: bounds)
        clone.userName = userName; clone.contents = contents
        clone.shouldDisplay = shouldDisplay; clone.shouldPrint = shouldPrint
        return clone
    }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(signatureImage, in: bounds)
        context.restoreGState()
    }

    static func preparedImage(_ image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let original = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil), original.width > 0, original.height > 0 else { return nil }
        let scale = min(1, 4096 / Double(max(original.width, original.height)))
        guard scale < 1 else { return original }
        let width = max(1, Int(Double(original.width) * scale)), height = max(1, Int(Double(original.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

@MainActor extension Library {
    func chooseImageSignature() {
        guard !busy, document != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = tr("Selecciona una firma en imagen. PNG con transparencia evita un fondo blanco.")
        guard panel.runModal() == .OK, let source = panel.url else { return }
        guard let image = NSImage(contentsOf: source) else { error = tr("No se pudo abrir la imagen de la firma."); return }
        _ = addImageSignature(image, width: CGFloat(stampWidth))
    }

    @discardableResult
    func addImageSignature(_ image: NSImage, width requestedWidth: CGFloat = 180) -> Bool {
        guard !busy, let target = document?.page(at: page) else { return false }
        guard requestedWidth.isFinite, requestedWidth > 0, let cg = ImageSignatureStamp.preparedImage(image) else { error = tr("La imagen o el tamaño de la firma no es válido."); return false }
        let crop = target.bounds(for: .cropBox)
        guard crop.width > 24, crop.height > 24 else { error = tr("La página es demasiado pequeña para colocar una firma."); return false }
        let ratio = CGFloat(cg.height) / CGFloat(cg.width)
        let width = min(requestedWidth, crop.width - 24, (crop.height - 24) / ratio)
        let bounds = CGRect(x: crop.minX + 12, y: crop.minY + 12, width: width, height: width * ratio)
        error = nil
        snapshot()
        target.addAnnotation(ImageSignatureStamp(image: cg, bounds: bounds))
        update { $0.signed = true }
        persist()
        guard error == nil else { return false }
        annotationMode = "Mover"
        message = tr("Firma importada · Arrastra para mover · ⌥ + arrastrar para cambiar tamaño")
        return true
    }
}

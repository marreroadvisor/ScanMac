import Foundation
import Vision
import AppKit
import PDFKit

@main struct OCRLanguageHarness {
    @MainActor static func main() throws {
        let suite = "ScanMac.OCR.Test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(OCRLanguageCatalog.name("vi-VT", locale: Locale(identifier: "es")).contains("vietnam"))
        let supported = OCRLanguageCatalog.supported
        precondition(!supported.isEmpty, "Vision must report its supported languages")
        let initial = OCRLanguageCatalog.load(from: defaults)
        precondition(initial.automaticallyDetectsLanguage)
        precondition(!initial.languages.isEmpty && initial.languages.allSatisfy(supported.contains))
        let aliases = OCRLanguageCatalog.validated(["es", "en", "es-ES", "nonexistent-language"])
        precondition(aliases == ["es-ES", "en-US"])
        precondition(OCRLanguageCatalog.validated(["nonsense"]) == initial.languages)
        let alternate = supported.filter { $0 == "ja-JP" || $0 == "fr-FR" }
        let custom = OCRConfiguration(languages: alternate, automaticallyDetectsLanguage: false)
        OCRLanguageCatalog.save(custom, to: defaults)
        precondition(OCRLanguageCatalog.load(from: defaults) == custom)
        let request = VNRecognizeTextRequest()
        custom.apply(to: request)
        precondition(request.recognitionLevel == .accurate)
        precondition(request.recognitionLanguages == alternate)
        precondition(!request.automaticallyDetectsLanguage)
        precondition(request.usesLanguageCorrection)
        let auto = OCRConfiguration(languages: aliases, automaticallyDetectsLanguage: true)
        auto.apply(to: request)
        precondition(request.automaticallyDetectsLanguage)
        defaults.set(["unsupported"], forKey: OCRLanguageCatalog.languagesKey)
        precondition(OCRLanguageCatalog.load(from: defaults).languages == initial.languages)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(rootOverride: root, ocrDefaults: defaults)
        library.ocrLanguages = ["es", "en", "unsupported"]
        precondition(library.ocrLanguages == aliases)
        library.ocrLanguages = alternate
        library.ocrAutomaticallyDetectsLanguage = false
        let restored = Library(rootOverride: root, ocrDefaults: defaults)
        precondition(restored.ocrConfiguration == custom)
        // Actual non-English OCR from synthetic raster pages, also through conversion OCR.
        for (language, text, expected) in [("fr-FR", "Bonjour document", "bonjour"), ("ja-JP", "日本語の書類", "日本語")] where supported.contains(language) {
            let image = NSImage(size: NSSize(width: 900, height: 260))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 260).fill()
            (text as NSString).draw(at: NSPoint(x: 45, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 68), .foregroundColor: NSColor.black]); image.unlockFocus()
            let doc = PDFDocument(); doc.insert(PDFPage(image: image)!, at: 0)
            let pages = try LayoutDocumentConverter.recognize(document: doc, configuration: OCRConfiguration(languages: [language], automaticallyDetectsLanguage: false))
            let recognized = pages.flatMap(\.boxes).map(\.text).joined(separator: " ")
            precondition(recognized.lowercased().contains(expected), "Actual OCR failed for \(language): \(recognized)")
        }
        print("OCR language tests passed: \(supported.count) supported language variants, persistence, aliases, invalid preference recovery, shared request settings")
        print(supported.joined(separator: ", "))
    }
}

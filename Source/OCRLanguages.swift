import SwiftUI
import Vision

/// A value snapshot: safe to capture before dispatching recognition to a worker queue.
struct OCRConfiguration: Equatable {
    var languages: [String]
    var automaticallyDetectsLanguage: Bool

    func apply(to request: VNRecognizeTextRequest) {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = OCRLanguageCatalog.validated(languages)
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }
}

enum OCRLanguageCatalog {
    static let languagesKey = "ScanMac.OCR.languages"
    static let automaticKey = "ScanMac.OCR.automatic"
    /// Query the same request revision and recognition level used by the app.
    static let supported: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }()
    static func validated(_ candidates: [String]) -> [String] {
        var result: [String] = []
        for candidate in candidates {
            let normalized = candidate.replacingOccurrences(of: "_", with: "-")
            let match = supported.first { $0.caseInsensitiveCompare(normalized) == .orderedSame }
                ?? (normalized.contains("-") ? nil : supported.first { $0.split(separator: "-").first?.lowercased() == normalized.lowercased() })
            if let match, !result.contains(match) { result.append(match) }
        }
        if !result.isEmpty { return result }
        let defaults = supported.filter { $0 == "es-ES" || $0 == "en-US" }
        return defaults.isEmpty ? Array(supported.prefix(1)) : defaults.sorted { $0 == "es-ES" && $1 != "es-ES" }
    }
    static func load(from defaults: UserDefaults = .standard) -> OCRConfiguration {
        OCRConfiguration(languages: validated(defaults.stringArray(forKey: languagesKey) ?? ["es", "en"]), automaticallyDetectsLanguage: defaults.object(forKey: automaticKey) == nil ? true : defaults.bool(forKey: automaticKey))
    }
    static func save(_ configuration: OCRConfiguration, to defaults: UserDefaults = .standard) {
        defaults.set(validated(configuration.languages), forKey: languagesKey)
        defaults.set(configuration.automaticallyDetectsLanguage, forKey: automaticKey)
    }
    static func name(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? locale.localizedString(forLanguageCode: String(code.split(separator: "-").first ?? Substring(code))) ?? code
    }
}

struct OCRLanguageSettingsView: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var search = ""
    private var languages: [String] {
        OCRLanguageCatalog.supported.sorted { OCRLanguageCatalog.name($0, locale: locale).localizedStandardCompare(OCRLanguageCatalog.name($1, locale: locale)) == .orderedAscending }.filter {
            search.isEmpty || languageSearchMatches(OCRLanguageCatalog.name($0, locale: locale), query: search, locale: locale) || $0.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(tr("OCR languages")).font(.title2.bold()); Spacer(); Button(tr("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
            Toggle(tr("Detect document language automatically"), isOn: $lib.ocrAutomaticallyDetectsLanguage)
            Text(tr("Choose preferred languages in priority order. Recognition runs locally using the languages supported by this Mac.")).font(.callout).foregroundStyle(.secondary)
            if OCRLanguageCatalog.supported.isEmpty { Text(tr("The OCR language list could not be loaded on this Mac.")).foregroundStyle(.red) }
            TextField(tr("Search languages"), text: $search).textFieldStyle(.roundedBorder)
            Text(tr("Preferred languages")).font(.headline)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(lib.ocrLanguages.enumerated()), id: \.element) { index, code in
                        HStack {
                            Text("\(index + 1). \(OCRLanguageCatalog.name(code, locale: locale))")
                            Button { if index > 0 { lib.ocrLanguages.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.left") }.disabled(index == 0).help(tr("Increase priority"))
                        }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            List(languages, id: \.self) { code in
                Toggle(isOn: Binding(get: { lib.ocrLanguages.contains(code) }, set: { checked in
                    if checked { lib.ocrLanguages.append(code) }
                    else if lib.ocrLanguages.count > 1 { lib.ocrLanguages.removeAll { $0 == code } }
                })) {
                    HStack { Text(OCRLanguageCatalog.name(code, locale: locale)); Spacer(); Text(code).foregroundStyle(.secondary).font(.caption) }
                }.disabled(lib.ocrLanguages == [code])
            }.frame(minHeight: 270)
            Text(tr("The interface language and the OCR language are separate settings.")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 620, height: 600)
    }
}

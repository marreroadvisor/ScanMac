import SwiftUI
import Foundation

func languageSearchMatches(_ value: String, query: String, locale: Locale) -> Bool {
    value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
}

struct InterfaceLanguage: Identifiable, Equatable {
    let id: String
    let nativeName: String
    let englishName: String
    var isRightToLeft: Bool { ["ar", "he", "fa", "ur"].contains(id) }
}

enum InterfaceLanguageCatalog {
    static let languages: [InterfaceLanguage] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Languages/languages.json"), let data = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([[String]].self, from: data) else {
            return [InterfaceLanguage(id: "en", nativeName: "English", englishName: "English"), InterfaceLanguage(id: "es", nativeName: "Español", englishName: "Spanish")]
        }
        return rows.compactMap { $0.count == 3 ? InterfaceLanguage(id: $0[0], nativeName: $0[1], englishName: $0[2]) : nil }
    }()
    static func resolve(_ preferred: [String]) -> String {
        for value in preferred {
            let code = value.replacingOccurrences(of: "_", with: "-")
            if let language = languages.first(where: { $0.id.caseInsensitiveCompare(code) == .orderedSame }) { return language.id }
            if code.hasPrefix("zh") { return code.contains("Hant") || code.contains("TW") || code.contains("HK") ? "zh-Hant" : "zh-Hans" }
            if code.hasPrefix("pt") { return code.contains("BR") ? "pt-BR" : "pt-PT" }
            let base = code.split(separator: "-").first.map(String.init) ?? code
            let aliases = ["nb": "no", "nn": "no", "tl": "fil", "iw": "he", "in": "id"]
            if let alias = aliases[base], languages.contains(where: { $0.id == alias }) { return alias }
            if let language = languages.first(where: { $0.id == base }) { return language.id }
        }
        return "en"
    }
}

/// Only app-owned UI text enters this catalog. Worker threads also create status text.
final class TranslationCatalog {
    static let shared = TranslationCatalog()
    private static let marker = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    private let lock = NSLock()
    private var selected: [String: String] = [:]
    private var english: [String: String] = [:]
    private var reverse: [String: String] = [:]
    private struct FormattedMessage: Equatable { let key: String; let arguments: [String] }
    private var formatted: [String: FormattedMessage] = [:]
    private var ambiguous: Set<String> = []
    private var messageOrder: [String] = []
    private(set) var resourceDirectory: URL?
    init(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Languages")) {
        resourceDirectory = directory
        english = Self.read("en", directory: directory)
        let saved = UserDefaults.standard.string(forKey: "ScanMac.Interface.language")
        let code = saved.flatMap { code in InterfaceLanguageCatalog.languages.contains(where: { $0.id == code }) ? code : nil } ?? InterfaceLanguageCatalog.resolve(Locale.preferredLanguages)
        selected = Self.read(code, directory: directory)
        register(english); register(selected)
    }
    private static func read(_ code: String, directory: URL?) -> [String: String] {
        guard let url = directory?.appendingPathComponent(code + ".json"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }
    private func register(_ values: [String: String]) {
        for (key, value) in values where Self.marker.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) == nil {
            reverse[value] = key
        }
    }
    func select(_ code: String) {
        let values = Self.read(code, directory: resourceDirectory)
        lock.lock(); selected = values; register(values); lock.unlock()
    }
    private static func format(_ template: String, arguments: [String]) -> String {
        var value = template
        let original = value as NSString
        for match in marker.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
            if let index = Int(original.substring(with: match.range(at: 1))), arguments.indices.contains(index), let range = Range(match.range, in: value) { value.replaceSubrange(range, with: arguments[index]) }
        }
        return value
    }
    private func remember(_ value: String, key: String, arguments: [String]) {
        guard !arguments.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !ambiguous.contains(value) else { return }
        let message = FormattedMessage(key: key, arguments: arguments)
        if let previous = formatted[value] {
            if previous != message { formatted.removeValue(forKey: value); ambiguous.insert(value) }
            return
        }
        formatted[value] = message; messageOrder.append(value)
        if messageOrder.count > 1024 {
            let oldest = messageOrder.removeFirst(); formatted.removeValue(forKey: oldest); ambiguous.remove(oldest)
        }
    }
    func text(_ key: String, arguments: [String] = []) -> String {
        lock.lock(); let template = selected[key] ?? english[key] ?? key; lock.unlock()
        let value = Self.format(template, arguments: arguments)
        remember(value, key: key, arguments: arguments)
        return value
    }
    /// Keep original formatting arguments; never infer filenames or paths from rendered text.
    /// Unknown, evicted or ambiguous status strings stay unchanged.
    func status(_ value: String) -> String {
        lock.lock()
        let provenance = formatted[value], isAmbiguous = ambiguous.contains(value)
        let key = reverse[value]
        let direct = selected[value] ?? english[value]
        let replacement = key.flatMap { selected[$0] ?? english[$0] }
        lock.unlock()
        if isAmbiguous { return value }
        if let provenance { return text(provenance.key, arguments: provenance.arguments) }
        return direct ?? replacement ?? value
    }
}
func tr(_ key: String, _ arguments: String...) -> String { TranslationCatalog.shared.text(key, arguments: arguments) }
func trStatus(_ value: String) -> String { TranslationCatalog.shared.status(value) }

@MainActor final class AppLanguageSettings: ObservableObject {
    static let shared = AppLanguageSettings()
    static let preferenceKey = "ScanMac.Interface.language"
    static let languages = InterfaceLanguageCatalog.languages
    let defaults: UserDefaults
    @Published private(set) var code: String
    var followsSystem: Bool { defaults.string(forKey: Self.preferenceKey) == nil }
    var language: InterfaceLanguage { Self.languages.first { $0.id == code } ?? Self.languages[0] }
    var locale: Locale { Locale(identifier: code) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.preferenceKey)
        code = saved.flatMap { value in Self.languages.contains(where: { $0.id == value }) ? value : nil } ?? Self.systemLanguage()
        TranslationCatalog.shared.select(code)
    }
    static func systemLanguage(preferred: [String]? = nil) -> String {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return InterfaceLanguageCatalog.resolve(preferred ?? system ?? Locale.preferredLanguages)
    }
    func select(_ value: String) {
        if value == "system" {
            objectWillChange.send()
            defaults.removeObject(forKey: Self.preferenceKey)
            defaults.removeObject(forKey: "AppleLanguages")
            refreshSystemLanguage(); return
        }
        guard Self.languages.contains(where: { $0.id == value }) else { return }
        TranslationCatalog.shared.select(value)
        defaults.set(value, forKey: Self.preferenceKey)
        defaults.set([value], forKey: "AppleLanguages")
        code = value
    }
    func refreshSystemLanguage() {
        guard followsSystem else { return }
        let resolved = Self.systemLanguage()
        guard resolved != code else { return }
        TranslationCatalog.shared.select(resolved)
        code = resolved
    }
}

struct InterfaceLanguageSettingsView: View {
    @EnvironmentObject var appLanguage: AppLanguageSettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pending = ""
    var filtered: [InterfaceLanguage] {
        AppLanguageSettings.languages.filter { language in
            search.isEmpty || [language.nativeName, language.englishName, appLanguage.locale.localizedString(forIdentifier: language.id) ?? "", language.id].contains { languageSearchMatches($0, query: search, locale: appLanguage.locale) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("Languages")).font(.title2.bold()); Spacer(); Text("\(AppLanguageSettings.languages.count)").foregroundStyle(.secondary) }
            Text(tr("Interface language")).font(.headline)
            TextField(tr("Search languages"), text: $search).textFieldStyle(.roundedBorder)
            List(filtered) { language in
                Button { pending = language.id } label: {
                    HStack {
                        Image(systemName: pending == language.id ? "checkmark.circle.fill" : "circle").foregroundStyle(pending == language.id ? scanGreen : .secondary)
                        Text(language.nativeName).frame(minWidth: 130, alignment: .leading)
                        Text(appLanguage.locale.localizedString(forIdentifier: language.id) ?? language.englishName).foregroundStyle(.secondary)
                        Spacer(); Text(language.id).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(language.nativeName + " — " + language.englishName)
            }.frame(minHeight: 310)
            if filtered.isEmpty { Text(tr("No languages found.")).foregroundStyle(.secondary) }
            Text(tr("Translation files are included in the app. Changing the interface does not change document text.")).font(.callout).foregroundStyle(.secondary)
            Text(tr("Automatic translation; wording may need review.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { pending = "system" } label: { Label(tr("Use system language"), systemImage: pending == "system" ? "checkmark" : "globe") }
                Spacer()
                Button(tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Apply")) { appLanguage.select(pending); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 690, height: 590).onAppear { pending = appLanguage.followsSystem ? "system" : appLanguage.code }
    }
}

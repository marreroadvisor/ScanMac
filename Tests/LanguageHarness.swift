import Foundation
import SwiftUI

@main struct LanguageTests {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let catalog = TranslationCatalog(directory: directory)
        precondition(languageSearchMatches("inglés", query: "ingles", locale: Locale(identifier: "es")))
        precondition(languageSearchMatches("Español", query: "ESPANOL", locale: Locale(identifier: "en")))
        catalog.select("es")
        precondition(catalog.text("Home") == "Inicio")
        precondition(catalog.text("Save") == "Guardar")
        let oldStatus = catalog.text("Página {0}", arguments: ["7"])
        catalog.select("en")
        precondition(catalog.status(oldStatus) == "Page 7")
        catalog.select("es")
        let filename = "A» en B {1} 😀", folder = "/tmp/«Documents»"
        let key = "Falta el PDF de «{0}» en {1}. Espera a que tu proveedor descargue los archivos y vuelve a intentarlo."
        let namedStatus = catalog.text(key, arguments: [filename, folder])
        catalog.select("en")
        precondition(catalog.status(namedStatus) == catalog.text(key, arguments: [filename, folder]), "Relocalization must preserve original arguments even when names contain template delimiters")
        precondition(catalog.status(namedStatus).contains(filename) && catalog.status(namedStatus).contains(folder))
        catalog.select("es")
        let collisionA = catalog.text(key, arguments: ["A» en B", "/tmp"])
        let collisionB = catalog.text(key, arguments: ["A", "B» en /tmp"])
        precondition(collisionA == collisionB)
        catalog.select("en")
        precondition(catalog.status(collisionA) == collisionA, "Ambiguous rendered messages must stay unchanged")
        catalog.select("es")
        precondition(catalog.text("Unir {0} documentos", arguments: ["7"]).contains("7"))
        precondition(catalog.text("{0} documents", arguments: ["{1}"]) == "{1} documentos", "Arguments must be inserted once, without interpreting embedded placeholders")
        precondition(catalog.text("user document name 😀") == "user document name 😀")
        catalog.select("missing-language")
        precondition(catalog.text("Guardar etiquetas") == "Save tags", "Unknown catalog must fall back to English")
        let suite = "ScanMac.Language.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppLanguageSettings(defaults: defaults)
        settings.select("es")
        precondition(AppLanguageSettings(defaults: defaults).code == "es")
        settings.select("en")
        precondition(AppLanguageSettings(defaults: defaults).code == "en")
        settings.select("not-a-language")
        precondition(settings.code == "en")
        precondition(AppLanguageSettings.systemLanguage(preferred: ["es-PR"]) == "es")
        precondition(AppLanguageSettings.systemLanguage(preferred: ["nb-NO"]) == "no")
        precondition(AppLanguageSettings.systemLanguage(preferred: ["tl-PH"]) == "fil")
        precondition(AppLanguageSettings.languages.count == 63, "Test must run inside its resource bundle")
        precondition(AppLanguageSettings.systemLanguage(preferred: ["zh-TW"]) == "zh-Hant")
        precondition(AppLanguageSettings.systemLanguage(preferred: ["pt-BR"]) == "pt-BR")
        precondition(AppLanguageSettings.systemLanguage(preferred: ["pt-AO"]) == "pt-PT")
        settings.select("ar")
        precondition(settings.language.isRightToLeft)
        precondition(AppLanguageSettings(defaults: defaults).code == "ar")
        settings.select("ja")
        precondition(!settings.language.isRightToLeft)
        settings.select("system")
        precondition(settings.followsSystem)
        precondition(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil, "The app override must be removed; the inherited system preference remains")
        let expected = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("keys.json")))
        for language in AppLanguageSettings.languages {
            let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent(language.id + ".json")))
            precondition(Set(values.keys) == Set(expected))
            catalog.select(language.id)
            for key in expected { precondition(!catalog.text(key).isEmpty) }
        }
        print("PASS localization: 63 catalogs, persisted selection, system regional/script mapping, RTL, fallback, safe interpolation, unchanged unknown/document strings")
    }
}

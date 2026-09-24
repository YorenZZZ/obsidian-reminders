import Foundation

/// Two-language UI: Chinese when the user's preferred language is Chinese,
/// English otherwise. Kept inline so every string stays next to its use.
enum L10n {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }
}

import Foundation

/// Two languages do not justify string catalogs: French when the Mac speaks
/// French, English otherwise.
enum L10n {
    static let isFrench = (Locale.preferredLanguages.first ?? "en").hasPrefix("fr")

    static func t(_ french: String, _ english: String) -> String {
        isFrench ? french : english
    }
}

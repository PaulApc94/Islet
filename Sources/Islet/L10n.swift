import Foundation

/// Two languages do not justify string catalogs: French when the Mac speaks
/// French, English otherwise.
enum L10n {
    /// Resolved the way macOS picks the app's localization (Info.plist lists
    /// en and fr): the first preferred language the app supports wins. So a Mac
    /// set to German, then French, gets French strings, the same language as
    /// the dates and numbers SwiftUI formats.
    static let isFrench = Bundle.preferredLocalizations(from: ["en", "fr"],
                                                        forPreferences: Locale.preferredLanguages).first == "fr"

    static func t(_ french: String, _ english: String) -> String {
        isFrench ? french : english
    }

    /// "82 %" in French (narrow no-break space), "82%" in English.
    static func percent(_ value: Int) -> String {
        t("\(value)\u{202F}%", "\(value)%")
    }
}

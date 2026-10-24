import Foundation

/// Portuguese when the Mac's first language is Brazilian Portuguese; English otherwise.
public let isPortuguese: Bool = {
    let l = Locale.preferredLanguages.first ?? ""
    return l == "pt" || l.hasPrefix("pt-BR")
}()

/// Picks the text in the system language.
public func tr(_ pt: String, _ en: String) -> String { isPortuguese ? pt : en }

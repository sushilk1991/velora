import Combine
import SwiftUI

final class InterfaceLocale: ObservableObject {
    static let shared = InterfaceLocale()
    @Published private(set) var language: InterfaceLanguage
    var locale: Locale { Locale(identifier: language.resolvedIdentifier()) }

    private init() {
        language = AppConfig.shared.interfaceLanguage
        L10n.setLanguage(language)
    }

    func refresh() {
        let selected = AppConfig.shared.interfaceLanguage
        L10n.setLanguage(selected)
        language = selected
    }
}

/// Re-evaluates translated labels and supplies SwiftUI's locale for dates,
/// numbers and any native LocalizedStringKey literals within the interface.
struct LocalizedInterface<Content: View>: View {
    @ObservedObject private var localization = InterfaceLocale.shared
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        content().environment(\.locale, localization.locale)
    }
}

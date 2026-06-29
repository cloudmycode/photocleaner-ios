import Foundation
import ObjectiveC
import SwiftUI

private var languageBundleKey: UInt8 = 0

private final class AppLocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &languageBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

@main
struct PhotoCleanerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoLibrary = PhotoLibraryService()
    @State private var languageSettings = AppLanguageSettings.shared

    init() {
        AppLanguageSettings.shared.applyLocalizationBundle()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(photoLibrary)
                .environment(\.locale, languageSettings.locale)
                .environment(languageSettings)
                .id(languageSettings.effectiveLocaleIdentifier)
                .task {
                    photoLibrary.start()
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        photoLibrary.refreshAuthorizationStatus()
                    }
                }
        }
    }
}

@Observable
final class AppLanguageSettings {
    static let shared = AppLanguageSettings()

    enum Option: String, CaseIterable, Identifiable {
        case system
        case english = "en"
        case simplifiedChinese = "zh-Hans"
        case japanese = "ja"

        var id: String { rawValue }

        var localeIdentifier: String? {
            switch self {
            case .system:
                nil
            case .english:
                "en"
            case .simplifiedChinese:
                "zh-Hans"
            case .japanese:
                "ja"
            }
        }

        var nativeDisplayName: String {
            switch self {
            case .system:
                ""
            case .english:
                "English"
            case .simplifiedChinese:
                "简体中文"
            case .japanese:
                "日本語"
            }
        }
    }

    private let storageKey = "app.language.preference"

    var selection: Option {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: storageKey)
            applyLocalizationBundle()
        }
    }

    var locale: Locale {
        Locale(identifier: effectiveLocaleIdentifier)
    }

    var effectiveLocaleIdentifier: String {
        if let localeIdentifier = selection.localeIdentifier {
            return localeIdentifier
        }
        return Self.resolvedSystemLocaleIdentifier()
    }

    var currentDisplayName: String {
        switch selection {
        case .system:
            Self.option(for: Self.resolvedSystemLocaleIdentifier()).nativeDisplayName
        default:
            selection.nativeDisplayName
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let option = Option(rawValue: raw) {
            selection = option
        } else {
            selection = .system
        }
        applyLocalizationBundle()
    }

    func applyLocalizationBundle() {
        Self.installBundleHookIfNeeded()
        let identifier = effectiveLocaleIdentifier
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            objc_setAssociatedObject(
                Bundle.main,
                &languageBundleKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return
        }
        objc_setAssociatedObject(
            Bundle.main,
            &languageBundleKey,
            bundle,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static var didInstallBundleHook = false

    private static func installBundleHookIfNeeded() {
        guard !didInstallBundleHook else { return }
        object_setClass(Bundle.main, AppLocalizedBundle.self)
        didInstallBundleHook = true
    }

    static func resolvedSystemLocaleIdentifier() -> String {
        for language in Locale.preferredLanguages {
            if language.hasPrefix("zh") { return "zh-Hans" }
            if language.hasPrefix("ja") { return "ja" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static func option(for localeIdentifier: String) -> Option {
        if localeIdentifier.hasPrefix("zh") { return .simplifiedChinese }
        if localeIdentifier.hasPrefix("ja") { return .japanese }
        return .english
    }

    func string(_ key: String) -> String {
        let identifier = effectiveLocaleIdentifier
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func formatMonth(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).locale(locale))
    }

    func formatMonthYear(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).locale(locale))
    }
}

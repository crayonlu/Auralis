//
//  Auralis
//
//  Created by crayonlu on 2025/7/26.
//

import Foundation
import SwiftUI

// MARK: - App Language Enum

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

// MARK: - Language Manager

class LanguageManager: ObservableObject {
    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
            // Post notification so all views know to refresh
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    static let shared = LanguageManager()

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        if let lang = AppLanguage(rawValue: saved) {
            currentLanguage = lang
        } else {
            // Auto-detect from system language
            let systemLang = Locale.current.language.languageCode?.identifier ?? "en"
            currentLanguage = systemLang == "zh" ? .chineseSimplified : .english
        }
    }

    /// Get localized string for a key in the current language.
    /// Used for non-SwiftUI contexts (help strings, NSMenuItem titles, etc.)
    func string(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: currentLanguage.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, comment: "")
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
}

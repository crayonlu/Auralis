//
//  Auralis
//
//  Created by crayonlu on 2025/7/26.
//

import Foundation

extension Bundle {
    /// Set the language for NSLocalizedString / String(localized:) calls.
    /// Updates the AppleLanguages user default to force the app's localization.
    static func setLanguage(_ languageCode: String) {
        UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }
}

import Foundation

@MainActor
enum AppKitWindowCorners {
    private static let radiusKeys = ["NSConvolutionOverride1", "NSConvolutionOverride2"]
    private static let savedPreferencesKey = "appKitWindowCornersPreviousPreferences"
    private static let squareRadius = 0.01 // AppKit treats zero as an unset override.

    static var isEnabled: Bool {
        get { UserDefaults.standard.dictionary(forKey: savedPreferencesKey) != nil }
        set {
            let defaults = UserDefaults.standard
            let previous = defaults.dictionary(forKey: savedPreferencesKey)
            if newValue {
                guard previous == nil else { return }
                let current = radiusKeys.reduce(into: [String: Any]()) { result, key in
                    result[key] = read(key)
                }
                defaults.set(current, forKey: savedPreferencesKey)
                guard defaults.synchronize() else {
                    defaults.removeObject(forKey: savedPreferencesKey)
                    NSLog("AeroSpace could not save the previous AppKit window corner preferences.")
                    return
                }
                for key in radiusKeys {
                    write(NSNumber(value: squareRadius), for: key)
                }
                if !synchronize() {
                    restore(current, defaults: defaults)
                    NSLog("AeroSpace could not update AppKit window corner preferences.")
                }
            } else if let previous {
                restore(previous, defaults: defaults)
            }
        }
    }

    private static func restore(_ previous: [String: Any], defaults: UserDefaults) {
        for key in radiusKeys where (read(key) as? NSNumber)?.doubleValue == squareRadius {
            // Preserve edits another app or the user made after enabling the override.
            write(previous[key].map { $0 as CFPropertyList }, for: key)
        }
        if synchronize() {
            defaults.removeObject(forKey: savedPreferencesKey)
        } else {
            NSLog("AeroSpace could not restore AppKit window corner preferences.")
        }
    }

    private static func read(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func write(_ value: CFPropertyList?, for key: String) {
        CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func synchronize() -> Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

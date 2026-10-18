import Foundation

/// Keep embedded settings in Sea Coffee's domain, never in Droppy's defaults.
enum SeaCoffeePreferences {
    #if SEACOFFEE_DROPPY
    static let shared = UserDefaults(suiteName: "com.seacoffee.SeaIsland")!
    #else
    static let shared = UserDefaults.standard
    #endif
}

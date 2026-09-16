import CoreFoundation
import Foundation

/// Reads the user's system setting without modifying or duplicating it in app preferences.
enum MacOSVolumeFeedbackPreference {
    private static let FEEDBACK_KEY = "com.apple.sound.beep.feedback" as CFString

    static func isEnabled() throws -> Bool {
        for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
            guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) else {
                throw VolumeFeedbackFailure(message: "Could not refresh the macOS volume feedback preference")
            }
            guard let value = CFPreferencesCopyValue(FEEDBACK_KEY, kCFPreferencesAnyApplication,
                                                     kCFPreferencesCurrentUser, host) else { continue }
            guard let number = value as? NSNumber, number == 0 || number == 1 else {
                throw VolumeFeedbackFailure(message: "Invalid macOS volume feedback preference; remaining silent")
            }
            return number.boolValue
        }
        return false
    }
}

import Foundation

enum RedactionConsentPreference {
    private static let key = "RedactionModelConsentAsked"
    static var asked: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func shouldPrompt(appleSilicon: Bool, aiEnabled: Bool, modelReady: Bool, asked: Bool) -> Bool {
        appleSilicon && aiEnabled && !modelReady && !asked
    }
}

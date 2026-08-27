import Foundation
import CryptoKit

/// Public halves of the license signing keys. Key 1 signs today; key 2 is the
/// pre-embedded standby so a leaked primary can be rotated without stranding
/// shipped builds. Private keys live only in the developer's login Keychain
/// (service com.seal-shot.licensegen).
enum LicenseKeys {
    static let production: [Int: Curve25519.Signing.PublicKey] = {
        let b64: [Int: String] = [
            1: "/tjy0vqLLdg5pvQjxsQ0jd0d9i4ihlMXLPynR8qurgk=",
            2: "rgK5y1C5cPJOlmc1AyXXFok3FJvtIgK4k9nLKIetyqs=",
        ]
        var keys: [Int: Curve25519.Signing.PublicKey] = [:]
        for (id, s) in b64 {
            if let data = Data(base64Encoded: s),
               let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
                keys[id] = key
            }
        }
        return keys
    }()
}

enum LicensingConfig {
    static let donateURL = URL(string: "https://www.seal-shot.com/donate")!
    static let blocklistURL = URL(string:
        "https://raw.githubusercontent.com/ldeng83/Sealshot/main/license-blocklist.json")!
    /// Every released DMG stays downloadable here, so rolling back to an
    /// earlier version is always possible. Nothing forces it: newer versions
    /// install and run in full whatever a license says.
    static let previousVersionsURL = URL(string:
        "https://github.com/ldeng83/Sealshot/releases")!

    /// What used to be the renewal checkout. Updates are permanent, so the page
    /// no longer sells anything: it explains that there is nothing to renew and
    /// that a pre-August-2026 windowed license is replaced free on request.
    ///
    /// It used to carry `?license_id=…&email=…` so the checkout could look the
    /// license up. The page has no lookup left, and putting a customer's email
    /// address in a query string it never reads only spreads it through server
    /// logs and referrers. The License ID they need is on screen beside this
    /// link, which is where the page tells them to find it.
    ///
    /// Kept pointing at our own site rather than any payment provider: which
    /// provider we use has to stay a website deploy, not an app update every
    /// user must download. Builds up to 0.7.8 link here WITH the parameters, so
    /// the URL itself can never be retired.
    static let renewURL = URL(string: "https://www.seal-shot.com/renew")!
}

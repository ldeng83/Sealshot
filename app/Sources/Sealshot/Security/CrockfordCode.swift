import Foundation

/// Crockford Base32-style grouped random code over an unambiguous alphabet
/// (no 0/O/1/I/L/U). Shared by recovery codes and generated share passphrases.
enum CrockfordCode {
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// `groups` blocks of `groupSize` characters, joined by "-".
    /// e.g. generate(groups: 4, groupSize: 5) → "K7M2Q-9XBHE-4FRPT-8WJ3N".
    static func generate(groups: Int, groupSize: Int) -> String {
        (0..<groups)
            .map { _ in String((0..<groupSize).map { _ in alphabet.randomElement()! }) }
            .joined(separator: "-")
    }
}

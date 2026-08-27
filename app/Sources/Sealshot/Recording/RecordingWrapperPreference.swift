import Foundation

/// How a finished recording is stored: wrapped in a Sealshot package, or left
/// as the plain movie the recorder produced.
///
/// A package carries the manifest (tags, summary, extracted text, duration),
/// a baked thumbnail, collection membership, and — with Enhanced security on —
/// encryption. A plain movie has none of that, but needs no export step before
/// it can be sent anywhere, which is the whole reason this setting exists.
enum RecordingWrapper {
    case sealPackage
    case plainMovie
}

/// Stored as the OPT-OUT (`RecordingSavesPlainMovie`), so `UserDefaults`'
/// natural `false` for a missing key keeps every existing install on packages.
/// No migration, and no way for a future default change to silently convert
/// someone's recordings.
struct RecordingWrapperPreference {
    private static let key = "RecordingSavesPlainMovie"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var wrapper: RecordingWrapper {
        get { defaults.bool(forKey: Self.key) ? .plainMovie : .sealPackage }
        nonmutating set { defaults.set(newValue == .plainMovie, forKey: Self.key) }
    }
}

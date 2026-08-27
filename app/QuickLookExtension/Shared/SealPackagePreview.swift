import Foundation

/// Reading a `.seal` package from OUTSIDE the app.
///
/// The Quick Look extension is a separate process with no access to the app's
/// crypto session or its keychain — deliberately. It shares only the container
/// reader, so an UNENCRYPTED capture's preview is a directory lookup and a
/// range read, nothing more.
///
/// Encrypted packages are not decrypted here and never should be. Preview
/// generation happens in a sandboxed extension the user never invoked, on
/// files that are encrypted precisely so that a passing process cannot read
/// them; handing it the session key to draw a thumbnail in Finder would trade
/// the app's central promise for a convenience. An encrypted capture simply
/// has no preview outside Sealshot.
enum SealPackagePreview {
    /// Entry names inside the package, in the order a preview should prefer
    /// them: the small thumbnail for icons, the composite for a full preview.
    static let thumbnailEntry = "thumbnail.png"
    static let compositeEntry = "composite.png"
    static let manifestEntry = "manifest.json"

    /// The header an encrypted package carries (codec v5). Its PRESENCE is the
    /// marker — when it exists every entry is sealed, including the manifest,
    /// so nothing else in the package can be read either.
    static let lockEntry = "lock.json"

    /// Whether this package's entries are encrypted — in which case there is
    /// nothing this process can (or should) render.
    ///
    /// A package with no readable manifest is ALSO treated as encrypted:
    /// refusing to preview something this process cannot understand is the
    /// safe direction to fail.
    static func isEncrypted(package: URL,
                            fileManager: FileManager = .default) -> Bool {
        guard let reader = try? SealContainer.Reader(url: package) else { return true }
        if reader.entry(lockEntry) != nil { return true }
        // Belt and braces: a sealed manifest does not parse as JSON, so an
        // unreadable one means "not ours to render" whatever the reason.
        guard let data = try? reader.data(manifestEntry),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return true }
        return false
    }

    /// The best previewable image inside the package, or nil when there is
    /// none to show (encrypted, missing, or not an image after all).
    /// `preferComposite` picks the full-size render for a preview panel; icons
    /// want the small one.
    static func imageData(in package: URL, preferComposite: Bool,
                          fileManager: FileManager = .default) -> Data? {
        guard let reader = try? SealContainer.Reader(url: package) else { return nil }
        guard reader.entry(lockEntry) == nil else { return nil }
        guard let manifest = try? reader.data(manifestEntry),
              (try? JSONSerialization.jsonObject(with: manifest)) != nil
        else { return nil }
        let order = preferComposite
            ? [compositeEntry, thumbnailEntry]
            : [thumbnailEntry, compositeEntry]
        for entry in order {
            if let data = try? reader.data(entry), !data.isEmpty { return data }
        }
        return nil
    }
}

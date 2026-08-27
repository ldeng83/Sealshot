import UniformTypeIdentifiers

extension UTType {
    /// Sealshot encrypted share package. Built from the filename extension so it never
    /// traps even before LaunchServices has registered the exported-type declaration
    /// (e.g. in unit tests). The Info.plist declaration drives Finder association.
    static let sealshare = UTType(filenameExtension: "sealshare", conformingTo: .data) ?? .data
}

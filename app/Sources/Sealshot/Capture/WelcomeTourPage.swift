import Foundation

/// The welcome tour's pages, in the order they're shown.
///
/// `WelcomeView` renders `visible(appleSilicon:)` rather than a fixed list of
/// seven: the smarter-redaction page offers the enhanced on-device model, which
/// ships as the arm64-only `SealshotRedactionEngine` plugin (`project.yml`
/// pins it to `ARCHS: arm64`). On an Intel Mac that page could only say
/// "requires Apple silicon", so it is dropped entirely.
enum WelcomeTourPage: CaseIterable, Equatable {
    case privacy
    case captureRecord
    case smarterRedaction
    case editAnnotate
    case findOrganize
    case shareProtect
    case permissions

    /// Pages shown on this Mac, in order.
    ///
    /// - Parameter appleSilicon: defaults to this build's slice. It's a
    ///   parameter, not a direct read, because `isAppleSilicon` is resolved at
    ///   COMPILE time (`#if arch(arm64)`) — tests running on Apple silicon
    ///   could otherwise never exercise the Intel list.
    static func visible(
        appleSilicon: Bool = RedactionEngineLoader.isAppleSilicon
    ) -> [WelcomeTourPage] {
        allCases.filter { $0 != .smarterRedaction || appleSilicon }
    }
}

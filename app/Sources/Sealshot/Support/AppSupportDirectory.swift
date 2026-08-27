import Foundation

/// The one place that answers "where does Sealshot keep its own files?".
///
/// Every store used to resolve this for itself — fourteen copies of
/// `urls(for: .applicationSupportDirectory…)` plus `"Sealshot/…"`. That left
/// nowhere to intervene for a test run, and a test run duly wrote to the live
/// directory: it deleted and recreated the user's `libraryIndex.sqlite` while
/// Sealshot was running, so the app went on querying an unlinked file and
/// showed an empty Library, and it left rows behind pointing at the tests' own
/// temp folders. `session.json` ended up claiming a dead test process too.
///
/// So the location is resolved once, here, and redirected under XCTest. This is
/// deliberately not an injectable parameter: a seam only helps the call sites
/// that remember to use it, and the ones that forgot are exactly the ones that
/// caused the damage.
enum AppSupportDirectory {

    /// Sealshot's directory inside Application Support — the real one when the
    /// app runs, a private temp directory when tests do.
    ///
    /// `static let` so it is resolved once per process: the stores each read
    /// this independently and must all land in the same place, and a fresh
    /// temp directory per call would scatter their state.
    static let sealshot: URL = {
        let base = isRunningTests
            ? testBaseDirectory
            : (FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
        let directory = base.appendingPathComponent("Sealshot", isDirectory: true)
        // Created eagerly so callers can write without each repeating this.
        // The app used to get the directory for free from Application Support
        // already existing; a temp base has no such guarantee.
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }()

    /// A file directly inside `sealshot`, e.g. `file("libraryIndex.sqlite")`.
    static func file(_ name: String) -> URL {
        sealshot.appendingPathComponent(name)
    }

    /// A subdirectory of `sealshot`, e.g. `subdirectory("keys")`.
    static func subdirectory(_ name: String) -> URL {
        sealshot.appendingPathComponent(name, isDirectory: true)
    }

    /// True while running under XCTest.
    ///
    /// The environment variable only, deliberately. Probing for the XCTestCase
    /// class would also answer yes if anything ever loaded XCTest into the
    /// shipping app — and the consequence of a false positive here is that
    /// Sealshot silently points at an empty temp directory and the user sees
    /// their entire library gone. The test runner sets this variable for the
    /// bundle it is about to run, before any of our code executes, so it is set
    /// by the time this `static let` initialises on first access.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Per-process temp base, so parallel test targets can't collide and a run
    /// never inherits the previous run's leftovers.
    private static var testBaseDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SealshotTests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
    }
}

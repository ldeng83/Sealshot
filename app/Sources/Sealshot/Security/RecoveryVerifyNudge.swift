import SwiftUI

/// Periodic "prove you still have your recovery code" nudge. A recovery code
/// is the only way back in if this Mac's encryption key is ever lost — but a
/// code the owner saved once and never looks at again could be transcribed
/// wrong, or the paper it's on could be gone, and nobody finds out until the
/// day it's needed. Surfacing a lightweight re-check periodically (after an
/// unlock, never while locked or mid-ceremony) catches that early.
enum RecoveryVerifyNudge {
    /// Re-verify at least this often. Monthly rather than quarterly: a code
    /// that was mistranscribed, or saved somewhere the owner can no longer
    /// find, is already wrong the day it's written — a long gap just delays
    /// the discovery until the paper is likelier gone too.
    static let dueInterval: TimeInterval = 30 * 86_400
    /// "Remind Me Later" holds the nudge off for this long. Deliberately much
    /// shorter than `dueInterval`: someone deferring the check is signalling
    /// they may not have the code to hand, which is the case worth chasing.
    static let snoozeInterval: TimeInterval = 7 * 86_400

    /// When the next check falls if verification happens at `date`. The sheet
    /// tells the user this date, so it is derived from `dueInterval` rather
    /// than written out again — a hardcoded promise would drift the first time
    /// the interval changed.
    static nonisolated func nextCheckDate(from date: Date) -> Date {
        date.addingTimeInterval(dueInterval)
    }

    /// Pure policy: due when never verified, or the last verification is
    /// stale (`dueInterval`) — UNLESS a more recent snooze is still fresh
    /// (`snoozeInterval`). Callers are additionally responsible for gating on
    /// encryption being enabled and a keystore existing
    /// (`RecoveryUnlock.isAvailable`) — this function only knows about the
    /// two timestamps.
    static nonisolated func isDue(lastVerified: Date?, lastSnoozed: Date?, now: Date) -> Bool {
        let stale: Bool
        if let lastVerified {
            stale = now.timeIntervalSince(lastVerified) > dueInterval
        } else {
            stale = true
        }
        guard stale else { return false }
        if let lastSnoozed, now.timeIntervalSince(lastSnoozed) < snoozeInterval {
            return false
        }
        return true
    }
}

/// Owns the UserDefaults stamps + the once-per-app-session guard. The window
/// controller asks `shouldPresent` after each unlock and calls `markShown`
/// before presenting, so a relock/unlock cycle within one launch can't nag
/// more than once — matching the "at most once per app session" rule.
@MainActor
final class RecoveryVerifyNudgeController {
    // Not per-instance: the window controller may recreate this alongside a
    // window teardown/rebuild, but "once per app session" means once per
    // process, so the guard is shared across all instances.
    private static var hasPresentedThisSession = false

    private static let lastVerifiedKey = "recovery.lastVerified"
    private static let lastSnoozedKey = "recovery.lastSnoozed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastVerified: Date? { readStamp(Self.lastVerifiedKey) }
    var lastSnoozed: Date? { readStamp(Self.lastSnoozedKey) }

    private func readStamp(_ key: String) -> Date? {
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    private func writeStamp(_ date: Date, key: String) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    /// Whether to present the nudge sheet right now: policy-due AND not
    /// already shown this session. Callers must separately confirm encryption
    /// is enabled, unlocked, and a keystore is available.
    func shouldPresent(now: Date = Date()) -> Bool {
        guard !Self.hasPresentedThisSession else { return false }
        return RecoveryVerifyNudge.isDue(lastVerified: lastVerified, lastSnoozed: lastSnoozed, now: now)
    }

    /// Call immediately before presenting the sheet — arms the session guard.
    func markShown() { Self.hasPresentedThisSession = true }

    func recordVerified(now: Date = Date()) { writeStamp(now, key: Self.lastVerifiedKey) }
    func recordSnoozed(now: Date = Date()) { writeStamp(now, key: Self.lastSnoozedKey) }

    /// Stamp verification from a site that isn't this nudge's own sheet but
    /// still proves live possession of a working recovery code: a successful
    /// Locked Archive restore, a successful lock-screen "Enter Your Recovery
    /// Key" entry, and acknowledging a freshly generated code all count.
    /// Static (and defaults-backed, reusing the same key this controller
    /// reads) since those call sites don't otherwise own a controller
    /// instance.
    static func stampVerifiedNow(now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: lastVerifiedKey)
    }
}

/// Drives the sheet's verify action against the local keystore. Pure logic
/// (no UI) so it is unit-testable in isolation, matching `RecoveryEntryModel`.
@Observable
@MainActor
final class RecoveryVerifyNudgeModel {
    enum Phase: Equatable {
        case entry
        case verifying
        case success
        case failed(message: String)
    }

    private(set) var phase: Phase = .entry

    @ObservationIgnored private let saveFolder: URL

    init(saveFolder: URL) {
        self.saveFolder = saveFolder
    }

    @discardableResult
    func verify(code: String) async -> Bool {
        phase = .verifying
        let ok = await RecoveryUnlock.verify(code: code, saveFolder: saveFolder)
        phase = ok ? .success : .failed(message: "That code doesn’t match. Check for typos, or generate a new one.")
        return ok
    }
}

/// The nudge sheet: title + code field + Verify / Remind Me Later. On success
/// shows a green check and auto-dismisses; on failure shows the mismatch
/// message plus a "Generate New Code…" button that routes to Settings
/// (Privacy & Security ▸ Recovery code ▸ Generate New…).
struct RecoveryVerifyNudgeView: View {
    @State private var model: RecoveryVerifyNudgeModel
    @State private var code = ""
    let onVerified: () -> Void
    let onSnooze: () -> Void
    let onGenerateNew: () -> Void

    init(saveFolder: URL,
         onVerified: @escaping () -> Void,
         onSnooze: @escaping () -> Void,
         onGenerateNew: @escaping () -> Void) {
        _model = State(initialValue: RecoveryVerifyNudgeModel(saveFolder: saveFolder))
        self.onVerified = onVerified
        self.onSnooze = onSnooze
        self.onGenerateNew = onGenerateNew
    }

    var body: some View {
        Group {
            if model.phase == .success {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("Verified").font(.title3.bold())
                    Text("Next check \(Self.nextCheckText)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 320, height: 160)
                .task {
                    // Brief confirmation, then dismiss on its own — the user
                    // already did the thing; no second click required.
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    onVerified()
                }
            } else {
                entryBody
            }
        }
    }

    /// The next check's date if verification happens now, localized. Computed
    /// per read rather than stored: a sheet left open overnight would otherwise
    /// promise yesterday's date.
    private static var nextCheckText: String {
        RecoveryVerifyNudge.nextCheckDate(from: Date())
            .formatted(date: .long, time: .omitted)
    }

    private var entryBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify Your Recovery Code").font(.title2.bold())
            Text("Sealshot checks in every 30 days so you don’t forget your recovery code — or lose track of where you saved it. It’s the only way back in if this Mac’s key is ever lost.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .disabled(model.phase == .verifying)
            if case .failed(let message) = model.phase {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).foregroundStyle(.red).font(.callout)
                    Button("Generate New Code…") { onGenerateNew() }
                    Text("This opens Settings ▸ Privacy & Security, where Recovery code ▸ Generate New… makes a fresh one.")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            // Answer the question the user is actually asking when they read
            // this: "when will it bother me again?" The date is what happens
            // if they verify NOW, which is the choice in front of them.
            Text("Verify now and the next check will be \(Self.nextCheckText).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Remind Me Later") { onSnooze() }.disabled(model.phase == .verifying)
                Spacer()
                Button("Verify") {
                    Task { await model.verify(code: code) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || model.phase == .verifying)
            }
        }
        .padding(24).frame(width: 460)
    }
}

import SwiftUI

/// What the lock screen should offer, derived from `EncryptionConsistency`.
enum LockScreenMode: Equatable {
    /// Normal: the key is on this Mac — Touch ID unlock (recovery as a fallback).
    case unlock
    /// The key isn't on this Mac but an escrow is — recovery is the way in.
    case recovery
    /// The encryption state is inconsistent (a divergence the keys can't resolve).
    /// Offer recovery AND a guaranteed "Turn Off Encryption" escape.
    case diverged
}

extension ConsistencyStatus {
    /// Pure mapping from a consistency classification to what the lock screen
    /// should present. `.off`/`.consistent` → unlock; `.recoverable` → recovery;
    /// `.diverged` → the escape.
    var lockScreenMode: LockScreenMode {
        switch self {
        case .off, .consistent: return .unlock
        case .recoverable: return .recovery
        case .diverged: return .diverged
        }
    }
}

/// Full-cover overlay shown while encryption is on but the session is locked.
/// Blocks all interaction with the content beneath (it is opaque and on top).
struct LockScreenView: View {
    var mode: LockScreenMode = .unlock
    /// Why the user was sent here, when something other than "you opened the
    /// app" put them in front of the lock screen — e.g. a capture shortcut
    /// refused while the library is locked. Without it, a blocked shortcut is a
    /// silent no-op and there is nowhere to learn why nothing happened.
    var notice: String?
    let onUnlock: () -> Void
    let onRecover: () -> Void
    /// Always-can-disable escape, offered in `.diverged`.
    var onTurnOff: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            // App icon (shield-S) as the hero mark, with a small badge in the
            // corner carrying the mode's status glyph so unlock / recovery /
            // diverged stay visually distinct. `applicationIconImage` needs no
            // new asset and always matches the shipped icon.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 78, height: 78)
                .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(badgeColor, in: Circle())
                        // Surface-colored ring so the badge reads as sitting on
                        // the lock screen rather than painted onto the icon.
                        .overlay(Circle().stroke(Color(nsColor: Theme.surfaceColor), lineWidth: 3))
                        .offset(x: 3, y: 3)
                }
            Text(title).font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let notice {
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 430)
                    .background(Color.orange.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.orange.opacity(0.35)))
            }
            switch mode {
            case .unlock:
                Button("Unlock…") { onUnlock() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                // The "I can't unlock…" guided-reset escape lives inside the
                // recovery-key sheet — users try their code first, then
                // escalate from there.
                Button("Use recovery key…") { onRecover() }
                    .buttonStyle(.link)
            case .recovery:
                Button("Use recovery key…") { onRecover() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            case .diverged:
                Button("Use recovery key…") { onRecover() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                Button("Turn Off Encryption…") { onTurnOff() }
                    .buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.surfaceColor))   // opaque — content beneath is hidden
        // Extend the opaque cover into the safe area (the titlebar/toolbar band).
        // Without this, SwiftUI insets the background below the safe area and the
        // editor's Capture tool bar pokes through that top strip.
        .ignoresSafeArea()
    }

    private var icon: String {
        switch mode {
        case .unlock: return "lock.fill"
        case .recovery: return "key.slash.fill"
        case .diverged: return "exclamationmark.triangle.fill"
        }
    }
    /// Badge tint per mode: calm accent when it's a normal unlock, orange when
    /// recovery is required, red when the state needs attention.
    private var badgeColor: Color {
        switch mode {
        case .unlock: return .accentColor
        case .recovery: return .orange
        case .diverged: return .red
        }
    }
    private var title: String {
        mode == .diverged ? "Encryption needs attention" : "Sealshot is locked"
    }
    private var message: String {
        switch mode {
        case .unlock:
            return "Your captures are encrypted on this Mac. Unlock to view them."
        case .recovery:
            return "The key for these captures isn’t available on this Mac. Enter your recovery key to regain access."
        case .diverged:
            return "Sealshot couldn’t reconcile this Mac’s encryption keys. Recover with your code, or turn encryption off — anything that can’t be decrypted is preserved in a “Locked-Unrecoverable” folder."
        }
    }
}

import Foundation
import Observation

@Observable @MainActor final class ImportPackageModel {
    var passphrase = ""
    private(set) var isWorking = false
    var errorMessage: String?

    let hint: String?
    let createdAt: Date
    let expiresAt: Date?

    init(hint: String?, createdAt: Date, expiresAt: Date?) {
        self.hint = hint
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    var canSubmit: Bool { !passphrase.isEmpty && !isWorking }

    func setWorking(_ working: Bool) { isWorking = working }
}

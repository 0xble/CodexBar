import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func selectedCodexTokenAccountEmailForOpenAIDashboard() -> String? {
        guard let selected = self.settings.selectedTokenAccount(for: .codex) else { return nil }
        return Self.normalizedCodexAccountEmail(selected.label)
    }

    static func normalizedCodexAccountEmail(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.contains("@")
        else {
            return nil
        }
        return value
    }

    static func shouldUseCodexCLICredits(selectedEmail: String?, cliEmail: String?) -> Bool {
        guard let normalizedSelected = normalizedCodexAccountEmail(selectedEmail)?.lowercased() else {
            return true
        }
        guard let normalizedCLI = normalizedCodexAccountEmail(cliEmail)?.lowercased() else {
            return true
        }
        return normalizedSelected == normalizedCLI
    }
}

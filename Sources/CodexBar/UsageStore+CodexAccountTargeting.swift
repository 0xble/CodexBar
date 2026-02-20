import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func selectedCodexTokenAccountEmailForOpenAIDashboard() -> String? {
        guard let selected = self.settings.selectedTokenAccount(for: .codex) else { return nil }
        if let labelEmail = Self.normalizedCodexAccountEmail(selected.label) {
            return labelEmail
        }
        let selector = selected.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty,
              let credentials = try? CodexOAuthCredentialsStore.load(accountSelector: selector)
        else {
            return nil
        }
        return Self.codexOAuthAccountEmail(credentials)
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

    private static func codexOAuthAccountEmail(_ credentials: CodexOAuthCredentials) -> String? {
        guard let idToken = credentials.idToken,
              let payload = UsageFetcher.parseJWT(idToken)
        else {
            return nil
        }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let email = (payload["email"] as? String) ?? (profile?["email"] as? String)
        return Self.normalizedCodexAccountEmail(email)
    }
}

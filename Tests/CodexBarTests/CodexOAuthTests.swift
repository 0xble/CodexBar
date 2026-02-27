import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CodexOAuthTests {
    @Test
    func parsesOAuthCredentials() throws {
        let json = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "id_token": "id-token",
            "account_id": "account-123"
          },
          "last_refresh": "2025-12-20T12:34:56Z"
        }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "access-token")
        #expect(creds.refreshToken == "refresh-token")
        #expect(creds.idToken == "id-token")
        #expect(creds.accountId == "account-123")
        #expect(creds.lastRefresh != nil)
    }

    @Test
    func parsesAPIKeyCredentials() throws {
        let json = """
        {
          "OPENAI_API_KEY": "sk-test"
        }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "sk-test")
        #expect(creds.refreshToken.isEmpty)
        #expect(creds.idToken == nil)
        #expect(creds.accountId == nil)
    }

    @Test
    func savesSelectedAccountCredentialsToCatalog() throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let secretsDir = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        let catalogURL = secretsDir.appendingPathComponent("codex-oauth.json")
        let catalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brian-brianle-xyz",
                    "profile": "brian-brianle-xyz",
                    "name": "brian@brianle.xyz",
                    "access_token": "old-access",
                    "refresh_token": "old-refresh",
                    "id_token": "old-id",
                    "account_id": "acct-1",
                    "last_refresh": "2026-02-18T05:19:10.199231Z",
                ],
                [
                    "key": "other-profile",
                    "profile": "other-profile",
                    "name": "other@example.com",
                    "access_token": "other-old-access",
                    "refresh_token": "other-old-refresh",
                ],
            ],
        ]
        let catalogData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        try catalogData.write(to: catalogURL, options: .atomic)

        let refreshed = CodexOAuthCredentials(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "acct-1",
            lastRefresh: Date())

        try self.withEnvironment(["XDG_CONFIG_HOME": root.path]) {
            try CodexOAuthCredentialsStore.save(refreshed, accountSelector: "brian-brianle-xyz")
        }

        let updatedData = try Data(contentsOf: catalogURL)
        let updatedRoot = try #require(JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let accounts = try #require(updatedRoot["accounts"] as? [[String: Any]])
        let selected = try #require(accounts.first(where: { ($0["key"] as? String) == "brian-brianle-xyz" }))
        let other = try #require(accounts.first(where: { ($0["key"] as? String) == "other-profile" }))

        #expect(selected["access_token"] as? String == "new-access")
        #expect(selected["refresh_token"] as? String == "new-refresh")
        #expect(selected["id_token"] as? String == "new-id")
        #expect(selected["account_id"] as? String == "acct-1")
        #expect((selected["last_refresh"] as? String)?.isEmpty == false)
        #expect(other["refresh_token"] as? String == "other-old-refresh")
    }

    @Test
    func decodesCreditsBalanceString() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "credits": {
            "has_credits": false,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
        #expect(response.planType?.rawValue == "pro")
        #expect(response.credits?.balance == 0)
        #expect(response.credits?.hasCredits == false)
        #expect(response.credits?.unlimited == false)
    }

    @Test
    func mapsUsageWindowsFromOAuth() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            }
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 43)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.primary?.resetsAt != nil)
        #expect(snapshot.secondary?.resetsAt != nil)
    }

    @Test
    func resolvesChatGPTUsageURLFromConfig() {
        let config = "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test
    func resolvesCodexUsageURLFromConfig() {
        let config = "chatgpt_base_url = \"https://api.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://api.openai.com/api/codex/usage")
    }

    @Test
    func normalizesChatGPTBaseURLWithoutBackendAPI() {
        let config = "chatgpt_base_url = \"https://chat.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chat.openai.com/backend-api/wham/usage")
    }

    private func withEnvironment<T>(_ environment: [String: String], operation: () throws -> T) rethrows -> T {
        var previous: [String: String?] = [:]
        for (key, value) in environment {
            previous[key] = getenv(key).map { String(cString: $0) }
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        return try operation()
    }
}

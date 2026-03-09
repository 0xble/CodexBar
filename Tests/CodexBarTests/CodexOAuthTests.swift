import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthTests {
    @Test
    func `parses O auth credentials`() throws {
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
    func `parses API key credentials`() throws {
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
    func `saves selected account credentials to legacy catalog`() throws {
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
    func `saves selected account credentials to broker catalog`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authDir = root.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        let catalogURL = authDir.appendingPathComponent("codex-catalog.json")
        let catalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brian-brianle-xyz",
                    "profile": "brian-brianle-xyz",
                    "name": "brian@brianle.xyz",
                    "access_token": "old-access",
                    "refresh_token": "old-refresh",
                ],
                [
                    "key": "brianandmahin-gmail-com",
                    "profile": "brianandmahin-gmail-com",
                    "name": "brianandmahin@gmail.com",
                    "access_token": "old-access-2",
                    "refresh_token": "old-refresh-2",
                ],
            ],
        ]
        let catalogData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        try catalogData.write(to: catalogURL, options: .atomic)

        let refreshed = CodexOAuthCredentials(
            accessToken: "new-access-2",
            refreshToken: "new-refresh-2",
            idToken: "new-id-2",
            accountId: "acct-2",
            lastRefresh: Date())

        try self.withEnvironment(["XDG_CONFIG_HOME": root.path]) {
            try CodexOAuthCredentialsStore.save(refreshed, accountSelector: "brianandmahin-gmail-com")
        }

        let updatedData = try Data(contentsOf: catalogURL)
        let updatedRoot = try #require(JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let accounts = try #require(updatedRoot["accounts"] as? [[String: Any]])
        let selected = try #require(accounts.first(where: { ($0["key"] as? String) == "brianandmahin-gmail-com" }))

        #expect(selected["access_token"] as? String == "new-access-2")
        #expect(selected["refresh_token"] as? String == "new-refresh-2")
        #expect(selected["id_token"] as? String == "new-id-2")
        #expect(selected["account_id"] as? String == "acct-2")
    }

    @Test
    func `load prefers broker catalog when both catalogs exist`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authDir = root.appendingPathComponent("auth", isDirectory: true)
        let secretsDir = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        let brokerCatalogURL = authDir.appendingPathComponent("codex-catalog.json")
        let legacyCatalogURL = secretsDir.appendingPathComponent("codex-oauth.json")

        let brokerCatalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brianandmahin-gmail-com",
                    "profile": "brianandmahin-gmail-com",
                    "name": "brianandmahin@gmail.com",
                    "access_token": "broker-access",
                    "refresh_token": "broker-refresh",
                ],
            ],
        ]
        let legacyCatalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brianandmahin-gmail-com",
                    "profile": "brianandmahin-gmail-com",
                    "name": "brianandmahin@gmail.com",
                    "access_token": "legacy-access",
                    "refresh_token": "legacy-refresh",
                ],
            ],
        ]

        let brokerData = try JSONSerialization.data(
            withJSONObject: brokerCatalog,
            options: [.prettyPrinted, .sortedKeys])
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyCatalog,
            options: [.prettyPrinted, .sortedKeys])
        try brokerData.write(to: brokerCatalogURL, options: .atomic)
        try legacyData.write(to: legacyCatalogURL, options: .atomic)

        let loaded = try self.withEnvironment(["XDG_CONFIG_HOME": root.path]) {
            try CodexOAuthCredentialsStore.load(accountSelector: "brianandmahin-gmail-com")
        }

        #expect(loaded.accessToken == "broker-access")
        #expect(loaded.refreshToken == "broker-refresh")
    }

    @Test
    func `load falls back to legacy catalog when broker lacks selected account`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authDir = root.appendingPathComponent("auth", isDirectory: true)
        let secretsDir = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        let brokerCatalogURL = authDir.appendingPathComponent("codex-catalog.json")
        let legacyCatalogURL = secretsDir.appendingPathComponent("codex-oauth.json")

        let brokerCatalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brian-brianle-xyz",
                    "profile": "brian-brianle-xyz",
                    "name": "brian@brianle.xyz",
                    "access_token": "broker-access",
                    "refresh_token": "broker-refresh",
                ],
            ],
        ]
        let legacyCatalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brianandmahin-gmail-com",
                    "profile": "brianandmahin-gmail-com",
                    "name": "brianandmahin@gmail.com",
                    "access_token": "legacy-access",
                    "refresh_token": "legacy-refresh",
                ],
            ],
        ]

        let brokerData = try JSONSerialization.data(
            withJSONObject: brokerCatalog,
            options: [.prettyPrinted, .sortedKeys])
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyCatalog,
            options: [.prettyPrinted, .sortedKeys])
        try brokerData.write(to: brokerCatalogURL, options: .atomic)
        try legacyData.write(to: legacyCatalogURL, options: .atomic)

        let loaded = try self.withEnvironment(["XDG_CONFIG_HOME": root.path]) {
            try CodexOAuthCredentialsStore.load(accountSelector: "brianandmahin-gmail-com")
        }

        #expect(loaded.accessToken == "legacy-access")
        #expect(loaded.refreshToken == "legacy-refresh")
    }

    @Test
    func `save updates legacy catalog when broker lacks selected account`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authDir = root.appendingPathComponent("auth", isDirectory: true)
        let secretsDir = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        let brokerCatalogURL = authDir.appendingPathComponent("codex-catalog.json")
        let legacyCatalogURL = secretsDir.appendingPathComponent("codex-oauth.json")

        let brokerCatalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brian-brianle-xyz",
                    "profile": "brian-brianle-xyz",
                    "name": "brian@brianle.xyz",
                    "access_token": "broker-access",
                    "refresh_token": "broker-refresh",
                ],
            ],
        ]
        let legacyCatalog: [String: Any] = [
            "accounts": [
                [
                    "key": "brianandmahin-gmail-com",
                    "profile": "brianandmahin-gmail-com",
                    "name": "brianandmahin@gmail.com",
                    "access_token": "legacy-access",
                    "refresh_token": "legacy-refresh",
                ],
            ],
        ]

        let brokerData = try JSONSerialization.data(
            withJSONObject: brokerCatalog,
            options: [.prettyPrinted, .sortedKeys])
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyCatalog,
            options: [.prettyPrinted, .sortedKeys])
        try brokerData.write(to: brokerCatalogURL, options: .atomic)
        try legacyData.write(to: legacyCatalogURL, options: .atomic)

        let refreshed = CodexOAuthCredentials(
            accessToken: "updated-legacy-access",
            refreshToken: "updated-legacy-refresh",
            idToken: "updated-legacy-id",
            accountId: "acct-legacy",
            lastRefresh: Date())

        try self.withEnvironment(["XDG_CONFIG_HOME": root.path]) {
            try CodexOAuthCredentialsStore.save(refreshed, accountSelector: "brianandmahin-gmail-com")
        }

        let brokerDataAfterSave = try Data(contentsOf: brokerCatalogURL)
        let brokerRoot = try #require(JSONSerialization.jsonObject(with: brokerDataAfterSave) as? [String: Any])
        let brokerAccounts = try #require(brokerRoot["accounts"] as? [[String: Any]])
        let brokerSelected = try #require(brokerAccounts.first)
        #expect(brokerSelected["access_token"] as? String == "broker-access")
        #expect(brokerSelected["refresh_token"] as? String == "broker-refresh")

        let legacyDataAfterSave = try Data(contentsOf: legacyCatalogURL)
        let legacyRoot = try #require(JSONSerialization.jsonObject(with: legacyDataAfterSave) as? [String: Any])
        let legacyAccounts = try #require(legacyRoot["accounts"] as? [[String: Any]])
        let legacySelected = try #require(legacyAccounts.first)
        #expect(legacySelected["access_token"] as? String == "updated-legacy-access")
        #expect(legacySelected["refresh_token"] as? String == "updated-legacy-refresh")
        #expect(legacySelected["id_token"] as? String == "updated-legacy-id")
        #expect(legacySelected["account_id"] as? String == "acct-legacy")
    }

    @Test
    func `decodes credits balance string`() throws {
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
    func `maps usage windows from O auth`() throws {
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
    func `resolves chat GPT usage URL from config`() {
        let config = "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test
    func `resolves codex usage URL from config`() {
        let config = "chatgpt_base_url = \"https://api.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://api.openai.com/api/codex/usage")
    }

    @Test
    func `normalizes chat GPT base URL without backend API`() {
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

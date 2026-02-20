import Foundation

public struct CodexOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
    }

    public var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

public enum CodexOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case decodeFailed(String)
    case missingTokens

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth.json not found. Run `codex` to log in."
        case let .decodeFailed(message):
            "Failed to decode Codex credentials: \(message)"
        case .missingTokens:
            "Codex auth.json exists but contains no tokens."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    public static let accountSelectorEnvKey = "CODEXBAR_CODEX_ACCOUNT_KEY"

    private static var authFilePath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !codexHome.isEmpty
        {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex").appendingPathComponent("auth.json")
    }

    private static var catalogFilePath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !xdgConfigHome.isEmpty
        {
            return URL(fileURLWithPath: xdgConfigHome)
                .appendingPathComponent("secrets")
                .appendingPathComponent("codex-oauth.json")
        }
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("secrets")
            .appendingPathComponent("codex-oauth.json")
    }

    public static func load(accountSelector: String?) throws -> CodexOAuthCredentials {
        if let selector = self.normalizedSelector(accountSelector),
           let selected = try self.loadCatalogCredentials(accountSelector: selector)
        {
            return selected
        }
        return try self.load()
    }

    public static func load() throws -> CodexOAuthCredentials {
        let url = self.authFilePath
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        return try self.parse(data: data)
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return CodexOAuthCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        guard let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String,
              !accessToken.isEmpty
        else {
            throw CodexOAuthCredentialsError.missingTokens
        }

        let idToken = tokens["id_token"] as? String
        let accountId = tokens["account_id"] as? String
        let lastRefresh = Self.parseLastRefresh(from: json["last_refresh"])

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: lastRefresh)
    }

    public static func save(_ credentials: CodexOAuthCredentials) throws {
        let url = self.authFilePath

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken,
        ]
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }

        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func loadCatalogCredentials(accountSelector: String) throws -> CodexOAuthCredentials? {
        let url = self.catalogFilePath
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]]
        else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid codex-oauth catalog JSON")
        }

        for account in accounts {
            if !self.accountMatchesSelector(account, selector: accountSelector) {
                continue
            }
            if let credentials = self.catalogAccountCredentials(account) {
                return credentials
            }
        }
        return nil
    }

    private static func accountMatchesSelector(_ account: [String: Any], selector: String) -> Bool {
        let candidates = [
            account["key"] as? String,
            account["profile"] as? String,
            account["name"] as? String,
        ]
        for candidate in candidates where self.normalizedSelector(candidate) == selector {
            return true
        }
        return false
    }

    private static func catalogAccountCredentials(_ account: [String: Any]) -> CodexOAuthCredentials? {
        guard let accessToken = (account["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let refreshToken = (account["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              !refreshToken.isEmpty
        else {
            return nil
        }

        let idToken = (account["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountId = (account["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastRefresh = Self.parseLastRefresh(from: account["last_refresh"])

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken?.isEmpty == false ? idToken : nil,
            accountId: accountId?.isEmpty == false ? accountId : nil,
            lastRefresh: lastRefresh)
    }

    private static func normalizedSelector(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

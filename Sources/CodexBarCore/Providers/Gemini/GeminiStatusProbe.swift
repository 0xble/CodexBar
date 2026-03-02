import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GeminiModelQuota: Sendable {
    public let modelId: String
    public let percentLeft: Double
    public let resetTime: Date?
    public let resetDescription: String?
}

public struct GeminiStatusSnapshot: Sendable {
    public let modelQuotas: [GeminiModelQuota]
    public let rawText: String
    public let accountEmail: String?
    public let accountPlan: String?

    // Convenience: lowest quota across all models (for icon display)
    public var lowestPercentLeft: Double? {
        self.modelQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.percentLeft
    }

    /// Legacy compatibility
    public var dailyPercentLeft: Double? {
        self.lowestPercentLeft
    }

    public var resetDescription: String? {
        self.modelQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.resetDescription
    }

    /// Converts Gemini quotas to a unified UsageSnapshot.
    /// Groups quotas by tier: Pro (24h window) as primary, Flash (24h window) as secondary.
    public func toUsageSnapshot() -> UsageSnapshot {
        let lower = self.modelQuotas.map { ($0.modelId.lowercased(), $0) }
        let flashQuotas = lower.filter { $0.0.contains("flash") }.map(\.1)
        let proQuotas = lower.filter { $0.0.contains("pro") }.map(\.1)

        let flashMin = flashQuotas.min(by: { $0.percentLeft < $1.percentLeft })
        let proMin = proQuotas.min(by: { $0.percentLeft < $1.percentLeft })

        let primary = RateWindow(
            usedPercent: proMin.map { 100 - $0.percentLeft } ?? 0,
            windowMinutes: 1440,
            resetsAt: proMin?.resetTime,
            resetDescription: proMin?.resetDescription)

        let secondary: RateWindow? = flashMin.map {
            RateWindow(
                usedPercent: 100 - $0.percentLeft,
                windowMinutes: 1440,
                resetsAt: $0.resetTime,
                resetDescription: $0.resetDescription)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.accountPlan)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: identity)
    }
}

public enum GeminiStatusProbeError: LocalizedError, Sendable, Equatable {
    case geminiNotInstalled
    case notLoggedIn
    case unsupportedAuthType(String)
    case parseFailed(String)
    case timedOut
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .geminiNotInstalled:
            "Gemini CLI is not installed or not on PATH."
        case .notLoggedIn:
            "Not logged in to Gemini. Run 'gemini' in Terminal to authenticate."
        case let .unsupportedAuthType(authType):
            "Gemini \(authType) auth not supported. Use Google account (OAuth) instead."
        case let .parseFailed(msg):
            "Could not parse Gemini usage: \(msg)"
        case .timedOut:
            "Gemini quota API request timed out."
        case let .apiError(msg):
            "Gemini API error: \(msg)"
        }
    }
}

public enum GeminiAuthType: String, Sendable {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

/// User tier IDs returned from the Cloud Code Private API (loadCodeAssist).
/// Maps to: google3/cloud/developer_experience/cloudcode/pa/service/usertier.go
public enum GeminiUserTierId: String, Sendable {
    case free = "free-tier"
    case legacy = "legacy-tier"
    case standard = "standard-tier"
}

public struct GeminiStatusProbe: Sendable {
    public var timeout: TimeInterval = 10.0
    public var homeDirectory: String
    public var dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private static let log = CodexBarLog.logger(LogCategories.geminiProbe)
    private static let quotaEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let projectsEndpoint = "https://cloudresourcemanager.googleapis.com/v1/projects"
    private static let legacyCredentialsPath = "/.gemini/oauth_creds.json"
    private static let settingsPath = "/.gemini/settings.json"
    private static let tokenRefreshEndpoint = "https://oauth2.googleapis.com/token"

    public init(
        timeout: TimeInterval = 10.0,
        homeDirectory: String = NSHomeDirectory(),
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        })
    {
        self.timeout = timeout
        self.homeDirectory = homeDirectory
        self.dataLoader = dataLoader
    }

    /// Reads the current Gemini auth type from settings.json
    public static func currentAuthType(homeDirectory: String = NSHomeDirectory()) -> GeminiAuthType {
        let settingsURL = URL(fileURLWithPath: homeDirectory + Self.settingsPath)

        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selectedType = auth["selectedType"] as? String
        else {
            return .unknown
        }

        return GeminiAuthType(rawValue: selectedType) ?? .unknown
    }

    public func fetch() async throws -> GeminiStatusSnapshot {
        // Block explicitly unsupported auth types; allow unknown to try OAuth creds
        let authType = Self.currentAuthType(homeDirectory: self.homeDirectory)
        switch authType {
        case .apiKey:
            throw GeminiStatusProbeError.unsupportedAuthType("API key")
        case .vertexAI:
            throw GeminiStatusProbeError.unsupportedAuthType("Vertex AI")
        case .oauthPersonal, .unknown:
            break
        }

        let snap = try await Self.fetchViaAPI(
            timeout: self.timeout,
            homeDirectory: self.homeDirectory,
            dataLoader: self.dataLoader)

        Self.log.info("Gemini API fetch ok", metadata: [
            "dailyPercentLeft": "\(snap.dailyPercentLeft ?? -1)",
        ])
        return snap
    }

    // MARK: - Direct API approach

    private static func fetchViaAPI(
        timeout: TimeInterval,
        homeDirectory: String,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> GeminiStatusSnapshot
    {
        let creds = try Self.loadCredentials(homeDirectory: homeDirectory)

        let expiryStr = creds.expiryDate.map { "\($0)" } ?? "nil"
        let hasRefresh = creds.refreshToken != nil
        Self.log.debug("Token check", metadata: [
            "expiry": expiryStr,
            "hasRefresh": hasRefresh ? "1" : "0",
            "now": "\(Date())",
        ])

        var accessToken = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var claims = Self.extractClaimsFromToken(creds.idToken)
        let shouldRefresh = accessToken.isEmpty || (creds.expiryDate.map { $0 < Date() } ?? false)
        if shouldRefresh {
            guard let refreshToken = creds.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !refreshToken.isEmpty
            else {
                Self.log.error("No refresh token available")
                throw GeminiStatusProbeError.notLoggedIn
            }

            let refreshed = try await Self.refreshAccessToken(
                refreshToken: refreshToken,
                timeout: timeout,
                homeDirectory: homeDirectory,
                dataLoader: dataLoader)
            accessToken = refreshed.accessToken
            if let refreshedIDToken = refreshed.idToken {
                claims = Self.extractClaimsFromToken(refreshedIDToken)
            }
        }
        if accessToken.isEmpty {
            Self.log.error("No access token available")
            throw GeminiStatusProbeError.notLoggedIn
        }

        // Load Code Assist status to get project ID and tier (aligned with CLI setupUser logic)
        let caStatus = await Self.loadCodeAssistStatus(
            accessToken: accessToken,
            timeout: timeout,
            dataLoader: dataLoader)

        // Determine the project ID to use for quota fetching.
        // Priority:
        // 1. Project ID returned by loadCodeAssist (e.g. managed project for free tier)
        // 2. Discovered project ID from cloud resource manager (e.g. user's own project)
        var projectId = caStatus.projectId
        if projectId == nil {
            projectId = try? await Self.discoverGeminiProjectId(
                accessToken: accessToken,
                timeout: timeout,
                dataLoader: dataLoader)
        }

        guard let url = URL(string: Self.quotaEndpoint) else {
            throw GeminiStatusProbeError.apiError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Include project ID for accurate quota
        if let projectId {
            request.httpBody = Data("{\"project\": \"\(projectId)\"}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }
        request.timeoutInterval = timeout

        let (data, response) = try await dataLoader(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiStatusProbeError.apiError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw GeminiStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw GeminiStatusProbeError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let snapshot = try Self.parseAPIResponse(data, email: claims.email ?? creds.accountEmail)

        // Plan display strings with tier mapping:
        // - standard-tier: Paid subscription (AI Pro, AI Ultra, Code Assist
        //   Standard/Enterprise, Developer Program Premium)
        // - free-tier + hd claim: Workspace account (Gemini included free since Jan 2025)
        // - free-tier: Personal free account (1000 req/day limit)
        // - legacy-tier: Unknown legacy/grandfathered tier
        // - nil (API failed): Leave blank (no display)
        let plan: String? = switch (caStatus.tier, claims.hostedDomain) {
        case (.standard, _):
            "Paid"
        case let (.free, .some(domain)):
            { Self.log.info("Workspace account detected", metadata: ["domain": domain]); return "Workspace" }()
        case (.free, .none):
            { Self.log.info("Personal free account"); return "Free" }()
        case (.legacy, _):
            "Legacy"
        case (.none, _):
            { Self.log.info("Tier detection failed, leaving plan blank"); return nil }()
        }

        return GeminiStatusSnapshot(
            modelQuotas: snapshot.modelQuotas,
            rawText: snapshot.rawText,
            accountEmail: snapshot.accountEmail ?? creds.accountEmail,
            accountPlan: plan)
    }

    private static func discoverGeminiProjectId(
        accessToken: String,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> String?
    {
        guard let url = URL(string: projectsEndpoint) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await dataLoader(request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]]
        else {
            return nil
        }

        // Look for Gemini API project (has "generative-language" label or "gen-lang-client" prefix)
        for project in projects {
            guard let projectId = project["projectId"] as? String else { continue }

            // Check for gen-lang-client prefix (Gemini CLI projects)
            if projectId.hasPrefix("gen-lang-client") {
                return projectId
            }

            // Check for generative-language label
            if let labels = project["labels"] as? [String: String],
               labels["generative-language"] != nil
            {
                return projectId
            }
        }

        return nil
    }

    private struct CodeAssistStatus: Sendable {
        let tier: GeminiUserTierId?
        let projectId: String?

        static let empty = CodeAssistStatus(tier: nil, projectId: nil)
    }

    private static func loadCodeAssistStatus(
        accessToken: String,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async -> CodeAssistStatus
    {
        guard let url = URL(string: loadCodeAssistEndpoint) else {
            self.log.warning("loadCodeAssist: invalid endpoint URL")
            return .empty
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
        } catch {
            Self.log.warning("loadCodeAssist: request failed", metadata: ["error": "\(error)"])
            return .empty
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.log.warning("loadCodeAssist: invalid response type")
            return .empty
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.warning("loadCodeAssist: HTTP error", metadata: [
                "statusCode": "\(httpResponse.statusCode)",
                "body": String(data: data, encoding: .utf8) ?? "<binary>",
            ])
            return .empty
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.log.warning("loadCodeAssist: failed to parse JSON", metadata: [
                "body": String(data: data, encoding: .utf8) ?? "<binary>",
            ])
            return .empty
        }

        let rawProjectId: String? = {
            if let project = json["cloudaicompanionProject"] as? String {
                return project
            }
            if let project = json["cloudaicompanionProject"] as? [String: Any] {
                if let projectId = project["id"] as? String {
                    return projectId
                }
                if let projectId = project["projectId"] as? String {
                    return projectId
                }
            }
            return nil
        }()
        let trimmedProjectId = rawProjectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = trimmedProjectId?.isEmpty == true ? nil : trimmedProjectId
        if let projectId {
            Self.log.info("loadCodeAssist: project detected", metadata: ["projectId": projectId])
        }

        let tierId = (json["currentTier"] as? [String: Any])?["id"] as? String
        guard let tierId else {
            Self.log.warning("loadCodeAssist: no currentTier.id in response", metadata: [
                "json": "\(json)",
            ])
            return CodeAssistStatus(tier: nil, projectId: projectId)
        }

        guard let tier = GeminiUserTierId(rawValue: tierId) else {
            Self.log.warning("loadCodeAssist: unknown tier ID", metadata: ["tierId": tierId])
            return CodeAssistStatus(tier: nil, projectId: projectId)
        }

        Self.log.info("loadCodeAssist: success", metadata: ["tier": tierId, "projectId": projectId ?? "nil"])
        return CodeAssistStatus(tier: tier, projectId: projectId)
    }

    private struct OAuthCredentials {
        let accessToken: String?
        let idToken: String?
        let refreshToken: String?
        let expiryDate: Date?
        let accountEmail: String?
        let credentialsURL: URL
    }

    private struct OAuthClientCredentials {
        let clientId: String
        let clientSecret: String
        let tokenURL: String
    }

    private struct RefreshedOAuthToken {
        let accessToken: String
        let idToken: String?
        let expiryDate: Date?
    }

    private static func resolveAuthDir(homeDirectory: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        if homeDirectory == NSHomeDirectory(),
           let configured = env["AUTH_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            if configured.hasPrefix("/") {
                return URL(fileURLWithPath: configured)
            }
            return URL(fileURLWithPath: homeDirectory).appendingPathComponent(configured)
        }
        return URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config").appendingPathComponent("auth")
    }

    private static func resolveGoogleCredentialsURL(homeDirectory: String) throws -> (URL, String?) {
        let authDir = Self.resolveAuthDir(homeDirectory: homeDirectory)
        let fm = FileManager.default
        let configURL = authDir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defaultAccount = (json["default_account"] as? String)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !defaultAccount.isEmpty
        {
            let url = authDir
                .appendingPathComponent("accounts")
                .appendingPathComponent(defaultAccount)
                .appendingPathComponent("credentials")
                .appendingPathComponent("google.json")
            if fm.fileExists(atPath: url.path) {
                return (url, defaultAccount)
            }
        }

        let legacyURL = URL(fileURLWithPath: homeDirectory + Self.legacyCredentialsPath)
        let accountsDir = authDir.appendingPathComponent("accounts")
        if let entries = try? fm.contentsOfDirectory(
            at: accountsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            for entry in entries {
                let accountPath = entry.appendingPathComponent("account.json")
                guard let data = try? Data(contentsOf: accountPath),
                      let account = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }
                if let enabled = account["enabled"] as? Bool, !enabled {
                    continue
                }
                let providers = account["providers"] as? [String] ?? []
                if !providers.contains("google") {
                    continue
                }

                let accountEmail = (account["email"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? entry.lastPathComponent
                if accountEmail.isEmpty {
                    continue
                }

                let credsURL = entry.appendingPathComponent("credentials").appendingPathComponent("google.json")
                if fm.fileExists(atPath: credsURL.path) {
                    return (credsURL, accountEmail)
                }
            }
        }

        if fm.fileExists(atPath: legacyURL.path) {
            return (legacyURL, nil)
        }

        throw GeminiStatusProbeError.notLoggedIn
    }

    private static func loadOAuthClientCredentials(homeDirectory: String) throws -> OAuthClientCredentials {
        let authDir = Self.resolveAuthDir(homeDirectory: homeDirectory)
        let clientURL = authDir
            .appendingPathComponent("providers")
            .appendingPathComponent("google")
            .appendingPathComponent("clients")
            .appendingPathComponent("default.json")
        if let data = try? Data(contentsOf: clientURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any]
        {
            let source = (payload["installed"] as? [String: Any]) ?? (payload["web"] as? [String: Any]) ?? payload
            if let clientId = source["client_id"] as? String,
               let clientSecret = source["client_secret"] as? String,
               !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let tokenURL = (source["token_uri"] as? String) ?? Self.tokenRefreshEndpoint
                return OAuthClientCredentials(clientId: clientId, clientSecret: clientSecret, tokenURL: tokenURL)
            }
            throw GeminiStatusProbeError.apiError("Google OAuth client is missing client_id/client_secret")
        }

        if let fallback = Self.extractOAuthCredentialsFromGeminiCLI() {
            return fallback
        }

        throw GeminiStatusProbeError.apiError("Google OAuth client config not found")
    }

    private static func extractOAuthCredentialsFromGeminiCLI() -> OAuthClientCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard let geminiPath = BinaryLocator.resolveGeminiBinary(
            env: env,
            loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which("gemini")
        else {
            return nil
        }

        let fm = FileManager.default
        var realPath = geminiPath
        if let resolved = try? fm.destinationOfSymbolicLink(atPath: geminiPath) {
            if resolved.hasPrefix("/") {
                realPath = resolved
            } else {
                realPath = (geminiPath as NSString).deletingLastPathComponent + "/" + resolved
            }
        }

        let binDir = (realPath as NSString).deletingLastPathComponent
        let baseDir = (binDir as NSString).deletingLastPathComponent
        let oauthSubpath =
            "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        let nixShareSubpath = "share/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let possiblePaths = [
            "\(baseDir)/libexec/lib/\(oauthSubpath)",
            "\(baseDir)/lib/\(oauthSubpath)",
            "\(baseDir)/\(nixShareSubpath)",
            "\(baseDir)/../gemini-cli-core/\(oauthFile)",
            "\(baseDir)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in possiblePaths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let parsed = Self.parseOAuthCredentialsFromSource(content)
            {
                return parsed
            }
        }
        return nil
    }

    private static func parseOAuthCredentialsFromSource(_ content: String) -> OAuthClientCredentials? {
        let clientIdPattern = #"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#
        let secretPattern = #"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#
        guard let clientIdRegex = try? NSRegularExpression(pattern: clientIdPattern),
              let secretRegex = try? NSRegularExpression(pattern: secretPattern)
        else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        guard let clientIdMatch = clientIdRegex.firstMatch(in: content, range: range),
              let clientIdRange = Range(clientIdMatch.range(at: 1), in: content),
              let secretMatch = secretRegex.firstMatch(in: content, range: range),
              let secretRange = Range(secretMatch.range(at: 1), in: content)
        else {
            return nil
        }
        let clientId = String(content[clientIdRange])
        let clientSecret = String(content[secretRange])
        return OAuthClientCredentials(
            clientId: clientId,
            clientSecret: clientSecret,
            tokenURL: Self.tokenRefreshEndpoint)
    }

    private static func refreshAccessToken(
        refreshToken: String,
        timeout: TimeInterval,
        homeDirectory: String,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> RefreshedOAuthToken
    {
        let oauthCreds = try Self.loadOAuthClientCredentials(homeDirectory: homeDirectory)
        guard let url = URL(string: oauthCreds.tokenURL) else {
            throw GeminiStatusProbeError.apiError("Invalid token refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: oauthCreds.clientId),
            URLQueryItem(name: "client_secret", value: oauthCreds.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await dataLoader(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiStatusProbeError.apiError("Invalid refresh response")
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.error("Token refresh failed", metadata: [
                "statusCode": "\(httpResponse.statusCode)",
            ])
            throw GeminiStatusProbeError.notLoggedIn
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String
        else {
            throw GeminiStatusProbeError.parseFailed("Could not parse refresh response")
        }

        let idToken = json["id_token"] as? String
        var expiryDate: Date?
        if let expiresIn = json["expires_in"] as? NSNumber {
            expiryDate = Date().addingTimeInterval(expiresIn.doubleValue)
        }
        try Self.updateStoredCredentials(
            accessToken: newAccessToken,
            idToken: idToken,
            expiryDate: expiryDate,
            homeDirectory: homeDirectory)

        Self.log.info("Token refreshed successfully")
        return RefreshedOAuthToken(accessToken: newAccessToken, idToken: idToken, expiryDate: expiryDate)
    }

    private static func updateStoredCredentials(
        accessToken: String,
        idToken: String?,
        expiryDate: Date?,
        homeDirectory: String) throws
    {
        let (credsURL, _) = try Self.resolveGoogleCredentialsURL(homeDirectory: homeDirectory)
        guard let existingCreds = try? Data(contentsOf: credsURL),
              var json = try? JSONSerialization.jsonObject(with: existingCreds) as? [String: Any]
        else {
            return
        }

        json["access_token"] = accessToken
        if let expiryDate {
            json["expiry_date"] = expiryDate.timeIntervalSince1970 * 1000
        }
        if let idToken {
            json["id_token"] = idToken
        }

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try updatedData.write(to: credsURL, options: .atomic)
    }

    private static func loadCredentials(homeDirectory: String) throws -> OAuthCredentials {
        let (credsURL, accountEmail) = try Self.resolveGoogleCredentialsURL(homeDirectory: homeDirectory)

        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw GeminiStatusProbeError.notLoggedIn
        }

        let data = try Data(contentsOf: credsURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiStatusProbeError.parseFailed("Invalid credentials file")
        }

        let accessToken = json["access_token"] as? String
        let idToken = json["id_token"] as? String
        let refreshToken = (json["secret"] as? String) ?? (json["refresh_token"] as? String)

        var expiryDate: Date?
        if let expiryMs = json["expiry_date"] as? NSNumber {
            expiryDate = Date(timeIntervalSince1970: expiryMs.doubleValue / 1000)
        }

        let hasAccess = !(accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRefresh = !(refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasAccess, !hasRefresh {
            throw GeminiStatusProbeError.notLoggedIn
        }

        return OAuthCredentials(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate,
            accountEmail: accountEmail,
            credentialsURL: credsURL)
    }

    private struct TokenClaims {
        let email: String?
        let hostedDomain: String?
    }

    private static func extractClaimsFromToken(_ idToken: String?) -> TokenClaims {
        guard let token = idToken else { return TokenClaims(email: nil, hostedDomain: nil) }

        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return TokenClaims(email: nil, hostedDomain: nil) }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }

        return TokenClaims(
            email: json["email"] as? String,
            hostedDomain: json["hd"] as? String)
    }

    private static func extractEmailFromToken(_ idToken: String?) -> String? {
        self.extractClaimsFromToken(idToken).email
    }

    private struct QuotaBucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
        let tokenType: String?
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private static func parseAPIResponse(_ data: Data, email: String?) throws -> GeminiStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(QuotaResponse.self, from: data)

        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw GeminiStatusProbeError.parseFailed("No quota buckets in response")
        }

        // Group quotas by model, keeping lowest per model (input tokens usually)
        var modelQuotaMap: [String: (fraction: Double, resetString: String?)] = [:]

        for bucket in buckets {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else { continue }

            if let existing = modelQuotaMap[modelId] {
                if fraction < existing.fraction {
                    modelQuotaMap[modelId] = (fraction, bucket.resetTime)
                }
            } else {
                modelQuotaMap[modelId] = (fraction, bucket.resetTime)
            }
        }

        // Convert to sorted array (by model name for consistent ordering)
        let quotas = modelQuotaMap
            .sorted { $0.key < $1.key }
            .map { modelId, info in
                let resetDate = info.resetString.flatMap { Self.parseResetTime($0) }
                return GeminiModelQuota(
                    modelId: modelId,
                    percentLeft: info.fraction * 100,
                    resetTime: resetDate,
                    resetDescription: info.resetString.flatMap { Self.formatResetTime($0) })
            }

        let rawText = String(data: data, encoding: .utf8) ?? ""

        return GeminiStatusSnapshot(
            modelQuotas: quotas,
            rawText: rawText,
            accountEmail: email,
            accountPlan: nil)
    }

    private static func parseResetTime(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private static func formatResetTime(_ isoString: String) -> String {
        guard let resetDate = parseResetTime(isoString) else {
            return "Resets soon"
        }

        let now = Date()
        let interval = resetDate.timeIntervalSince(now)

        if interval <= 0 {
            return "Resets soon"
        }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    // MARK: - Legacy CLI parsing (kept for fallback)

    public static func parse(text: String) throws -> GeminiStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        guard !clean.isEmpty else { throw GeminiStatusProbeError.timedOut }

        let quotas = Self.parseModelUsageTable(clean)

        if quotas.isEmpty {
            if clean.contains("Login with Google") || clean.contains("Use Gemini API key") {
                throw GeminiStatusProbeError.notLoggedIn
            }
            if clean.contains("Waiting for auth"), !clean.contains("Usage") {
                throw GeminiStatusProbeError.notLoggedIn
            }
            throw GeminiStatusProbeError.parseFailed("No usage data found in /stats output")
        }

        return GeminiStatusSnapshot(
            modelQuotas: quotas,
            rawText: text,
            accountEmail: nil,
            accountPlan: nil)
    }

    private static func parseModelUsageTable(_ text: String) -> [GeminiModelQuota] {
        let lines = text.components(separatedBy: .newlines)
        var quotas: [GeminiModelQuota] = []

        let pattern = #"(gemini[-\w.]+)\s+[\d-]+\s+([0-9]+(?:\.[0-9]+)?)\s*%\s*\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        for line in lines {
            let cleanLine = line.replacingOccurrences(of: "│", with: " ")
            let range = NSRange(cleanLine.startIndex..<cleanLine.endIndex, in: cleanLine)
            guard let match = regex.firstMatch(in: cleanLine, options: [], range: range),
                  match.numberOfRanges >= 4 else { continue }

            guard let modelRange = Range(match.range(at: 1), in: cleanLine),
                  let pctRange = Range(match.range(at: 2), in: cleanLine),
                  let pct = Double(cleanLine[pctRange])
            else { continue }

            let modelId = String(cleanLine[modelRange])
            var resetDesc: String?
            if let resetRange = Range(match.range(at: 3), in: cleanLine) {
                resetDesc = String(cleanLine[resetRange]).trimmingCharacters(in: .whitespaces)
            }

            quotas.append(GeminiModelQuota(
                modelId: modelId,
                percentLeft: pct,
                resetTime: nil,
                resetDescription: resetDesc))
        }

        return quotas
    }
}

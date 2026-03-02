import Foundation

struct GeminiTestEnvironment {
    enum GeminiCLILayout {
        case npmNested
        case nixShare
    }

    let homeURL: URL
    private let geminiDir: URL
    private let authDir: URL
    private let defaultGoogleAccount = "user@example.com"

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let geminiDir = root.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let authDir = root.appendingPathComponent(".config").appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        self.homeURL = root
        self.geminiDir = geminiDir
        self.authDir = authDir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.homeURL)
    }

    func writeSettings(authType: String) throws {
        let payload: [String: Any] = [
            "security": [
                "auth": [
                    "selectedType": authType,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: self.geminiDir.appendingPathComponent("settings.json"), options: .atomic)
    }

    func writeCredentials(accessToken: String, refreshToken: String?, expiry: Date, idToken: String?) throws {
        try self.writeAuthConfig(defaultAccount: self.defaultGoogleAccount)
        try self.writeAuthAccount(email: self.defaultGoogleAccount)
        try self.writeGoogleOAuthClient()

        var payload: [String: Any] = [
            "version": 1,
            "provider": "google",
            "account_id": self.defaultGoogleAccount,
            "type": "oauth_refresh_token",
            "access_token": accessToken,
            "expiry_date": expiry.timeIntervalSince1970 * 1000,
            "updated_at": "2026-03-01T00:00:00Z",
        ]
        if let refreshToken {
            payload["secret"] = refreshToken
        }
        if let idToken {
            payload["id_token"] = idToken
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let credsURL = self.authDir
            .appendingPathComponent("accounts")
            .appendingPathComponent(self.defaultGoogleAccount)
            .appendingPathComponent("credentials")
            .appendingPathComponent("google.json")
        try data.write(to: credsURL, options: .atomic)
    }

    func writeLegacyCredentials(accessToken: String, refreshToken: String?, expiry: Date, idToken: String?) throws {
        var payload: [String: Any] = [
            "access_token": accessToken,
            "expiry_date": expiry.timeIntervalSince1970 * 1000,
        ]
        if let refreshToken {
            payload["refresh_token"] = refreshToken
        }
        if let idToken {
            payload["id_token"] = idToken
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: self.geminiDir.appendingPathComponent("oauth_creds.json"), options: .atomic)
    }

    func readCredentials() throws -> [String: Any] {
        let url = self.authDir
            .appendingPathComponent("accounts")
            .appendingPathComponent(self.defaultGoogleAccount)
            .appendingPathComponent("credentials")
            .appendingPathComponent("google.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    func removeGoogleOAuthClient() {
        let clientURL = self.authDir
            .appendingPathComponent("providers")
            .appendingPathComponent("google")
            .appendingPathComponent("clients")
            .appendingPathComponent("default.json")
        try? FileManager.default.removeItem(at: clientURL)
    }

    func removeAuthStore() {
        try? FileManager.default.removeItem(at: self.authDir)
    }

    func writeFakeGeminiCLI(includeOAuth: Bool = true, layout: GeminiCLILayout = .npmNested) throws -> URL {
        let base = self.homeURL.appendingPathComponent("gemini-cli")
        let binDir = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let oauthPath: URL = switch layout {
        case .npmNested:
            base
                .appendingPathComponent("lib")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli-core")
                .appendingPathComponent("dist")
                .appendingPathComponent("src")
                .appendingPathComponent("code_assist")
                .appendingPathComponent("oauth2.js")
        case .nixShare:
            base
                .appendingPathComponent("share")
                .appendingPathComponent("gemini-cli")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli-core")
                .appendingPathComponent("dist")
                .appendingPathComponent("src")
                .appendingPathComponent("code_assist")
                .appendingPathComponent("oauth2.js")
        }

        if includeOAuth {
            try FileManager.default.createDirectory(
                at: oauthPath.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            let oauthContent = """
            const OAUTH_CLIENT_ID = 'test-client-id';
            const OAUTH_CLIENT_SECRET = 'test-client-secret';
            """
            try oauthContent.write(to: oauthPath, atomically: true, encoding: .utf8)
        }

        let geminiBinary = binDir.appendingPathComponent("gemini")
        try "#!/bin/bash\nexit 0\n".write(to: geminiBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: geminiBinary.path)
        return geminiBinary
    }

    private func writeAuthConfig(defaultAccount: String) throws {
        let payload: [String: Any] = [
            "version": 1,
            "default_account": defaultAccount,
            "updated_at": "2026-03-01T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: self.authDir.appendingPathComponent("config.json"), options: .atomic)
    }

    private func writeAuthAccount(email: String) throws {
        let accountDir = self.authDir.appendingPathComponent("accounts").appendingPathComponent(email)
        try FileManager.default.createDirectory(
            at: accountDir.appendingPathComponent("credentials"),
            withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "version": 1,
            "account_id": email,
            "email": email,
            "display_name": email,
            "enabled": true,
            "providers": ["google"],
            "updated_at": "2026-03-01T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: accountDir.appendingPathComponent("account.json"), options: .atomic)
    }

    private func writeGoogleOAuthClient() throws {
        let clientDir = self.authDir
            .appendingPathComponent("providers")
            .appendingPathComponent("google")
            .appendingPathComponent("clients")
        try FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "version": 1,
            "provider": "google",
            "client": "default",
            "payload": [
                "installed": [
                    "client_id": "test-client-id",
                    "client_secret": "test-client-secret",
                    "token_uri": "https://oauth2.googleapis.com/token",
                ],
            ],
            "updated_at": "2026-03-01T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: clientDir.appendingPathComponent("default.json"), options: .atomic)
    }
}

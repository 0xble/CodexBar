import AppKit
import CodexBarCore
import Foundation

enum GeminiLoginRunner {
    private static let authDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("auth")
    private static let authConfigFile = "config.json"
    private static let legacyGeminiCredsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini")
        .appendingPathComponent("oauth_creds.json")

    private static func defaultGoogleCredentialsPath() -> String? {
        let configURL = self.authDir.appendingPathComponent(self.authConfigFile)
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defaultAccount = (json["default_account"] as? String)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !defaultAccount.isEmpty
        {
            return self.authDir
                .appendingPathComponent("accounts")
                .appendingPathComponent(defaultAccount)
                .appendingPathComponent("credentials")
                .appendingPathComponent("google.json")
                .path
        }

        return self.legacyGeminiCredsPath.path
    }

    struct Result {
        enum Outcome {
            case success
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
    }

    static func run(onCredentialsCreated: (@Sendable () -> Void)? = nil) async -> Result {
        await Task(priority: .userInitiated) {
            let env = ProcessInfo.processInfo.environment
            guard let binary = BinaryLocator.resolveGeminiBinary(
                env: env,
                loginPATH: LoginShellPathCache.shared.current)
            else {
                return Result(outcome: .missingBinary)
            }

            let watchedCredentialsPath = Self.defaultGoogleCredentialsPath()

            // Start watching for auth-store credentials to be created or updated.
            if let callback = onCredentialsCreated {
                Self.watchForCredentials(path: watchedCredentialsPath, callback: callback)
            }

            // Create a temporary shell script that runs gemini (auto-prompts for auth when no creds)
            let scriptContent = """
            #!/bin/bash
            cd ~
            "\(binary)"
            """

            let tempDir = FileManager.default.temporaryDirectory
            let scriptURL = tempDir.appendingPathComponent("gemini_login_\(UUID().uuidString).command")

            do {
                try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                try await NSWorkspace.shared.open(scriptURL, configuration: config)

                // Clean up script after Terminal has time to read it
                let scriptPath = scriptURL.path
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    try? FileManager.default.removeItem(atPath: scriptPath)
                }

                return Result(outcome: .success)
            } catch {
                return Result(outcome: .launchFailed(error.localizedDescription))
            }
        }.value
    }

    /// Watch for auth-store credentials to be created or updated, then call callback once.
    private static func watchForCredentials(
        path: String?,
        callback: @escaping @Sendable () -> Void,
        timeout: TimeInterval = 300)
    {
        guard let credsPath = path, !credsPath.isEmpty else { return }
        let initialModifiedAt = (try? FileManager.default
            .attributesOfItem(atPath: credsPath)[.modificationDate]) as? Date

        DispatchQueue.global(qos: .utility).async {
            let startTime = Date()
            while Date().timeIntervalSince(startTime) < timeout {
                if let modifiedAt =
                    (try? FileManager.default.attributesOfItem(atPath: credsPath)[.modificationDate]) as? Date
                {
                    if let initialModifiedAt {
                        if modifiedAt > initialModifiedAt {
                            Thread.sleep(forTimeInterval: 0.5)
                            callback()
                            return
                        }
                    } else {
                        Thread.sleep(forTimeInterval: 0.5)
                        callback()
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }
}

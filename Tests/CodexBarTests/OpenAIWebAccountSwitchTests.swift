import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct OpenAIWebAccountSwitchTests {
    @Test
    func clearsDashboardWhenCodexEmailChanges() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-clears"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "a@example.com")
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "a@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "b@example.com")
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.openAIDashboardCookieImportStatus?.contains("Codex account changed") == true)
    }

    @Test
    func keepsDashboardWhenCodexEmailStaysSame() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-keeps"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "a@example.com")
        let dash = OpenAIDashboardSnapshot(
            signedInEmail: "a@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.openAIDashboard = dash

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "a@example.com")
        #expect(store.openAIDashboard == dash)
    }

    @Test
    func codexDashboardTargetPrefersSelectedTokenAccountEmail() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-selected-email"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.addTokenAccount(provider: .codex, label: "first@example.com", token: "profile-first")
        settings.addTokenAccount(provider: .codex, label: "second@example.com", token: "profile-second")
        settings.setActiveTokenAccountIndex(1, for: .codex)

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "snapshot@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")),
            provider: .codex)

        #expect(store.codexAccountEmailForOpenAIDashboard() == "second@example.com")
    }

    @Test
    func codexDashboardTargetIgnoresNonEmailTokenAccountLabel() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-non-email-label"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.addTokenAccount(provider: .codex, label: "Work profile", token: "profile-work")
        settings.setActiveTokenAccountIndex(0, for: .codex)

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "snapshot@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")),
            provider: .codex)

        #expect(store.codexAccountEmailForOpenAIDashboard() == "snapshot@example.com")
    }

    @Test
    func codexCLICreditsRequireMatchingSelectedAccountEmail() {
        #expect(UsageStore.shouldUseCodexCLICredits(
            selectedEmail: "alpha@example.com",
            cliEmail: "alpha@example.com"))
        #expect(UsageStore.shouldUseCodexCLICredits(
            selectedEmail: "Alpha@Example.com",
            cliEmail: "alpha@example.com"))
        #expect(!UsageStore.shouldUseCodexCLICredits(
            selectedEmail: "alpha@example.com",
            cliEmail: "beta@example.com"))
        #expect(UsageStore.shouldUseCodexCLICredits(
            selectedEmail: nil,
            cliEmail: "beta@example.com"))
        #expect(UsageStore.shouldUseCodexCLICredits(
            selectedEmail: "alpha@example.com",
            cliEmail: nil))
    }
}

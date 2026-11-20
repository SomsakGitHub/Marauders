#if DEBUG
    import Testing

    @testable import Marauders

    /// The test-user sign-in sends a secret that only the Worker the Debug builds are configured for knows (production
    /// while there is one backend, ADR 010). It is offered while the app talks to the host the build configured, and
    /// withheld when an override points the run somewhere else: an override can name any host, and a host the secret
    /// was not meant for must never receive it.
    @MainActor
    struct DevLoginTests {
        @Test func aSecretIsOfferedAgainstTheConfiguredHost() {
            #expect(DevLogin.offeredSecret("s", source: .configured) == "s")
        }

        @Test func noSecretIsOfferedAgainstAnOverride() {
            #expect(DevLogin.offeredSecret("s", source: .override) == nil)
        }

        @Test func noSecretWithoutOne() {
            #expect(DevLogin.offeredSecret(nil, source: .configured) == nil)
            #expect(DevLogin.offeredSecret("", source: .configured) == nil)
        }
    }
#endif

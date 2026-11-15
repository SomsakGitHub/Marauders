//
//  TokenRefresher.swift
//  Marauders
//

import Foundation

/// Trades the stored refresh token for a new access token when the Worker answers a request with 401.
///
/// Every request that meets the same 401, or the 401 of another token of the same account, waits for one call: the
/// first starts it, the others wait for its answer. A request of anyone else waits for that call to end and is then
/// looked at on its own, because the answer is not about its session. The refresh token is single use and the Worker
/// revokes the whole family of a token that is spent twice, so two calls in a row would end the session they were meant
/// to keep. A request that meets the rejection after the call has finished finds the new token already stored and takes
/// that.
///
/// The stored tokens belong to the viewer, who can sign out or sign in as someone else while the Worker is answering.
/// Every look at them and every write happens in one hop to the main actor, where the sign-in and sign-out code runs
/// its own store calls, so nothing can change them between the look and the write. A refresh whose session is no longer
/// the stored one writes nothing.
///
/// When the Worker gives no verdict (it cannot be reached, is down, is rate limiting, or answers with something that is
/// not a refresh), that answer stands for ten seconds for the refresh token it was asked with: a request that meets a
/// rejection in that time gets it without another call. Otherwise a Worker that cannot answer would be asked once for
/// every request on screen, each of them slower for it, and the calls would spend the sign-in rate limit that everyone
/// behind the same address shares.
///
/// It never clears a store and never signs anyone out: it reports what happened and the caller decides.
actor TokenRefresher: TokenRefreshing {
    private let accessTokenStore: any APIAccessTokenStore
    private let refreshTokenStore: any APIRefreshTokenStore
    private let authAPI: any AuthAPIClientProtocol
    private let retryDelay: Duration
    private let unavailableCooldown: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var inFlight: Flight?
    private var cooldown: Cooldown?

    /// - Parameters:
    ///   - retryDelay: How long to wait before asking again after a failure to reach the Worker.
    ///   - unavailableCooldown: How long the Worker is left alone after an answer that is not a verdict.
    ///   - now: The time, which a test sets.
    init(
        accessTokenStore: any APIAccessTokenStore,
        refreshTokenStore: any APIRefreshTokenStore,
        authAPI: any AuthAPIClientProtocol,
        retryDelay: Duration = .seconds(1),
        unavailableCooldown: Duration = .seconds(10),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.accessTokenStore = accessTokenStore
        self.refreshTokenStore = refreshTokenStore
        self.authAPI = authAPI
        self.retryDelay = retryDelay
        self.unavailableCooldown = unavailableCooldown
        self.now = now
    }

    func refreshedAccessToken(replacing rejectedAccessToken: String) async -> TokenRefreshOutcome {
        while let flight = inFlight {
            let outcome = await flight.task.value
            if flight.answers(for: rejectedAccessToken) { return outcome }
            // The call was for someone else's session, and its answer says nothing about this caller's. It is over now:
            // look at the stored session for this caller's own token, as a caller who met no call in flight does.
        }
        // Unstructured on purpose: a caller that is cancelled must not cancel the call for everyone else. It does not
        // stop waiting for it either, and gets the answer like the rest. The task ends the flight itself, in the same
        // turn on the actor as its last step, so no caller can join a call that has already finished and be handed a
        // token it has just seen rejected.
        let task = Task {
            let outcome = await self.refresh(replacing: rejectedAccessToken)
            self.inFlight = nil
            return outcome
        }
        inFlight = Flight(task: task, rejectedAccessToken: rejectedAccessToken)
        return await task.value
    }

    private func refresh(replacing rejected: String) async -> TokenRefreshOutcome {
        let stored = await storedTokens()
        guard let storedAccessToken = stored.accessToken else { return await rejectedOutcome() }

        if storedAccessToken != rejected {
            // Another request has already traded for a new token. It is handed out only when it is the same account's:
            // what is stored may belong to whoever signed in since, and a token that cannot be read proves nothing.
            guard let wanted = APIAccessTokenSubject.subject(of: rejected),
                let current = APIAccessTokenSubject.subject(of: storedAccessToken),
                wanted == current
            else { return await rejectedOutcome() }
            return .refreshed(storedAccessToken)
        }

        guard let refreshToken = stored.refreshToken, APIRefreshTokenFormat.isValid(refreshToken) else {
            return await rejectedOutcome()
        }
        // The Worker could not answer a moment ago for this session. It is left alone, and a request that meets the
        // rejection in the meantime gets the same answer without a call.
        if let cooldown, cooldown.refreshToken == refreshToken, now() < cooldown.until {
            return .unavailable(cooldown.error)
        }

        let tokens: AuthTokens
        do {
            tokens = try await exchange(refreshToken)
        } catch AuthAPIError.refreshRejected {
            return await rejectedOutcome()
        } catch {
            return await unavailableOutcome(error, for: refreshToken)
        }
        // Every answer to a refresh carries the next refresh token; one without it cannot keep the session going.
        guard let newRefreshToken = tokens.refreshToken, APIRefreshTokenFormat.isValid(newRefreshToken) else {
            return await unavailableOutcome(AuthAPIError.invalidResponse, for: refreshToken)
        }

        switch await save(accessToken: tokens.accessToken, refreshToken: newRefreshToken, replacing: refreshToken) {
        case .saved:
            await AppLog.info("api.refresh", "refreshed")
            return .refreshed(tokens.accessToken)
        case .sessionChanged:
            return await rejectedOutcome()
        case .failed(let error):
            return await unavailableOutcome(error, for: refreshToken)
        }
    }

    /// One call to the Worker, asked again once when it could not be reached or the Worker was only passing through. The
    /// Worker may have spent the token and lost the answer on the way: it takes the same token a second time within a
    /// minute and answers with a new pair, so asking again with it is safe. A refusal, a 429 and any other answer are
    /// final: asking again would not change them.
    private func exchange(_ refreshToken: String) async throws -> AuthTokens {
        do {
            return try await authAPI.refreshTokens(using: refreshToken)
        } catch {
            guard Self.isWorthAskingAgain(error) else { throw error }
            try? await Task.sleep(for: retryDelay)
            return try await authAPI.refreshTokens(using: refreshToken)
        }
    }

    private nonisolated static func isWorthAskingAgain(_ error: any Error) -> Bool {
        if error is URLError || error is HTTPClientError { return true }
        if case .serverError(let status)? = error as? AuthAPIError { return [502, 503, 504].contains(status) }
        return false
    }

    // MARK: - the call in flight

    /// The one call to the Worker that is running, and the token whose rejection started it.
    private nonisolated struct Flight: Sendable {
        let task: Task<TokenRefreshOutcome, Never>
        let rejectedAccessToken: String

        /// Whether the call's answer is also the answer for a caller who met the rejection of `callerToken`: the same
        /// rejection, or another token of the same account. The answer says nothing about anyone else's session, and a
        /// token that names no account cannot be told apart from someone else's.
        func answers(for callerToken: String) -> Bool {
            if callerToken == rejectedAccessToken { return true }
            guard let caller = APIAccessTokenSubject.subject(of: callerToken),
                let started = APIAccessTokenSubject.subject(of: rejectedAccessToken)
            else { return false }
            return caller == started
        }
    }

    /// Why the Worker is not asked for a while: it could not answer for this refresh token, and the answer it gave
    /// stands until `until`.
    private nonisolated struct Cooldown: Sendable {
        let refreshToken: String
        let until: ContinuousClock.Instant
        let error: any Error
    }

    // MARK: - the stored session

    private nonisolated struct StoredTokens: Sendable {
        let accessToken: String?
        let refreshToken: String?
    }

    private nonisolated enum SaveResult: Sendable {
        case saved
        /// The refresh token that was spent is no longer the stored one: the viewer signed out, or signed in again.
        case sessionChanged
        case failed(any Error)
    }

    private func storedTokens() async -> StoredTokens {
        let accessTokenStore = accessTokenStore
        let refreshTokenStore = refreshTokenStore
        return await MainActor.run {
            StoredTokens(
                accessToken: accessTokenStore.loadAccessToken(), refreshToken: refreshTokenStore.loadRefreshToken())
        }
    }

    /// Keeps the new pair, unless the session it is for is gone. The refresh token goes first: the one that was spent
    /// is useless now, so the new one is the one thing that must not be lost. An access token that fails to save after
    /// it leaves a stale access token beside a good refresh token, which the next 401 trades again.
    private func save(
        accessToken newAccessToken: String, refreshToken newRefreshToken: String, replacing spent: String
    ) async -> SaveResult {
        let accessTokenStore = accessTokenStore
        let refreshTokenStore = refreshTokenStore
        return await MainActor.run {
            guard refreshTokenStore.loadRefreshToken() == spent else { return SaveResult.sessionChanged }
            do {
                try refreshTokenStore.saveRefreshToken(newRefreshToken)
                try accessTokenStore.saveAccessToken(newAccessToken)
                return SaveResult.saved
            } catch {
                return SaveResult.failed(error)
            }
        }
    }

    // MARK: - the log (never a token)

    private func rejectedOutcome() async -> TokenRefreshOutcome {
        await AppLog.warning("api.refresh", "rejected")
        return .rejected
    }

    /// The answer when the Worker could not give a verdict for `refreshToken`. It starts the cooldown for that token: a
    /// session that has since been refreshed or replaced holds another token, which the cooldown does not cover.
    private func unavailableOutcome(_ error: any Error, for refreshToken: String) async -> TokenRefreshOutcome {
        cooldown = Cooldown(refreshToken: refreshToken, until: now().advanced(by: unavailableCooldown), error: error)
        await AppLog.warning("api.refresh", "unavailable (\(type(of: error)))")
        return .unavailable(error)
    }
}

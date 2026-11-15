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
/// It never clears a store and never signs anyone out: it reports what happened and the caller decides.
actor TokenRefresher: TokenRefreshing {
    private let accessTokenStore: any APIAccessTokenStore
    private let refreshTokenStore: any APIRefreshTokenStore
    private let authAPI: any AuthAPIClientProtocol
    private let retryDelay: Duration
    private var inFlight: Flight?

    /// - Parameter retryDelay: How long to wait before asking again after a failure to reach the Worker.
    init(
        accessTokenStore: any APIAccessTokenStore,
        refreshTokenStore: any APIRefreshTokenStore,
        authAPI: any AuthAPIClientProtocol,
        retryDelay: Duration = .seconds(1)
    ) {
        self.accessTokenStore = accessTokenStore
        self.refreshTokenStore = refreshTokenStore
        self.authAPI = authAPI
        self.retryDelay = retryDelay
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

        let tokens: AuthTokens
        do {
            tokens = try await exchange(refreshToken)
        } catch AuthAPIError.refreshRejected {
            return await rejectedOutcome()
        } catch {
            return await unavailableOutcome(error)
        }
        // Every answer to a refresh carries the next refresh token; one without it cannot keep the session going.
        guard let newRefreshToken = tokens.refreshToken, APIRefreshTokenFormat.isValid(newRefreshToken) else {
            return await unavailableOutcome(AuthAPIError.invalidResponse)
        }

        switch await save(accessToken: tokens.accessToken, refreshToken: newRefreshToken, replacing: refreshToken) {
        case .saved:
            await AppLog.info("api.refresh", "refreshed")
            return .refreshed(tokens.accessToken)
        case .sessionChanged:
            return await rejectedOutcome()
        case .failed(let error):
            return await unavailableOutcome(error)
        }
    }

    /// One call to the Worker, asked again once when it could not be reached or the Worker was only passing through. The
    /// Worker may have spent the token and lost the answer on the way: it takes the same token a second time within a
    /// minute and answers with a new pair, so asking again with it is safe. A refusal, a 429 and any other answer are
    /// final: asking again would not change them.
    private func exchange(_ refreshToken: String) async throws -> AuthTokens {
        do {
            return try await authAPI.refreshTokens(using: refreshToken)
        } catch where Self.isWorthAskingAgain(error) {
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

    private func unavailableOutcome(_ error: any Error) async -> TokenRefreshOutcome {
        await AppLog.warning("api.refresh", "unavailable (\(type(of: error)))")
        return .unavailable(error)
    }
}

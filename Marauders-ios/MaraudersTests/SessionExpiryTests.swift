//
//  SessionExpiryTests.swift
//  MaraudersTests
//

import AuthenticationServices
import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth

// MARK: - restoring a saved session

/// `AuthViewModel.restoreSession()` runs whenever a tab appears, so a token that has run out ends the session there.
@MainActor
struct SessionRestoreExpiryTests {
    private static let userID = "001234.abcdef.5678"
    /// The shape of a real refresh token: 43 base64url characters.
    private static let refreshToken = String(repeating: "Ab-_0", count: 8) + "xyz"
    private static let nextRefreshToken = String(repeating: "Zy_-9", count: 8) + "abc"

    private func makeViewModel(
        _ storage: MemorySessionStorage, apple: AppleAnswers, authAPI: any AuthAPIClientProtocol = UnusedAuthAPI()
    ) -> AuthViewModel {
        AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            refreshTokenStore: storage,
            authAPI: authAPI,
            credentialState: apple.provider
        )
    }

    @Test func anExpiredTokenEndsTheSessionWithoutAskingApple() async {
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: -60))
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(!viewModel.isCheckingCredential)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
        #expect(apple.askedUserIDs.isEmpty)
    }

    @Test func aTokenThatIsStillValidKeepsTheViewerSignedIn() async {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: token)
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)

        await viewModel.restoreSession()

        #expect(viewModel.isSignedIn)
        #expect(!viewModel.isCheckingCredential)
        #expect(storage.userID == Self.userID)
        #expect(storage.accessToken == token)
        #expect(apple.askedUserIDs == [Self.userID])
    }

    /// A tab that appears after the token ran out finds the viewer signed in; the check there signs them out.
    @Test func aSessionThatExpiresWhileTheAppIsOpenEndsAtTheNextRestore() async throws {
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: 3_600))
        let viewModel = makeViewModel(storage, apple: AppleAnswers(.authorized))
        await viewModel.restoreSession()
        try #require(viewModel.isSignedIn)

        storage.accessToken = TestAccessToken.make(expiresIn: -1)
        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
    }

    @Test(arguments: [
        // Not a JWT at all.
        String(repeating: "x", count: 40),
        "only.two-parts-of-a-token",
        "header.!!!-not-base64-!!!.signature",
        "header.bm90LWpzb24.signature",
        // A JWT with no readable `exp`.
        TestAccessToken.make(claims: ["sub": "user-1", "iat": 1_797_408_000]),
        TestAccessToken.make(claims: ["sub": "user-1", "exp": "1900000000"]),
        TestAccessToken.make(claims: ["sub": "user-1", "exp": true]),
        TestAccessToken.make(payload: Data("[]".utf8)),
    ])
    func aTokenWhoseExpCannotBeReadEndsTheSession(token: String) async {
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: token)
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
        #expect(apple.askedUserIDs.isEmpty)
    }

    @Test func aMissingTokenEndsTheSession() async {
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: nil)
        let viewModel = makeViewModel(storage, apple: AppleAnswers(.authorized))

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
    }

    @Test func aMissingUserIDEndsTheSession() async {
        let storage = MemorySessionStorage(userID: nil, accessToken: TestAccessToken.make(expiresIn: 3_600))
        let viewModel = makeViewModel(storage, apple: AppleAnswers(.authorized))

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.accessToken == nil)
    }

    // MARK: a refresh token keeps the session of an access token that has run out

    /// The first request that meets the 401 trades the refresh token for a new access token; opening the app asks the
    /// Worker nothing.
    @Test func anExpiredAccessTokenWithARefreshTokenKeepsTheSession() async {
        let expired = TestAccessToken.make(expiresIn: -60)
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: expired, refreshToken: Self.refreshToken)
        let apple = AppleAnswers(.authorized)
        let authAPI = CountingAuthAPI()
        let viewModel = makeViewModel(storage, apple: apple, authAPI: authAPI)

        await viewModel.restoreSession()

        #expect(viewModel.isSignedIn)
        #expect(!viewModel.isCheckingCredential)
        #expect(storage.userID == Self.userID)
        #expect(storage.accessToken == expired)
        #expect(storage.refreshToken == Self.refreshToken)
        #expect(apple.askedUserIDs == [Self.userID])
        #expect(authAPI.callCount == 0, "no refresh at launch")
    }

    @Test func anExpiredAccessTokenWithoutARefreshTokenStillEndsTheSession() async {
        let storage = MemorySessionStorage(
            userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: -60), refreshToken: nil)
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
        #expect(apple.askedUserIDs.isEmpty)
    }

    @Test func anExpiredAccessTokenWithAMalformedRefreshTokenEndsTheSession() async {
        let storage = MemorySessionStorage(
            userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: -60), refreshToken: "short")
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
        #expect(storage.refreshToken == nil, "the unusable token goes with the session")
        #expect(apple.askedUserIDs.isEmpty)
    }

    /// A refresh renews the session that is stored; it is not a sign out or a new sign in, so Apple's answer still
    /// belongs to it and the viewer stays signed in.
    @Test func aRefreshWhileAppleIsAnsweringKeepsTheSession() async {
        let old = TestAccessToken.make(subject: "same-user", expiresIn: 60)
        let new = TestAccessToken.make(subject: "same-user", expiresIn: 3_600)
        let next = Self.nextRefreshToken
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: old, refreshToken: Self.refreshToken)
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)
        apple.whileAnswering = {
            // What the refresher does: a new pair for the session that is stored.
            storage.accessToken = new
            storage.refreshToken = next
        }

        await viewModel.restoreSession()

        #expect(viewModel.isSignedIn)
        #expect(!viewModel.isCheckingCredential)
        #expect(storage.userID == Self.userID)
        #expect(storage.accessToken == new)
        #expect(storage.refreshToken == next)
    }

    @Test(arguments: [ASAuthorizationAppleIDProvider.CredentialState.revoked, .notFound])
    func appleRevokingTheAccountEndsTheSession(state: ASAuthorizationAppleIDProvider.CredentialState) async {
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: TestAccessToken.make(expiresIn: 3_600))
        let viewModel = makeViewModel(storage, apple: AppleAnswers(state))

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
    }

    /// Apple's answer takes a moment. If the Worker rejects the token meanwhile, "authorized" is about a session
    /// that is gone and must not make the viewer look signed in again.
    @Test func aRejectionWhileAppleIsAnsweringIsNotUndone() async {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: token)
        let apple = AppleAnswers(.authorized)
        let viewModel = makeViewModel(storage, apple: apple)
        apple.whileAnswering = {
            await MainActor.run { viewModel.handleRejectedAccessToken(token) }
        }

        await viewModel.restoreSession()

        #expect(!viewModel.isSignedIn)
        #expect(!viewModel.isCheckingCredential)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
    }

    @Test func aNewSignInWhileAppleIsAnsweringIsNotUndone() async {
        let old = TestAccessToken.make(subject: "old", expiresIn: 3_600)
        let new = TestAccessToken.make(subject: "new", expiresIn: 3_600)
        let userID = Self.userID
        let storage = MemorySessionStorage(userID: userID, accessToken: old)
        let apple = AppleAnswers(.revoked)
        let signIn = SignInAuthAPI(tokens: AuthTokens(accessToken: new, refreshToken: nil))
        let viewModel = makeViewModel(storage, apple: apple, authAPI: signIn)
        apple.whileAnswering = {
            // The viewer signs in again; the answer about the old account must not wipe the new session.
            await viewModel.completeSignIn(userID: userID, identityToken: String(repeating: "i", count: 32))
        }

        await viewModel.restoreSession()

        #expect(storage.accessToken == new)
        #expect(storage.userID == Self.userID)
    }
}

// MARK: - a 401 to a request that carried the token

@MainActor
struct RejectedAccessTokenTests {
    private static let userID = "001234.abcdef.5678"

    private func signedIn(token: String = TestAccessToken.make(expiresIn: 3_600)) async -> (
        AuthViewModel, MemorySessionStorage
    ) {
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: token)
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            refreshTokenStore: storage,
            authAPI: UnusedAuthAPI(),
            credentialState: { _ in .authorized }
        )
        await viewModel.restoreSession()
        return (viewModel, storage)
    }

    @Test func aRejectedStoredTokenSignsTheViewerOut() async throws {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let (viewModel, storage) = await signedIn(token: token)
        try #require(viewModel.isSignedIn)

        viewModel.handleRejectedAccessToken(token)

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
    }

    @Test func aRejectedTokenThatIsNoLongerStoredChangesNothing() async throws {
        let current = TestAccessToken.make(subject: "current", expiresIn: 3_600)
        let (viewModel, storage) = await signedIn(token: current)
        try #require(viewModel.isSignedIn)

        // The late answer to a request sent before the viewer signed in again.
        viewModel.handleRejectedAccessToken(TestAccessToken.make(subject: "earlier", expiresIn: 60))

        #expect(viewModel.isSignedIn)
        #expect(storage.userID == Self.userID)
        #expect(storage.accessToken == current)
    }

    /// Two requests that carried the same token are both answered 401; the viewer signs in again in between.
    @Test func theSecondRejectionOfAnEndedSessionDoesNotEndTheNewOne() async throws {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let (viewModel, storage) = await signedIn(token: token)

        viewModel.handleRejectedAccessToken(token)
        try #require(!viewModel.isSignedIn)
        let newToken = TestAccessToken.make(subject: "again", expiresIn: 3_600)
        storage.userID = Self.userID
        storage.accessToken = newToken
        await viewModel.restoreSession()
        try #require(viewModel.isSignedIn)
        viewModel.handleRejectedAccessToken(token)

        #expect(viewModel.isSignedIn)
        #expect(storage.accessToken == newToken)
    }

    @Test func aRejectionWhileSignedOutChangesNothing() {
        let storage = MemorySessionStorage()
        let viewModel = AuthViewModel(
            sessionStore: storage, tokenStore: storage, refreshTokenStore: storage, authAPI: UnusedAuthAPI())

        viewModel.handleRejectedAccessToken(TestAccessToken.make(expiresIn: 3_600))

        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
    }
}

// MARK: - through the real clients

/// The real API clients over the real decorator and a stubbed network: the Worker's 401 ends the session, and each
/// client still reports it in its own words.
@Suite(.serialized)
@MainActor
struct RejectedSessionEndToEndTests {
    private static let userID = "001234.abcdef.5678"
    private static let videoID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let commentsPage = """
        {"items":[{"id":"11111111-2222-4333-8444-555555555555","body":"Nice view","language":null,\
        "createdAt":"2026-10-30T12:34:56.789Z","authorName":"@friend","authorAvatarURL":null,"canDelete":false}],\
        "nextCursor":null}
        """

    private struct Harness {
        let viewModel: AuthViewModel
        let storage: MemorySessionStorage
        let token: String
        let authorization: SessionAPIAuthorization
    }

    private func signedInHarness() async -> Harness {
        let token = TestAccessToken.make(expiresIn: 3_600)
        let storage = MemorySessionStorage(userID: Self.userID, accessToken: token)
        let viewModel = AuthViewModel(
            sessionStore: storage,
            tokenStore: storage,
            refreshTokenStore: storage,
            authAPI: UnusedAuthAPI(),
            credentialState: { _ in .authorized }
        )
        await viewModel.restoreSession()
        return Harness(
            viewModel: viewModel,
            storage: storage,
            token: token,
            authorization: SessionAPIAuthorization(tokenStore: storage)
        )
    }

    private func transport(_ session: URLSession, reportingTo viewModel: AuthViewModel)
        -> RejectedSessionReportingHTTPClient
    {
        RejectedSessionReportingHTTPClient(base: URLSessionHTTPClient(session: session)) { accessToken in
            await viewModel.handleRejectedAccessToken(accessToken)
        }
    }

    private func expectSignedOut(_ harness: Harness) {
        #expect(!harness.viewModel.isSignedIn)
        #expect(harness.storage.userID == nil)
        #expect(harness.storage.accessToken == nil)
    }

    @Test func theProfileKeepsItsServerErrorAndTheSessionEnds() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        var sentAuthorization: String?
        let session = StubURLSessionFactory.make { request in
            sentAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return respond(request, 401, #"{"error":"invalid session"}"#)
        }
        defer { StubURLSessionFactory.reset(session) }
        let client = UserProfileAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        await #expect(throws: UserProfileAPIError.serverError(401)) {
            try await client.fetchProfile()
        }

        #expect(sentAuthorization == "Bearer \(harness.token)")
        expectSignedOut(harness)
    }

    @Test func aClientThatMapsA401KeepsItsErrorAndTheSessionEnds() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        let session = StubURLSessionFactory.make { request in respond(request, 401) }
        defer { StubURLSessionFactory.reset(session) }
        let client = UserProfileAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        await #expect(throws: UserProfileAPIError.notAuthenticated) {
            try await client.deleteAvatar()
        }

        expectSignedOut(harness)
    }

    @Test func theFeedReadsAsAGuestAndTheSessionEnds() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        let videoID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var sentAuthorizations: [String?] = []
        let session = StubURLSessionFactory.make { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            sentAuthorizations.append(authorization)
            if authorization != nil { return respond(request, 401, #"{"error":"invalid session"}"#) }
            return respond(
                request, 200,
                #"{"items":[{"id":"\#(videoID.uuidString)","streamURL":"https://cdn.example.com/v/guest.mp4"}]}"#)
        }
        defer { StubURLSessionFactory.reset(session) }
        let client = FeedAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        let page = try await client.fetchFeed()

        // The 401 ends the session and the same read goes on as a guest, so the feed still shows clips.
        #expect(page.items.map(\.id) == [videoID])
        #expect(sentAuthorizations == ["Bearer \(harness.token)", nil])
        expectSignedOut(harness)
    }

    @Test func aLocationReportEndsTheSession() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        let session = StubURLSessionFactory.make { request in respond(request, 401) }
        defer { StubURLSessionFactory.reset(session) }
        let client = UserLocationAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        let location = try #require(ClipLocation(latitude: 13.7563, longitude: 100.5018))

        await #expect(throws: UserLocationAPIError.serverError(401)) {
            try await client.report(location: location)
        }

        expectSignedOut(harness)
    }

    @Test func aPostedCommentKeepsSignInRequiredAndTheSessionEnds() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        let session = StubURLSessionFactory.make { request in respond(request, 401, #"{"error":"invalid session"}"#) }
        defer { StubURLSessionFactory.reset(session) }
        let client = CommentsAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        await #expect(throws: CommentError.signInRequired) {
            try await client.postComment(videoID: Self.videoID, body: "Hello")
        }

        expectSignedOut(harness)
    }

    /// The comments read answers a rejected token by reading again as a guest. That keeps working, and the session
    /// still ends: the guest read is not reported because it carries no token.
    @Test func theCommentsReadStillRetriesAsAGuestAndTheSessionEnds() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        var sentAuthorizations: [String?] = []
        let session = StubURLSessionFactory.make { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            sentAuthorizations.append(authorization)
            return authorization == nil
                ? respond(request, 200, Self.commentsPage)
                : respond(request, 401, #"{"error":"invalid session"}"#)
        }
        defer { StubURLSessionFactory.reset(session) }
        let client = CommentsAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        let page = try await client.fetchComments(videoID: Self.videoID)

        #expect(page.items.map(\.body) == ["Nice view"])
        #expect(sentAuthorizations == ["Bearer \(harness.token)", nil])
        expectSignedOut(harness)
    }

    @Test func aGuestIsUnaffectedByA401() async {
        let storage = MemorySessionStorage()
        let viewModel = AuthViewModel(
            sessionStore: storage, tokenStore: storage, refreshTokenStore: storage, authAPI: UnusedAuthAPI())
        var sentAuthorizations: [String?] = []
        let session = StubURLSessionFactory.make { request in
            sentAuthorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            return respond(request, 401)
        }
        defer { StubURLSessionFactory.reset(session) }
        let http = transport(session, reportingTo: viewModel)
        let feed = FeedAPIClient(client: http, authorization: SessionAPIAuthorization(tokenStore: storage))
        let comments = CommentsAPIClient(client: http, authorization: SessionAPIAuthorization(tokenStore: storage))

        await #expect(throws: FeedAPIError.serverError(401)) { try await feed.fetchFeed() }
        // A guest read that is rejected is not retried: there is no token to blame.
        await #expect(throws: CommentError.serverError(401)) {
            try await comments.fetchComments(videoID: Self.videoID)
        }

        #expect(sentAuthorizations == [nil, nil])
        #expect(!viewModel.isSignedIn)
        #expect(storage.userID == nil)
        #expect(storage.accessToken == nil)
    }

    /// A request that carries no token cannot have a token rejected, even for a viewer who is signed in. (The public
    /// profile now sends the session when there is one, so this client is given none.)
    @Test func aTokenlessRequestOfASignedInViewerDoesNotEndTheSession() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        var sentAuthorization: String?
        let session = StubURLSessionFactory.make { request in
            sentAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return respond(request, 401)
        }
        defer { StubURLSessionFactory.reset(session) }
        let client = UserProfileAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: nil
        )

        await #expect(throws: UserProfileAPIError.serverError(401)) {
            try await client.fetchPublicProfile(handle: "@friend")
        }

        #expect(sentAuthorization == nil)
        #expect(harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == harness.token)
    }

    /// The answer to a request sent before the viewer signed in again belongs to the old session.
    @Test func aLateRejectionDoesNotEndANewerSession() async throws {
        let harness = await signedInHarness()
        try #require(harness.viewModel.isSignedIn)
        let newToken = TestAccessToken.make(subject: "again", expiresIn: 3_600)
        let session = StubURLSessionFactory.make { [storage = harness.storage] request in
            // While the request is out, the viewer signs in again.
            storage.accessToken = newToken
            return respond(request, 401)
        }
        defer { StubURLSessionFactory.reset(session) }
        let client = UserProfileAPIClient(
            client: transport(session, reportingTo: harness.viewModel),
            authorization: harness.authorization
        )

        await #expect(throws: UserProfileAPIError.serverError(401)) {
            try await client.fetchProfile()
        }

        #expect(harness.viewModel.isSignedIn)
        #expect(harness.storage.accessToken == newToken)
        #expect(harness.storage.userID == Self.userID)
    }
}

// MARK: - doubles

private func respond(_ request: URLRequest, _ status: Int, _ body: String = "") -> (HTTPURLResponse, Data) {
    (StubURLSessionFactory.httpResponse(for: request, statusCode: status), Data(body.utf8))
}

// nonisolated: Swift 6.4 would make a class that conforms to these MainActor-isolated protocols MainActor-isolated, but
// the tests change the token from `@Sendable` closures and from the stub's URLProtocol thread, which the lock makes safe.
nonisolated private final class MemorySessionStorage: AuthSessionStore, APIAccessTokenStore, APIRefreshTokenStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedUserID: String?
    private var storedAccessToken: String?
    private var storedRefreshToken: String?

    init(userID: String? = nil, accessToken: String? = nil, refreshToken: String? = nil) {
        storedUserID = userID
        storedAccessToken = accessToken
        storedRefreshToken = refreshToken
    }

    var userID: String? {
        get { lock.withLock { storedUserID } }
        set { lock.withLock { storedUserID = newValue } }
    }

    var accessToken: String? {
        get { lock.withLock { storedAccessToken } }
        set { lock.withLock { storedAccessToken = newValue } }
    }

    var refreshToken: String? {
        get { lock.withLock { storedRefreshToken } }
        set { lock.withLock { storedRefreshToken = newValue } }
    }

    func loadUserID() -> String? { userID }
    func saveUserID(_ userID: String) throws { self.userID = userID }
    func clear() throws { userID = nil }

    func loadAccessToken() -> String? { accessToken }
    func saveAccessToken(_ token: String) throws { accessToken = token }
    func clearAccessToken() throws { accessToken = nil }

    func loadRefreshToken() -> String? { refreshToken }
    func saveRefreshToken(_ token: String) throws { refreshToken = token }
    func clearRefreshToken() throws { refreshToken = nil }
}

/// What Apple answers about the account behind a saved session, and which accounts it was asked about.
private final class AppleAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private let state: ASAuthorizationAppleIDProvider.CredentialState
    /// Runs while Apple is still answering, so a test can change the world in between.
    var whileAnswering: (@Sendable () async -> Void)?

    init(_ state: ASAuthorizationAppleIDProvider.CredentialState) {
        self.state = state
    }

    var askedUserIDs: [String] { lock.withLock { asked } }

    var provider: AuthViewModel.CredentialStateProvider {
        { [self] userID in
            lock.withLock { asked.append(userID) }
            await whileAnswering?()
            return state
        }
    }
}

/// Counts every call it gets, and refuses all of them.
private final class CountingAuthAPI: AuthAPIClientProtocol, @unchecked Sendable {
    private(set) var callCount = 0

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        callCount += 1
        throw AuthAPIError.invalidResponse
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        callCount += 1
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        callCount += 1
        throw AuthAPIError.invalidResponse
    }
}

/// Answers a sign-in with the given pair.
private struct SignInAuthAPI: AuthAPIClientProtocol {
    let tokens: AuthTokens

    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        tokens
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}

private struct UnusedAuthAPI: AuthAPIClientProtocol {
    func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func refreshTokens(using refreshToken: String) async throws -> AuthTokens {
        throw AuthAPIError.invalidResponse
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        throw AuthAPIError.invalidResponse
    }
}

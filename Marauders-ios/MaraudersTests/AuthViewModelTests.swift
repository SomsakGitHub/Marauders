//
//  AuthViewModelTests.swift
//  MaraudersTests
//

import Testing
@testable import Marauders

@MainActor
struct AuthViewModelTests {
    @Test func completeSignInPersistsValidUserID() {
        let store = InMemoryAuthSessionStore()
        let viewModel = AuthViewModel(sessionStore: store)

        viewModel.completeSignIn(userID: "001234.abcdef.5678")

        #expect(viewModel.isSignedIn)
        #expect(store.savedUserID == "001234.abcdef.5678")
        #expect(viewModel.errorMessage == nil)
    }

    @Test func completeSignInRejectsEmptyUserID() {
        let store = InMemoryAuthSessionStore()
        let viewModel = AuthViewModel(sessionStore: store)

        viewModel.completeSignIn(userID: "   ")

        #expect(!viewModel.isSignedIn)
        #expect(viewModel.errorMessage == "Invalid account")
    }

    @Test func signOutClearsSession() {
        let store = InMemoryAuthSessionStore()
        store.savedUserID = "user-1"
        let viewModel = AuthViewModel(sessionStore: store)
        viewModel.completeSignIn(userID: "user-1")

        viewModel.signOut()

        #expect(!viewModel.isSignedIn)
        #expect(store.savedUserID == nil)
    }
}

private final class InMemoryAuthSessionStore: AuthSessionStore, @unchecked Sendable {
    var savedUserID: String?

    func loadUserID() -> String? { savedUserID }

    func saveUserID(_ userID: String) throws {
        savedUserID = userID
    }

    func clear() throws {
        savedUserID = nil
    }
}

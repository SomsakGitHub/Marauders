//
//  AccountDeletionViewModelTests.swift
//  MaraudersTests
//

import AuthenticationServices
import Foundation
import Testing

@testable import Marauders

/// What the deletion sheet shows and does as a deletion goes on, from the first tap to the last word.
@MainActor
struct AccountDeletionViewModelTests {
    private struct Rig {
        let viewModel: AccountDeletionViewModel
        let repository: ControlledDeletionRepository
        let sightings: PhaseSightings
    }

    /// A sheet wired to a repository the test controls, and a record of the phase `onAccountDeleted` found.
    private func makeRig() -> Rig {
        let repository = ControlledDeletionRepository()
        let viewModel = AccountDeletionViewModel(
            deleteAccount: DeleteAccountUseCase(repository: repository, feedCache: nil))
        let sightings = PhaseSightings()
        viewModel.onAccountDeleted = { [weak viewModel] in
            sightings.phases.append(viewModel?.phase ?? .idle)
        }
        return Rig(viewModel: viewModel, repository: repository, sightings: sightings)
    }

    /// The words the person is shown for a reason.
    private static func text(of error: AccountDeletionError) -> String {
        error.errorDescription ?? ""
    }

    /// What Apple's sheet reports when it ends in the way `code` names.
    private static func appleError(_ code: Int) -> NSError {
        NSError(domain: ASAuthorizationError.errorDomain, code: code)
    }

    /// Lets a tap that was started in a `Task` run until it is inside the repository (everything here runs on the main
    /// actor, so a yield is all it takes). Gives up after a while so a deletion that never gets there fails the test
    /// that expects it instead of hanging it.
    private static func waitUntilAsked(_ repository: ControlledDeletionRepository) async {
        for _ in 0..<1_000 where repository.codes.isEmpty {
            await Task.yield()
        }
    }

    // MARK: - A deletion that works

    @Test func aDeletionThatWorksEndsDeletedAndOnlyThenTellsTheApp() async {
        let rig = makeRig()

        await rig.viewModel.delete(authorizationCode: "code-1")

        #expect(rig.viewModel.phase == .deleted)
        #expect(rig.repository.codes == ["code-1"])
        #expect(rig.sightings.phases == [.deleted], "once, and after the phase said .deleted")
    }

    /// What the Debug-only buttons of a test user do: a test user of the Simulator has no Apple ID to confirm with.
    @Test func aDeletionWithoutACodeAsksTheRepositoryWithNone() async {
        let rig = makeRig()

        await rig.viewModel.delete(authorizationCode: nil)

        #expect(rig.repository.codes == [nil])
        #expect(rig.viewModel.phase == .deleted)
    }

    // MARK: - A deletion that fails

    @Test(arguments: [
        AccountDeletionError.signInRequired, .appleNotConfirmed, .wrongAppleAccount, .tooManyClips(limit: 15),
        .rateLimited, .notAvailable, .couldNotFinish,
    ])
    func eachReasonOfTheWorkerIsShownInItsOwnWords(_ error: AccountDeletionError) async {
        let rig = makeRig()
        rig.repository.failure = error

        await rig.viewModel.delete(authorizationCode: "code-1")

        #expect(rig.viewModel.phase == .failed(Self.text(of: error)))
        #expect(rig.sightings.phases.isEmpty, "a failed deletion never signs the viewer out")
    }

    /// No answer at all is not a reason the Worker gave: the person is told the deletion did not finish.
    @Test(arguments: [
        URLError(.timedOut) as any Error, URLError(.notConnectedToInternet), NSError(domain: "test.other", code: 7),
    ])
    func anythingElseIsShownAsNotFinished(_ error: any Error) async {
        let rig = makeRig()
        rig.repository.failure = error

        await rig.viewModel.delete(authorizationCode: "code-1")

        #expect(rig.viewModel.phase == .failed(Self.text(of: .couldNotFinish)))
        #expect(rig.sightings.phases.isEmpty)
    }

    @Test func aFailedAttemptAndThenASuccessfulOneFromTheSameSheet() async {
        let rig = makeRig()
        rig.repository.failure = AccountDeletionError.couldNotFinish
        await rig.viewModel.delete(authorizationCode: "code-1")
        #expect(rig.viewModel.phase == .failed(Self.text(of: .couldNotFinish)))
        #expect(rig.sightings.phases.isEmpty)

        rig.repository.failure = nil
        await rig.viewModel.delete(authorizationCode: "code-2")

        #expect(rig.viewModel.phase == .deleted)
        #expect(rig.repository.codes == ["code-1", "code-2"])
        #expect(rig.sightings.phases == [.deleted], "the app is told once, by the attempt that worked")
    }

    // MARK: - Two taps

    /// An Apple code can be used once, so a second tap while the first deletion runs must not send a second request.
    @Test(.timeLimit(.minutes(1)))
    func aSecondTapWhileTheFirstIsRunningAsksNothingMore() async {
        let rig = makeRig()
        let viewModel = rig.viewModel
        let gate = SignOutGate()
        rig.repository.gateForTheNextCall = gate
        let first = Task { await viewModel.delete(authorizationCode: "code-1") }
        await Self.waitUntilAsked(rig.repository)
        #expect(viewModel.phase == .deleting)

        await viewModel.delete(authorizationCode: "code-2")

        #expect(rig.repository.codes == ["code-1"], "the second tap never reached the repository")
        #expect(viewModel.phase == .deleting)
        await gate.open()
        await first.value
        #expect(viewModel.phase == .deleted)
        #expect(rig.sightings.phases == [.deleted], "one deletion tells the app once")
    }

    /// A late answer of Apple's sheet (a second tap on its button, a slow callback) must not wipe out the progress of a
    /// deletion that is under way, nor start another one.
    @Test(.timeLimit(.minutes(1)))
    func anAppleAnswerWhileTheAccountIsBeingDeletedChangesNothing() async {
        let rig = makeRig()
        let viewModel = rig.viewModel
        let gate = SignOutGate()
        rig.repository.gateForTheNextCall = gate
        let first = Task { await viewModel.delete(authorizationCode: "code-1") }
        await Self.waitUntilAsked(rig.repository)
        #expect(viewModel.phase == .deleting)

        await viewModel.handleAppleResult(.failure(Self.appleError(ASAuthorizationError.canceled.rawValue)))
        #expect(viewModel.phase == .deleting, "a cancelled sheet does not end the progress")
        await viewModel.handleAppleResult(.failure(Self.appleError(ASAuthorizationError.failed.rawValue)))
        #expect(viewModel.phase == .deleting, "a failure does not replace the progress with a message")
        await viewModel.handleAppleResult(.success(nil))
        #expect(viewModel.phase == .deleting, "a missing code does not either")
        await viewModel.handleAppleResult(.success(Data("code-2".utf8)))
        #expect(rig.repository.codes == ["code-1"], "a second code is not used")

        await gate.open()
        await first.value
        #expect(viewModel.phase == .deleted)
        #expect(rig.sightings.phases == [.deleted])
    }

    // MARK: - Apple's side

    @Test func aCancelledAppleSheetLeavesTheSheetIdleAndAsksNothing() async {
        let rig = makeRig()

        await rig.viewModel.handleAppleResult(.failure(Self.appleError(ASAuthorizationError.canceled.rawValue)))

        #expect(rig.viewModel.phase == .idle)
        #expect(rig.repository.codes.isEmpty)
    }

    /// Backing out of Apple's sheet takes the person back to where the sheet began, so an old message goes too.
    @Test func cancellingAppleSheetAfterAFailureClearsItsMessage() async throws {
        let rig = makeRig()
        rig.repository.failure = AccountDeletionError.couldNotFinish
        await rig.viewModel.delete(authorizationCode: "code-1")
        try #require(rig.viewModel.phase == .failed(Self.text(of: .couldNotFinish)))

        await rig.viewModel.handleAppleResult(.failure(Self.appleError(ASAuthorizationError.canceled.rawValue)))

        #expect(rig.viewModel.phase == .idle)
        #expect(rig.repository.codes == ["code-1"], "the cancelled sheet asked nothing")
    }

    @Test(arguments: [
        ASAuthorizationError.failed.rawValue, ASAuthorizationError.invalidResponse.rawValue,
        ASAuthorizationError.notHandled.rawValue, ASAuthorizationError.unknown.rawValue,
    ])
    func anyOtherAppleFailureIsNotAConfirmationAndAsksNothing(_ code: Int) async {
        let rig = makeRig()

        await rig.viewModel.handleAppleResult(.failure(Self.appleError(code)))

        #expect(rig.viewModel.phase == .failed(Self.text(of: .appleNotConfirmed)))
        #expect(rig.repository.codes.isEmpty)
        #expect(rig.sightings.phases.isEmpty)
    }

    @Test func anErrorThatIsNotAppleSIsNotAConfirmationEither() async {
        let rig = makeRig()

        await rig.viewModel.handleAppleResult(.failure(URLError(.notConnectedToInternet)))

        #expect(rig.viewModel.phase == .failed(Self.text(of: .appleNotConfirmed)))
        #expect(rig.repository.codes.isEmpty)
    }

    /// Without a code Apple cannot be told to revoke anything, so nothing is asked of the Worker.
    @Test(arguments: [Data?.none, Data(), Data([0xFF, 0xFE])])
    func noUsableCodeIsNotAConfirmationAndAsksNothing(_ data: Data?) async {
        let rig = makeRig()

        await rig.viewModel.handleAppleResult(.success(data))

        #expect(rig.viewModel.phase == .failed(Self.text(of: .appleNotConfirmed)))
        #expect(rig.repository.codes.isEmpty)
        #expect(rig.sightings.phases.isEmpty)
    }

    @Test func theCodeAppleGaveIsPassedOnAsText() async {
        let rig = makeRig()

        await rig.viewModel.handleAppleResult(.success(Data("abc.def".utf8)))

        #expect(rig.repository.codes == ["abc.def"])
        #expect(rig.viewModel.phase == .deleted)
    }

    /// The entry point the sign-in button reports to hands a failure on the way `handleAppleResult` treats it. (A
    /// success carries a system object a test cannot make; the code it holds is what `handleAppleResult` is driven with.)
    @Test func theAuthorizationEntryPointTreatsAFailureTheSameWay() async {
        let cancelled = makeRig()
        await cancelled.viewModel.handleAuthorization(
            .failure(Self.appleError(ASAuthorizationError.canceled.rawValue)))
        let failed = makeRig()
        await failed.viewModel.handleAuthorization(.failure(Self.appleError(ASAuthorizationError.failed.rawValue)))

        #expect(cancelled.viewModel.phase == .idle)
        #expect(failed.viewModel.phase == .failed(Self.text(of: .appleNotConfirmed)))
        #expect(cancelled.repository.codes.isEmpty)
        #expect(failed.repository.codes.isEmpty)
    }

    // MARK: - Starting over

    @Test func resetBringsAFailureBackToIdle() async throws {
        let rig = makeRig()
        rig.repository.failure = AccountDeletionError.couldNotFinish
        await rig.viewModel.delete(authorizationCode: "code-1")
        try #require(rig.viewModel.phase == .failed(Self.text(of: .couldNotFinish)))

        rig.viewModel.reset()

        #expect(rig.viewModel.phase == .idle)
    }

    /// The sheet is dismissed after a deletion too, and the next account to sign in must not meet its confirmation.
    @Test func resetAfterADeletionBringsTheSheetBackToIdle() async throws {
        let rig = makeRig()
        await rig.viewModel.delete(authorizationCode: "code-1")
        try #require(rig.viewModel.phase == .deleted)

        rig.viewModel.reset()

        #expect(rig.viewModel.phase == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func resetDoesNothingWhileTheAccountIsBeingDeleted() async {
        let rig = makeRig()
        let viewModel = rig.viewModel
        let gate = SignOutGate()
        rig.repository.gateForTheNextCall = gate
        let first = Task { await viewModel.delete(authorizationCode: "code-1") }
        await Self.waitUntilAsked(rig.repository)
        #expect(viewModel.phase == .deleting)

        viewModel.reset()

        #expect(viewModel.phase == .deleting, "a dismissed sheet does not cancel a deletion that is under way")
        await gate.open()
        await first.value
        #expect(viewModel.phase == .deleted)
    }
}

/// The phases `onAccountDeleted` found the sheet in, one per call.
@MainActor
private final class PhaseSightings {
    var phases: [AccountDeletionViewModel.Phase] = []
}

/// The Worker's side of a deletion as the sheet meets it: it notes every code it is asked with, can fail, and can hold
/// the next call until the test lets it go.
private final class ControlledDeletionRepository: AccountDeletionRepository, @unchecked Sendable {
    private(set) var codes: [String?] = []
    var failure: Error?
    /// The next call waits here before it answers; the calls after it do not.
    var gateForTheNextCall: SignOutGate?

    func deleteAccount(authorizationCode: String?) async throws {
        codes.append(authorizationCode)
        if let gate = gateForTheNextCall {
            gateForTheNextCall = nil
            await gate.wait()
        }
        if let failure { throw failure }
    }
}

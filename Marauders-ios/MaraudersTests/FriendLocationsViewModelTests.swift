//
//  FriendLocationsViewModelTests.swift
//  Marauders
//

import CoreLocation
import Foundation
import Testing

@testable import Marauders

@MainActor
struct FriendLocationsViewModelTests {
    private static let alice = FriendLocation(
        handle: "@alice", avatarURL: nil, latitude: 13.76, longitude: 100.51, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    private static let fix = CLLocation(latitude: 13.7563, longitude: 100.5018)

    private struct SUT {
        let viewModel: FriendLocationsViewModel
        let repository: StubLocationSharingRepository
        let manager: FakeLocationManager
        let reports: RecordingUserLocationRepository
        let clock: ForegroundLocationReporterTests.Clock
    }

    private func makeSUT(
        _ repository: StubLocationSharingRepository = StubLocationSharingRepository(),
        authorization: CLAuthorizationStatus = .authorizedAlways
    ) -> SUT {
        let manager = FakeLocationManager(authorizationStatus: authorization)
        let reports = RecordingUserLocationRepository()
        let clock = ForegroundLocationReporterTests.Clock()
        let reporter = ForegroundLocationReporter(
            locationManager: manager,
            report: ReportUserLocationUseCase(repository: reports),
            now: { clock.now }
        )
        let viewModel = FriendLocationsViewModel(
            loadFriends: LoadFriendLocationsUseCase(repository: repository),
            setSharing: SetLocationSharingUseCase(repository: repository),
            reporter: reporter,
            now: { clock.now }
        )
        return SUT(viewModel: viewModel, repository: repository, manager: manager, reports: reports, clock: clock)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func sharingIsUnknownUntilTheWorkerSays() {
        let sut = makeSUT()

        #expect(sut.viewModel.sharing == nil)
        #expect(sut.viewModel.friends.isEmpty)
    }

    @Test func aRefreshShowsWhatTheWorkerSays() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice]))))

        await sut.viewModel.refresh()

        #expect(sut.viewModel.sharing == true)
        #expect(sut.viewModel.located)
        #expect(sut.viewModel.friends == [Self.alice])
    }

    /// The Worker shows nobody to a viewer who does not share; the app does not either, whatever it is sent.
    @Test func aViewerWhoDoesNotShareSeesNobody() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: false, friends: [Self.alice]))))

        await sut.viewModel.refresh()

        #expect(sut.viewModel.sharing == false)
        #expect(sut.viewModel.friends.isEmpty)
    }

    @Test func aFailedRefreshKeepsWhatIsShownForAWhile() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice]))))
        await sut.viewModel.refresh()

        sut.repository.friends = .failure(LocationSharingError.serverError(500))
        sut.clock.now += FriendLocationsViewModel.staleAfter
        await sut.viewModel.refresh()

        #expect(sut.viewModel.sharing == true)
        #expect(sut.viewModel.friends == [Self.alice])
    }

    /// The friend may have stopped sharing or unfollowed since; a pin the Worker has not confirmed for long goes.
    @Test func pinsGoOnceNoRefreshHasWorkedForFiveMinutes() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice]))))
        await sut.viewModel.refresh()

        sut.repository.friends = .failure(LocationSharingError.serverError(500))
        sut.clock.now += FriendLocationsViewModel.staleAfter + 1
        await sut.viewModel.refresh()

        #expect(sut.viewModel.friends.isEmpty)
    }

    @Test func turningSharingOnSendsTheViewersLocationAtOnceAndFetchesFriends() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: false, friends: []))))
        await sut.viewModel.refresh()

        sut.repository.friends = .success(FriendLocations(sharing: true, friends: [Self.alice]))
        let failure = await sut.viewModel.setSharing(true)

        #expect(failure == nil)
        #expect(sut.repository.sharingChanges == [true])
        #expect(sut.viewModel.sharing == true)
        #expect(sut.manager.locationRequestCount == 1, "a fresh location goes out as soon as sharing is on")
        #expect(sut.viewModel.friends == [Self.alice])
        #expect(!sut.viewModel.isChangingSharing)
    }

    /// Turning sharing on forgets the location on file, so the Worker shows nobody until the viewer's own fix lands;
    /// the friends come as soon as it has.
    @Test func friendsComeOnceTheViewersFirstLocationHasGoneOut() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: false, friends: []))))
        await sut.viewModel.refresh()
        sut.repository.friends = .success(FriendLocations(sharing: true, located: false, friends: []))

        await sut.viewModel.setSharing(true)
        #expect(!sut.viewModel.located)
        #expect(sut.viewModel.friends.isEmpty)

        sut.repository.friends = .success(FriendLocations(sharing: true, friends: [Self.alice]))
        sut.manager.simulateLocations([Self.fix])
        await waitUntil { sut.viewModel.friends == [Self.alice] }

        #expect(sut.reports.reportCount == 1)
        #expect(sut.viewModel.located)
        #expect(sut.viewModel.friends == [Self.alice])
    }

    @Test func turningSharingOffHidesFriendsAtOnce() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice]))))
        await sut.viewModel.refresh()

        await sut.viewModel.setSharing(false)

        #expect(sut.repository.sharingChanges == [false])
        #expect(sut.viewModel.sharing == false)
        #expect(sut.viewModel.friends.isEmpty)
        #expect(sut.manager.locationRequestCount == 0)
    }

    @Test func turningSharingOffDropsALocationStillOnItsWay() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: false, friends: []))))
        await sut.viewModel.refresh()
        sut.repository.friends = .success(FriendLocations(sharing: true, friends: []))
        await sut.viewModel.setSharing(true)
        #expect(sut.manager.locationRequestCount == 1)

        await sut.viewModel.setSharing(false)
        sut.manager.simulateLocations([Self.fix])
        try? await Task.sleep(for: .milliseconds(50))

        #expect(sut.reports.reportCount == 0, "the viewer stopped sharing before the fix arrived")
    }

    @Test func aFailedChangeKeepsTheSwitchWhereItWasAndSaysWhy() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: false, friends: []))))
        await sut.viewModel.refresh()

        sut.repository.change = .failure(LocationSharingError.serverError(503))
        let failure = await sut.viewModel.setSharing(true)

        #expect(failure == "Server responded with status 503")
        #expect(sut.viewModel.sharing == false)
        #expect(!sut.viewModel.isChangingSharing)
        #expect(sut.manager.locationRequestCount == 0)
    }

    /// The map refreshes every minute: an answer that left the Worker before the viewer turned sharing off must not turn
    /// it back on, or the app would go on sending the location of someone who just stopped.
    @Test func aRefreshAnsweredAfterATurnOffDoesNotUndoIt() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice]))))
        await sut.viewModel.refresh()
        let gate = SharingGate()
        sut.repository.beforeFriends = { await gate.wait() }

        let olderRefresh = Task { await sut.viewModel.refresh() }
        await waitUntil { sut.repository.friendRequests == 2 }
        await sut.viewModel.setSharing(false)
        await gate.open()
        await olderRefresh.value

        #expect(sut.viewModel.sharing == false)
        #expect(sut.viewModel.friends.isEmpty)
    }

    @Test func theViewersLocationGoesOutOnlyWhileTheyShare() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: false, friends: []))))

        sut.viewModel.reportLocationIfDue()
        #expect(sut.manager.locationRequestCount == 0, "nothing is known yet")

        await sut.viewModel.refresh()
        sut.viewModel.reportLocationIfDue()
        #expect(sut.manager.locationRequestCount == 0, "the viewer does not share")

        sut.repository.friends = .success(FriendLocations(sharing: true, friends: []))
        await sut.viewModel.refresh()
        sut.viewModel.reportLocationIfDue()
        #expect(sut.manager.locationRequestCount == 1)
    }

    @Test func resetForgetsTheEndedSession() async {
        let sut = makeSUT(StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice]))))
        await sut.viewModel.refresh()

        sut.viewModel.reset()
        sut.viewModel.reportLocationIfDue()

        #expect(sut.viewModel.sharing == nil)
        #expect(sut.viewModel.friends.isEmpty)
        #expect(sut.manager.locationRequestCount == 0)
    }

    @Test func anAnswerThatArrivesAfterAResetChangesNothing() async {
        let repository = StubLocationSharingRepository(friends: .success(FriendLocations(sharing: true, friends: [Self.alice])))
        let gate = SharingGate()
        repository.beforeFriends = { await gate.wait() }
        let sut = makeSUT(repository)

        let refresh = Task { await sut.viewModel.refresh() }
        await waitUntil { repository.friendRequests == 1 }
        sut.viewModel.reset()
        await gate.open()
        await refresh.value

        #expect(sut.viewModel.sharing == nil)
        #expect(sut.viewModel.friends.isEmpty)
    }
}

final class StubLocationSharingRepository: LocationSharingRepository, @unchecked Sendable {
    var friends: Result<FriendLocations, Error>
    var change: Result<Bool, Error>?
    var beforeFriends: (@Sendable () async -> Void)?
    private(set) var friendRequests = 0
    private(set) var sharingChanges: [Bool] = []

    init(friends: Result<FriendLocations, Error> = .success(FriendLocations(sharing: false, friends: []))) {
        self.friends = friends
    }

    func friendLocations() async throws -> FriendLocations {
        friendRequests += 1
        let answer = friends
        await beforeFriends?()
        return try answer.get()
    }

    func setSharing(_ enabled: Bool) async throws -> Bool {
        sharingChanges.append(enabled)
        if let change { return try change.get() }
        return enabled
    }
}

private actor SharingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

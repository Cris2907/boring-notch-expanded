import Combine
import Defaults
import XCTest
@testable import boringNotch

@MainActor
final class PomodoroActivityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var now: Date!

    override func setUp() {
        super.setUp()
        suiteName = "PomodoroActivityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        now = Date(timeIntervalSince1970: 10_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        now = nil
        super.tearDown()
    }

    func testStableActivityIDMetadataAndDefaultRegistration() throws {
        XCTAssertEqual(PomodoroActivity.activityID.rawValue, "builtin.pomodoro")

        let registered = try XCTUnwrap(ActivityRegistry.shared.activity(for: .pomodoro))
        XCTAssertEqual(registered.metadata.name, "Pomodoro")
        XCTAssertEqual(registered.metadata.systemImage, "timer")
        XCTAssertTrue(registered.isAvailable)
        XCTAssertTrue(registered.supportsCompactPresentation)
        XCTAssertEqual(registered.livePresentationState, .hidden)
        XCTAssertTrue(registered.supportsConfiguration)
    }

    func testRegistrationAloneAddsPomodoroToNavigation() throws {
        let manager = makeManager()
        let registry = try ActivityRegistry {
            PomodoroActivity(manager: manager)
        }

        XCTAssertEqual(
            visibleNotchViews(
                availableActivityIDs: registry.availableActivityIDs,
                includesShelf: true
            ),
            [.home, .activity(.pomodoro), .activities, .shelf]
        )
    }

    func testActivityForwardsActiveStateChangesThroughRegistry() throws {
        let manager = makeManager()
        let registry = try ActivityRegistry {
            PomodoroActivity(manager: manager)
        }
        let activity = try XCTUnwrap(registry.activity(for: .pomodoro))
        var updates = 0
        let observation = registry.objectWillChange.sink { updates += 1 }

        XCTAssertFalse(activity.isActive)
        manager.start()
        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(activity.livePresentationState, .visible(priority: .normal))
        manager.pause()
        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(activity.livePresentationState, .visible(priority: .low))
        manager.reset()
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(activity.livePresentationState, .hidden)
        XCTAssertGreaterThanOrEqual(updates, 3)
        withExtendedLifetime(observation) {}
    }

    func testPausedLivePresentationKeepsTimestampDerivedRemainingTime() throws {
        let manager = makeManager()
        let registry = try ActivityRegistry {
            PomodoroActivity(manager: manager)
        }
        let activity = try XCTUnwrap(registry.activity(for: .pomodoro))

        manager.start()
        advance(by: 3)
        manager.pause()
        advance(by: 100)

        XCTAssertEqual(activity.livePresentationState, .visible(priority: .low))
        XCTAssertEqual(manager.remaining(at: now), 7, accuracy: 0.001)
        XCTAssertEqual(
            selectedActivityLivePresentation(from: registry.activities)?.id,
            .pomodoro
        )
    }

    func testStandardConfigurationDurations() {
        let configuration = PomodoroConfiguration.standard

        XCTAssertEqual(configuration.focusDuration, 25 * 60)
        XCTAssertEqual(configuration.shortBreakDuration, 5 * 60)
        XCTAssertEqual(configuration.longBreakDuration, 15 * 60)
        XCTAssertEqual(configuration.focusSessionsBeforeLongBreak, 4)
        XCTAssertFalse(configuration.automaticallyStartsNextSession)
    }

    func testCompletedFocusTransitionsToReadyShortBreakAndIncrementsCount() {
        let manager = makeManager()
        manager.start()

        advance(by: testConfiguration.focusDuration)
        manager.reconcile()

        XCTAssertEqual(manager.snapshot?.kind, .shortBreak)
        XCTAssertEqual(manager.snapshot?.phase, .ready)
        XCTAssertEqual(manager.completedFocusSessions, 1)
        let activity = PomodoroActivity(manager: manager)
        XCTAssertEqual(activity.livePresentationState, .hidden)
    }

    func testFourthCompletedFocusTransitionsToLongBreak() {
        let manager = makeManager()

        for completedFocus in 1...4 {
            manager.start()
            advance(by: testConfiguration.focusDuration)
            manager.reconcile()

            if completedFocus < 4 {
                XCTAssertEqual(manager.snapshot?.kind, .shortBreak)
                manager.start()
                advance(by: testConfiguration.shortBreakDuration)
                manager.reconcile()
                XCTAssertEqual(manager.snapshot?.kind, .focus)
            }
        }

        XCTAssertEqual(manager.snapshot?.kind, .longBreak)
        XCTAssertEqual(manager.snapshot?.phase, .ready)
        XCTAssertEqual(manager.completedFocusSessions, 4)
    }

    func testPauseAndResumeUseTimestampAnchors() {
        let manager = makeManager()
        manager.start()
        advance(by: 3)
        manager.pause()

        advance(by: 100)
        XCTAssertEqual(manager.remaining(at: now), 7, accuracy: 0.001)

        manager.resume()
        advance(by: 2)
        XCTAssertEqual(manager.remaining(at: now), 5, accuracy: 0.001)
    }

    func testResetClearsSessionAndCompletedCount() {
        let manager = makeManager()
        manager.start()
        advance(by: testConfiguration.focusDuration)
        manager.reconcile()
        XCTAssertEqual(manager.completedFocusSessions, 1)

        manager.reset()

        XCTAssertNil(manager.snapshot)
        XCTAssertEqual(manager.completedFocusSessions, 0)
        XCTAssertFalse(manager.isActive)
    }

    func testSkipAdvancesWithoutCountingFocusCompletion() {
        let manager = makeManager()
        manager.start()
        manager.skip()

        XCTAssertEqual(manager.snapshot?.kind, .shortBreak)
        XCTAssertEqual(manager.snapshot?.phase, .ready)
        XCTAssertEqual(manager.completedFocusSessions, 0)

        manager.start()
        manager.skip()
        XCTAssertEqual(manager.snapshot?.kind, .focus)
        XCTAssertEqual(manager.completedFocusSessions, 0)
    }

    func testAutomaticNextSessionStartsImmediatelyWhenEnabled() {
        let configuration = PomodoroConfiguration(
            focusDuration: 10,
            shortBreakDuration: 5,
            longBreakDuration: 15,
            focusSessionsBeforeLongBreak: 4,
            automaticallyStartsNextSession: true
        )
        let manager = makeManager(configuration: configuration)
        manager.start()
        advance(by: configuration.focusDuration)

        manager.reconcile()

        XCTAssertEqual(manager.snapshot?.kind, .shortBreak)
        XCTAssertEqual(manager.snapshot?.phase, .running)
        XCTAssertEqual(manager.snapshot?.resumedAt, now)
    }

    func testDelayedReconciliationUsesTimestampWithoutAccumulatedTicks() {
        let manager = makeManager()
        manager.start()

        advance(by: 4.25)
        XCTAssertEqual(manager.remaining(at: now), 5.75, accuracy: 0.001)

        advance(by: 20)
        manager.reconcile()
        XCTAssertEqual(manager.snapshot?.kind, .shortBreak)
        XCTAssertEqual(manager.completedFocusSessions, 1)
    }

    func testPausedSessionSurvivesManagerRecreation() {
        let firstManager = makeManager()
        firstManager.start()
        advance(by: 4)
        firstManager.pause()

        advance(by: 100)
        let restoredManager = makeManager()

        XCTAssertEqual(restoredManager.snapshot?.phase, .paused)
        XCTAssertEqual(restoredManager.remaining(at: now), 6, accuracy: 0.001)
        XCTAssertTrue(restoredManager.isActive)
    }

    func testRunningSessionSurvivesManagerRecreationUsingTimestamp() {
        let firstManager = makeManager()
        firstManager.start()
        advance(by: 3)

        let restoredManager = makeManager()

        XCTAssertEqual(restoredManager.snapshot?.phase, .running)
        XCTAssertEqual(restoredManager.remaining(at: now), 7, accuracy: 0.001)
        XCTAssertTrue(restoredManager.isActive)
    }

    func testDefaultsBackedConfigurationPersistence() {
        let originalValues = (
            Defaults[.pomodoroFocusMinutes],
            Defaults[.pomodoroShortBreakMinutes],
            Defaults[.pomodoroLongBreakMinutes],
            Defaults[.pomodoroFocusSessionsBeforeLongBreak],
            Defaults[.pomodoroAutoStartNextSession]
        )
        defer {
            Defaults[.pomodoroFocusMinutes] = originalValues.0
            Defaults[.pomodoroShortBreakMinutes] = originalValues.1
            Defaults[.pomodoroLongBreakMinutes] = originalValues.2
            Defaults[.pomodoroFocusSessionsBeforeLongBreak] = originalValues.3
            Defaults[.pomodoroAutoStartNextSession] = originalValues.4
        }

        Defaults[.pomodoroFocusMinutes] = 40
        Defaults[.pomodoroShortBreakMinutes] = 8
        Defaults[.pomodoroLongBreakMinutes] = 20
        Defaults[.pomodoroFocusSessionsBeforeLongBreak] = 3
        Defaults[.pomodoroAutoStartNextSession] = true

        let restored = PomodoroConfiguration.current
        XCTAssertEqual(restored.focusDuration, 40 * 60)
        XCTAssertEqual(restored.shortBreakDuration, 8 * 60)
        XCTAssertEqual(restored.longBreakDuration, 20 * 60)
        XCTAssertEqual(restored.focusSessionsBeforeLongBreak, 3)
        XCTAssertTrue(restored.automaticallyStartsNextSession)
    }

    private var testConfiguration: PomodoroConfiguration {
        PomodoroConfiguration(
            focusDuration: 10,
            shortBreakDuration: 5,
            longBreakDuration: 15,
            focusSessionsBeforeLongBreak: 4,
            automaticallyStartsNextSession: false
        )
    }

    private func makeManager(
        configuration: PomodoroConfiguration? = nil
    ) -> PomodoroManager {
        let selectedConfiguration = configuration ?? testConfiguration
        return PomodoroManager(
            defaults: defaults,
            now: { self.now },
            configuration: { selectedConfiguration },
            managesBackgroundExecution: false
        )
    }

    private func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

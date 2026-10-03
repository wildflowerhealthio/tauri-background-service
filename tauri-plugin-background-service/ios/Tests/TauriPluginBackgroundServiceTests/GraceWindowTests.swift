import XCTest
import BackgroundTasks
import UIKit
@testable import tauri_plugin_background_service

/// Background grace window: when the app enters the background with the service
/// running in-process (Rust is blocked on `waitForCancel`) and no BGTask active,
/// the plugin holds a UIKit background task and resolves the pending cancel
/// invoke before iOS suspends the app, so Rust stops the service gracefully with
/// `PlatformExpiration` instead of being frozen mid-flight.
///
/// The UIKit calls go through the `BackgroundTimeProviding` seam
/// (`FakeBackgroundTimeProvider`). XCTest runs on `.main`, so the plugin's
/// `onMain { ... }` bodies and the transition handlers execute inline and the
/// assertions are final synchronously, except where a real timer is awaited.
final class GraceWindowTests: XCTestCase {

    private var plugin: BackgroundServicePlugin!
    private var backgroundTime: FakeBackgroundTimeProvider!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = TestDefaults.makeIsolatedSuite()
        backgroundTime = FakeBackgroundTimeProvider()
        plugin = BackgroundServicePlugin()
        plugin.scheduler = FakeBGTaskScheduler()
        plugin.notificationAuthorizer = FakeNotificationAuthorizer()
        plugin.backgroundTime = backgroundTime
        plugin.defaults = suite
        suite.set(true, forKey: "ios_desired_running")
    }

    override func tearDown() {
        TestDefaults.clearAll(on: suite)
        plugin = nil
        backgroundTime = nil
        suite = nil
        super.tearDown()
    }

    /// Simulate a running in-process service: Rust's cancel listener is blocked
    /// on `waitForCancel`. Returns the capture observing that invoke.
    @discardableResult
    private func startServiceListener() -> InvokeCapture {
        let capture = InvokeCapture()
        plugin.waitForCancel(capture.makeInvoke())
        return capture
    }

    // MARK: - Opening the grace window

    func testBackground_withServiceRunning_beginsOneGraceWindow() {
        let cancel = startServiceListener()

        plugin.appDidEnterBackground()

        XCTAssertEqual(backgroundTime.begun.count, 1, "backgrounding a running service begins one background task")
        XCTAssertTrue(plugin.isGraceWindowActive)
        XCTAssertNotNil(backgroundTime.lastName, "the background task is named for diagnostics")
        XCTAssertEqual(cancel.resolveCount, 0, "opening the window does not stop the service")
        XCTAssertEqual(cancel.rejectCount, 0)
    }

    func testBackgroundTwice_beginsOnlyOneGraceWindow() {
        startServiceListener()

        plugin.appDidEnterBackground()
        plugin.appDidEnterBackground()

        XCTAssertEqual(backgroundTime.begun.count, 1, "a second background transition must not begin a second task")
        XCTAssertEqual(backgroundTime.openTasks.count, 1)
    }

    func testBackground_withNoServiceRunning_beginsNoGraceWindow() {
        plugin.appDidEnterBackground()

        XCTAssertTrue(backgroundTime.begun.isEmpty, "no cancel listener means no in-process service to protect")
        XCTAssertFalse(plugin.isGraceWindowActive)
    }

    func testBackground_withActiveBGTask_beginsNoGraceWindow() {
        startServiceListener()
        plugin.injectedActiveTask = FakeBGTask()

        plugin.appDidEnterBackground()

        XCTAssertTrue(backgroundTime.begun.isEmpty,
                      "an active BGTask owns the lifecycle (expiration handler + safety timer)")
        XCTAssertFalse(plugin.isGraceWindowActive)
    }

    func testBackground_whenBeginIsRefused_holdsNoTask() {
        let cancel = startServiceListener()
        backgroundTime.refuseBegin = true

        plugin.appDidEnterBackground()

        XCTAssertFalse(plugin.isGraceWindowActive, ".invalid from beginBackgroundTask is not a grace window")
        XCTAssertTrue(backgroundTime.ended.isEmpty, ".invalid must never be passed to endBackgroundTask")
        XCTAssertEqual(cancel.resolveCount, 0)
    }

    // MARK: - Stopping the service before suspension

    func testDeadline_resolvesCancelInvoke_andKeepsTaskOpen() {
        let cancel = startServiceListener()
        plugin.appDidEnterBackground()

        plugin.handleGraceWindowDeadline()

        XCTAssertEqual(cancel.resolveCount, 1,
                       "the deadline resolves the cancel invoke → Rust stops with PlatformExpiration")
        XCTAssertEqual(cancel.rejectCount, 0)
        XCTAssertTrue(plugin.isGraceWindowActive,
                      "the task stays open so Rust has time to stop the service and notify")
        XCTAssertTrue(backgroundTime.ended.isEmpty)
    }

    func testDeadlineTimer_firesAndResolvesCancelInvoke() {
        let cancel = startServiceListener()
        // Less budget than the margin → the timer fires immediately.
        backgroundTime.backgroundTimeRemaining = 1
        let resolved = expectation(description: "grace-window timer resolved the cancel invoke")
        cancel.onResponse = { resolved.fulfill() }

        plugin.appDidEnterBackground()

        wait(for: [resolved], timeout: 5.0)
        XCTAssertEqual(cancel.resolveCount, 1)
        XCTAssertEqual(cancel.rejectCount, 0)
    }

    func testExpiration_resolvesCancelInvoke_andEndsTask() {
        let cancel = startServiceListener()
        plugin.appDidEnterBackground()

        backgroundTime.expire()

        XCTAssertEqual(cancel.resolveCount, 1, "expiration before the deadline still stops the service")
        XCTAssertEqual(backgroundTime.ended, backgroundTime.begun, "expiration ends the task it was given")
        XCTAssertFalse(plugin.isGraceWindowActive)
    }

    func testDeadlineThenExpiration_resolvesOnce_andEndsTaskOnce() {
        let cancel = startServiceListener()
        plugin.appDidEnterBackground()

        plugin.handleGraceWindowDeadline()
        backgroundTime.expire()
        backgroundTime.expire()  // duplicate → no-op

        XCTAssertEqual(cancel.resolveCount, 1, "the cancel invoke is resolved exactly once")
        XCTAssertEqual(cancel.rejectCount, 0)
        XCTAssertEqual(backgroundTime.ended.count, 1, "the task is ended exactly once")
        XCTAssertTrue(backgroundTime.openTasks.isEmpty)
    }

    // MARK: - Ending the grace window

    func testForeground_endsTask_withoutStoppingService() {
        let cancel = startServiceListener()
        // Timer would fire immediately if it were still armed.
        backgroundTime.backgroundTimeRemaining = 1
        plugin.appDidEnterBackground()

        plugin.appWillEnterForeground()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(backgroundTime.ended.count, 1, "returning to the foreground ends the task")
        XCTAssertTrue(backgroundTime.openTasks.isEmpty)
        XCTAssertFalse(plugin.isGraceWindowActive)
        XCTAssertEqual(cancel.resolveCount, 0, "the service keeps running in the foreground")
        XCTAssertEqual(cancel.rejectCount, 0)
    }

    func testForegroundThenBackground_opensFreshWindow() {
        startServiceListener()
        plugin.appDidEnterBackground()
        plugin.appWillEnterForeground()

        plugin.appDidEnterBackground()

        XCTAssertEqual(backgroundTime.begun.count, 2)
        XCTAssertEqual(backgroundTime.openTasks.count, 1, "only the new window is open")
    }

    func testStopKeepalive_endsTask() {
        let cancel = startServiceListener()
        plugin.appDidEnterBackground()

        plugin.stopKeepalive(InvokeCapture().makeInvoke())

        XCTAssertEqual(cancel.rejectCount, 1, "an explicit stop rejects the cancel invoke as before")
        XCTAssertTrue(backgroundTime.openTasks.isEmpty, "an explicit stop ends the task")
        XCTAssertFalse(plugin.isGraceWindowActive)
    }

    func testCompleteBgTask_afterDeadline_endsTask() {
        let cancel = startServiceListener()
        plugin.appDidEnterBackground()
        plugin.handleGraceWindowDeadline()

        // Rust finished stopping the service and reports completion.
        plugin.completeBgTask(InvokeCapture().makeInvoke(args: "{\"success\":false}"))

        XCTAssertEqual(cancel.resolveCount, 1)
        XCTAssertTrue(backgroundTime.openTasks.isEmpty, "the stopped service releases the task")
        XCTAssertFalse(plugin.isGraceWindowActive)
    }

    func testCompleteBgTask_naturalCompletion_endsTask() {
        let cancel = startServiceListener()
        plugin.appDidEnterBackground()

        plugin.completeBgTask(InvokeCapture().makeInvoke(args: "{\"success\":true}"))

        XCTAssertEqual(cancel.rejectCount, 1, "natural completion rejects the cancel invoke as before")
        XCTAssertTrue(backgroundTime.openTasks.isEmpty)
    }

    func testDeinit_endsOpenTask() {
        startServiceListener()
        plugin.appDidEnterBackground()

        plugin = nil

        XCTAssertTrue(backgroundTime.openTasks.isEmpty, "a torn-down plugin must not leak the task")
    }

    // MARK: - Stop delay arithmetic

    func testStopDelay_isRemainingMinusMargin() {
        XCTAssertEqual(BackgroundServicePlugin.graceWindowStopDelay(timeRemaining: 30, margin: 5), 25)
    }

    func testStopDelay_clampsAtZero() {
        XCTAssertEqual(BackgroundServicePlugin.graceWindowStopDelay(timeRemaining: 3, margin: 5), 0)
        XCTAssertEqual(BackgroundServicePlugin.graceWindowStopDelay(timeRemaining: -1, margin: 5), 0)
    }

    func testStopDelay_fallsBackWhenRemainingUnusable() {
        let fallback = BackgroundServicePlugin.graceWindowFallbackBudget - 5
        for remaining in [TimeInterval.greatestFiniteMagnitude, .infinity, .nan] {
            XCTAssertEqual(
                BackgroundServicePlugin.graceWindowStopDelay(timeRemaining: remaining, margin: 5), fallback,
                "remaining \(remaining) falls back to the assumed budget")
        }
    }
}

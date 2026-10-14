import Observation
import XCTest
@testable import HermesMobile

/// The persistent per-session channel keeps an idle chat in step with turns it
/// did not start (#1208). These tests drive `ChatSessionChannelCoordinator`
/// through a scripted SSE client, a scripted `/api/session/status` and a manual
/// poll clock: every wait is on an expectation or an observed state change,
/// never on wall-clock sleeps.
@MainActor
final class ChatSessionChannelCoordinatorTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testOpensTheChannelForAnIdleChatWithKnownCount() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        delegate.messageCount = 7

        coordinator.startMonitoringIfIdle()

        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(stream.startedURLs.count, 1)
        let url = stream.startedURLs[0]
        XCTAssertEqual(url.path, "/api/session/stream")
        XCTAssertTrue(url.query?.contains("session_id=session-1") == true)
        XCTAssertTrue(url.query?.contains("known_count=7") == true, url.absoluteString)
    }

    func testDoesNotOpenWhileAStreamOfItsOwnIsActive() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        delegate.hasActiveStream = true

        coordinator.startMonitoringIfIdle()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertTrue(stream.startedURLs.isEmpty)
    }

    func testRepeatedStartKeepsTheExistingChannel() {
        let (coordinator, stream, delegate, _) = makeCoordinator()

        coordinator.startMonitoringIfIdle()
        coordinator.startMonitoringIfIdle()

        XCTAssertEqual(stream.startedURLs.count, 1)
        XCTAssertEqual(stream.stopCount, 0)
        withExtendedLifetime(delegate) {}
    }

    func testStopClosesTheChannel() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()

        coordinator.stopMonitoring()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(stream.stopCount, 1)
        withExtendedLifetime(delegate) {}
    }

    func testDisabledPreferenceNeverOpens() {
        let (coordinator, stream, delegate, _) = makeCoordinator(isEnabled: false)

        coordinator.startMonitoringIfIdle()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertTrue(stream.startedURLs.isEmpty)
        withExtendedLifetime(delegate) {}
    }

    func testTurningThePreferenceOffClosesAndOnReopens() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()

        coordinator.setEnabled(false)
        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(stream.stopCount, 1)

        coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(stream.startedURLs.count, 2)
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Events

    func testServerTurnStartedAsksTheDelegateToReload() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        let reloaded = delegate.expectReloads(1)

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "stream-9", source: "bg_task")))
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.serverTurnStarted(streamID: "stream-9")])
    }

    func testSessionUpdatedReloadsOnlyWhenTheServerIsAhead() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        delegate.messageCount = 10
        coordinator.startMonitoringIfIdle()
        let reloaded = delegate.expectReloads(1)

        // Equal and lower counts are not a change; the first reload must be for 12.
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 10, knownCount: 10)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 9, knownCount: 10)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 12, knownCount: 10)))
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.sessionUpdated(messageCount: 12)])
    }

    func testEventsForAnotherSessionAreIgnored() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        let reloaded = delegate.expectReloads(1)

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-OTHER", streamId: "x", source: nil)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-OTHER", messageCount: 99, knownCount: 0)))
        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "mine", source: nil)))
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.serverTurnStarted(streamID: "mine")])
    }

    func testEventsAfterStopAreIgnored() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        coordinator.stopMonitoring()
        XCTAssertNil(stream.currentHandler, "a stopped channel delivers nothing")
        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "stale", source: nil)))

        coordinator.startMonitoringIfIdle()
        let reloaded = delegate.expectReloads(1)
        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "live", source: nil)))
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.serverTurnStarted(streamID: "live")])
    }

    func testChangesDuringAReloadRunExactlyOneMoreReload() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        delegate.holdReload = true
        coordinator.startMonitoringIfIdle()
        let started = delegate.expectReloadStarts(1)
        let reloaded = delegate.expectReloads(2)

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "s", source: nil)))
        await fulfillment(of: [started], timeout: 5)
        // Both arrive while the first load is in flight; it may already have read
        // the older transcript, so one follow-up load must run — but only one.
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 50, knownCount: 0)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 51, knownCount: 0)))
        delegate.holdReload = false
        delegate.releaseReload()
        await fulfillment(of: [reloaded], timeout: 5)

        // The reload loop decides whether to go again in the same main-actor turn
        // as the delegate's return, so by now a third load would have started.
        XCTAssertEqual(delegate.reloadStarts, 2)
        XCTAssertEqual(delegate.reloadReasons, [.serverTurnStarted(streamID: "s"), .polled])
    }

    func testAnEventAfterTheReloadFinishedStartsANewOne() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        let first = delegate.expectReloads(1)
        let second = delegate.expectReloads(2)

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "a", source: nil)))
        await fulfillment(of: [first], timeout: 5)
        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "b", source: nil)))
        await fulfillment(of: [second], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [.serverTurnStarted(streamID: "a"), .serverTurnStarted(streamID: "b")])
    }

    func testAFailedReloadIsRetriedAfterAPollInterval() async {
        let (coordinator, stream, delegate, clock) = makeCoordinator()
        delegate.reloadSucceeds = false
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)
        let failed = delegate.expectReloads(1)
        let waiting = clock.expectSleeps(1)

        // The channel stays healthy, so no further event will report this change.
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 4, knownCount: 3)))
        await fulfillment(of: [failed, waiting], timeout: 5)
        XCTAssertFalse(coordinator.isFallbackPolling, "a failed load is not a dropped channel")

        delegate.reloadSucceeds = true
        let retried = delegate.expectReloads(2)
        clock.advance()
        await fulfillment(of: [retried], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [.sessionUpdated(messageCount: 4), .polled])
        XCTAssertEqual(clock.sleeps, 1, "a successful retry ends the loop")
    }

    func testStoppingReleasesAReloadWithoutBlockingTheNextChannel() async {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        delegate.holdReload = true
        coordinator.startMonitoringIfIdle()
        let started = delegate.expectReloadStarts(1)
        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "a", source: nil)))
        await fulfillment(of: [started], timeout: 5)
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 9, knownCount: 0)))

        // A send closes the channel mid-reload, then the turn ends and it reopens.
        coordinator.stopMonitoring()
        coordinator.startMonitoringIfIdle()
        let released = delegate.expectReloads(1)
        delegate.holdReload = false
        delegate.releaseReload()
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(delegate.reloadStarts, 1, "the released reload runs no follow-up")

        let next = delegate.expectReloads(2)
        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "b", source: nil)))
        await fulfillment(of: [next], timeout: 5)
        XCTAssertEqual(delegate.reloadReasons, [.serverTurnStarted(streamID: "a"), .serverTurnStarted(streamID: "b")])
    }

    // MARK: - Fallback polling

    func testDroppedChannelFallsBackToPollingAndReloadsOnNewActiveStream() async {
        let status = StatusScript([.init(nil, 3), .init(nil, 3), .init("stream-42", 3)])
        let (coordinator, stream, delegate, clock) = makeCoordinator(status: status)
        delegate.messageCount = 3
        delegate.attachesOnReload = true
        coordinator.startMonitoringIfIdle()

        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))
        XCTAssertTrue(coordinator.isFallbackPolling)
        XCTAssertEqual(stream.stopCount, 1, "the dropped SSE client is stopped before polling starts")

        for polls in 1...2 {
            let slept = clock.expectSleeps(polls)
            await fulfillment(of: [slept], timeout: 5)
            XCTAssertTrue(delegate.reloadReasons.isEmpty, "nothing changed on poll \(polls)")
            clock.advance()
        }
        let reloaded = delegate.expectReloads(1)
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.polled])
        XCTAssertEqual(status.calls, 3)
    }

    func testFallbackPollingReloadsWhenTheMessageCountGrows() async {
        let status = StatusScript([.init(nil, 3), .init(nil, 5)])
        let (coordinator, stream, delegate, clock) = makeCoordinator(status: status)
        delegate.messageCount = 3
        delegate.messageCountAfterReload = 5
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))

        let firstPoll = clock.expectSleeps(1)
        await fulfillment(of: [firstPoll], timeout: 5)
        XCTAssertTrue(delegate.reloadReasons.isEmpty)
        let reloaded = delegate.expectReloads(1)
        clock.advance()
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.polled])
    }

    func testFailedReloadIsRetriedOnTheNextPoll() async {
        let status = StatusScript([.init(nil, 5)])
        let (coordinator, stream, delegate, clock) = makeCoordinator(status: status)
        delegate.messageCount = 3
        delegate.reloadSucceeds = false
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))

        // Poll 1 sees the server ahead and reloads; the load fails, so the
        // transcript stays at 3.
        let firstReload = delegate.expectReloads(1)
        await fulfillment(of: [firstReload], timeout: 5)

        // The retry succeeds and catches the transcript up; a later poll is quiet.
        // Waits so far: the failed reload's retry wait and poll 1's wait. The
        // advance releases both; the retry succeeds (no further wait) and poll 2
        // runs, then parks as wait 3.
        delegate.reloadSucceeds = true
        delegate.messageCountAfterReload = 5
        let retried = delegate.expectReloads(2)
        let poll2Parked = clock.expectSleeps(3)
        clock.advance()
        await fulfillment(of: [retried, poll2Parked], timeout: 5)
        XCTAssertEqual(status.calls, 2)

        let poll3Parked = clock.expectSleeps(4)
        clock.advance()
        await fulfillment(of: [poll3Parked], timeout: 5)

        XCTAssertEqual(status.calls, 3)
        XCTAssertEqual(delegate.reloadReasons.count, 2, "a caught-up transcript stops the retries")
        withExtendedLifetime(coordinator) {}
    }

    func testPollingThatEndsForATurnOfItsOwnReleasesTheSessionForANewChannel() async {
        let status = StatusScript([.init(nil, 3)])
        let (coordinator, stream, delegate, clock) = makeCoordinator(status: status)
        delegate.messageCount = 3
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))
        let polled = clock.expectSleeps(1)
        await fulfillment(of: [polled], timeout: 5)

        // The chat starts streaming without going through stopMonitoring (the loop
        // notices on its next tick) — the coordinator must not stay stuck "monitoring".
        delegate.hasActiveStream = true
        let callsBefore = status.calls
        clock.advance()
        await waitUntil { !coordinator.isMonitoring }
        XCTAssertFalse(coordinator.isFallbackPolling)
        XCTAssertEqual(status.calls, callsBefore, "polling ends once the chat streams a turn of its own")

        delegate.hasActiveStream = false
        coordinator.startMonitoringIfIdle()
        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(stream.startedURLs.count, 2, "the turn's end reopens the channel")
    }

    func testAClarifyInitialFrameCountsAsAnOpenChannel() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()

        stream.emit(.clarificationPending(ClarificationPendingResponse(pending: nil, pendingCount: 0)))
        stream.emit(.transportError("socket reset"))

        XCTAssertTrue(coordinator.isFallbackPolling, "a channel that sent its initial frame dropped; poll through it")
        withExtendedLifetime(delegate) {}
    }

    func testAChannelThatNeverOpenedIsRetriedOnAConnectivityChange() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        stream.emit(.transportError("The network connection was lost."))
        XCTAssertFalse(coordinator.isMonitoring)

        coordinator.reconnectIfIdle()

        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(stream.startedURLs.count, 2)
        withExtendedLifetime(delegate) {}
    }

    func testAConnectivityChangeReplacesPollingWithTheChannel() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))
        XCTAssertTrue(coordinator.isFallbackPolling)

        coordinator.reconnectIfIdle()
        XCTAssertFalse(coordinator.isFallbackPolling)
        XCTAssertEqual(stream.startedURLs.count, 2)

        // This server has opened the channel before, so a new subscription that
        // drops before its first frame is a lost network: poll, don't give up.
        stream.emit(.transportError("The network connection was lost."))
        XCTAssertTrue(coordinator.isFallbackPolling)
        withExtendedLifetime(delegate) {}
    }

    func testReconnectKeepsAHealthyOpenChannel() {
        let (coordinator, stream, delegate, _) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)

        coordinator.reconnectIfIdle()

        XCTAssertEqual(stream.startedURLs.count, 1)
        XCTAssertEqual(stream.stopCount, 0)
        withExtendedLifetime(delegate) {}
    }

    func testChannelThatNeverOpenedDoesNotPoll() {
        let status = StatusScript([.init(nil, 0)])
        let (coordinator, stream, delegate, clock) = makeCoordinator(status: status)
        coordinator.startMonitoringIfIdle()

        // An older server (no /api/session/stream) fails the request outright.
        // The decision is synchronous: no poll task is created at all.
        stream.emit(.transportError("404"))

        XCTAssertFalse(coordinator.isFallbackPolling)
        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(status.calls, 0, "no polling against a server that never opened the channel")
        XCTAssertEqual(clock.sleeps, 0)
        XCTAssertEqual(stream.stopCount, 1)
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Decoding

    func testDecodesTheChannelEventsByWireName() throws {
        let turn = SSEEventDecoder.decode(
            eventType: "server_turn_started",
            data: #"{"session_id":"s1","stream_id":"st9","pending_started_at":1.0,"source":"bg_task_complete"}"#
        )
        XCTAssertEqual(turn, .serverTurnStarted(ServerTurnStartedEvent(sessionId: "s1", streamId: "st9", source: "bg_task_complete")))

        let updated = SSEEventDecoder.decode(
            eventType: "session-updated",
            data: #"{"session_id":"s1","message_count":12,"known_count":10}"#
        )
        XCTAssertEqual(updated, .sessionUpdated(SessionUpdatedEvent(sessionId: "s1", messageCount: 12, knownCount: 10)))

        // Tolerant: unknown keys and an empty body still produce the event.
        XCTAssertEqual(
            SSEEventDecoder.decode(eventType: "server_turn_started", data: "{}"),
            .serverTurnStarted(ServerTurnStartedEvent())
        )
    }

    func testSessionStatusDecodesMessageCount() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(
            SessionStatusResponse.self,
            from: Data(#"{"session_id":"s1","active_stream_id":null,"is_streaming":false,"message_count":12}"#.utf8)
        )
        XCTAssertEqual(status.messageCount, 12)
        XCTAssertNil(status.activeStreamId)

        let older = try decoder.decode(SessionStatusResponse.self, from: Data(#"{"session_id":"s1"}"#.utf8))
        XCTAssertNil(older.messageCount, "older servers without the field still decode")
    }

    // MARK: - Helpers

    private func makeCoordinator(
        isEnabled: Bool = true,
        status: StatusScript = StatusScript([.init(nil, 0)])
    ) -> (ChatSessionChannelCoordinator, SessionChannelScriptedSSEClient, ScriptedSessionChannelDelegate, ManualPollClock) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            if request.url?.path == "/api/session/status" {
                return (response, status.next())
            }
            return (response, StatusScript.body(.init(nil, 0)))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
        let stream = SessionChannelScriptedSSEClient()
        let delegate = ScriptedSessionChannelDelegate()
        let clock = ManualPollClock()
        let coordinator = ChatSessionChannelCoordinator(
            client: client,
            streamClient: stream,
            isEnabled: isEnabled,
            pollInterval: { await clock.sleep() }
        )
        coordinator.delegate = delegate
        addTeardownBlock { @MainActor in
            // Let any parked poll or retry loop observe the stop and finish.
            coordinator.stopMonitoring()
            clock.advance()
            delegate.releaseReload()
        }
        return (coordinator, stream, delegate, clock)
    }

    /// Suspends until `condition` holds, re-checking only when the observed
    /// state it reads changes (no polling).
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    Task { @MainActor in continuation.resume() }
                }
            }
        }
    }
}

/// Scripted `/api/session/status` responses, served in order (the last repeats).
/// Called from URLProtocol's thread, so access is locked.
private final class StatusScript: @unchecked Sendable {
    struct Status {
        let activeStreamID: String?
        let messageCount: Int
        init(_ activeStreamID: String?, _ messageCount: Int) {
            self.activeStreamID = activeStreamID
            self.messageCount = messageCount
        }
    }

    private let lock = NSLock()
    private let responses: [Status]
    private var count = 0

    init(_ responses: [Status]) { self.responses = responses }

    var calls: Int { lock.withLock { count } }

    func next() -> Data {
        let status: Status = lock.withLock {
            let status = responses[min(count, responses.count - 1)]
            count += 1
            return status
        }
        return Self.body(status)
    }

    static func body(_ status: Status) -> Data {
        let active = status.activeStreamID.map { "\"\($0)\"" } ?? "null"
        return Data(#"{"session_id":"session-1","active_stream_id":\#(active),"is_streaming":\#(status.activeStreamID != nil),"message_count":\#(status.messageCount)}"#.utf8)
    }
}

/// Stands in for the coordinator's poll interval: each wait parks until the
/// test calls `advance()`.
@MainActor
private final class ManualPollClock {
    private(set) var sleeps = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, XCTestExpectation)] = []

    func sleep() async {
        sleeps += 1
        let reached = sleeps
        waiters.removeAll { target, expectation in
            guard reached >= target else { return false }
            expectation.fulfill()
            return true
        }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Fulfilled once the coordinator has started its `target`-th wait.
    func expectSleeps(_ target: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(target) poll waits")
        if sleeps >= target { expectation.fulfill() } else { waiters.append((target, expectation)) }
        return expectation
    }

    func advance() {
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class SessionChannelScriptedSSEClient: SSEStreamingClient {
    var lastEventID: String?
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var currentHandler: (@MainActor (SSEEvent) -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        currentHandler = onEvent
    }

    func stop() {
        stopCount += 1
        currentHandler = nil
    }

    func emit(_ event: SSEEvent) {
        currentHandler?(event)
    }
}

@MainActor
private final class ScriptedSessionChannelDelegate: ChatSessionChannelCoordinatorDelegate {
    var sessionChannelSessionID: String? = "session-1"
    var hasActiveStream = false
    var messageCount = 0
    var holdReload = false
    /// What the load reports: false simulates a failed transcript request.
    var reloadSucceeds = true
    /// Simulates a load that finds an active stream and attaches to it.
    var attachesOnReload = false
    /// Simulates a successful load that brings the transcript up to the server.
    var messageCountAfterReload: Int?
    private(set) var reloadReasons: [ChatSessionChannelChangeReason] = []
    private(set) var reloadStarts = 0
    private var release: CheckedContinuation<Void, Never>?
    private var reloadWaiters: [(Int, XCTestExpectation)] = []
    private var startWaiters: [(Int, XCTestExpectation)] = []

    var sessionChannelHasActiveStream: Bool { hasActiveStream }
    var sessionChannelKnownMessageCount: Int { messageCount }

    func sessionChannelDidDetectServerChange(reason: ChatSessionChannelChangeReason) async -> Bool {
        reloadStarts += 1
        Self.fulfill(&startWaiters, reached: reloadStarts)
        if holdReload {
            await withCheckedContinuation { release = $0 }
        }
        let succeeded = reloadSucceeds
        if succeeded {
            if attachesOnReload { hasActiveStream = true }
            if let messageCountAfterReload { messageCount = messageCountAfterReload }
        }
        reloadReasons.append(reason)
        Self.fulfill(&reloadWaiters, reached: reloadReasons.count)
        return succeeded
    }

    func releaseReload() {
        release?.resume()
        release = nil
    }

    /// Fulfilled once `count` reloads have finished in total.
    func expectReloads(_ count: Int) -> XCTestExpectation {
        Self.expectation(&reloadWaiters, target: count, current: reloadReasons.count, what: "reloads")
    }

    /// Fulfilled once `count` reloads have started in total.
    func expectReloadStarts(_ count: Int) -> XCTestExpectation {
        Self.expectation(&startWaiters, target: count, current: reloadStarts, what: "reload starts")
    }

    private static func expectation(
        _ waiters: inout [(Int, XCTestExpectation)], target: Int, current: Int, what: String
    ) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(target) \(what)")
        if current >= target { expectation.fulfill() } else { waiters.append((target, expectation)) }
        return expectation
    }

    private static func fulfill(_ waiters: inout [(Int, XCTestExpectation)], reached count: Int) {
        waiters.removeAll { target, expectation in
            guard count >= target else { return false }
            expectation.fulfill()
            return true
        }
    }
}

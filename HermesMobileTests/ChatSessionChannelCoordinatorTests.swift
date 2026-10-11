import XCTest
@testable import HermesMobile

/// The persistent per-session channel keeps an idle chat in step with turns it
/// did not start (#1208). These tests drive `ChatSessionChannelCoordinator`
/// through a scripted SSE client and a scripted `/api/session/status`.
@MainActor
final class ChatSessionChannelCoordinatorTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testOpensTheChannelForAnIdleChatWithKnownCount() {
        let (coordinator, stream, delegate) = makeCoordinator()
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
        let (coordinator, stream, delegate) = makeCoordinator()
        delegate.hasActiveStream = true

        coordinator.startMonitoringIfIdle()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertTrue(stream.startedURLs.isEmpty)
    }

    func testRepeatedStartKeepsTheExistingChannel() {
        let (coordinator, stream, delegate) = makeCoordinator()

        coordinator.startMonitoringIfIdle()
        coordinator.startMonitoringIfIdle()

        XCTAssertEqual(stream.startedURLs.count, 1)
        XCTAssertEqual(stream.stopCount, 0)
        withExtendedLifetime(delegate) {}
    }

    func testStopClosesTheChannel() {
        let (coordinator, stream, delegate) = makeCoordinator()
        coordinator.startMonitoringIfIdle()

        coordinator.stopMonitoring()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(stream.stopCount, 1)
        withExtendedLifetime(delegate) {}
    }

    func testDisabledPreferenceNeverOpens() {
        let (coordinator, stream, delegate) = makeCoordinator(isEnabled: false)

        coordinator.startMonitoringIfIdle()

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertTrue(stream.startedURLs.isEmpty)
        withExtendedLifetime(delegate) {}
    }

    func testTurningThePreferenceOffClosesAndOnReopens() {
        let (coordinator, stream, delegate) = makeCoordinator()
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
        let (coordinator, stream, delegate) = makeCoordinator()
        coordinator.startMonitoringIfIdle()

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "stream-9", source: "bg_task")))
        await delegate.waitForReload()

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.serverTurnStarted(streamID: "stream-9")])
    }

    func testSessionUpdatedReloadsOnlyWhenTheServerIsAhead() async {
        let (coordinator, stream, delegate) = makeCoordinator()
        delegate.messageCount = 10
        coordinator.startMonitoringIfIdle()

        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 10, knownCount: 10)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 9, knownCount: 10)))
        await Task.yield()
        XCTAssertTrue(delegate.reloadReasons.isEmpty, "equal or lower counts are not a change")

        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 12, knownCount: 10)))
        await delegate.waitForReload()

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.sessionUpdated(messageCount: 12)])
    }

    func testEventsForAnotherSessionAreIgnored() async {
        let (coordinator, stream, delegate) = makeCoordinator()
        coordinator.startMonitoringIfIdle()

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-OTHER", streamId: "s", source: nil)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-OTHER", messageCount: 99, knownCount: 0)))
        await Task.yield()

        XCTAssertTrue(delegate.reloadReasons.isEmpty)
    }

    func testEventsAfterStopAreIgnored() async {
        let (coordinator, stream, delegate) = makeCoordinator()
        coordinator.startMonitoringIfIdle()
        coordinator.stopMonitoring()

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "s", source: nil)))
        await Task.yield()

        XCTAssertTrue(delegate.reloadReasons.isEmpty)
    }

    func testBurstOfEventsCoalescesIntoOneReloadInFlight() async {
        let (coordinator, stream, delegate) = makeCoordinator()
        delegate.holdReload = true
        coordinator.startMonitoringIfIdle()

        stream.emit(.serverTurnStarted(ServerTurnStartedEvent(sessionId: "session-1", streamId: "s", source: nil)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 50, knownCount: 0)))
        stream.emit(.sessionUpdated(SessionUpdatedEvent(sessionId: "session-1", messageCount: 51, knownCount: 0)))
        await delegate.waitForReloadStart()
        delegate.releaseReload()
        await delegate.waitForReload()

        XCTAssertEqual(delegate.reloadReasons.count, 1)
    }

    // MARK: - Fallback polling

    func testDroppedChannelFallsBackToPollingAndReloadsOnNewActiveStream() async {
        var statusCalls = 0
        let activeStreamIDs: [String?] = [nil, nil, "stream-42", "stream-42"]
        let (coordinator, stream, delegate) = makeCoordinator(
            fallbackPollingIntervalNanoseconds: 20_000_000,
            statusHandler: { _ in
                defer { statusCalls += 1 }
                let active = activeStreamIDs[min(statusCalls, activeStreamIDs.count - 1)]
                return Self.statusBody(activeStreamID: active, messageCount: 3)
            }
        )
        delegate.messageCount = 3
        coordinator.startMonitoringIfIdle()

        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))
        await delegate.waitForReload(timeout: 3)

        XCTAssertTrue(coordinator.isFallbackPolling)
        XCTAssertEqual(stream.stopCount, 1, "the dropped SSE client is stopped before polling starts")
        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.polled])
        XCTAssertGreaterThanOrEqual(statusCalls, 3)
    }

    func testFallbackPollingReloadsWhenTheMessageCountGrows() async {
        var statusCalls = 0
        let (coordinator, stream, delegate) = makeCoordinator(
            fallbackPollingIntervalNanoseconds: 20_000_000,
            statusHandler: { _ in
                defer { statusCalls += 1 }
                return Self.statusBody(activeStreamID: nil, messageCount: statusCalls < 2 ? 3 : 5)
            }
        )
        delegate.messageCount = 3
        coordinator.startMonitoringIfIdle()

        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))
        await delegate.waitForReload(timeout: 3)

        XCTAssertEqual(delegate.reloadReasons, [ChatSessionChannelChangeReason.polled])
    }

    func testFallbackPollingStopsWhenAStreamOfItsOwnStarts() async {
        var statusCalls = 0
        let (coordinator, stream, delegate) = makeCoordinator(
            fallbackPollingIntervalNanoseconds: 10_000_000,
            statusHandler: { _ in
                statusCalls += 1
                return Self.statusBody(activeStreamID: nil, messageCount: 3)
            }
        )
        delegate.messageCount = 3
        coordinator.startMonitoringIfIdle()
        stream.emit(.heartbeat)
        stream.emit(.transportError("socket reset"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(statusCalls, 0)

        delegate.hasActiveStream = true
        try? await Task.sleep(nanoseconds: 50_000_000)
        let callsWhenStreamStarted = statusCalls
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(statusCalls, callsWhenStreamStarted, "polling ends once the chat streams a turn of its own")
    }

    func testChannelThatNeverOpenedDoesNotPoll() async {
        var statusCalls = 0
        let (coordinator, stream, delegate) = makeCoordinator(
            fallbackPollingIntervalNanoseconds: 10_000_000,
            statusHandler: { _ in
                statusCalls += 1
                return Self.statusBody(activeStreamID: nil, messageCount: 0)
            }
        )
        coordinator.startMonitoringIfIdle()

        // An older server (no /api/session/stream) fails the request outright.
        stream.emit(.transportError("404"))
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertFalse(coordinator.isFallbackPolling)
        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertEqual(statusCalls, 0, "no polling against a server that never opened the channel")
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
        fallbackPollingIntervalNanoseconds: UInt64 = 5_000_000_000,
        statusHandler: ((URLRequest) throws -> Data)? = nil
    ) -> (ChatSessionChannelCoordinator, SessionChannelScriptedSSEClient, ScriptedSessionChannelDelegate) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            if let statusHandler, request.url?.path == "/api/session/status" {
                return (response, try statusHandler(request))
            }
            return (response, Self.statusBody(activeStreamID: nil, messageCount: 0))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
        let stream = SessionChannelScriptedSSEClient()
        let delegate = ScriptedSessionChannelDelegate()
        let coordinator = ChatSessionChannelCoordinator(
            client: client,
            streamClient: stream,
            fallbackPollingIntervalNanoseconds: fallbackPollingIntervalNanoseconds,
            isEnabled: isEnabled
        )
        coordinator.delegate = delegate
        return (coordinator, stream, delegate)
    }

    private static func statusBody(activeStreamID: String?, messageCount: Int) -> Data {
        let active = activeStreamID.map { "\"\($0)\"" } ?? "null"
        return Data(#"{"session_id":"session-1","active_stream_id":\#(active),"is_streaming":\#(activeStreamID != nil),"message_count":\#(messageCount)}"#.utf8)
    }
}

@MainActor
private final class SessionChannelScriptedSSEClient: SSEStreamingClient {
    var lastEventID: String?
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
        onEvent = nil
    }

    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class ScriptedSessionChannelDelegate: ChatSessionChannelCoordinatorDelegate {
    var sessionChannelSessionID: String? = "session-1"
    var hasActiveStream = false
    var messageCount = 0
    var holdReload = false
    private(set) var reloadReasons: [ChatSessionChannelChangeReason] = []
    private var reloadStarted = 0
    private var release: CheckedContinuation<Void, Never>?

    var sessionChannelHasActiveStream: Bool { hasActiveStream }
    var sessionChannelKnownMessageCount: Int { messageCount }

    func sessionChannelDidDetectServerChange(reason: ChatSessionChannelChangeReason) async {
        reloadStarted += 1
        if holdReload {
            await withCheckedContinuation { release = $0 }
        }
        reloadReasons.append(reason)
    }

    func releaseReload() {
        release?.resume()
        release = nil
    }

    func waitForReloadStart(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while reloadStarted == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func waitForReload(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        let target = reloadReasons.count + 1
        while reloadReasons.count < target, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

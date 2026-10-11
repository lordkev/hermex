import Foundation
import Observation
import OSLog

private let chatSessionChannelCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatSessionChannelCoordinator"
)

/// Preference for the persistent per-session channel (#1208).
enum ChatSessionChannelPreference {
    /// `UserDefaults` key for the Settings toggle. On by default: an idle chat
    /// learns about turns it did not start (background-job notifications, cron,
    /// another client) instead of showing them on the next send.
    static let liveSessionUpdatesKey = "liveSessionUpdatesEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: liveSessionUpdatesKey) as? Bool ?? true
    }
}

@MainActor
protocol ChatSessionChannelCoordinatorDelegate: AnyObject {
    /// The open chat's webui session, or nil for a chat with no session yet.
    var sessionChannelSessionID: String? { get }
    /// Whether the chat is streaming a turn of its own. The channel stays
    /// closed meanwhile: `chat/stream` already carries everything.
    var sessionChannelHasActiveStream: Bool { get }
    /// How many messages the chat currently shows; sent as `known_count` so the
    /// server can tell when a turn started and finished entirely while this
    /// client was disconnected.
    var sessionChannelKnownMessageCount: Int { get }

    /// The session changed on the server. The delegate reloads it; a load that
    /// finds an active stream attaches to it the same way a chat that opens
    /// mid-turn does.
    func sessionChannelDidDetectServerChange(reason: ChatSessionChannelChangeReason) async
}

enum ChatSessionChannelChangeReason: Equatable {
    /// `server_turn_started`: a turn this client did not start is running.
    case serverTurnStarted(streamID: String)
    /// `session-updated`: the server holds more messages than this client.
    case sessionUpdated(messageCount: Int)
    /// The fallback poller saw a new active stream or a higher message count.
    case polled
}

/// Keeps an idle chat in step with its session on the server through the
/// webui's persistent per-session SSE channel, `GET /api/session/stream`
/// (hermes-webui ≥ v0.51.340). Unlike `chat/stream`, which exists only for the
/// duration of one turn, the channel lives across turns and carries
/// `server_turn_started` and `session-updated` — the two ways a session changes
/// without this client asking for it (#1208).
///
/// Mirrors `ChatPendingActionCoordinator`: one SSE client, a session-scoped
/// monitoring id, and a fallback poll of `/api/session/status` when the socket
/// drops (`.transportError`, which `SSEClient` reports since #1205).
@MainActor
@Observable
final class ChatSessionChannelCoordinator {
    weak var delegate: ChatSessionChannelCoordinatorDelegate?

    private let client: APIClient
    private let streamClient: SSEStreamingClient
    private let fallbackPollingIntervalNanoseconds: UInt64
    private var isEnabled: Bool

    private(set) var monitoringSessionID: String?
    /// Whether the server has acknowledged the current subscription (its
    /// `initial` frame or a keepalive). A channel that drops after that is a
    /// lost socket worth polling through; one that never opens is a server
    /// without the endpoint (hermes-webui < v0.51.340) and is left alone.
    private(set) var channelWasOpen = false
    @ObservationIgnored private var fallbackPollingTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// What the fallback poller last saw, so it reloads once per change.
    private var lastPolledActiveStreamID: String?
    private var lastPolledMessageCount: Int?

    var isMonitoring: Bool { monitoringSessionID != nil }
    var isFallbackPolling: Bool { fallbackPollingTask != nil }

    init(
        client: APIClient,
        streamClient: SSEStreamingClient,
        fallbackPollingIntervalNanoseconds: UInt64 = 5_000_000_000,
        isEnabled: Bool = ChatSessionChannelPreference.isEnabled()
    ) {
        self.client = client
        self.streamClient = streamClient
        self.fallbackPollingIntervalNanoseconds = fallbackPollingIntervalNanoseconds
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            startMonitoringIfIdle()
        } else {
            stopMonitoring()
        }
    }

    /// Opens the channel for the delegate's session when the chat is idle.
    /// Safe to call repeatedly: a channel already open for that session is kept.
    func startMonitoringIfIdle() {
        guard isEnabled,
              let sessionID = delegate?.sessionChannelSessionID,
              delegate?.sessionChannelHasActiveStream != true
        else { return }
        guard monitoringSessionID != sessionID else { return }

        stopMonitoring()
        monitoringSessionID = sessionID
        let knownCount = delegate?.sessionChannelKnownMessageCount ?? 0
        streamClient.start(url: client.sessionStreamURL(sessionID: sessionID, knownCount: knownCount)) { [weak self] event in
            self?.handleEvent(event, sessionID: sessionID)
        }
    }

    /// Closes the channel. Called when a turn of this client's own starts (the
    /// turn's `chat/stream` takes over) and when the chat leaves the screen.
    func stopMonitoring() {
        let hadChannel = monitoringSessionID != nil || fallbackPollingTask != nil
        fallbackPollingTask?.cancel()
        fallbackPollingTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        if hadChannel {
            streamClient.stop()
        }
        monitoringSessionID = nil
        channelWasOpen = false
        lastPolledActiveStreamID = nil
        lastPolledMessageCount = nil
    }

    private func handleEvent(_ event: SSEEvent, sessionID: String) {
        guard monitoringSessionID == sessionID else { return }
        switch event {
        case .approvalPending, .heartbeat:
            // The channel's `initial` frame decodes through the shared pending-prompt
            // path; it and every keepalive prove the subscription is live.
            channelWasOpen = true
        case .serverTurnStarted(let payload):
            channelWasOpen = true
            guard payload.sessionId == nil || payload.sessionId == sessionID else { return }
            chatSessionChannelCoordinatorLogger.info("server_turn_started for the open session")
            scheduleReload(.serverTurnStarted(streamID: payload.streamId ?? ""))
        case .sessionUpdated(let payload):
            channelWasOpen = true
            guard payload.sessionId == nil || payload.sessionId == sessionID else { return }
            let serverCount = payload.messageCount ?? 0
            let localCount = delegate?.sessionChannelKnownMessageCount ?? 0
            guard serverCount > localCount else { return }
            chatSessionChannelCoordinatorLogger.info("session-updated: server ahead by \(serverCount - localCount, privacy: .public)")
            scheduleReload(.sessionUpdated(messageCount: serverCount))
        case .transportError, .error:
            guard channelWasOpen else {
                // Never opened: an older server, a proxy that rejects the path, or
                // a test double. Nothing to recover; stay quiet rather than poll.
                chatSessionChannelCoordinatorLogger.info("session channel unavailable; not polling")
                streamClient.stop()
                monitoringSessionID = nil
                return
            }
            startFallbackPolling(sessionID: sessionID)
        case .token, .interimAssistant, .reasoning, .toolStarted, .toolCompleted, .title, .metering, .done,
             .clarificationPending, .pendingSteerLeftover, .streamEnd, .cancelled, .ignored:
            break
        }
    }

    /// One reload at a time: a `server_turn_started` closely followed by its
    /// `session-updated` (or a burst of polls) coalesces into the load in flight.
    private func scheduleReload(_ reason: ChatSessionChannelChangeReason) {
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await self?.delegate?.sessionChannelDidDetectServerChange(reason: reason)
            self?.reloadTask = nil
        }
    }

    private func startFallbackPolling(sessionID: String) {
        guard monitoringSessionID == sessionID else { return }
        streamClient.stop()
        fallbackPollingTask?.cancel()
        let interval = fallbackPollingIntervalNanoseconds
        chatSessionChannelCoordinatorLogger.info("session channel dropped; polling /api/session/status")
        fallbackPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.delegate?.sessionChannelSessionID == sessionID,
                      self.delegate?.sessionChannelHasActiveStream != true
                else { break }
                await self.pollOnce(sessionID: sessionID)
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func pollOnce(sessionID: String) async {
        do {
            let status = try await client.sessionStatus(id: sessionID)
            guard !Task.isCancelled, monitoringSessionID == sessionID else { return }
            let activeStreamID = status.activeStreamId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedActive = (activeStreamID?.isEmpty == false) ? activeStreamID : nil
            let messageCount = status.messageCount
            let localCount = delegate?.sessionChannelKnownMessageCount ?? 0
            let newStream = normalizedActive != nil && normalizedActive != lastPolledActiveStreamID
            let moreMessages = (messageCount ?? 0) > localCount && messageCount != lastPolledMessageCount
            lastPolledActiveStreamID = normalizedActive
            lastPolledMessageCount = messageCount
            if newStream || moreMessages {
                scheduleReload(.polled)
            }
        } catch {
            chatSessionChannelCoordinatorLogger.debug(
                "session status poll failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }
}

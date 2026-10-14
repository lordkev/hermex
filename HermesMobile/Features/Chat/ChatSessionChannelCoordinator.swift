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
    /// How many of the chat's messages exist on the server — local-only rows
    /// (slash-command output, notices) excluded. Sent as `known_count` so the
    /// server can tell when a turn started and finished entirely while this
    /// client was disconnected, and compared with the server's count on every
    /// event and poll.
    var sessionChannelKnownMessageCount: Int { get }

    /// The session changed on the server. The delegate reloads it; a load that
    /// finds an active stream attaches to it the same way a chat that opens
    /// mid-turn does. A failed load needs no reporting: the poller compares
    /// counts again on its next tick and the channel's next event re-triggers.
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
    /// lost socket worth polling through.
    private(set) var channelWasOpen = false
    /// Sticky for this chat's server: some subscription has opened before, so
    /// the endpoint exists. A later channel that fails before its first frame
    /// is a dropped network, not an older server, and is polled through too.
    /// Until then a never-opened channel is treated as unsupported
    /// (hermes-webui < v0.51.340) and only retried on a connectivity change.
    private(set) var serverSupportsChannel = false
    @ObservationIgnored private var fallbackPollingTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// Another change arrived while a reload was in flight; run one more after it.
    @ObservationIgnored private var reloadPending = false
    /// Identifies the current reload loop. `stopMonitoring` releases a reload
    /// without cancelling it — a cancelled transcript request would surface as a
    /// load error — and the bumped token stops it from looping on or clearing a
    /// newer one. The delegate discards a stale result itself.
    @ObservationIgnored private var reloadToken = 0

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
    /// Safe to call repeatedly: a channel (or fallback poll) already running for
    /// that session is kept.
    func startMonitoringIfIdle() {
        guard isEnabled,
              let sessionID = delegate?.sessionChannelSessionID,
              delegate?.sessionChannelHasActiveStream != true
        else { return }
        guard monitoringSessionID != sessionID else { return }
        openChannel(sessionID: sessionID)
    }

    /// The network path changed: reopen the channel, replacing a fallback poll
    /// or retrying a subscription that failed before its first frame.
    func reconnectIfIdle() {
        guard isEnabled,
              let sessionID = delegate?.sessionChannelSessionID,
              delegate?.sessionChannelHasActiveStream != true
        else { return }
        guard monitoringSessionID != sessionID || isFallbackPolling else { return }
        openChannel(sessionID: sessionID)
    }

    private func openChannel(sessionID: String) {
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
        reloadToken += 1
        reloadTask = nil
        reloadPending = false
        if hadChannel {
            streamClient.stop()
        }
        monitoringSessionID = nil
        channelWasOpen = false
    }

    private func handleEvent(_ event: SSEEvent, sessionID: String) {
        guard monitoringSessionID == sessionID else { return }
        switch event {
        case .approvalPending, .clarificationPending, .heartbeat:
            // The channel's `initial` frame decodes through the shared pending-prompt
            // path (as an approval or a clarify prompt, depending on what is
            // pending); it and every keepalive prove the subscription is live.
            markOpen()
        case .serverTurnStarted(let payload):
            markOpen()
            guard payload.sessionId == nil || payload.sessionId == sessionID else { return }
            chatSessionChannelCoordinatorLogger.info("server_turn_started for the open session")
            scheduleReload(.serverTurnStarted(streamID: payload.streamId ?? ""))
        case .sessionUpdated(let payload):
            markOpen()
            guard payload.sessionId == nil || payload.sessionId == sessionID else { return }
            let serverCount = payload.messageCount ?? 0
            let localCount = delegate?.sessionChannelKnownMessageCount ?? 0
            guard serverCount > localCount else { return }
            chatSessionChannelCoordinatorLogger.info("session-updated: server ahead by \(serverCount - localCount, privacy: .public)")
            scheduleReload(.sessionUpdated(messageCount: serverCount))
        case .transportError, .error:
            guard channelWasOpen || serverSupportsChannel else {
                // Never opened on a server that has never opened one: an older
                // server, a proxy that rejects the path, or a network that dropped
                // before the first frame. Stay quiet rather than poll; a
                // connectivity change retries (`reconnectIfIdle`).
                chatSessionChannelCoordinatorLogger.info("session channel unavailable; not polling")
                streamClient.stop()
                monitoringSessionID = nil
                return
            }
            startFallbackPolling(sessionID: sessionID)
        case .token, .interimAssistant, .reasoning, .toolStarted, .toolCompleted, .title, .metering, .done,
             .pendingSteerLeftover, .streamEnd, .cancelled, .ignored:
            break
        }
    }

    private func markOpen() {
        channelWasOpen = true
        serverSupportsChannel = true
    }

    /// One reload at a time. A change that arrives while one is in flight —
    /// a `server_turn_started` closely followed by its `session-updated`, or a
    /// second turn finishing — is not dropped: it runs one more reload after
    /// the current one, since the load in flight may have read the older
    /// transcript.
    private func scheduleReload(_ reason: ChatSessionChannelChangeReason) {
        guard reloadTask == nil else {
            reloadPending = true
            return
        }
        let token = reloadToken
        reloadTask = Task { @MainActor [weak self] in
            var reason = reason
            while let self, self.reloadToken == token {
                self.reloadPending = false
                await self.delegate?.sessionChannelDidDetectServerChange(reason: reason)
                guard self.reloadToken == token, self.reloadPending else { break }
                reason = .polled
            }
            guard let self, self.reloadToken == token else { return }
            self.reloadTask = nil
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
            // The loop ends when the chat's own turn takes over or the chat moves
            // to another session. Release the session so the next
            // `startMonitoringIfIdle` (stream finished, transcript reloaded)
            // opens a fresh channel instead of finding a dead one.
            guard let self, !Task.isCancelled, self.monitoringSessionID == sessionID else { return }
            self.fallbackPollingTask = nil
            self.monitoringSessionID = nil
            self.channelWasOpen = false
        }
    }

    /// Stateless on purpose: every tick compares the server with what the chat
    /// shows, so a reload that failed is simply retried on the next tick.
    private func pollOnce(sessionID: String) async {
        do {
            let status = try await client.sessionStatus(id: sessionID)
            guard !Task.isCancelled, monitoringSessionID == sessionID else { return }
            let activeStreamID = status.activeStreamId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverIsStreaming = activeStreamID?.isEmpty == false
            let localCount = delegate?.sessionChannelKnownMessageCount ?? 0
            let moreMessages = (status.messageCount ?? 0) > localCount
            // A running turn the chat isn't attached to: the reload attaches to it
            // and the chat's own stream takes over, which ends this loop.
            if serverIsStreaming || moreMessages {
                scheduleReload(.polled)
            }
        } catch {
            chatSessionChannelCoordinatorLogger.debug(
                "session status poll failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }
}

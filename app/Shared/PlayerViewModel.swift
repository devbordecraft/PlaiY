import Foundation
import Combine
import CoreGraphics
import QuartzCore

private enum PlexTimelineState: String {
    case stopped
    case paused
    case playing
}

private struct PlexMetadataSnapshot: Sendable {
    let viewOffsetMs: Int64
    let viewCount: Int
    let introMarker: PlexMarker?
}

private enum PlexMetadataRefreshResult: Sendable {
    case success(PlexMetadataSnapshot)
    case unauthorized
    case failure
}

private enum PlexSyncRequestStatus: Sendable {
    case success
    case unauthorized
    case failure
}

private actor PlexSyncSession {
    private enum PlexSyncError: Error {
        case unauthorized
        case badResponse
    }

    private let context: PlexPlaybackContext
    private let token: String
    private let clientIdentifier: String
    private let sessionIdentifier = UUID().uuidString
    private let session: URLSession

    init?(context: PlexPlaybackContext) {
        guard !context.authToken.isEmpty else {
            return nil
        }

        self.context = context
        self.token = context.authToken
        self.clientIdentifier = Self.sharedClientIdentifier()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func refreshMetadata() async -> PlexMetadataRefreshResult {
        let json: [String: Any]
        do {
            json = try await requestJSON(
                path: context.key,
                method: "GET",
                queryItems: []
            )
        } catch PlexSyncError.unauthorized {
            return .unauthorized
        } catch {
            return .failure
        }

        guard let mediaContainer = json["MediaContainer"] as? [String: Any],
              let metadata = mediaContainer["Metadata"] as? [[String: Any]],
              let item = metadata.first else {
            return .failure
        }

        let viewOffsetMs = Self.int64Value(item["viewOffset"])
        let viewCount = Self.intValue(item["viewCount"])
        let introMarker = parseMarkers(item: item, mediaContainer: mediaContainer)
            .first(where: { $0.type.caseInsensitiveCompare("intro") == .orderedSame })

        return .success(PlexMetadataSnapshot(
            viewOffsetMs: viewOffsetMs,
            viewCount: viewCount,
            introMarker: introMarker
        ))
    }

    func reportTimeline(state: PlexTimelineState,
                        positionUs: Int64,
                        durationUs: Int64,
                        continuing: Bool = false) async -> PlexSyncRequestStatus {
        let queryItems = [
            URLQueryItem(name: "key", value: context.key),
            URLQueryItem(name: "ratingKey", value: context.ratingKey),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(max(0, positionUs / 1_000))),
            URLQueryItem(name: "duration", value: String(max(0, durationUs / 1_000))),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "continuing", value: continuing ? "1" : "0")
        ]

        do {
            try await send(path: "/:/timeline", method: "POST", queryItems: queryItems)
            return .success
        } catch PlexSyncError.unauthorized {
            return .unauthorized
        } catch {
            return .failure
        }
    }

    func scrobble() async -> PlexSyncRequestStatus {
        let queryItems = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: context.ratingKey)
        ]

        do {
            try await send(path: "/:/scrobble", method: "PUT", queryItems: queryItems)
            return .success
        } catch PlexSyncError.unauthorized {
            return .unauthorized
        } catch {
            return .failure
        }
    }

    private func send(path: String,
                      method: String,
                      queryItems: [URLQueryItem]) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexSyncError.badResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PlexSyncError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw PlexSyncError.badResponse
        }
    }

    private func requestJSON(path: String,
                             method: String,
                             queryItems: [URLQueryItem]) async throws -> [String: Any] {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexSyncError.badResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PlexSyncError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw PlexSyncError.badResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    private func makeRequest(path: String,
                             method: String,
                             queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(string: context.serverBaseURL + path) else {
            throw URLError(.badURL)
        }

        var mergedQueryItems = components.queryItems ?? []
        mergedQueryItems.append(contentsOf: queryItems)
        components.queryItems = mergedQueryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("PlaiY", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("1.0", forHTTPHeaderField: "X-Plex-Version")
        request.setValue(Self.platformName, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(sessionIdentifier, forHTTPHeaderField: "X-Plex-Session-Identifier")
        return request
    }

    private func parseMarkers(item: [String: Any],
                              mediaContainer: [String: Any]) -> [PlexMarker] {
        let markerArrays: [[Any]] = [
            item["Marker"] as? [Any],
            item["Markers"] as? [Any],
            mediaContainer["Marker"] as? [Any],
            mediaContainer["Markers"] as? [Any]
        ].compactMap { $0 }

        for markerArray in markerArrays {
            let markers = markerArray.compactMap(Self.parseMarker)
            if !markers.isEmpty {
                return markers
            }
        }
        return []
    }

    private static func parseMarker(_ value: Any) -> PlexMarker? {
        guard let marker = value as? [String: Any] else { return nil }

        let id = stringValue(marker["id"])
        let type = stringValue(marker["type"])
        let start = int64Value(marker["startTimeOffset"], fallback: int64Value(marker["start"]))
        let end = int64Value(marker["endTimeOffset"], fallback: int64Value(marker["end"]))

        guard !id.isEmpty, !type.isEmpty, end > start else { return nil }
        return PlexMarker(id: id, type: type, startTimeOffsetMs: start, endTimeOffsetMs: end)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let stringValue = value as? String, let intValue = Int(stringValue) { return intValue }
        return 0
    }

    private static func int64Value(_ value: Any?, fallback: Int64 = 0) -> Int64 {
        if let intValue = value as? Int64 { return intValue }
        if let intValue = value as? Int { return Int64(intValue) }
        if let stringValue = value as? String, let intValue = Int64(stringValue) { return intValue }
        return fallback
    }

    private static func stringValue(_ value: Any?) -> String {
        if let stringValue = value as? String { return stringValue }
        if let intValue = value as? Int { return String(intValue) }
        if let intValue = value as? Int64 { return String(intValue) }
        return ""
    }

    private static func sharedClientIdentifier() -> String {
        let key = "plexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }
}

// ---------------------------------------------------------------------------
// PlaybackTransport: high-frequency state that must NOT trigger SwiftUI
// objectWillChange. Views that need these values poll via their own timers.
// This is the key to preventing UI interactions from dropping video frames.
// ---------------------------------------------------------------------------
@MainActor
final class PlaybackTransport {
    // Written by tick(), read by controls/subtitle views
    var currentPosition: Int64 = 0 {
        didSet {
            // Only reformat when the displayed second changes
            let newSec = Int(currentPosition / 1_000_000)
            if newSec != cachedPositionSec {
                cachedPositionSec = newSec
                cachedPositionText = formatTime(currentPosition)
            }
        }
    }
    var duration: Int64 = 0 {
        didSet { cachedDurationText = formatTime(duration) }
    }
    var currentSubtitle: SubtitleData?
    var passthroughActive: Bool = false
    var spatialActive: Bool = false
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var videoSARNum: Int = 1
    var videoSARDen: Int = 1
    nonisolated(unsafe) var isHDRContent: Bool = false
    var playbackStats: PYPlaybackStats?

    // Display settings (aspect ratio, crop, zoom, pan)
    // Accessed from both main thread and Metal render thread.
    nonisolated(unsafe) var displaySettings: VideoDisplaySettings = .default
    nonisolated(unsafe) var pendingCropDetection = false
    nonisolated(unsafe) var onCropDetected: (@Sendable (CropInsets) -> Void)?

    // Written by PlayerViewModel, read by MetalViewCoordinator to manage display link rate
    nonisolated(unsafe) var isPlaying: Bool = false

    // Seek preview (written on MainActor via DispatchQueue.main.async, read by controls view)
    var seekPreviewImage: CGImage?

    // Interaction flags (written by controls, read by auto-hide timer)
    var isHoveringTimeline = false
    var isDraggingTimeline = false
    var isHoveringVolume = false
    var isHoveringControls = false
    var hoverFraction: Double = 0

    var isUserInteracting: Bool {
        isHoveringTimeline || isDraggingTimeline || isHoveringVolume || isHoveringControls
    }

    /// True only when the user is actively dragging the timeline.
    /// Used by tick() to avoid overwriting the scrub position.
    var isScrubbing: Bool {
        isDraggingTimeline
    }

    var positionFraction: Double {
        guard duration > 0 else { return 0 }
        return Double(currentPosition) / Double(duration)
    }

    func formatTime(_ us: Int64) -> String {
        TimeFormatting.display(us)
    }

    // Cached text — only reformatted when the second changes
    private var cachedPositionSec: Int = -1
    private(set) var cachedPositionText: String = "0:00"
    private(set) var cachedDurationText: String = "0:00"
    var positionText: String { cachedPositionText }
    var durationText: String { cachedDurationText }
}

// ---------------------------------------------------------------------------
// PlayerViewModel: only @Published properties that genuinely need to rebuild
// the SwiftUI view tree. High-frequency data lives in `transport`.
// ---------------------------------------------------------------------------
@MainActor
class PlayerViewModel: ObservableObject {
    private struct PendingOpenContext {
        let item: PlaybackItem
        let settings: AppSettings
        let onNextTrack: (() -> Void)?
        let onPreviousTrack: (() -> Void)?
    }

    let bridge: any PlayerBridgeProtocol
    let transport = PlaybackTransport()
    private var playbackState = Int32(PY_STATE_IDLE.rawValue)

    /// Concrete bridge for views that need frame-level access (Metal rendering, controls).
    /// Force-unwraps because production code always uses PlayerBridge.
    var playerBridge: PlayerBridge { bridge as! PlayerBridge }

    init(bridge: any PlayerBridgeProtocol = PlayerBridge()) {
        self.bridge = bridge
        bridge.setStateCallback { [weak self] state in
            if Thread.isMainThread {
                MainActor.assumeIsolated { [weak self] in
                    self?.applyPlaybackState(state)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.applyPlaybackState(state)
                }
            }
        }
    }

    // --- Properties that trigger view rebuilds (infrequent changes) ---
    @Published var isPlaying = false
    @Published var mediaTitle: String = ""
    @Published var audioTracks: [TrackInfo] = []
    @Published var subtitleTracks: [TrackInfo] = []
    @Published var activeAudioStream: Int = -1
    @Published var activeSubtitleStream: Int = -1
    @Published var isMuted = false
    // volume is NOT @Published — slider drag must not fire objectWillChange.
    // VolumeControlView uses local @State and reads this directly.
    var volume: Float = 1.0
    private var preMuteVolume: Float = 1.0
    @Published var playbackSpeed: Double = 1.0
    @Published var passthroughEnabled = false
    @Published var passthroughCaps = PYPassthroughCapabilities(ac3: false, eac3: false, dts: false, dts_hd_ma: false, truehd: false)
    @Published var headTrackingEnabled = false
    @Published var showDebugOverlay = false
    @Published var playbackEnded = false
    @Published var aspectRatioMode: AspectRatioMode = .auto
    @Published var cropActive: Bool = false
    @Published var openError: String?
    @Published var isDolbyVision = false
    @Published var showSkipIntro = false
    @Published var isPreparingPlayback = false
    @Published var prepareStatusText = "Opening media..."

    // NOT @Published — ContentView reads this in one-shot closures (onBack, playbackEnded),
    // not in body. Avoiding @Published prevents once-per-second PlayerView rebuilds.
    var currentPosition: Int64 = 0
    var currentPlaybackItem: PlaybackItem?
    var duration: Int64 {
        get { transport.duration }
        set { transport.duration = newValue }
    }

    // Throttles for expensive per-frame operations
    private var lastNowPlayingUpdate: CFTimeInterval = 0
    private var lastSubtitleUpdate: CFTimeInterval = 0
    private var lastPlexTimelineUpdate: CFTimeInterval = 0

    // Thumbnail async loading
    private let thumbQueue = DispatchQueue(label: "com.plaiy.seekthumb", qos: .userInitiated)
    private var thumbRequestId: UInt64 = 0
    private var lastThumbIndex: Int = -1
    private var thumbRetryWork: DispatchWorkItem?
    private let thumbRetryDelay: TimeInterval = 0.12

    private var pendingSeekFraction: Double?
    private var hoverEndWork: DispatchWorkItem?
    private var plexSync: PlexSyncSession?
    private var plexSyncHealthy = false
    private var plexIntroMarker: PlexMarker?
    private var onPlexAuthInvalid: ((String) -> Void)?
    private var plexSessionGeneration: UInt64 = 0
    private var pendingOpenContext: PendingOpenContext?
    private var deferredPlayOnReady = false
    private var openRequestID: UInt64 = 0
    private var openTask: Task<Void, Never>?
    private var openBridgeCallPending = false

    var shouldPersistLocalResumeFallback: Bool {
        guard currentPlaybackItem?.isPlex == true else { return true }
        return !plexSyncHealthy
    }

    private func applyPlaybackState(_ state: Int32) {
        playbackState = state

        let playing = state == Int32(PY_STATE_PLAYING.rawValue)
        isPlaying = playing
        transport.isPlaying = playing
        isPreparingPlayback = state == Int32(PY_STATE_OPENING.rawValue) ||
            state == Int32(PY_STATE_BUFFERING.rawValue)

        if state == Int32(PY_STATE_OPENING.rawValue) {
            prepareStatusText = "Opening media..."
        } else if state == Int32(PY_STATE_BUFFERING.rawValue) {
            prepareStatusText = currentPlaybackItem?.isPlex == true
                ? currentPlexBufferMode().statusText
                : "Buffering media..."
        }

        if state != Int32(PY_STATE_STOPPED.rawValue) {
            playbackEnded = false
        }
        if state == Int32(PY_STATE_STOPPED.rawValue) {
            playbackEnded = true
        }

        if state == Int32(PY_STATE_READY.rawValue) {
            if openBridgeCallPending { return }
            finishPendingOpenIfNeeded()
        } else if state == Int32(PY_STATE_IDLE.rawValue), pendingOpenContext != nil {
            if openBridgeCallPending { return }
            failPendingOpen()
        }
    }

    private func currentPlexBufferMode() -> PlexBufferMode {
        guard let settings = pendingOpenContext?.settings else { return .disk }
        return settings.plexBufferMode
    }

    private func configureRemoteBuffering(for item: PlaybackItem, settings: AppSettings) {
        if item.isPlex {
            bridge.setRemoteSourceKind(Int32(PY_REMOTE_SOURCE_PLEX.rawValue))
            bridge.setRemoteBufferMode(Int32(settings.plexBufferMode.rawValue))
            bridge.setRemoteBufferProfile(Int32(settings.plexBufferProfile.rawValue))
        } else {
            bridge.setRemoteSourceKind(Int32(PY_REMOTE_SOURCE_NONE.rawValue))
            bridge.setRemoteBufferMode(Int32(PY_REMOTE_BUFFER_OFF.rawValue))
            bridge.setRemoteBufferProfile(Int32(PY_REMOTE_BUFFER_BALANCED.rawValue))
        }
    }

    private func failPendingOpen() {
        let fallback = "Could not open: \(pendingOpenContext?.item.displayName ?? mediaTitle)"
        let message = bridge.lastErrorMessage()
        openError = message.isEmpty ? fallback : message
        mediaTitle = ""
        audioTracks = []
        subtitleTracks = []
        pendingOpenContext = nil
        deferredPlayOnReady = false
        isPreparingPlayback = false
    }

    private func cancelPendingThumbnailRequest() {
        thumbRequestId &+= 1
        lastThumbIndex = -1
        thumbRetryWork?.cancel()
        thumbRetryWork = nil
    }

    private func resetPlexState(advanceGeneration: Bool = true) {
        if advanceGeneration {
            plexSessionGeneration &+= 1
        }
        plexSync = nil
        plexSyncHealthy = false
        plexIntroMarker = nil
        showSkipIntro = false
        lastPlexTimelineUpdate = 0
    }

    private func isActivePlexSession(generation: UInt64, itemID: String) -> Bool {
        plexSessionGeneration == generation && currentPlaybackItem?.id == itemID
    }

    private func configurePlexSync(for item: PlaybackItem) {
        resetPlexState(advanceGeneration: false)
        let sessionGeneration = plexSessionGeneration

        guard let context = item.plexContext,
              let session = PlexSyncSession(context: context) else {
            if let context = item.plexContext, context.authToken.isEmpty {
                onPlexAuthInvalid?(context.sourceId)
            }
            return
        }

        plexSync = session
        plexSyncHealthy = true

        Task { [weak self] in
            guard let self else { return }
            let snapshotResult = await session.refreshMetadata()
            await MainActor.run {
                guard self.isActivePlexSession(generation: sessionGeneration, itemID: item.id) else { return }
                switch snapshotResult {
                case .success(let snapshot):
                    self.plexSyncHealthy = true
                    self.plexIntroMarker = snapshot.introMarker
                    self.updateSkipIntroVisibility(for: self.currentPosition)
                case .unauthorized:
                    self.plexSyncHealthy = false
                    self.onPlexAuthInvalid?(context.sourceId)
                case .failure:
                    self.plexSyncHealthy = false
                }
            }
        }
    }

    private func updateSkipIntroVisibility(for positionUs: Int64) {
        updateSkipIntroVisibility(for: positionUs, deferPublishedUpdate: false)
    }

    private func updateSkipIntroVisibility(for positionUs: Int64,
                                           deferPublishedUpdate: Bool) {
        let visible: Bool
        if let marker = plexIntroMarker {
            let positionMs = max(0, positionUs / 1_000)
            visible = positionMs >= marker.startTimeOffsetMs &&
                positionMs < marker.endTimeOffsetMs
        } else {
            visible = false
        }

        guard showSkipIntro != visible else { return }

        if deferPublishedUpdate {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.showSkipIntro != visible else { return }
                self.showSkipIntro = visible
            }
        } else {
            showSkipIntro = visible
        }
    }

    private func reportPlexTimeline(_ state: PlexTimelineState,
                                    positionUs: Int64,
                                    continuing: Bool = false) {
        guard let plexSync, let item = currentPlaybackItem else { return }
        let sourceId = item.plexContext?.sourceId
        let sessionGeneration = plexSessionGeneration

        lastPlexTimelineUpdate = CACurrentMediaTime()
        let durationUs = transport.duration

        Task { [weak self] in
            let status = await plexSync.reportTimeline(
                state: state,
                positionUs: positionUs,
                durationUs: durationUs,
                continuing: continuing
            )
            await MainActor.run {
                guard let self,
                      self.isActivePlexSession(generation: sessionGeneration, itemID: item.id) else {
                    return
                }
                self.plexSyncHealthy = status == .success
                if status == .unauthorized, let sourceId {
                    self.onPlexAuthInvalid?(sourceId)
                }
            }
        }
    }

    private func finalizePlexPlayback(positionUs: Int64,
                                      continuing: Bool,
                                      finished: Bool) {
        guard let plexSync, let item = currentPlaybackItem else { return }
        let sourceId = item.plexContext?.sourceId
        let sessionGeneration = plexSessionGeneration

        lastPlexTimelineUpdate = CACurrentMediaTime()
        let durationUs = transport.duration

        Task { [weak self] in
            let timelineStatus = await plexSync.reportTimeline(
                state: .stopped,
                positionUs: positionUs,
                durationUs: durationUs,
                continuing: continuing
            )
            let scrobbleStatus = finished ? await plexSync.scrobble() : .success
            await MainActor.run {
                guard let self,
                      self.isActivePlexSession(generation: sessionGeneration, itemID: item.id) else {
                    return
                }
                self.plexSyncHealthy = timelineStatus == .success && scrobbleStatus == .success
                if (timelineStatus == .unauthorized || scrobbleStatus == .unauthorized),
                   let sourceId {
                    self.onPlexAuthInvalid?(sourceId)
                }
            }
        }
    }

    static func seekThumbnailIntervalSeconds(for durationUs: Int64) -> Int32 {
        switch durationUs {
        case ...1_800_000_000:
            return 1
        case ...5_400_000_000:
            return 2
        case ...14_400_000_000:
            return 5
        default:
            return 10
        }
    }

    private func finishPendingOpenIfNeeded() {
        guard let context = pendingOpenContext else { return }
        _ = bridge.state
        pendingOpenContext = nil
        openError = nil
        isPreparingPlayback = false
        transport.duration = bridge.duration
        isDolbyVision = (bridge as? PlayerBridge)?.isDolbyVision ?? false

        passthroughEnabled = context.settings.audioPassthrough
        passthroughCaps = bridge.queryPassthroughSupport()

        bridge.setDeviceChangeCallback { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.passthroughCaps = self.bridge.queryPassthroughSupport()
                self.transport.spatialActive = self.bridge.isSpatialActive
            }
        }

        mediaTitle = context.item.displayName

        loadDisplaySettings(for: context.item.resumeKey)
        transport.onCropDetected = { [weak self] crop in
            Task { @MainActor in self?.setCrop(crop) }
        }

        let json = bridge.mediaInfoJSON()
        let parsed = TrackInfo.parseTracks(from: json)
        audioTracks = parsed.audio
        subtitleTracks = parsed.subtitle
        activeAudioStream = Int(bridge.activeAudioStream)
        activeSubtitleStream = Int(bridge.activeSubtitleStream)
        if let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tracks = root["tracks"] as? [[String: Any]],
           let videoTrack = tracks.first(where: { ($0["type"] as? Int ?? 0) == 1 }) {
            transport.videoWidth = videoTrack["width"] as? Int ?? 0
            transport.videoHeight = videoTrack["height"] as? Int ?? 0
            transport.videoSARNum = max(1, videoTrack["sar_num"] as? Int ?? 1)
            transport.videoSARDen = max(1, videoTrack["sar_den"] as? Int ?? 1)
        } else {
            transport.videoWidth = 0
            transport.videoHeight = 0
            transport.videoSARNum = 1
            transport.videoSARDen = 1
        }

        if !context.settings.preferredAudioLanguage.isEmpty,
           let match = audioTracks.first(where: { $0.language == context.settings.preferredAudioLanguage }) {
            selectAudioTrack(streamIndex: match.streamIndex)
        }

        if context.settings.autoSelectSubtitles && !context.settings.preferredSubtitleLanguage.isEmpty {
            if let match = subtitleTracks.first(where: { $0.language == context.settings.preferredSubtitleLanguage }) {
                selectSubtitleTrack(streamIndex: match.streamIndex)
            }
        } else if !context.settings.autoSelectSubtitles {
            disableSubtitles()
        }

        let interval = Self.seekThumbnailIntervalSeconds(for: transport.duration)
        bridge.startSeekThumbnails(interval: interval)

        NowPlayingManager.shared.setup(
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onNextTrack: context.onNextTrack,
            onPreviousTrack: context.onPreviousTrack
        )

        configurePlexSync(for: context.item)

        if deferredPlayOnReady {
            deferredPlayOnReady = false
            bridge.play()
            reportPlexTimeline(.playing, positionUs: max(currentPosition, bridge.position))
        }
    }

    private func completeOpen(requestID: UInt64,
                              result: Result<Void, BridgeOperationError>,
                              fallbackDisplayName: String) {
        guard requestID == openRequestID else { return }

        openTask = nil
        openBridgeCallPending = false

        switch result {
        case .success:
            applyPlaybackState(bridge.state)
            if bridge.state == Int32(PY_STATE_READY.rawValue) {
                finishPendingOpenIfNeeded()
            } else if bridge.state == Int32(PY_STATE_IDLE.rawValue), pendingOpenContext != nil {
                failPendingOpen()
            }
        case .failure(let err):
            let fallback = "Could not open: \(fallbackDisplayName)"
            openError = err.message.isEmpty ? fallback : err.message
            mediaTitle = ""
            audioTracks = []
            subtitleTracks = []
            pendingOpenContext = nil
            deferredPlayOnReady = false
            isPreparingPlayback = false
        }
    }

    func open(item: PlaybackItem, settings: AppSettings,
              onNextTrack: (() -> Void)? = nil,
              onPreviousTrack: (() -> Void)? = nil,
              onPlexAuthInvalid: ((String) -> Void)? = nil) {
        openTask?.cancel()
        openRequestID &+= 1
        let requestID = openRequestID
        playbackEnded = false
        playbackSpeed = 1.0
        currentPlaybackItem = item
        self.onPlexAuthInvalid = onPlexAuthInvalid
        resetPlexState()
        pendingOpenContext = PendingOpenContext(
            item: item,
            settings: settings,
            onNextTrack: onNextTrack,
            onPreviousTrack: onPreviousTrack
        )
        deferredPlayOnReady = false
        openBridgeCallPending = true
        isPreparingPlayback = true
        prepareStatusText = item.isPlex ? settings.plexBufferMode.statusText : "Opening media..."
        mediaTitle = item.displayName
        audioTracks = []
        subtitleTracks = []
        activeAudioStream = -1
        activeSubtitleStream = -1
        transport.duration = 0
        transport.currentPosition = 0
        currentPosition = 0
        transport.currentSubtitle = nil
        transport.seekPreviewImage = nil
        transport.videoWidth = 0
        transport.videoHeight = 0
        transport.videoSARNum = 1
        transport.videoSARDen = 1
        isDolbyVision = false
        openError = nil

        bridge.setHWDecodePref(Int32(settings.hwDecodePref))
        bridge.setSubtitleFontScale(settings.styledSubtitleScale)
        bridge.setSpatialAudioMode(Int32(settings.spatialAudioMode))
        bridge.setHeadTracking(settings.headTrackingEnabled)
        bridge.setAudioPassthrough(settings.audioPassthrough)
        passthroughEnabled = settings.audioPassthrough
        volume = Float(settings.volume)
        bridge.setVolume(volume)
        configureRemoteBuffering(for: item, settings: settings)
        headTrackingEnabled = settings.headTrackingEnabled
        let path = item.path
        let displayName = item.displayName
        let bridge = self.bridge

        openTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = bridge.open(path: path)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.completeOpen(requestID: requestID,
                                   result: result,
                                   fallbackDisplayName: displayName)
            }
        }
    }

    func play() {
        if pendingOpenContext != nil {
            deferredPlayOnReady = true
            return
        }
        bridge.play()
        reportPlexTimeline(.playing, positionUs: max(currentPosition, bridge.position))
    }

    func pause() {
        if pendingOpenContext != nil {
            deferredPlayOnReady = false
            return
        }
        bridge.pause()
        reportPlexTimeline(.paused, positionUs: max(currentPosition, bridge.position))
    }

    func togglePlayPause() {
        if bridge.state == Int32(PY_STATE_PLAYING.rawValue) {
            pause()
        } else {
            play()
        }
    }

    func seek(to fraction: Double) {
        let target = Int64(fraction * Double(transport.duration))
        seek(toMicroseconds: target)
    }

    func seek(toMicroseconds target: Int64) {
        bridge.seek(to: target)
        transport.currentPosition = target
        currentPosition = target
        updateSkipIntroVisibility(for: target)
        reportPlexTimeline(isPlaying ? .playing : .paused, positionUs: target)
    }

    func seekRelative(seconds: Double) {
        let offsetUs = Int64(seconds * 1_000_000)
        let target = max(0, min(transport.duration, transport.currentPosition + offsetUs))
        seek(toMicroseconds: target)
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            bridge.setMuted(false)
            if volume == 0 {
                volume = preMuteVolume > 0 ? preMuteVolume : 1.0
                bridge.setVolume(volume)
            }
        } else {
            preMuteVolume = volume
            isMuted = true
            bridge.setMuted(true)
        }
    }

    func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        volume = clamped
        bridge.setVolume(clamped)
        if isMuted && clamped > 0 {
            isMuted = false
            bridge.setMuted(false)
        }
    }

    static let speedPresets: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        bridge.setPlaybackSpeed(speed)
    }

    func cycleSpeedUp() {
        if let idx = Self.speedPresets.firstIndex(where: { $0 > playbackSpeed + 0.01 }) {
            setPlaybackSpeed(Self.speedPresets[idx])
        }
    }

    func cycleSpeedDown() {
        if let idx = Self.speedPresets.lastIndex(where: { $0 < playbackSpeed - 0.01 }) {
            setPlaybackSpeed(Self.speedPresets[idx])
        }
    }

    func stop(continuing: Bool = false, finished: Bool = false) {
        openTask?.cancel()
        openTask = nil
        openRequestID &+= 1
        openBridgeCallPending = false
        let finalPositionUs = max(currentPosition, bridge.position)
        finalizePlexPlayback(positionUs: finalPositionUs, continuing: continuing, finished: finished)
        cancelPendingThumbnailRequest()
        bridge.cancelSeekThumbnails()
        pendingOpenContext = nil
        deferredPlayOnReady = false
        isPreparingPlayback = false
        bridge.stop()
        playbackState = Int32(PY_STATE_IDLE.rawValue)
        isPlaying = false
        transport.isPlaying = false
        playbackEnded = false
        currentPosition = 0
        transport.currentPosition = 0
        playbackSpeed = 1.0
        transport.seekPreviewImage = nil
        transport.videoWidth = 0
        transport.videoHeight = 0
        transport.videoSARNum = 1
        transport.videoSARDen = 1
        transport.displaySettings = .default
        transport.onCropDetected = nil
        aspectRatioMode = .auto
        cropActive = false
        displaySettingsPath = nil
        currentPlaybackItem = nil
        resetPlexState()
        NowPlayingManager.shared.clearNowPlaying()
    }

    // MARK: - Display-Synchronized Tick
    // Called by TimelineView(.animation) at the display's native refresh rate.
    // Writes ONLY to transport and plain properties — ZERO objectWillChange fires
    // (except for end-of-stream detection).

    func tick() {
        guard isPlaying else { return }

        let state = bridge.state
        if state != playbackState {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.playbackState != state else { return }
                self.applyPlaybackState(state)
            }
        }
        guard state == Int32(PY_STATE_PLAYING.rawValue) else { return }

        // Skip while the user is scrubbing the timeline to avoid fighting
        if transport.isScrubbing { return }

        // Update transport and plain property — no objectWillChange
        transport.currentPosition = bridge.position
        currentPosition = transport.currentPosition
        transport.passthroughActive = bridge.isPassthroughActive
        transport.spatialActive = bridge.isSpatialActive
        updateSkipIntroVisibility(for: transport.currentPosition, deferPublishedUpdate: true)

        let now = CACurrentMediaTime()

        // Subtitle: throttle to ~20Hz — subtitles change every 0.5-5s,
        // no need to cross the C bridge and alloc/free memory 120x/sec
        if now - lastSubtitleUpdate >= 0.05 {
            lastSubtitleUpdate = now
            transport.currentSubtitle = bridge.getSubtitle(at: transport.currentPosition)
        }

        // Throttle NowPlaying updates to ~1Hz
        if now - lastNowPlayingUpdate >= 1.0 {
            lastNowPlayingUpdate = now
            NowPlayingManager.shared.updateNowPlaying(
                title: mediaTitle,
                position: Double(transport.currentPosition) / 1_000_000.0,
                duration: Double(transport.duration) / 1_000_000.0,
                isPlaying: isPlaying
            )
        }

        if now - lastPlexTimelineUpdate >= 10.0 {
            reportPlexTimeline(.playing, positionUs: transport.currentPosition)
        }
    }

    func selectAudioTrack(streamIndex: Int) {
        bridge.selectAudioTrack(Int32(streamIndex))
        activeAudioStream = streamIndex
    }

    func selectSubtitleTrack(streamIndex: Int) {
        bridge.selectSubtitleTrack(Int32(streamIndex))
        activeSubtitleStream = streamIndex
        // Force immediate subtitle refresh so the user sees the result
        transport.currentSubtitle = bridge.getSubtitle(at: bridge.position)
    }

    func disableSubtitles() {
        bridge.selectSubtitleTrack(-1)
        activeSubtitleStream = -1
        transport.currentSubtitle = nil
    }

    func setPassthrough(_ enabled: Bool) {
        passthroughEnabled = enabled
        bridge.setAudioPassthrough(enabled)
    }

    func setSpatialMode(_ mode: Int) {
        bridge.setSpatialAudioMode(Int32(mode))
    }

    func setHeadTracking(_ enabled: Bool) {
        headTrackingEnabled = enabled
        bridge.setHeadTracking(enabled)
    }

    // MARK: - Display Settings (aspect ratio, crop, zoom, pan)

    private var displaySettingsPath: String?

    func setAspectRatioMode(_ mode: AspectRatioMode) {
        transport.displaySettings.aspectRatioMode = mode
        aspectRatioMode = mode
        // Reset pan when switching modes
        transport.displaySettings.panX = 0
        transport.displaySettings.panY = 0
        saveDisplaySettings()
    }

    func setCrop(_ crop: CropInsets) {
        transport.displaySettings.crop = crop
        cropActive = crop.isActive
        saveDisplaySettings()
    }

    func setZoom(_ zoom: Double) {
        transport.displaySettings.zoom = max(1.0, min(5.0, zoom))
        if transport.displaySettings.zoom <= 1.001 {
            transport.displaySettings.panX = 0
            transport.displaySettings.panY = 0
        }
    }

    func setPan(x: Double, y: Double) {
        transport.displaySettings.panX = max(-1, min(1, x))
        transport.displaySettings.panY = max(-1, min(1, y))
    }

    func adjustZoom(by delta: Double) {
        setZoom(transport.displaySettings.zoom + delta)
    }

    func resetDisplaySettings() {
        transport.displaySettings = .default
        aspectRatioMode = .auto
        cropActive = false
        saveDisplaySettings()
    }

    func detectBlackBars() {
        transport.pendingCropDetection = true
    }

    private func loadDisplaySettings(for path: String) {
        displaySettingsPath = path
        let settings = VideoDisplaySettingsStore.settings(for: path)
        transport.displaySettings = settings
        aspectRatioMode = settings.aspectRatioMode
        cropActive = settings.crop.isActive
    }

    private func saveDisplaySettings() {
        guard let path = displaySettingsPath else { return }
        VideoDisplaySettingsStore.save(path: path, settings: transport.displaySettings)
    }

    // MARK: - Timeline interaction (writes to transport, not @Published)

    func timelineHoverChanged(_ hovering: Bool) {
        hoverEndWork?.cancel()
        hoverEndWork = nil
        if hovering {
            transport.isHoveringTimeline = true
        } else {
            transport.isHoveringTimeline = false
            cancelPendingThumbnailRequest()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.transport.seekPreviewImage = nil
            }
            hoverEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func timelineHoverMoved(fraction: Double) {
        transport.hoverFraction = max(0, min(1, fraction))
        updateSeekPreview(fraction: transport.hoverFraction)
    }

    func timelineDragStarted() {
        transport.isDraggingTimeline = true
    }

    func timelineDragChanged(fraction: Double) {
        let clamped = max(0, min(1, fraction))
        transport.hoverFraction = clamped
        updateSeekPreview(fraction: clamped)
        pendingSeekFraction = clamped
    }

    func timelineDragEnded() {
        if let fraction = pendingSeekFraction {
            seek(to: fraction)
        }
        pendingSeekFraction = nil
        transport.isDraggingTimeline = false
        transport.seekPreviewImage = nil
        cancelPendingThumbnailRequest()
    }

    private func scheduleThumbnailRetry(fraction: Double, requestId: UInt64) {
        thumbRetryWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.thumbRequestId == requestId else { return }
                guard self.transport.isHoveringTimeline || self.transport.isDraggingTimeline else { return }
                self.updateSeekPreview(fraction: fraction, forceRefresh: true)
            }
        }
        thumbRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + thumbRetryDelay, execute: work)
    }

    private func updateSeekPreview(fraction: Double, forceRefresh: Bool = false) {
        guard transport.duration > 0 else { return }
        let timestampUs = Int64(fraction * Double(transport.duration))

        let intervalSec = Int(Self.seekThumbnailIntervalSeconds(for: transport.duration))
        let index = Int(timestampUs / 1_000_000) / intervalSec
        guard forceRefresh || index != lastThumbIndex else { return }
        lastThumbIndex = index

        thumbRequestId &+= 1
        let requestId = thumbRequestId
        let bridge = self.bridge
        thumbRetryWork?.cancel()
        thumbRetryWork = nil

        thumbQueue.async { [weak self] in
            guard let self, self.thumbRequestId == requestId else { return }
            let image = bridge.seekThumbnail(at: timestampUs)
            let progress = bridge.seekThumbnailProgress
            DispatchQueue.main.async { [weak self] in
                guard let self, self.thumbRequestId == requestId else { return }
                guard self.transport.isHoveringTimeline || self.transport.isDraggingTimeline else { return }
                self.transport.seekPreviewImage = image
                if image == nil && progress < 100 {
                    self.scheduleThumbnailRetry(fraction: fraction, requestId: requestId)
                }
            }
        }
    }

    func activeTimelinePositionUs() -> Int64 {
        guard transport.duration > 0 else { return 0 }
        if transport.isHoveringTimeline || transport.isDraggingTimeline {
            let clampedFraction = max(0, min(1, transport.hoverFraction))
            return max(0, min(transport.duration, Int64(clampedFraction * Double(transport.duration))))
        }
        return max(0, min(transport.duration, transport.currentPosition))
    }

    func timelineElapsedText() -> String {
        transport.formatTime(activeTimelinePositionUs())
    }

    func timelineRemainingText() -> String {
        let remainingUs = max(0, transport.duration - activeTimelinePositionUs())
        return "-\(transport.formatTime(remainingUs))"
    }

    func timeText(for fraction: Double) -> String {
        let us = Int64(fraction * Double(transport.duration))
        return transport.formatTime(us)
    }

    func skipIntro() {
        guard let marker = plexIntroMarker else { return }
        seek(toMicroseconds: marker.endTimeOffsetMs * 1_000)
    }
}

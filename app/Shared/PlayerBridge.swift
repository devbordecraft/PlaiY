import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

@c
private func deviceChangeTrampoline(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    Unmanaged<DeviceCallbackBox>.fromOpaque(userdata).takeUnretainedValue().invoke()
}

@c
private func stateChangeTrampoline(_ state: Int32, _ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    Unmanaged<StateCallbackBox>.fromOpaque(userdata).takeUnretainedValue().invoke(state)
}

private final class DeviceCallbackBox: NSObject {
    private let lock = NSLock()
    private var callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func update(_ callback: @escaping () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func invoke() {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        callback()
    }
}

private final class StateCallbackBox: NSObject {
    private let lock = NSLock()
    private var callback: (Int32) -> Void

    init(_ callback: @escaping (Int32) -> Void) {
        self.callback = callback
    }

    func update(_ callback: @escaping (Int32) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func invoke(_ state: Int32) {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        callback(state)
    }
}

struct PlayerTransportSnapshot: Sendable {
    let state: Int32
    let positionUs: Int64
    let isPassthroughActive: Bool
    let isSpatialActive: Bool
    let subtitleRevision: UInt64

    init(state: Int32,
         positionUs: Int64,
         isPassthroughActive: Bool,
         isSpatialActive: Bool,
         subtitleRevision: UInt64) {
        self.state = state
        self.positionUs = positionUs
        self.isPassthroughActive = isPassthroughActive
        self.isSpatialActive = isSpatialActive
        self.subtitleRevision = subtitleRevision
    }

    init(raw: PYPlayerTransportSnapshot) {
        self.init(
            state: Int32(raw.state),
            positionUs: raw.position_us,
            isPassthroughActive: raw.passthrough_active,
            isSpatialActive: raw.spatial_active,
            subtitleRevision: raw.subtitle_revision
        )
    }
}

private final class PlayerThreadExecutor {
    private final class WorkItem: NSObject {
        let operation: () -> Void

        init(operation: @escaping () -> Void) {
            self.operation = operation
        }

        @objc func run() {
            operation()
        }
    }

    private final class Runner: NSObject {
        let readySemaphore = DispatchSemaphore(value: 0)
        private let keepAlivePort = Port()

        @objc func threadMain() {
            let runLoop = RunLoop.current
            runLoop.add(keepAlivePort, forMode: .default)
            readySemaphore.signal()

            while !Thread.current.isCancelled {
                autoreleasepool {
                    _ = runLoop.run(mode: .default, before: .distantFuture)
                }
            }
        }

        @objc func execute(_ workItem: WorkItem) {
            workItem.run()
        }

        @objc func stopRunLoop() {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private let runner = Runner()
    private let thread: Thread

    init(name: String) {
        thread = Thread(target: runner, selector: #selector(Runner.threadMain), object: nil)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        runner.readySemaphore.wait()
    }

    func sync<T>(_ operation: @escaping () -> T) -> T {
        if Thread.current == thread {
            return operation()
        }

        var result: T?
        let workItem = WorkItem {
            result = operation()
        }
        runner.perform(#selector(Runner.execute(_:)), on: thread, with: workItem, waitUntilDone: true)
        return result!
    }

    func async(_ operation: @escaping () -> Void) {
        if Thread.current == thread {
            operation()
            return
        }

        let workItem = WorkItem(operation: operation)
        runner.perform(#selector(Runner.execute(_:)), on: thread, with: workItem, waitUntilDone: false)
    }

    func shutdown() {
        if Thread.current == thread {
            Thread.current.cancel()
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }

        runner.perform(#selector(Runner.stopRunLoop), on: thread, with: nil, waitUntilDone: false)
        thread.cancel()
    }
}

/// Swift wrapper around the C bridge API (plaiy_c.h)
final class PlayerBridge: @unchecked Sendable {
    private let executor: PlayerThreadExecutor
    private let handle: OpaquePointer
    private var deviceCallbackBox: DeviceCallbackBox?
    private var stateCallbackBox: StateCallbackBox?

    private static func stringFromCString(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    private func sync<T>(_ operation: @escaping (OpaquePointer) -> T) -> T {
        executor.sync { operation(self.handle) }
    }

    private func async(_ operation: @escaping (OpaquePointer) -> Void) {
        executor.async { operation(self.handle) }
    }

    init() {
        let executor = PlayerThreadExecutor(name: "com.plaiy.player-bridge")
        self.executor = executor
        self.handle = executor.sync {
            py_player_create()
        }
    }

    deinit {
        sync { handle in
            py_player_set_device_change_callback(handle, nil, nil)
            py_player_set_state_callback(handle, nil, nil)
            py_player_destroy(handle)
        }

        deviceCallbackBox = nil
        stateCallbackBox = nil
        executor.shutdown()
    }

    func open(path: String) -> Result<Void, BridgeOperationError> {
        sync { handle in
            let code = py_player_open(handle, path)
            if code == Int32(PY_OK.rawValue) {
                return .success(())
            }

            let message = Self.stringFromCString(py_player_get_last_error(handle))
            return .failure(
                BridgeOperationError(
                    operation: "open",
                    code: code,
                    message: message
                )
            )
        }
    }

    func lastErrorMessage() -> String {
        sync { handle in
            Self.stringFromCString(py_player_get_last_error(handle))
        }
    }

    var isDolbyVision: Bool {
        sync { handle in
            py_player_is_dolby_vision(handle)
        }
    }

    func setDVDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        let ptr = Unmanaged.passUnretained(layer).toOpaque()
        async { handle in
            py_player_set_dv_display_layer(handle, ptr)
        }
    }

    func play() {
        async { handle in
            py_player_play(handle)
        }
    }

    func pause() {
        async { handle in
            py_player_pause(handle)
        }
    }

    func seek(to microseconds: Int64) {
        async { handle in
            py_player_seek(handle, microseconds)
        }
    }

    func stop() {
        async { handle in
            py_player_stop(handle)
        }
    }

    var state: Int32 {
        sync { handle in
            py_player_get_state(handle)
        }
    }

    var position: Int64 {
        sync { handle in
            py_player_get_position(handle)
        }
    }

    var duration: Int64 {
        sync { handle in
            py_player_get_duration(handle)
        }
    }

    func getTransportSnapshot() -> PlayerTransportSnapshot {
        sync { handle in
            PlayerTransportSnapshot(raw: py_player_get_transport_snapshot(handle))
        }
    }

    var audioTrackCount: Int32 {
        sync { handle in
            py_player_get_audio_track_count(handle)
        }
    }

    var subtitleTrackCount: Int32 {
        sync { handle in
            py_player_get_subtitle_track_count(handle)
        }
    }

    func selectAudioTrack(_ index: Int32) {
        async { handle in
            py_player_select_audio_track(handle, index)
        }
    }

    func selectSubtitleTrack(_ index: Int32) {
        async { handle in
            py_player_select_subtitle_track(handle, index)
        }
    }

    var activeAudioStream: Int32 {
        sync { handle in
            py_player_get_active_audio_stream(handle)
        }
    }

    var activeSubtitleStream: Int32 {
        sync { handle in
            py_player_get_active_subtitle_stream(handle)
        }
    }

    func setHWDecodePref(_ pref: Int32) {
        async { handle in
            py_player_set_hw_decode_pref(handle, pref)
        }
    }

    func setSubtitleFontScale(_ scale: Double) {
        async { handle in
            py_player_set_subtitle_font_scale(handle, scale)
        }
    }

    func setRemoteSourceKind(_ kind: Int32) {
        async { handle in
            py_player_set_remote_source_kind(handle, kind)
        }
    }

    func setRemoteBufferMode(_ mode: Int32) {
        async { handle in
            py_player_set_remote_buffer_mode(handle, mode)
        }
    }

    func setRemoteBufferProfile(_ profile: Int32) {
        async { handle in
            py_player_set_remote_buffer_profile(handle, profile)
        }
    }

    // MARK: - Audio Filters

    // Equalizer
    func setEQEnabled(_ enabled: Bool) {
        async { handle in
            py_player_set_eq_enabled(handle, enabled)
        }
    }

    var isEQEnabled: Bool {
        sync { handle in
            py_player_is_eq_enabled(handle)
        }
    }

    func setEQBand(_ band: Int32, gain: Float) {
        async { handle in
            py_player_set_eq_band(handle, band, gain)
        }
    }

    func eqBand(_ band: Int32) -> Float {
        sync { handle in
            py_player_get_eq_band(handle, band)
        }
    }

    func setEQPreset(_ preset: Int32) {
        async { handle in
            py_player_set_eq_preset(handle, preset)
        }
    }

    var eqPreset: Int32 {
        sync { handle in
            py_player_get_eq_preset(handle)
        }
    }

    // Compressor
    func setCompressorEnabled(_ enabled: Bool) {
        async { handle in
            py_player_set_compressor_enabled(handle, enabled)
        }
    }

    var isCompressorEnabled: Bool {
        sync { handle in
            py_player_is_compressor_enabled(handle)
        }
    }

    func setCompressorThreshold(_ db: Float) {
        async { handle in
            py_player_set_compressor_threshold(handle, db)
        }
    }

    func setCompressorRatio(_ ratio: Float) {
        async { handle in
            py_player_set_compressor_ratio(handle, ratio)
        }
    }

    func setCompressorAttack(_ ms: Float) {
        async { handle in
            py_player_set_compressor_attack(handle, ms)
        }
    }

    func setCompressorRelease(_ ms: Float) {
        async { handle in
            py_player_set_compressor_release(handle, ms)
        }
    }

    func setCompressorMakeup(_ db: Float) {
        async { handle in
            py_player_set_compressor_makeup(handle, db)
        }
    }

    // Dialogue Boost
    func setDialogueBoostEnabled(_ enabled: Bool) {
        async { handle in
            py_player_set_dialogue_boost_enabled(handle, enabled)
        }
    }

    var isDialogueBoostEnabled: Bool {
        sync { handle in
            py_player_is_dialogue_boost_enabled(handle)
        }
    }

    func setDialogueBoostAmount(_ amount: Float) {
        async { handle in
            py_player_set_dialogue_boost_amount(handle, amount)
        }
    }

    var dialogueBoostAmount: Float {
        sync { handle in
            py_player_get_dialogue_boost_amount(handle)
        }
    }

    // MARK: - Video Filters (GPU)

    func setBrightness(_ value: Float) {
        async { handle in
            py_player_set_brightness(handle, value)
        }
    }

    var brightness: Float {
        sync { handle in
            py_player_get_brightness(handle)
        }
    }

    func setContrast(_ value: Float) {
        async { handle in
            py_player_set_contrast(handle, value)
        }
    }

    var contrast: Float {
        sync { handle in
            py_player_get_contrast(handle)
        }
    }

    func setSaturation(_ value: Float) {
        async { handle in
            py_player_set_saturation(handle, value)
        }
    }

    var saturation: Float {
        sync { handle in
            py_player_get_saturation(handle)
        }
    }

    func setSharpness(_ value: Float) {
        async { handle in
            py_player_set_sharpness(handle, value)
        }
    }

    var sharpness: Float {
        sync { handle in
            py_player_get_sharpness(handle)
        }
    }

    func setDebandEnabled(_ enabled: Bool) {
        async { handle in
            py_player_set_deband_enabled(handle, enabled)
        }
    }

    var isDebandEnabled: Bool {
        sync { handle in
            py_player_is_deband_enabled(handle)
        }
    }

    func setLanczosUpscaling(_ enabled: Bool) {
        async { handle in
            py_player_set_lanczos_upscaling(handle, enabled)
        }
    }

    var isLanczosUpscaling: Bool {
        sync { handle in
            py_player_is_lanczos_upscaling(handle)
        }
    }

    func setFilmGrainEnabled(_ enabled: Bool) {
        async { handle in
            py_player_set_film_grain_enabled(handle, enabled)
        }
    }

    var isFilmGrainEnabled: Bool {
        sync { handle in
            py_player_is_film_grain_enabled(handle)
        }
    }

    func resetVideoAdjustments() {
        async { handle in
            py_player_reset_video_adjustments(handle)
        }
    }

    // MARK: - Video Filters (CPU: Deinterlace)

    func setDeinterlaceEnabled(_ enabled: Bool) {
        async { handle in
            py_player_set_deinterlace_enabled(handle, enabled)
        }
    }

    var isDeinterlaceEnabled: Bool {
        sync { handle in
            py_player_is_deinterlace_enabled(handle)
        }
    }

    func setDeinterlaceMode(_ mode: Int32) {
        async { handle in
            py_player_set_deinterlace_mode(handle, mode)
        }
    }

    var deinterlaceMode: Int32 {
        sync { handle in
            py_player_get_deinterlace_mode(handle)
        }
    }

    func setAudioPassthrough(_ enabled: Bool) {
        async { handle in
            py_player_set_audio_passthrough(handle, enabled)
        }
    }

    var isPassthroughActive: Bool {
        sync { handle in
            py_player_is_passthrough_active(handle)
        }
    }

    func queryPassthroughSupport() -> PYPassthroughCapabilities {
        sync { handle in
            py_player_query_passthrough_support(handle)
        }
    }

    func setVolume(_ volume: Float) {
        async { handle in
            py_player_set_volume(handle, volume)
        }
    }

    var volume: Float {
        sync { handle in
            py_player_get_volume(handle)
        }
    }

    func setMuted(_ muted: Bool) {
        async { handle in
            py_player_set_muted(handle, muted)
        }
    }

    var isMuted: Bool {
        sync { handle in
            py_player_is_muted(handle)
        }
    }

    func setDeviceChangeCallback(_ callback: @escaping () -> Void) {
        let box = deviceCallbackBox ?? DeviceCallbackBox(callback)
        box.update(callback)
        deviceCallbackBox = box
        sync { handle in
            py_player_set_device_change_callback(
                handle,
                deviceChangeTrampoline,
                Unmanaged.passUnretained(box).toOpaque()
            )
        }
    }

    func setStateCallback(_ callback: @escaping (Int32) -> Void) {
        let box = stateCallbackBox ?? StateCallbackBox(callback)
        box.update(callback)
        stateCallbackBox = box
        sync { handle in
            py_player_set_state_callback(
                handle,
                stateChangeTrampoline,
                Unmanaged.passUnretained(box).toOpaque()
            )
        }
    }

    // MARK: - Spatial audio

    func setSpatialAudioMode(_ mode: Int32) {
        async { handle in
            py_player_set_spatial_audio_mode(handle, mode)
        }
    }

    var spatialAudioMode: Int32 {
        sync { handle in
            py_player_get_spatial_audio_mode(handle)
        }
    }

    var isSpatialActive: Bool {
        sync { handle in
            py_player_is_spatial_active(handle)
        }
    }

    func setHeadTracking(_ enabled: Bool) {
        async { handle in
            py_player_set_head_tracking(handle, enabled)
        }
    }

    var isHeadTracking: Bool {
        sync { handle in
            py_player_is_head_tracking(handle)
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        async { handle in
            py_player_set_playback_speed(handle, speed)
        }
    }

    var playbackSpeed: Double {
        sync { handle in
            py_player_get_playback_speed(handle)
        }
    }

    func getPlaybackStats() -> PYPlaybackStats {
        sync { handle in
            py_player_get_playback_stats(handle)
        }
    }

    func mediaInfoJSON() -> String {
        sync { handle in
            guard let cStr = py_player_get_media_info_json(handle) else { return "{}" }
            return String(cString: cStr)
        }
    }

    // Video frame acquisition for Metal rendering
    func acquireVideoFrame(targetPts: Int64) -> UnsafeMutableRawPointer? {
        py_player_acquire_video_frame(handle, targetPts)
    }

    func releaseVideoFrame(_ frame: UnsafeMutableRawPointer) {
        py_player_release_video_frame(handle, frame)
    }

    static func framePixelBuffer(_ frame: UnsafeMutableRawPointer) -> CVPixelBuffer? {
        guard let ptr = py_player_frame_get_pixel_buffer(frame) else { return nil }
        return Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeUnretainedValue()
    }

static func frameWidth(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_width(frame)
    }

static func frameHeight(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_height(frame)
    }

static func frameHDRType(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_hdr_type(frame)
    }

static func frameMaxLuminance(_ frame: UnsafeMutableRawPointer) -> UInt32 {
        py_player_frame_get_max_luminance(frame)
    }

static func frameMaxCLL(_ frame: UnsafeMutableRawPointer) -> UInt16 {
        py_player_frame_get_max_cll(frame)
    }

static func frameMaxFALL(_ frame: UnsafeMutableRawPointer) -> UInt16 {
        py_player_frame_get_max_fall(frame)
    }

static func frameColorTrc(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_trc(frame)
    }

static func frameColorSpace(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_space(frame)
    }

static func framePts(_ frame: UnsafeMutableRawPointer) -> Int64 {
        py_player_frame_get_pts(frame)
    }

static func frameSarNum(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_sar_num(frame)
    }

static func frameSarDen(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_sar_den(frame)
    }

static func frameColorPrimaries(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_primaries(frame)
    }

static func frameColorRange(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_range(frame)
    }

static func frameChromaFormat(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_chroma_format(frame)
    }

    // HDR10+ per-frame dynamic metadata
static func frameHasHDR10Plus(_ frame: UnsafeMutableRawPointer) -> Bool {
        py_player_frame_has_hdr10plus(frame)
    }

static func frameHDR10PlusTargetMaxLum(_ frame: UnsafeMutableRawPointer) -> Float {
        py_player_frame_hdr10plus_target_max_lum(frame)
    }

static func frameHDR10PlusKneeX(_ frame: UnsafeMutableRawPointer) -> Float {
        py_player_frame_hdr10plus_knee_x(frame)
    }

static func frameHDR10PlusKneeY(_ frame: UnsafeMutableRawPointer) -> Float {
        py_player_frame_hdr10plus_knee_y(frame)
    }

    static func frameHDR10PlusAnchors(_ frame: UnsafeMutableRawPointer) -> [Float] {
        let count = Int(py_player_frame_hdr10plus_num_anchors(frame))
        guard count > 0 else { return [] }
        var anchors = [Float](repeating: 0, count: count)
        py_player_frame_hdr10plus_anchors(frame, &anchors, Int32(count))
        return anchors
    }

    static func frameHDR10PlusMaxSCL(_ frame: UnsafeMutableRawPointer) -> (Float, Float, Float) {
        var rgb: (Float, Float, Float) = (0, 0, 0)
        withUnsafeMutablePointer(to: &rgb) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 3) { floatPtr in
                py_player_frame_hdr10plus_maxscl(frame, floatPtr)
            }
        }
        return rgb
    }

    // Dolby Vision per-frame color metadata
static func frameHasDoviColor(_ frame: UnsafeMutableRawPointer) -> Bool {
        py_player_frame_has_dovi_color(frame)
    }

    static func frameDoviYccToRgb(_ frame: UnsafeMutableRawPointer) -> (matrix: [Float], offset: [Float])? {
        var matrix = [Float](repeating: 0, count: 9)
        var offset = [Float](repeating: 0, count: 3)
        guard py_player_frame_dovi_ycc_to_rgb(frame, &matrix, &offset) else { return nil }
        return (matrix, offset)
    }

    static func frameDoviRgbToLms(_ frame: UnsafeMutableRawPointer) -> [Float]? {
        var matrix = [Float](repeating: 0, count: 9)
        guard py_player_frame_dovi_rgb_to_lms(frame, &matrix) else { return nil }
        return matrix
    }

    static func frameDoviLmsToRgb(_ frame: UnsafeMutableRawPointer) -> [Float]? {
        var matrix = [Float](repeating: 0, count: 9)
        guard py_player_frame_dovi_lms_to_rgb(frame, &matrix) else { return nil }
        return matrix
    }

    static func frameDoviL1(_ frame: UnsafeMutableRawPointer) -> (minPQ: UInt16, maxPQ: UInt16, avgPQ: UInt16)? {
        var minPQ: UInt16 = 0
        var maxPQ: UInt16 = 0
        var avgPQ: UInt16 = 0
        guard py_player_frame_dovi_l1(frame, &minPQ, &maxPQ, &avgPQ) else { return nil }
        return (minPQ, maxPQ, avgPQ)
    }

    static func frameDoviL2(_ frame: UnsafeMutableRawPointer) -> (slope: UInt16, offset: UInt16, power: UInt16, chromaWeight: UInt16, saturationGain: UInt16, msWeight: Int16)? {
        var slope: UInt16 = 0
        var offset: UInt16 = 0
        var power: UInt16 = 0
        var chromaWeight: UInt16 = 0
        var saturationGain: UInt16 = 0
        var msWeight: Int16 = 0
        guard py_player_frame_dovi_l2(frame, &slope, &offset, &power, &chromaWeight, &saturationGain, &msWeight) else { return nil }
        return (slope, offset, power, chromaWeight, saturationGain, msWeight)
    }

    static func frameDoviL5(_ frame: UnsafeMutableRawPointer) -> (left: UInt16, right: UInt16, top: UInt16, bottom: UInt16)? {
        var left: UInt16 = 0
        var right: UInt16 = 0
        var top: UInt16 = 0
        var bottom: UInt16 = 0
        guard py_player_frame_dovi_l5(frame, &left, &right, &top, &bottom) else { return nil }
        return (left, right, top, bottom)
    }

    static func frameDoviL6(_ frame: UnsafeMutableRawPointer) -> (maxLum: UInt16, minLum: UInt16, maxCLL: UInt16, maxFALL: UInt16)? {
        var maxLum: UInt16 = 0
        var minLum: UInt16 = 0
        var maxCLL: UInt16 = 0
        var maxFALL: UInt16 = 0
        guard py_player_frame_dovi_l6(frame, &maxLum, &minLum, &maxCLL, &maxFALL) else { return nil }
        return (maxLum, minLum, maxCLL, maxFALL)
    }

static func frameMinLuminance(_ frame: UnsafeMutableRawPointer) -> UInt32 {
        py_player_frame_get_min_luminance(frame)
    }

static func frameDoviHasReshaping(_ frame: UnsafeMutableRawPointer) -> Bool {
        py_player_frame_dovi_has_reshaping(frame)
    }

    static func frameDoviReshapeFingerprint(_ frame: UnsafeMutableRawPointer) -> UInt64 {
        py_player_frame_dovi_reshape_fingerprint(frame)
    }

    static func frameDoviReshapeLUT(_ frame: UnsafeMutableRawPointer, component: Int32) -> [Float]? {
        var lut = [Float](repeating: 0, count: 1024)
        guard py_player_frame_dovi_reshape_lut(frame, component, &lut) else { return nil }
        return lut
    }

    // Seek preview thumbnails
    func startSeekThumbnails(interval: Int32 = 10) {
        async { handle in
            py_player_start_seek_thumbnails(handle, interval)
        }
    }

    func cancelSeekThumbnails() {
        async { handle in
            py_player_cancel_seek_thumbnails(handle)
        }
    }

    func seekThumbnail(at timestampUs: Int64) -> CGImage? {
        sync { handle in
            var dataPtr: UnsafePointer<UInt8>?
            var width: Int32 = 0
            var height: Int32 = 0
            let result = py_player_get_seek_thumbnail(handle, timestampUs, &dataPtr, &width, &height)
            guard result == Int32(PY_OK.rawValue),
                  let data = dataPtr,
                  width > 0, height > 0 else { return nil }

            let bytesPerRow = Int(width) * 4
            let totalBytes = bytesPerRow * Int(height)
            let cfData = Data(bytes: data, count: totalBytes) as CFData
            guard let provider = CGDataProvider(data: cfData) else { return nil }

            return CGImage(width: Int(width), height: Int(height),
                           bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: bytesPerRow,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider,
                           decode: nil, shouldInterpolate: true,
                           intent: .defaultIntent)
        }
    }

    var seekThumbnailProgress: Int32 {
        sync { handle in
            py_player_get_seek_thumbnail_progress(handle)
        }
    }

    // Subtitle
    func getSubtitleFrame(at timestamp: Int64) -> ResolvedSubtitle? {
        sync { handle in
            guard let sf = py_player_get_subtitle(handle, timestamp) else { return nil }
            defer { py_subtitle_free(sf) }

            let pointed = sf.pointee
            if let text = pointed.text {
                return ResolvedSubtitle(
                    data: .text(String(cString: text)),
                    startUs: pointed.start_us,
                    endUs: pointed.end_us
                )
            } else if let regions = pointed.regions, pointed.region_count > 0 {
                let count = Int(pointed.region_count)
                let buffer = UnsafeBufferPointer(start: regions, count: count)
                let decoded = buffer.compactMap { regionPtr -> SubtitleBitmapRegion? in
                    let region = regionPtr
                    guard let rgba = region.rgba_data,
                          region.width > 0,
                          region.height > 0 else { return nil }
                    let size = Int(region.width) * Int(region.height) * 4
                    return SubtitleBitmapRegion(
                        data: Data(bytes: rgba, count: size),
                        width: Int(region.width),
                        height: Int(region.height),
                        x: Int(region.x),
                        y: Int(region.y)
                    )
                }
                if !decoded.isEmpty {
                    return ResolvedSubtitle(
                        data: .bitmap(regions: decoded),
                        startUs: pointed.start_us,
                        endUs: pointed.end_us
                    )
                }
            }
            return nil
        }
    }
}

struct SubtitleBitmapRegion: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

enum SubtitleData {
    case text(String)
    case bitmap(regions: [SubtitleBitmapRegion])
}

struct ResolvedSubtitle: Sendable {
    let data: SubtitleData
    let startUs: Int64
    let endUs: Int64
}

struct LibraryBridgeError: Error, Equatable, Sendable {
    let operation: String
    let code: Int32
    let message: String

    var localizedDescription: String {
        if !message.isEmpty {
            return message
        }

        switch code {
        case Int32(PY_ERROR_FILE_NOT_FOUND.rawValue):
            return "Folder not found"
        case Int32(PY_ERROR_INVALID_ARG.rawValue):
            return "Invalid folder path"
        default:
            return "\(operation) failed (code \(code))"
        }
    }
}

protocol LibraryBridgeProtocol: AnyObject, Sendable {
    var itemCount: Int32 { get }
    var folderCount: Int32 { get }
    func addFolder(_ path: String) -> Result<Void, LibraryBridgeError>
    func removeFolder(at index: Int32) -> Bool
    func itemJSON(at index: Int32) -> String
    func allItemsJSON() -> String
    func folder(at index: Int32) -> String
}

/// Library bridge
final class LibraryBridge: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        handle = py_library_create()
    }

    deinit {
        py_library_destroy(handle)
    }

var itemCount: Int32 {
        py_library_get_item_count(handle)
    }

var folderCount: Int32 {
        py_library_get_folder_count(handle)
    }

func removeFolder(at index: Int32) -> Bool {
        py_library_remove_folder(handle, index) == Int32(PY_OK.rawValue)
    }

    func addFolder(_ path: String) -> Result<Void, LibraryBridgeError> {
        let result = py_library_add_folder(handle, path)
        if result == Int32(PY_OK.rawValue) {
            return .success(())
        }

        return .failure(
            LibraryBridgeError(
                operation: "addFolder",
                code: result,
                message: ""
            )
        )
    }

    func itemJSON(at index: Int32) -> String {
        guard let cStr = py_library_get_item_json(handle, index) else { return "{}" }
        return String(cString: cStr)
    }

    func allItemsJSON() -> String {
        guard let cStr = py_library_get_all_items_json(handle) else { return "[]" }
        return String(cString: cStr)
    }

    func folder(at index: Int32) -> String {
        guard let cStr = py_library_get_folder(handle, index) else { return "" }
        return String(cString: cStr)
    }
}

extension LibraryBridge: LibraryBridgeProtocol {}

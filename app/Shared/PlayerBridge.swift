import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

@c
private func deviceChangeTrampoline(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    guard let cb = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue() as? () -> Void else { return }
    cb()
}

@c
private func stateChangeTrampoline(_ state: Int32, _ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    guard let cb = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue() as? (Int32) -> Void else { return }
    cb(state)
}

/// Swift wrapper around the C bridge API (plaiy_c.h)
final class PlayerBridge: @unchecked Sendable {
    private let handle: OpaquePointer
    private var deviceCallbackContext: UnsafeMutableRawPointer?
    private var stateCallbackContext: UnsafeMutableRawPointer?

    init() {
        handle = py_player_create()
    }

    deinit {
        if let ctx = deviceCallbackContext {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
        }
        if let ctx = stateCallbackContext {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
        }
        py_player_destroy(handle)
    }

    func open(path: String) -> Bool {
        let result = py_player_open(handle, path)
        return result == Int32(PY_OK.rawValue)
    }

    var isDolbyVision: Bool {
        py_player_is_dolby_vision(handle)
    }

    func setDVDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        let ptr = Unmanaged.passUnretained(layer).toOpaque()
        py_player_set_dv_display_layer(handle, ptr)
    }

    @inline(always) func play() {
        py_player_play(handle)
    }

    @inline(always) func pause() {
        py_player_pause(handle)
    }

    @inline(always) func seek(to microseconds: Int64) {
        py_player_seek(handle, microseconds)
    }

    @inline(always) func stop() {
        py_player_stop(handle)
    }

    @inline(always) var state: Int32 {
        py_player_get_state(handle)
    }

    @inline(always) var position: Int64 {
        py_player_get_position(handle)
    }

    @inline(always) var duration: Int64 {
        py_player_get_duration(handle)
    }

    @inline(always) var audioTrackCount: Int32 {
        py_player_get_audio_track_count(handle)
    }

    @inline(always) var subtitleTrackCount: Int32 {
        py_player_get_subtitle_track_count(handle)
    }

    @inline(always) func selectAudioTrack(_ index: Int32) {
        py_player_select_audio_track(handle, index)
    }

    @inline(always) func selectSubtitleTrack(_ index: Int32) {
        py_player_select_subtitle_track(handle, index)
    }

    @inline(always) var activeAudioStream: Int32 {
        py_player_get_active_audio_stream(handle)
    }

    @inline(always) var activeSubtitleStream: Int32 {
        py_player_get_active_subtitle_stream(handle)
    }

    @inline(always) func setHWDecodePref(_ pref: Int32) {
        py_player_set_hw_decode_pref(handle, pref)
    }

    @inline(always) func setSubtitleFontScale(_ scale: Double) {
        py_player_set_subtitle_font_scale(handle, scale)
    }

    // MARK: - Audio Filters

    // Equalizer
    @inline(always) func setEQEnabled(_ enabled: Bool) { py_player_set_eq_enabled(handle, enabled) }
    @inline(always) var isEQEnabled: Bool { py_player_is_eq_enabled(handle) }
    @inline(always) func setEQBand(_ band: Int32, gain: Float) { py_player_set_eq_band(handle, band, gain) }
    @inline(always) func eqBand(_ band: Int32) -> Float { py_player_get_eq_band(handle, band) }
    @inline(always) func setEQPreset(_ preset: Int32) { py_player_set_eq_preset(handle, preset) }
    @inline(always) var eqPreset: Int32 { py_player_get_eq_preset(handle) }

    // Compressor
    @inline(always) func setCompressorEnabled(_ enabled: Bool) { py_player_set_compressor_enabled(handle, enabled) }
    @inline(always) var isCompressorEnabled: Bool { py_player_is_compressor_enabled(handle) }
    @inline(always) func setCompressorThreshold(_ db: Float) { py_player_set_compressor_threshold(handle, db) }
    @inline(always) func setCompressorRatio(_ ratio: Float) { py_player_set_compressor_ratio(handle, ratio) }
    @inline(always) func setCompressorAttack(_ ms: Float) { py_player_set_compressor_attack(handle, ms) }
    @inline(always) func setCompressorRelease(_ ms: Float) { py_player_set_compressor_release(handle, ms) }
    @inline(always) func setCompressorMakeup(_ db: Float) { py_player_set_compressor_makeup(handle, db) }

    // Dialogue Boost
    @inline(always) func setDialogueBoostEnabled(_ enabled: Bool) { py_player_set_dialogue_boost_enabled(handle, enabled) }
    @inline(always) var isDialogueBoostEnabled: Bool { py_player_is_dialogue_boost_enabled(handle) }
    @inline(always) func setDialogueBoostAmount(_ amount: Float) { py_player_set_dialogue_boost_amount(handle, amount) }
    @inline(always) var dialogueBoostAmount: Float { py_player_get_dialogue_boost_amount(handle) }

    // MARK: - Video Filters (GPU)

    @inline(always) func setBrightness(_ value: Float) { py_player_set_brightness(handle, value) }
    @inline(always) var brightness: Float { py_player_get_brightness(handle) }

    @inline(always) func setContrast(_ value: Float) { py_player_set_contrast(handle, value) }
    @inline(always) var contrast: Float { py_player_get_contrast(handle) }

    @inline(always) func setSaturation(_ value: Float) { py_player_set_saturation(handle, value) }
    @inline(always) var saturation: Float { py_player_get_saturation(handle) }

    @inline(always) func setSharpness(_ value: Float) { py_player_set_sharpness(handle, value) }
    @inline(always) var sharpness: Float { py_player_get_sharpness(handle) }

    @inline(always) func setDebandEnabled(_ enabled: Bool) { py_player_set_deband_enabled(handle, enabled) }
    @inline(always) var isDebandEnabled: Bool { py_player_is_deband_enabled(handle) }

    @inline(always) func setLanczosUpscaling(_ enabled: Bool) { py_player_set_lanczos_upscaling(handle, enabled) }
    @inline(always) var isLanczosUpscaling: Bool { py_player_is_lanczos_upscaling(handle) }

    @inline(always) func setFilmGrainEnabled(_ enabled: Bool) { py_player_set_film_grain_enabled(handle, enabled) }
    @inline(always) var isFilmGrainEnabled: Bool { py_player_is_film_grain_enabled(handle) }

    @inline(always) func resetVideoAdjustments() { py_player_reset_video_adjustments(handle) }

    // MARK: - Video Filters (CPU: Deinterlace)

    @inline(always) func setDeinterlaceEnabled(_ enabled: Bool) { py_player_set_deinterlace_enabled(handle, enabled) }
    @inline(always) var isDeinterlaceEnabled: Bool { py_player_is_deinterlace_enabled(handle) }
    @inline(always) func setDeinterlaceMode(_ mode: Int32) { py_player_set_deinterlace_mode(handle, mode) }
    @inline(always) var deinterlaceMode: Int32 { py_player_get_deinterlace_mode(handle) }

    @inline(always) func setAudioPassthrough(_ enabled: Bool) {
        py_player_set_audio_passthrough(handle, enabled)
    }

    @inline(always) var isPassthroughActive: Bool {
        py_player_is_passthrough_active(handle)
    }

    @inline(always) func queryPassthroughSupport() -> PYPassthroughCapabilities {
        py_player_query_passthrough_support(handle)
    }

    func setDeviceChangeCallback(_ callback: @escaping () -> Void) {
        // Release previously retained callback to avoid memory leak
        if let prev = deviceCallbackContext {
            Unmanaged<AnyObject>.fromOpaque(prev).release()
        }
        let context = Unmanaged.passRetained(callback as AnyObject).toOpaque()
        deviceCallbackContext = context
        py_player_set_device_change_callback(handle, deviceChangeTrampoline, context)
    }

    func setStateCallback(_ callback: @escaping (Int32) -> Void) {
        if let prev = stateCallbackContext {
            Unmanaged<AnyObject>.fromOpaque(prev).release()
        }
        let context = Unmanaged.passRetained(callback as AnyObject).toOpaque()
        stateCallbackContext = context
        py_player_set_state_callback(handle, stateChangeTrampoline, context)
    }

    // MARK: - Spatial audio

    @inline(always) func setSpatialAudioMode(_ mode: Int32) {
        py_player_set_spatial_audio_mode(handle, mode)
    }

    @inline(always) var spatialAudioMode: Int32 {
        py_player_get_spatial_audio_mode(handle)
    }

    @inline(always) var isSpatialActive: Bool {
        py_player_is_spatial_active(handle)
    }

    @inline(always) func setHeadTracking(_ enabled: Bool) {
        py_player_set_head_tracking(handle, enabled)
    }

    @inline(always) var isHeadTracking: Bool {
        py_player_is_head_tracking(handle)
    }

    @inline(always) func setMuted(_ muted: Bool) {
        py_player_set_muted(handle, muted)
    }

    @inline(always) var isMuted: Bool {
        py_player_is_muted(handle)
    }

    @inline(always) func setVolume(_ volume: Float) {
        py_player_set_volume(handle, volume)
    }

    @inline(always) var volume: Float {
        py_player_get_volume(handle)
    }

    @inline(always) func setPlaybackSpeed(_ speed: Double) {
        py_player_set_playback_speed(handle, speed)
    }

    @inline(always) var playbackSpeed: Double {
        py_player_get_playback_speed(handle)
    }

    @inline(always) func getPlaybackStats() -> PYPlaybackStats {
        py_player_get_playback_stats(handle)
    }

    func mediaInfoJSON() -> String {
        guard let cStr = py_player_get_media_info_json(handle) else { return "{}" }
        return String(cString: cStr)
    }

    // Video frame acquisition for Metal rendering
    @inline(always) func acquireVideoFrame(targetPts: Int64) -> UnsafeMutableRawPointer? {
        py_player_acquire_video_frame(handle, targetPts)
    }

    @inline(always) func releaseVideoFrame(_ frame: UnsafeMutableRawPointer) {
        py_player_release_video_frame(handle, frame)
    }

    static func framePixelBuffer(_ frame: UnsafeMutableRawPointer) -> CVPixelBuffer? {
        guard let ptr = py_player_frame_get_pixel_buffer(frame) else { return nil }
        return Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeUnretainedValue()
    }

    @inline(always) static func frameWidth(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_width(frame)
    }

    @inline(always) static func frameHeight(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_height(frame)
    }

    @inline(always) static func frameHDRType(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_hdr_type(frame)
    }

    @inline(always) static func frameMaxLuminance(_ frame: UnsafeMutableRawPointer) -> UInt32 {
        py_player_frame_get_max_luminance(frame)
    }

    @inline(always) static func frameMaxCLL(_ frame: UnsafeMutableRawPointer) -> UInt16 {
        py_player_frame_get_max_cll(frame)
    }

    @inline(always) static func frameMaxFALL(_ frame: UnsafeMutableRawPointer) -> UInt16 {
        py_player_frame_get_max_fall(frame)
    }

    @inline(always) static func frameColorTrc(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_trc(frame)
    }

    @inline(always) static func frameColorSpace(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_space(frame)
    }

    @inline(always) static func framePts(_ frame: UnsafeMutableRawPointer) -> Int64 {
        py_player_frame_get_pts(frame)
    }

    @inline(always) static func frameSarNum(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_sar_num(frame)
    }

    @inline(always) static func frameSarDen(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_sar_den(frame)
    }

    @inline(always) static func frameColorPrimaries(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_primaries(frame)
    }

    @inline(always) static func frameColorRange(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_color_range(frame)
    }

    @inline(always) static func frameChromaFormat(_ frame: UnsafeMutableRawPointer) -> Int32 {
        py_player_frame_get_chroma_format(frame)
    }

    // HDR10+ per-frame dynamic metadata
    @inline(always) static func frameHasHDR10Plus(_ frame: UnsafeMutableRawPointer) -> Bool {
        py_player_frame_has_hdr10plus(frame)
    }

    @inline(always) static func frameHDR10PlusTargetMaxLum(_ frame: UnsafeMutableRawPointer) -> Float {
        py_player_frame_hdr10plus_target_max_lum(frame)
    }

    @inline(always) static func frameHDR10PlusKneeX(_ frame: UnsafeMutableRawPointer) -> Float {
        py_player_frame_hdr10plus_knee_x(frame)
    }

    @inline(always) static func frameHDR10PlusKneeY(_ frame: UnsafeMutableRawPointer) -> Float {
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
    @inline(always) static func frameHasDoviColor(_ frame: UnsafeMutableRawPointer) -> Bool {
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

    @inline(always) static func frameMinLuminance(_ frame: UnsafeMutableRawPointer) -> UInt32 {
        py_player_frame_get_min_luminance(frame)
    }

    @inline(always) static func frameDoviHasReshaping(_ frame: UnsafeMutableRawPointer) -> Bool {
        py_player_frame_dovi_has_reshaping(frame)
    }

    static func frameDoviReshapeLUT(_ frame: UnsafeMutableRawPointer, component: Int32) -> [Float]? {
        var lut = [Float](repeating: 0, count: 1024)
        guard py_player_frame_dovi_reshape_lut(frame, component, &lut) else { return nil }
        return lut
    }

    // Seek preview thumbnails
    @inline(always) func startSeekThumbnails(interval: Int32 = 10) {
        py_player_start_seek_thumbnails(handle, interval)
    }

    @inline(always) func cancelSeekThumbnails() {
        py_player_cancel_seek_thumbnails(handle)
    }

    func seekThumbnail(at timestampUs: Int64) -> CGImage? {
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

    @inline(always) var seekThumbnailProgress: Int32 {
        py_player_get_seek_thumbnail_progress(handle)
    }

    // Subtitle
    func getSubtitle(at timestamp: Int64) -> SubtitleData? {
        guard let sf = py_player_get_subtitle(handle, timestamp) else { return nil }
        defer { py_subtitle_free(sf) }

        let pointed = sf.pointee
        if let text = pointed.text {
            return SubtitleData.text(String(cString: text))
        } else if let rgba = pointed.rgba_data {
            let size = Int(pointed.width) * Int(pointed.height) * 4
            let data = Data(bytes: rgba, count: size)
            return SubtitleData.bitmap(
                data: data,
                width: Int(pointed.width),
                height: Int(pointed.height),
                x: Int(pointed.x),
                y: Int(pointed.y)
            )
        }
        return nil
    }

}

enum SubtitleData {
    case text(String)
    case bitmap(data: Data, width: Int, height: Int, x: Int, y: Int)
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

    @inline(always) var itemCount: Int32 {
        py_library_get_item_count(handle)
    }

    @inline(always) var folderCount: Int32 {
        py_library_get_folder_count(handle)
    }

    @inline(always) func removeFolder(at index: Int32) -> Bool {
        py_library_remove_folder(handle, index) == Int32(PY_OK.rawValue)
    }

    @inline(always) static func generateThumbnail(videoPath: String, outputPath: String,
                                                    maxWidth: Int32, maxHeight: Int32) -> Bool {
        py_thumbnail_generate(videoPath, outputPath, maxWidth, maxHeight) == Int32(PY_OK.rawValue)
    }

    func addFolder(_ path: String) -> Bool {
        let result = py_library_add_folder(handle, path)
        return result == Int32(PY_OK.rawValue)
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

import Foundation
import CoreVideo

/// Swift wrapper around the C bridge API (plaiy_c.h)
class PlayerBridge {
    private let handle: OpaquePointer

    init() {
        handle = py_player_create()
    }

    deinit {
        py_player_destroy(handle)
    }

    func open(path: String) -> Bool {
        let result = py_player_open(handle, path)
        return result == Int32(PY_OK.rawValue)
    }

    func play() {
        py_player_play(handle)
    }

    func pause() {
        py_player_pause(handle)
    }

    func seek(to microseconds: Int64) {
        py_player_seek(handle, microseconds)
    }

    func stop() {
        py_player_stop(handle)
    }

    var state: Int32 {
        py_player_get_state(handle)
    }

    var position: Int64 {
        py_player_get_position(handle)
    }

    var duration: Int64 {
        py_player_get_duration(handle)
    }

    var audioTrackCount: Int32 {
        py_player_get_audio_track_count(handle)
    }

    var subtitleTrackCount: Int32 {
        py_player_get_subtitle_track_count(handle)
    }

    func selectAudioTrack(_ index: Int32) {
        py_player_select_audio_track(handle, index)
    }

    func selectSubtitleTrack(_ index: Int32) {
        py_player_select_subtitle_track(handle, index)
    }

    var activeAudioStream: Int32 {
        py_player_get_active_audio_stream(handle)
    }

    var activeSubtitleStream: Int32 {
        py_player_get_active_subtitle_stream(handle)
    }

    func setAudioPassthrough(_ enabled: Bool) {
        py_player_set_audio_passthrough(handle, enabled)
    }

    var isPassthroughActive: Bool {
        py_player_is_passthrough_active(handle)
    }

    func getPlaybackStats() -> PYPlaybackStats {
        py_player_get_playback_stats(handle)
    }

    func mediaInfoJSON() -> String {
        guard let cStr = py_player_get_media_info_json(handle) else { return "{}" }
        return String(cString: cStr)
    }

    // Video frame acquisition for Metal rendering
    func acquireVideoFrame(targetPts: Int64) -> UnsafeMutableRawPointer? {
        return py_player_acquire_video_frame(handle, targetPts)
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

    static func frameIsHardware(_ frame: UnsafeMutableRawPointer) -> Bool {
        py_player_frame_is_hardware(frame)
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

    func setStateCallback(_ callback: @escaping (Int32) -> Void) {
        // Store callback reference to prevent dealloc
        // For simplicity, we use the C callback with context
        // In production, this would need proper prevent-dealloc handling
    }
}

enum SubtitleData {
    case text(String)
    case bitmap(data: Data, width: Int, height: Int, x: Int, y: Int)
}

/// Library bridge
class LibraryBridge {
    private let handle: OpaquePointer

    init() {
        handle = py_library_create()
    }

    deinit {
        py_library_destroy(handle)
    }

    func addFolder(_ path: String) -> Bool {
        let result = py_library_add_folder(handle, path)
        return result == Int32(PY_OK.rawValue)
    }

    var itemCount: Int32 {
        py_library_get_item_count(handle)
    }

    func itemJSON(at index: Int32) -> String {
        guard let cStr = py_library_get_item_json(handle, index) else { return "{}" }
        return String(cString: cStr)
    }

    func allItemsJSON() -> String {
        guard let cStr = py_library_get_all_items_json(handle) else { return "[]" }
        return String(cString: cStr)
    }
}

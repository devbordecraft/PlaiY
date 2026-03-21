import Foundation
import CoreVideo

/// Swift wrapper around the C bridge API (testplayer_c.h)
class PlayerBridge {
    private let handle: OpaquePointer

    init() {
        handle = tp_player_create()
    }

    deinit {
        tp_player_destroy(handle)
    }

    func open(path: String) -> Bool {
        let result = tp_player_open(handle, path)
        return result == Int32(TP_OK.rawValue)
    }

    func play() {
        tp_player_play(handle)
    }

    func pause() {
        tp_player_pause(handle)
    }

    func seek(to microseconds: Int64) {
        tp_player_seek(handle, microseconds)
    }

    func stop() {
        tp_player_stop(handle)
    }

    var state: Int32 {
        tp_player_get_state(handle)
    }

    var position: Int64 {
        tp_player_get_position(handle)
    }

    var duration: Int64 {
        tp_player_get_duration(handle)
    }

    var audioTrackCount: Int32 {
        tp_player_get_audio_track_count(handle)
    }

    var subtitleTrackCount: Int32 {
        tp_player_get_subtitle_track_count(handle)
    }

    func selectAudioTrack(_ index: Int32) {
        tp_player_select_audio_track(handle, index)
    }

    func selectSubtitleTrack(_ index: Int32) {
        tp_player_select_subtitle_track(handle, index)
    }

    func mediaInfoJSON() -> String {
        guard let cStr = tp_player_get_media_info_json(handle) else { return "{}" }
        return String(cString: cStr)
    }

    // Video frame acquisition for Metal rendering
    func acquireVideoFrame(targetPts: Int64) -> UnsafeMutableRawPointer? {
        return tp_player_acquire_video_frame(handle, targetPts)
    }

    func releaseVideoFrame(_ frame: UnsafeMutableRawPointer) {
        tp_player_release_video_frame(handle, frame)
    }

    static func framePixelBuffer(_ frame: UnsafeMutableRawPointer) -> CVPixelBuffer? {
        guard let ptr = tp_player_frame_get_pixel_buffer(frame) else { return nil }
        return Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeUnretainedValue()
    }

    static func frameWidth(_ frame: UnsafeMutableRawPointer) -> Int32 {
        tp_player_frame_get_width(frame)
    }

    static func frameHeight(_ frame: UnsafeMutableRawPointer) -> Int32 {
        tp_player_frame_get_height(frame)
    }

    static func frameHDRType(_ frame: UnsafeMutableRawPointer) -> Int32 {
        tp_player_frame_get_hdr_type(frame)
    }

    static func frameColorTrc(_ frame: UnsafeMutableRawPointer) -> Int32 {
        tp_player_frame_get_color_trc(frame)
    }

    static func frameColorSpace(_ frame: UnsafeMutableRawPointer) -> Int32 {
        tp_player_frame_get_color_space(frame)
    }

    static func frameIsHardware(_ frame: UnsafeMutableRawPointer) -> Bool {
        tp_player_frame_is_hardware(frame)
    }

    // Subtitle
    func getSubtitle(at timestamp: Int64) -> SubtitleData? {
        guard let sf = tp_player_get_subtitle(handle, timestamp) else { return nil }
        defer { tp_subtitle_free(sf) }

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
        handle = tp_library_create()
    }

    deinit {
        tp_library_destroy(handle)
    }

    func addFolder(_ path: String) -> Bool {
        let result = tp_library_add_folder(handle, path)
        return result == Int32(TP_OK.rawValue)
    }

    var itemCount: Int32 {
        tp_library_get_item_count(handle)
    }

    func itemJSON(at index: Int32) -> String {
        guard let cStr = tp_library_get_item_json(handle, index) else { return "{}" }
        return String(cString: cStr)
    }

    func allItemsJSON() -> String {
        guard let cStr = tp_library_get_all_items_json(handle) else { return "[]" }
        return String(cString: cStr)
    }
}

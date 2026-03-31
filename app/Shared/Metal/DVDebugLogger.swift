#if DEBUG
import Foundation
import QuartzCore

/// Writes detailed per-frame DV metadata to /tmp/plaiy_dv_debug.log for debugging.
/// Throttled to 1 write/second. Only active in DEBUG builds.
final class DVDebugLogger {
    nonisolated(unsafe) static let shared = DVDebugLogger()

    private let fileURL = URL(fileURLWithPath: "/tmp/plaiy_dv_debug.log")
    private var lastLogTime: CFTimeInterval = 0
    private let throttleInterval: CFTimeInterval = 1.0
    private var frameCount: UInt64 = 0
    private var fileHandle: FileHandle?

    private init() {
        // Create or truncate the log file on first init
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
        write("=== PlaiY DV Debug Log — \(Date()) ===\n\n")
    }

    deinit {
        fileHandle?.closeFile()
    }

    func log(uniforms: VideoUniforms, reshapingActive: Bool, edrHeadroom: Float) {
        frameCount += 1
        let now = CACurrentMediaTime()
        guard now - lastLogTime >= throttleInterval else { return }
        lastLogTime = now

        var s = ""
        s += "--- Frame \(frameCount) @ \(String(format: "%.3f", now))s ---\n"

        // EDR / display
        s += "  EDR headroom: \(String(format: "%.2f", edrHeadroom))x"
        s += "  sdrWhite: \(String(format: "%.1f", uniforms.sdrWhite)) nits"
        s += "  display peak: \(String(format: "%.0f", edrHeadroom * uniforms.sdrWhite)) nits\n"

        // Color space routing
        s += "  colorSpace: \(uniforms.colorSpace) (0=709,1=2020,3=ICtCp)"
        s += "  transferFunc: \(uniforms.transferFunc) (0=SDR,1=PQ,2=HLG,3=DV-IPTPQc2)\n"

        // DV presence
        s += "  doviPresent: \(uniforms.doviPresent)"
        s += "  reshaping: \(reshapingActive ? "ACTIVE" : "DISABLED")\n"

        // L1 metadata
        if uniforms.doviHasL1 != 0 {
            let minNits = pqToNits(uniforms.doviL1MinPQ)
            let maxNits = pqToNits(uniforms.doviL1MaxPQ)
            let avgNits = pqToNits(uniforms.doviL1AvgPQ)
            s += "  L1 minPQ: \(String(format: "%.4f", uniforms.doviL1MinPQ))"
            s += " (\(String(format: "%.4f", minNits)) nits)"
            s += "  maxPQ: \(String(format: "%.4f", uniforms.doviL1MaxPQ))"
            s += " (\(String(format: "%.0f", maxNits)) nits)"
            s += "  avgPQ: \(String(format: "%.4f", uniforms.doviL1AvgPQ))"
            s += " (\(String(format: "%.0f", avgNits)) nits)\n"

            // Tone mapping decision
            let dstMaxPQ = linearToPQ(Double(edrHeadroom * uniforms.sdrWhite))
            let srcMaxPQ = Double(uniforms.doviL1MaxPQ)
            let willToneMap = srcMaxPQ > dstMaxPQ * 1.05
            let ks = max(0, min(1, 1.5 * dstMaxPQ / max(srcMaxPQ, 0.001) - 0.5))
            s += "  Tone map: \(willToneMap ? "YES" : "NO (src <= dst)")"
            s += "  srcMaxPQ=\(String(format: "%.4f", srcMaxPQ))"
            s += "  dstMaxPQ=\(String(format: "%.4f", dstMaxPQ))"
            s += "  kneeStart=\(String(format: "%.4f", ks))\n"
        } else {
            s += "  L1: NOT PRESENT (using fallback)\n"
        }

        // L2 metadata
        if uniforms.doviHasL2 != 0 {
            s += "  L2 slope: \(String(format: "%.4f", uniforms.doviL2Slope))"
            s += "  offset: \(String(format: "%.4f", uniforms.doviL2Offset))"
            s += "  power: \(String(format: "%.4f", uniforms.doviL2Power))"
            s += "  chromaW: \(String(format: "%.4f", uniforms.doviL2ChromaWeight))"
            s += "  satGain: \(String(format: "%.4f", uniforms.doviL2SatGain))\n"
        } else {
            s += "  L2: NOT PRESENT\n"
        }

        // YCC-to-RGB matrix diagonal + offset
        if uniforms.doviPresent != 0 {
            withUnsafePointer(to: uniforms.doviYccToRgb) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 9) { fp in
                    s += "  yccToRgb diag: [\(String(format: "%.4f", fp[0])), \(String(format: "%.4f", fp[4])), \(String(format: "%.4f", fp[8]))]\n"
                }
            }
            withUnsafePointer(to: uniforms.doviYccOffset) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 3) { fp in
                    s += "  yccOffset: [\(String(format: "%.4f", fp[0])), \(String(format: "%.4f", fp[1])), \(String(format: "%.4f", fp[2]))]\n"
                }
            }
            withUnsafePointer(to: uniforms.doviLmsToRgb) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 9) { fp in
                    s += "  lmsToRgb diag: [\(String(format: "%.4f", fp[0])), \(String(format: "%.4f", fp[4])), \(String(format: "%.4f", fp[8]))]\n"
                }
            }
        }

        s += "\n"
        write(s)
    }

    private func write(_ text: String) {
        if let data = text.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    // PQ EOTF: PQ [0,1] -> nits
    private func pqToNits(_ pq: Float) -> Double {
        let m1: Double = 0.1593017578125
        let m2: Double = 78.84375
        let c1: Double = 0.8359375
        let c2: Double = 18.8515625
        let c3: Double = 18.6875
        let Np = pow(max(Double(pq), 0.0), 1.0 / m2)
        let L = pow(max(Np - c1, 0.0) / (c2 - c3 * Np), 1.0 / m1)
        return L * 10000.0
    }

    // Linear nits -> PQ [0,1]
    private func linearToPQ(_ L: Double) -> Double {
        let m1: Double = 0.1593017578125
        let m2: Double = 78.84375
        let c1: Double = 0.8359375
        let c2: Double = 18.8515625
        let c3: Double = 18.6875
        let Y = max(L / 10000.0, 0.0)
        let Ym1 = pow(Y, m1)
        return pow((c1 + c2 * Ym1) / (1.0 + c3 * Ym1), m2)
    }
}
#endif

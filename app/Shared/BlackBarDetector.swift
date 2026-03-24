import CoreVideo
import Foundation

enum BlackBarDetector {
    private static let blackThreshold8bit: UInt8 = 24
    private static let blackThreshold16bit: UInt16 = 24 * 256
    /// A row/column is "black" if this fraction or more of pixels are below threshold
    private static let blackPixelFraction: Double = 0.95

    /// Analyze a CVPixelBuffer's Y (luma) plane and return normalized crop insets
    /// for detected black bars. Thread-safe; caller must retain the pixel buffer.
    static func detect(pixelBuffer: CVPixelBuffer) -> CropInsets {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return .zero
        }

        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pixFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is10bit = (pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        // Scan from top
        var topCrop = 0
        for row in 0..<(height / 2) {
            if !isBlackRow(base: baseAddress, stride: stride, row: row,
                           width: width, is10bit: is10bit) { break }
            topCrop = row + 1
        }

        // Scan from bottom
        var bottomCrop = 0
        for row in Swift.stride(from: height - 1, through: height / 2, by: -1) {
            if !isBlackRow(base: baseAddress, stride: stride, row: row,
                           width: width, is10bit: is10bit) { break }
            bottomCrop += 1
        }

        // Scan from left
        var leftCrop = 0
        for col in 0..<(width / 2) {
            if !isBlackColumn(base: baseAddress, stride: stride, col: col,
                              height: height, is10bit: is10bit) { break }
            leftCrop = col + 1
        }

        // Scan from right
        var rightCrop = 0
        for col in Swift.stride(from: width - 1, through: width / 2, by: -1) {
            if !isBlackColumn(base: baseAddress, stride: stride, col: col,
                              height: height, is10bit: is10bit) { break }
            rightCrop += 1
        }

        // Subtract a small margin to avoid edge artifacts
        topCrop = max(0, topCrop - 2)
        bottomCrop = max(0, bottomCrop - 2)
        leftCrop = max(0, leftCrop - 2)
        rightCrop = max(0, rightCrop - 2)

        return CropInsets(
            top: Double(topCrop) / Double(height),
            bottom: Double(bottomCrop) / Double(height),
            left: Double(leftCrop) / Double(width),
            right: Double(rightCrop) / Double(width)
        )
    }

    private static func isBlackRow(base: UnsafeMutableRawPointer, stride: Int,
                                   row: Int, width: Int, is10bit: Bool) -> Bool {
        let rowPtr = base.advanced(by: row * stride)
        let maxNonBlack = Int(Double(width) * (1.0 - blackPixelFraction))
        var nonBlack = 0

        if is10bit {
            let pixels = rowPtr.assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                if pixels[x] > blackThreshold16bit { nonBlack += 1 }
                if nonBlack > maxNonBlack { return false }
            }
        } else {
            let pixels = rowPtr.assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                if pixels[x] > blackThreshold8bit { nonBlack += 1 }
                if nonBlack > maxNonBlack { return false }
            }
        }
        return true
    }

    private static func isBlackColumn(base: UnsafeMutableRawPointer, stride: Int,
                                      col: Int, height: Int, is10bit: Bool) -> Bool {
        let maxNonBlack = Int(Double(height) * (1.0 - blackPixelFraction))
        var nonBlack = 0
        let bytesPerPixel = is10bit ? 2 : 1

        for y in 0..<height {
            let addr = base.advanced(by: y * stride + col * bytesPerPixel)
            if is10bit {
                if addr.load(as: UInt16.self) > blackThreshold16bit { nonBlack += 1 }
            } else {
                if addr.load(as: UInt8.self) > blackThreshold8bit { nonBlack += 1 }
            }
            if nonBlack > maxNonBlack { return false }
        }
        return true
    }
}

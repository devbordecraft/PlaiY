import SwiftUI

struct SubtitleOverlayView: View {
    let subtitle: SubtitleData?

    // Cache last decoded bitmap to avoid re-creating NSImage/UIImage every frame
    private static var cachedDataCount: Int = 0
    #if os(macOS)
    private static var cachedImage: NSImage?
    #else
    private static var cachedImage: UIImage?
    #endif

    var body: some View {
        VStack {
            Spacer()

            if let subtitle {
                switch subtitle {
                case .text(let text):
                    Text(text)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 1, y: 1)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.black.opacity(0.6))
                        )
                        .multilineTextAlignment(.center)

                case .bitmap(let data, let width, let height, _, _):
                    if let image = cachedBitmapImage(data: data, width: width, height: height) {
                        #if os(macOS)
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 600)
                        #else
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 600)
                        #endif
                    }
                }
            }
        }
        .padding(.bottom, 60)
    }

    #if os(macOS)
    private func cachedBitmapImage(data: Data, width: Int, height: Int) -> NSImage? {
        if data.count == Self.cachedDataCount, let cached = Self.cachedImage {
            return cached
        }
        let image = bitmapImage(data: data, width: width, height: height)
        Self.cachedDataCount = data.count
        Self.cachedImage = image
        return image
    }

    private func bitmapImage(data: Data, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { return nil }

        data.withUnsafeBytes { ptr in
            if let src = ptr.baseAddress {
                memcpy(rep.bitmapData!, src, min(data.count, width * height * 4))
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
    #else
    private func cachedBitmapImage(data: Data, width: Int, height: Int) -> UIImage? {
        if data.count == Self.cachedDataCount, let cached = Self.cachedImage {
            return cached
        }
        let image = bitmapImage(data: data, width: width, height: height)
        Self.cachedDataCount = data.count
        Self.cachedImage = image
        return image
    }

    private func bitmapImage(data: Data, width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: (data as NSData).bytes),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

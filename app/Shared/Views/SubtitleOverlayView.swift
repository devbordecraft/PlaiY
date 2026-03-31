import SwiftUI

struct SubtitleOverlayView: View {
    @EnvironmentObject var settings: AppSettings
    let subtitle: SubtitleData?
    var isHDRContent: Bool = false
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var videoSARNum: Int = 1
    var videoSARDen: Int = 1
    var displaySettings: VideoDisplaySettings = .default

    // Cache decoded bitmap regions to avoid re-creating platform images every frame.
    #if os(macOS)
    @MainActor private static var cachedImages: [Int: NSImage] = [:]
    #else
    @MainActor private static var cachedImages: [Int: UIImage] = [:]
    #endif

    var body: some View {
        GeometryReader { geometry in
            switch subtitle {
            case .some(.text(let text)):
                VStack {
                    Spacer()
                    Text(text)
                        .font(settings.subtitleFont)
                        .fontWeight(.medium)
                        .foregroundStyle(settings.subtitleForegroundColor)
                        .brightness(isHDRContent ? 0.3 : 0.0)
                        .shadow(color: .black, radius: 2, x: 1, y: 1)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(settings.subtitleBackgroundColor)
                        )
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 60)

            case .some(.bitmap(let regions)):
                let videoRect = subtitleViewport(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                        if let image = cachedBitmapImage(
                            data: region.data,
                            width: region.width,
                            height: region.height
                        ) {
                            let frame = subtitleRegionFrame(region, in: videoRect)
                            bitmapImageView(image)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            case nil:
                EmptyView()
            }
        }
    }

    #if os(macOS)
    @MainActor
    private func cachedBitmapImage(data: Data, width: Int, height: Int) -> NSImage? {
        let hash = data.hashValue ^ (width << 4) ^ height
        if let cached = Self.cachedImages[hash] {
            return cached
        }
        let image = bitmapImage(data: data, width: width, height: height)
        if let image {
            Self.cachedImages[hash] = image
        }
        return image
    }

    @ViewBuilder
    private func bitmapImageView(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.none)
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
        ), let bitmapData = rep.bitmapData else { return nil }

        data.withUnsafeBytes { ptr in
            if let src = ptr.baseAddress {
                memcpy(bitmapData, src, min(data.count, width * height * 4))
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
    #else
    @MainActor
    private func cachedBitmapImage(data: Data, width: Int, height: Int) -> UIImage? {
        let hash = data.hashValue ^ (width << 4) ^ height
        if let cached = Self.cachedImages[hash] {
            return cached
        }
        let image = bitmapImage(data: data, width: width, height: height)
        if let image {
            Self.cachedImages[hash] = image
        }
        return image
    }

    @ViewBuilder
    private func bitmapImageView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.none)
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

    func subtitleViewport(in size: CGSize) -> CGRect {
        guard videoWidth > 0, videoHeight > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let nativeDAR = (Double(videoWidth) * Double(max(videoSARNum, 1))) /
                        (Double(videoHeight) * Double(max(videoSARDen, 1)))

        var effectiveDAR: Double
        if let forced = displaySettings.aspectRatioMode.forcedDAR {
            effectiveDAR = forced
        } else {
            effectiveDAR = nativeDAR
            if displaySettings.crop.isActive {
                effectiveDAR *= Double(displaySettings.crop.texScaleX) /
                                Double(displaySettings.crop.texScaleY)
            }
        }

        let viewW = Double(size.width)
        let viewH = Double(size.height)
        let viewAR = viewW / viewH
        var vpW = viewW
        var vpH = viewH

        switch displaySettings.aspectRatioMode {
        case .stretch:
            break
        case .fill:
            if effectiveDAR > viewAR {
                vpW = viewH * effectiveDAR
                vpH = viewH
            } else if effectiveDAR < viewAR {
                vpH = viewW / effectiveDAR
                vpW = viewW
            }
        default:
            if effectiveDAR > viewAR {
                vpH = vpW / effectiveDAR
            } else if effectiveDAR < viewAR {
                vpW = vpH * effectiveDAR
            }
        }

        let zoom = max(1.0, displaySettings.zoom)
        vpW *= zoom
        vpH *= zoom

        var vpX = (viewW - vpW) / 2.0
        var vpY = (viewH - vpH) / 2.0
        let maxPanX = max(0, (vpW - viewW) / 2.0)
        let maxPanY = max(0, (vpH - viewH) / 2.0)
        vpX += displaySettings.panX * maxPanX
        vpY += displaySettings.panY * maxPanY

        return CGRect(x: vpX, y: vpY, width: vpW, height: vpH)
    }

    func subtitleRegionFrame(_ region: SubtitleBitmapRegion, in videoRect: CGRect) -> CGRect {
        guard videoWidth > 0, videoHeight > 0 else {
            return CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        }

        let scaleX = videoRect.width / CGFloat(videoWidth)
        let scaleY = videoRect.height / CGFloat(videoHeight)

        return CGRect(
            x: videoRect.minX + CGFloat(region.x) * scaleX,
            y: videoRect.minY + CGFloat(region.y) * scaleY,
            width: CGFloat(region.width) * scaleX,
            height: CGFloat(region.height) * scaleY
        )
    }
}

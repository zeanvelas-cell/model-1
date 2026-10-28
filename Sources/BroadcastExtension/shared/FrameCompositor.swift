import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import ReplayKit
import ImageIO

public final class FrameCompositor: @unchecked Sendable {
    private let ciContext: CIContext
    private let bt709ColorSpace: CGColorSpace
    private var settings: PulseSettings
    private var targetSize: CGSize
    private var solidBlackCanvas: CIImage
    private var privacyShieldCanvas: CIImage
    private let settingsLock = NSLock()

    private var retainedShortsBgBuffer: CVPixelBuffer?
    private var retainedLandscapeOverlayBuffer: CVPixelBuffer?
    private var shortsBackgroundImage: CIImage?
    private var landscapeOverlayImage: CIImage?
    private var pixelBufferPool: CVPixelBufferPool?

    public init(settings: PulseSettings) {
        var effectiveSettings = settings
        // Automatic 50MB Extension Safety Stepdown if available RAM is critically low (<15MB) at startup
        if AppGroupBridge.currentProcessAvailableMemoryMB() < 15 {
            effectiveSettings.qualityTier = .safe720p
        }
        self.settings = effectiveSettings
        let resolvedSize = effectiveSettings.resolvedCanvasSize
        self.targetSize = resolvedSize

        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        self.bt709ColorSpace = colorSpace

        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace,
                .cacheIntermediates: false
            ])
        } else {
            self.ciContext = CIContext(options: [
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace,
                .cacheIntermediates: false
            ])
        }

        let bounds = CGRect(origin: .zero, size: resolvedSize)
        self.solidBlackCanvas = CIImage(color: .black).cropped(to: bounds)
        self.privacyShieldCanvas = CIImage(color: CIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)).cropped(to: bounds)
        self.pixelBufferPool = Self.createNV12Pool(width: Int(resolvedSize.width), height: Int(resolvedSize.height))
        self.reloadStaticOverlays(with: effectiveSettings)
    }

    public func updateLiveSettings(_ newSettings: PulseSettings) {
        settingsLock.lock()
        self.settings = newSettings
        settingsLock.unlock()
    }

    public func reloadOverlaysFromDisk() {
        let current = readCurrentSettingsSync()
        reloadStaticOverlays(with: current)
    }

    private func readCurrentSettingsSync() -> PulseSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return settings
    }

    private func reloadStaticOverlays(with currentSettings: PulseSettings) {
        // Free existing GPU buffers FIRST before allocating new ones to prevent any 2x memory spike
        settingsLock.lock()
        retainedShortsBgBuffer = nil
        shortsBackgroundImage = nil
        retainedLandscapeOverlayBuffer = nil
        landscapeOverlayImage = nil
        settingsLock.unlock()

        guard currentSettings.enableStaticGapOverlay else { return }

        let canvasSize = self.targetSize
        if currentSettings.aspectMode == .verticalShorts9x16,
           let url = AppGroupBridge.bakedShortsURL,
           let diskCI = CIImage(contentsOf: url) {
            let scaledCI = diskCI.transformed(by: CGAffineTransform(
                scaleX: canvasSize.width / max(1, diskCI.extent.width),
                y: canvasSize.height / max(1, diskCI.extent.height)
            ))
            if let gpuBuf = Self.renderToRetainedBuffer(
                ciImage: scaledCI,
                size: canvasSize,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                context: ciContext,
                colorSpace: bt709ColorSpace
            ) {
                let ciImg = CIImage(cvPixelBuffer: gpuBuf)
                settingsLock.lock()
                self.retainedShortsBgBuffer = gpuBuf
                self.shortsBackgroundImage = ciImg
                settingsLock.unlock()
            }
        } else if currentSettings.aspectMode == .landscape16x9,
                  let url = AppGroupBridge.bakedLandscapeURL,
                  let diskCI = CIImage(contentsOf: url) {
            let scaledCI = diskCI.transformed(by: CGAffineTransform(
                scaleX: canvasSize.width / max(1, diskCI.extent.width),
                y: canvasSize.height / max(1, diskCI.extent.height)
            ))
            if let gpuBuf = Self.renderToRetainedBuffer(
                ciImage: scaledCI,
                size: canvasSize,
                pixelFormat: kCVPixelFormatType_32BGRA,
                context: ciContext,
                colorSpace: bt709ColorSpace
            ) {
                let ciImg = CIImage(cvPixelBuffer: gpuBuf)
                settingsLock.lock()
                self.retainedLandscapeOverlayBuffer = gpuBuf
                self.landscapeOverlayImage = ciImg
                settingsLock.unlock()
            }
        }
    }

    private static func renderToRetainedBuffer(
        ciImage: CIImage,
        size: CGSize,
        pixelFormat: OSType,
        context: CIContext,
        colorSpace: CGColorSpace
    ) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            pixelFormat,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let dst = buffer else { return nil }
        context.render(ciImage, to: dst, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        return dst
    }

    private static func createNV12Pool(width: Int, height: Int) -> CVPixelBufferPool? {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 2
        ]
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, pixelAttrs as CFDictionary, &pool)
        return pool
    }

    private func snapshotCompositorState() -> (PulseSettings, CIImage?, CIImage?) {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return (settings, shortsBackgroundImage, landscapeOverlayImage)
    }

    public func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let inPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let (activeSettings, activeShortsBg, activeLandscapeOverlay) = snapshotCompositorState()
        let canvasBounds = CGRect(origin: .zero, size: targetSize)

        if activeSettings.enablePrivacyShieldBanner {
            let shieldImage = activeShortsBg ?? activeLandscapeOverlay ?? privacyShieldCanvas
            return renderOutputSampleBuffer(from: shieldImage.cropped(to: canvasBounds), referenceSampleBuffer: sampleBuffer, canvasBounds: canvasBounds)
        }

        var rawImage = CIImage(cvPixelBuffer: inPixelBuffer)

        if let orientationAttachment = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            let orientationValue = orientationAttachment.uint32Value
            if let cgOrientation = CGImagePropertyOrientation(rawValue: orientationValue),
               cgOrientation != .up {
                rawImage = rawImage.oriented(cgOrientation)
            }
        }

        let src = rawImage.extent
        guard src.width > 0, src.height > 0 else { return nil }

        let finalCIImage: CIImage

        switch activeSettings.aspectMode {
        case .landscape16x9:
            let scale = min(targetSize.width / src.width, targetSize.height / src.height)
            let scaledW = src.width * scale
            let scaledH = src.height * scale
            let offsetX = (targetSize.width - scaledW) * 0.5
            let offsetY = (targetSize.height - scaledH) * 0.5

            let normalized = rawImage.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
            let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

            var base = positioned.composited(over: solidBlackCanvas)
            if activeSettings.enableStaticGapOverlay, let overlay = activeLandscapeOverlay {
                base = overlay.composited(over: base)
            }
            finalCIImage = base.cropped(to: canvasBounds)

        case .verticalShorts9x16:
            var workingImage = rawImage.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
            var workWidth = src.width
            var workHeight = src.height

            if workWidth > workHeight, let targetAspect = activeSettings.shortsCropPreset.targetAspectRatio {
                let currentAspect = workWidth / workHeight
                if currentAspect > targetAspect + 0.03 {
                    let croppedWidth = round(workHeight * targetAspect)
                    let cropX = round((workWidth - croppedWidth) * 0.5)
                    let cropRect = CGRect(x: cropX, y: 0, width: croppedWidth, height: workHeight)
                    workingImage = workingImage.cropped(to: cropRect)
                        .transformed(by: CGAffineTransform(translationX: -cropX, y: 0))
                    workWidth = croppedWidth
                }
            }

            let scale = min(targetSize.width / workWidth, targetSize.height / workHeight)
            let scaledW = workWidth * scale
            let scaledH = workHeight * scale
            let offsetX = (targetSize.width - scaledW) * 0.5
            let centerY = (targetSize.height - scaledH) * 0.5

            let maxSafeOffset = max(0, (targetSize.height - scaledH) * 0.5)
            let clampedOffset = min(max(activeSettings.shortsGameVerticalOffset, -maxSafeOffset), maxSafeOffset)

            let scaled = workingImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: offsetX,
                y: centerY - clampedOffset
            ))

            let bg = (activeSettings.enableStaticGapOverlay ? activeShortsBg : nil) ?? solidBlackCanvas
            finalCIImage = positioned.composited(over: bg).cropped(to: canvasBounds)
        }

        return renderOutputSampleBuffer(from: finalCIImage, referenceSampleBuffer: sampleBuffer, canvasBounds: canvasBounds)
    }

    private func renderOutputSampleBuffer(
        from finalCIImage: CIImage,
        referenceSampleBuffer: CMSampleBuffer,
        canvasBounds: CGRect
    ) -> CMSampleBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var outPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPixelBuffer)
        guard status == kCVReturnSuccess, let dstBuffer = outPixelBuffer else { return nil }

        CVBufferSetAttachment(dstBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(dstBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(dstBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        ciContext.render(finalCIImage, to: dstBuffer, bounds: canvasBounds, colorSpace: bt709ColorSpace)

        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(referenceSampleBuffer, at: 0, timingInfoOut: &timingInfo)

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: dstBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let validFormat = formatDesc else { return nil }

        var outputSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: dstBuffer,
            formatDescription: validFormat,
            sampleTiming: &timingInfo,
            sampleBufferOut: &outputSampleBuffer
        )
        return outputSampleBuffer
    }
}

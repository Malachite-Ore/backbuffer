import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// GPU-backed 2-slot pixel buffer pool + VTPixelTransferSession so incoming ScreenCaptureKit
/// IOSurface pixel buffers can be blitted and released immediately inside capture callbacks.
public final class PixelTransferPool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType

    private let lock = NSLock()
    private var pixelBufferPool: CVPixelBufferPool?
    private var transferSession: VTPixelTransferSession?

    public init(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        minimumBufferCount: Int = 2
    ) throws {
        guard width > 0, height > 0 else {
            throw BackbufferError.pixelTransferFailed("Invalid transfer pool dimensions \(width)x\(height).")
        }

        let sanitized = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: CGFloat(width),
            logicalHeight: CGFloat(height),
            pointPixelScale: 1.0,
            cap: .native
        )
        self.width = sanitized.width
        self.height = sanitized.height
        self.pixelFormat = pixelFormat

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: max(2, minimumBufferCount)
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
            kCVPixelBufferWidthKey as String: sanitized.width,
            kCVPixelBufferHeightKey as String: sanitized.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var poolOut: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &poolOut
        )
        guard poolStatus == kCVReturnSuccess, let pool = poolOut else {
            throw BackbufferError.pixelTransferFailed("CVPixelBufferPoolCreate failed (CVReturn \(poolStatus)).")
        }

        var sessionOut: VTPixelTransferSession?
        let sessionStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &sessionOut
        )
        guard sessionStatus == noErr, let session = sessionOut else {
            throw BackbufferError.pixelTransferFailed("VTPixelTransferSessionCreate failed (OSStatus \(sessionStatus)).")
        }

        self.pixelBufferPool = pool
        self.transferSession = session
    }

    public func copyToDetachedBuffer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }

        guard let pool = pixelBufferPool, let session = transferSession else {
            throw BackbufferError.pixelTransferFailed("PixelTransferPool has been invalidated.")
        }

        var destOut: CVPixelBuffer?
        let allocStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destOut)
        guard allocStatus == kCVReturnSuccess, let destination = destOut else {
            throw BackbufferError.pixelTransferFailed("CVPixelBufferPoolCreatePixelBuffer failed (CVReturn \(allocStatus)).")
        }

        let transferStatus = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard transferStatus == noErr else {
            throw BackbufferError.pixelTransferFailed("VTPixelTransferSessionTransferImage failed (OSStatus \(transferStatus)).")
        }

        return destination
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if let session = transferSession {
            VTPixelTransferSessionInvalidate(session)
            transferSession = nil
        }
        if let pool = pixelBufferPool {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
            pixelBufferPool = nil
        }
    }

    deinit {
        if let session = transferSession {
            VTPixelTransferSessionInvalidate(session)
        }
        if let pool = pixelBufferPool {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
        }
    }
}

// MARK: - VideoEncoder

private final class EncoderCallbackContext: @unchecked Sendable {
    let onPacket: @Sendable (BufferedVideoPacket) -> Void
    let onError: (@Sendable (BackbufferError) -> Void)?
    private let lock = NSLock()
    private var invalidated = false
    private var lastAsyncError: BackbufferError?

    init(
        onPacket: @escaping @Sendable (BufferedVideoPacket) -> Void,
        onError: (@Sendable (BackbufferError) -> Void)?
    ) {
        self.onPacket = onPacket
        self.onError = onError
    }

    var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func markInvalidated() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func recordAsyncError(_ error: BackbufferError) {
        lock.lock()
        lastAsyncError = error
        let handler = onError
        lock.unlock()
        handler?(error)
    }

    func consumeAsyncError() -> BackbufferError? {
        lock.lock()
        let error = lastAsyncError
        lastAsyncError = nil
        lock.unlock()
        return error
    }
}

private func videoEncoderOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let context = Unmanaged<EncoderCallbackContext>.fromOpaque(refCon).takeUnretainedValue()
    guard !context.isInvalidated else { return }

    if status != noErr {
        context.recordAsyncError(.encodeFailed("VideoToolbox compression callback failed (OSStatus \(status))."))
        return
    }

    if infoFlags.contains(.frameDropped) {
        return
    }

    guard let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer),
          CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
        return
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isNumeric else { return }
    let duration = CMSampleBufferGetDuration(sampleBuffer)
    let isKeyframe = VideoEncoder.isSampleBufferKeyframe(sampleBuffer)

    let packet = BufferedVideoPacket(
        pts: pts,
        isKeyframe: isKeyframe,
        sampleBuffer: sampleBuffer,
        duration: duration
    )
    context.onPacket(packet)
}

/// Real-time VideoToolbox encoder (HEVC / H.264) with zero B-frames, 1s IDR keyframes,
/// Intel QuickSync 4096 px width guard, and optional 1/fps CFR keepalive over a 2-slot GPU PixelTransferPool.
public final class VideoEncoder: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let codec: VideoCodecChoice
    public let bitrateBps: Int
    public let fps: Int

    private let queue = DispatchQueue(label: "io.malachiteore.backbuffer.videoencoder", qos: .userInteractive)
    private let callbackContext: EncoderCallbackContext
    private var retainedRefCon: UnsafeMutableRawPointer?
    private let frameDuration: CMTime
    private let frameDurationSeconds: Double
    private let enableCFRKeepalive: Bool

    private var session: VTCompressionSession?
    private var transferPool: PixelTransferPool?
    private var latestDetachedFrame: CVPixelBuffer?
    private var lastEncodedPTS: CMTime = .invalid
    private var lastLiveFrameUptimeNs: UInt64 = 0
    private var lastEmitUptimeNs: UInt64 = 0
    private var keepaliveTimer: DispatchSourceTimer?
    private var isKeepalivePaused = false
    private var isInvalidated = true

    public init(
        width: Int,
        height: Int,
        codec: VideoCodecChoice,
        bitrateBps: Int,
        fps: Int = 60,
        maxKeyframeIntervalSeconds: Double = 1.0,
        enableCFRKeepalive: Bool = false,
        onPacket: @escaping @Sendable (BufferedVideoPacket) -> Void,
        onError: (@Sendable (BackbufferError) -> Void)? = nil
    ) throws {
        guard width > 0, height > 0 else {
            throw BackbufferError.encoderSetupFailed("Invalid encoder dimensions \(width)x\(height).")
        }

        let sanitized = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: CGFloat(width),
            logicalHeight: CGFloat(height),
            pointPixelScale: 1.0,
            cap: .native
        )
        let clampedFPS = max(1, fps)
        let clampedBitrate = max(150_000, bitrateBps)
        let clampedKeyframeInterval = max(0.2, maxKeyframeIntervalSeconds)

        self.width = sanitized.width
        self.height = sanitized.height
        self.codec = codec
        self.bitrateBps = clampedBitrate
        self.fps = clampedFPS
        self.frameDuration = CMTime(value: 1, timescale: Int32(clampedFPS))
        self.frameDurationSeconds = 1.0 / Double(clampedFPS)
        self.enableCFRKeepalive = enableCFRKeepalive

        let pool: PixelTransferPool?
        if enableCFRKeepalive {
            pool = try PixelTransferPool(
                width: sanitized.width,
                height: sanitized.height,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                minimumBufferCount: 2
            )
        } else {
            pool = nil
        }

        let context = EncoderCallbackContext(onPacket: onPacket, onError: onError)
        self.callbackContext = context
        let refCon = Unmanaged.passRetained(context).toOpaque()

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: sanitized.width,
            kCVPixelBufferHeightKey as String: sanitized.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        // Prefer hardware encoding on real Macs without breaking virtualized CI runners that lack AppleAVD.
        let encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]

        var sessionOut: VTCompressionSession?
        var createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(sanitized.width),
            height: Int32(sanitized.height),
            codecType: codec.cmVideoCodecType,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: videoEncoderOutputCallback,
            refcon: refCon,
            compressionSessionOut: &sessionOut
        )

        if createStatus != noErr || sessionOut == nil {
            createStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(sanitized.width),
                height: Int32(sanitized.height),
                codecType: codec.cmVideoCodecType,
                encoderSpecification: nil,
                imageBufferAttributes: sourceAttributes as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: videoEncoderOutputCallback,
                refcon: refCon,
                compressionSessionOut: &sessionOut
            )
        }

        guard createStatus == noErr, let compressionSession = sessionOut else {
            Unmanaged<EncoderCallbackContext>.fromOpaque(refCon).release()
            pool?.invalidate()
            throw BackbufferError.encoderSetupFailed("VTCompressionSessionCreate failed (OSStatus \(createStatus)).")
        }

        do {
            try Self.configureSession(
                compressionSession,
                codec: codec,
                bitrateBps: clampedBitrate,
                fps: clampedFPS,
                maxKeyframeIntervalSeconds: clampedKeyframeInterval
            )
        } catch {
            context.markInvalidated()
            VTCompressionSessionInvalidate(compressionSession)
            Unmanaged<EncoderCallbackContext>.fromOpaque(refCon).release()
            pool?.invalidate()
            throw error
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        if prepareStatus != noErr {
            context.markInvalidated()
            VTCompressionSessionInvalidate(compressionSession)
            Unmanaged<EncoderCallbackContext>.fromOpaque(refCon).release()
            pool?.invalidate()
            throw BackbufferError.encoderSetupFailed("VTCompressionSessionPrepareToEncodeFrames failed (OSStatus \(prepareStatus)).")
        }

        self.transferPool = pool
        self.session = compressionSession
        self.retainedRefCon = refCon
        self.isInvalidated = false
    }

    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime? = nil
    ) throws {
        guard presentationTimeStamp.isNumeric else {
            throw BackbufferError.encodeFailed("Invalid presentation timestamp for frame.")
        }

        try queue.sync {
            guard !isInvalidated, let compressionSession = session else {
                throw BackbufferError.encodeFailed("VideoEncoder has been invalidated.")
            }

            let bufferToEncode: CVPixelBuffer
            if CVPixelBufferGetWidth(pixelBuffer) != width || CVPixelBufferGetHeight(pixelBuffer) != height {
                let pool = try ensureTransferPoolLocked()
                bufferToEncode = try pool.copyToDetachedBuffer(pixelBuffer)
            } else {
                bufferToEncode = pixelBuffer
            }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            lastLiveFrameUptimeNs = nowNs
            lastEmitUptimeNs = nowNs

            let monotonicPTS = makeMonotonicPTSLocked(requested: presentationTimeStamp)
            try encodeFrameLocked(
                compressionSession,
                pixelBuffer: bufferToEncode,
                pts: monotonicPTS,
                duration: duration ?? frameDuration
            )
        }
    }

    /// GPU-blits a ScreenCaptureKit frame into the 2-slot PixelTransferPool so the caller's IOSurface
    /// can be released immediately upon return, updates the CFR keepalive frame slot, and encodes it.
    public func ingestLivePixelBuffer(
        _ sourcePixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime
    ) throws {
        guard presentationTimeStamp.isNumeric else {
            throw BackbufferError.encodeFailed("Invalid presentation timestamp for live frame.")
        }

        try queue.sync {
            guard !isInvalidated, let compressionSession = session else {
                throw BackbufferError.encodeFailed("VideoEncoder has been invalidated.")
            }

            let pool = try ensureTransferPoolLocked()
            let detached = try pool.copyToDetachedBuffer(sourcePixelBuffer)

            let nowNs = DispatchTime.now().uptimeNanoseconds
            lastLiveFrameUptimeNs = nowNs
            lastEmitUptimeNs = nowNs
            latestDetachedFrame = detached

            let monotonicPTS = makeMonotonicPTSLocked(requested: presentationTimeStamp)
            try encodeFrameLocked(
                compressionSession,
                pixelBuffer: detached,
                pts: monotonicPTS,
                duration: frameDuration
            )

            if enableCFRKeepalive && !isKeepalivePaused && keepaliveTimer == nil {
                startKeepaliveTimerLocked()
            }
        }
    }

    public func setKeepalivePaused(_ paused: Bool) {
        queue.sync {
            guard !isInvalidated else { return }
            isKeepalivePaused = paused
            if paused {
                stopKeepaliveTimerLocked()
            } else if enableCFRKeepalive && latestDetachedFrame != nil && keepaliveTimer == nil {
                let nowNs = DispatchTime.now().uptimeNanoseconds
                lastLiveFrameUptimeNs = nowNs
                lastEmitUptimeNs = nowNs
                startKeepaliveTimerLocked()
            }
        }
    }

    public func flush() throws {
        try queue.sync {
            guard !isInvalidated, let compressionSession = session else { return }
            let status = VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            if status != noErr {
                throw BackbufferError.encodeFailed("VTCompressionSessionCompleteFrames failed (OSStatus \(status)).")
            }
            if let asyncError = callbackContext.consumeAsyncError() {
                throw asyncError
            }
        }
    }

    public func invalidate() {
        queue.sync {
            invalidateLocked()
        }
    }

    deinit {
        if !isInvalidated {
            stopKeepaliveTimerLocked()
            callbackContext.markInvalidated()
            if let compressionSession = session {
                VTCompressionSessionInvalidate(compressionSession)
                session = nil
            }
            latestDetachedFrame = nil
            transferPool?.invalidate()
            transferPool = nil
            if let refCon = retainedRefCon {
                Unmanaged<EncoderCallbackContext>.fromOpaque(refCon).release()
                retainedRefCon = nil
            }
            isInvalidated = true
        }
    }

    // MARK: - Helpers

    static func isSampleBufferKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
              let first = attachments.first else {
            return true
        }
        if let notSyncBool = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSyncBool
        }
        if let notSyncNum = first[kCMSampleAttachmentKey_NotSync] as? NSNumber {
            return !notSyncNum.boolValue
        }
        return true
    }

    private static func configureSession(
        _ session: VTCompressionSession,
        codec: VideoCodecChoice,
        bitrateBps: Int,
        fps: Int,
        maxKeyframeIntervalSeconds: Double
    ) throws {
        try setRequiredProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try setRequiredProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        let keyframeIntervalFrames = max(1, Int((Double(fps) * maxKeyframeIntervalSeconds).rounded()))
        try setRequiredProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: keyframeIntervalFrames)
        )
        try setRequiredProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: maxKeyframeIntervalSeconds)
        )
        try setRequiredProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrateBps)
        )

        // Optional rate-control & profile hints (ignore kVTPropertyNotSupportedErr on virtualized/older hardware encoders).
        setOptionalProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: fps)
        )

        let maxBytesPerSecond = max(16_384, Int((Double(bitrateBps) * 1.25 / 8.0).rounded()))
        let dataRateLimits: [NSNumber] = [NSNumber(value: maxBytesPerSecond), NSNumber(value: 1.0)]
        setOptionalProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
        )

        let profileLevel: CFString
        switch codec {
        case .hevc:
            profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264:
            profileLevel = kVTProfileLevel_H264_High_AutoLevel
        }
        setOptionalProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
    }

    private static func setRequiredProperty(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr && status != kVTPropertyNotSupportedErr {
            throw BackbufferError.encoderSetupFailed("VTSessionSetProperty(\(key)) failed (OSStatus \(status)).")
        }
    }

    private static func setOptionalProperty(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef
    ) {
        _ = VTSessionSetProperty(session, key: key, value: value)
    }

    private func ensureTransferPoolLocked() throws -> PixelTransferPool {
        if let existing = transferPool {
            return existing
        }
        let pool = try PixelTransferPool(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            minimumBufferCount: 2
        )
        transferPool = pool
        return pool
    }

    private func makeMonotonicPTSLocked(requested: CMTime) -> CMTime {
        if lastEncodedPTS.isNumeric && CMTimeCompare(requested, lastEncodedPTS) <= 0 {
            let minBump = CMTime(value: 1, timescale: Int32(max(fps * 10, 600)))
            return CMTimeAdd(lastEncodedPTS, minBump)
        }
        return requested
    }

    private func encodeFrameLocked(
        _ compressionSession: VTCompressionSession,
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime
    ) throws {
        var flagsOut = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        guard status == noErr else {
            throw BackbufferError.encodeFailed("VTCompressionSessionEncodeFrame failed (OSStatus \(status)).")
        }
        lastEncodedPTS = pts
    }

    private func startKeepaliveTimerLocked() {
        stopKeepaliveTimerLocked()

        let intervalNs = max(1_000_000, Int((frameDurationSeconds * 1_000_000_000.0).rounded()))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .nanoseconds(intervalNs),
            repeating: .nanoseconds(intervalNs),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.handleKeepaliveTickOnQueue()
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func stopKeepaliveTimerLocked() {
        if let timer = keepaliveTimer {
            timer.setEventHandler {}
            timer.cancel()
            keepaliveTimer = nil
        }
    }

    private func handleKeepaliveTickOnQueue() {
        guard !isInvalidated,
              !isKeepalivePaused,
              let compressionSession = session,
              let cachedFrame = latestDetachedFrame else {
            return
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let sinceLiveSeconds = Double(nowNs &- lastLiveFrameUptimeNs) / 1_000_000_000.0
        let sinceEmitSeconds = Double(nowNs &- lastEmitUptimeNs) / 1_000_000_000.0

        // Only synthesize CFR duplicate frames once SCStream has stopped emitting dirty updates (>= 1.5x frame interval),
        // then maintain steady 1/fps cadence until live frames resume.
        guard sinceLiveSeconds >= 1.5 * frameDurationSeconds,
              sinceEmitSeconds >= 0.85 * frameDurationSeconds else {
            return
        }

        let nextPTS: CMTime
        if lastEncodedPTS.isNumeric {
            nextPTS = CMTimeAdd(lastEncodedPTS, frameDuration)
        } else {
            nextPTS = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600)
        }

        lastEmitUptimeNs = nowNs
        do {
            try encodeFrameLocked(
                compressionSession,
                pixelBuffer: cachedFrame,
                pts: nextPTS,
                duration: frameDuration
            )
        } catch let error as BackbufferError {
            callbackContext.recordAsyncError(error)
        } catch {
            callbackContext.recordAsyncError(.encodeFailed(error.localizedDescription))
        }
    }

    private func invalidateLocked() {
        guard !isInvalidated else { return }
        isInvalidated = true
        stopKeepaliveTimerLocked()
        callbackContext.markInvalidated()
        if let compressionSession = session {
            VTCompressionSessionInvalidate(compressionSession)
            session = nil
        }
        latestDetachedFrame = nil
        transferPool?.invalidate()
        transferPool = nil
        if let refCon = retainedRefCon {
            Unmanaged<EncoderCallbackContext>.fromOpaque(refCon).release()
            retainedRefCon = nil
        }
    }
}

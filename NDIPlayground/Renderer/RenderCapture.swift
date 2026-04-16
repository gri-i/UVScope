import Foundation
import AVFoundation
import Metal
import CoreVideo
import CoreMedia
import AppKit
import Accelerate

final class RenderCapture {
    enum State { case idle, recording }
    private(set) var state: State = .idle

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    
    // Audio: video source + mic
    private var videoAudioWriterInput: AVAssetWriterInput?
    private var micWriterInput: AVAssetWriterInput?
    private var videoAudioConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    
    // Real-time sync
    private var recordingStartWallTime: CFTimeInterval = 0
    private var videoPausedTime: CFTimeInterval = 0
    private var videoWasPaused: Bool = false
    private var videoPauseStartTime: CFTimeInterval = 0
    private var lastVideoPTS: CMTime = .zero
    var isSourcePlaying: Bool = true  // Set by caller to sync with source

    private var frameIndex: Int64 = 0
    private var fps: Int32 = 30

    private var pixelBufferPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?

    // ✅ Keep last frame so screenshot can work even if caller doesn't have capTex reference
    private var lastFrameTexture: MTLTexture?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - Recording

    func startRecording(url: URL, width: Int, height: Int, fps: Int32 = 30, bitrate: Int = 12_000_000, includeVideoAudio: Bool = false, includeMic: Bool = false) throws {
        stopRecordingIfNeeded()

        self.fps = fps
        self.frameIndex = 0
        self.recordingStartWallTime = CACurrentMediaTime()
        self.videoPausedTime = 0
        self.videoWasPaused = false
        self.isSourcePlaying = true
        self.lastVideoPTS = .zero

        // Remove existing file to avoid AVAssetWriter failure from previous failed run
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "RenderCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"])
        }
        writer.add(videoInput)

        // Video source audio (from FileTextureSource tap)
        if includeVideoAudio {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000,
                AVChannelLayoutKey: layoutData
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                self.videoAudioWriterInput = input
            }
        }

        // Microphone track
        if includeMic {
            var micChannelLayout = AudioChannelLayout()
            micChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let micLayoutData = Data(bytes: &micChannelLayout, count: MemoryLayout<AudioChannelLayout>.size)
            
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000,
                AVChannelLayoutKey: micLayoutData
            ]
            
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micInput.expectsMediaDataInRealTime = true
            
            if writer.canAdd(micInput) {
                writer.add(micInput)
                self.micWriterInput = micInput
                print("Audio: microphone writer input added (AAC)")
            } else {
                print("Audio: cannot add microphone writer input")
            }
        }

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, pbAttrs as CFDictionary, &pool)
        self.pixelBufferPool = pool

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "RenderCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.writerInput = videoInput
        self.state = .recording
    }
    
    // MARK: - Audio
    
    private func setupVideoAudioConverter() {
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &inputASBD),
              let output = AVAudioFormat(streamDescription: &outputASBD) else { return }
        self.videoAudioConverter = AVAudioConverter(from: input, to: output)
    }

    private func setupMicConverter() {
        // Input: float32 stereo 48kHz planar (more reliable for AVAudioConverter)
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,  // 1 channel * 4 bytes (planar)
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // Output: int16 stereo 48kHz (for AAC)
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,  // 2 channels * 2 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        let inputFormat = AVAudioFormat(streamDescription: &inputASBD)
        let outputFormat = AVAudioFormat(streamDescription: &outputASBD)
        
        guard let input = inputFormat, let output = outputFormat else {
            print("Audio: Failed to create formats for mic converter")
            return
        }
        
        self.micConverter = AVAudioConverter(from: input, to: output)
        print("Audio: Microphone converter created")
    }
    
    private func convertWithConverter(sampleBuffer: CMSampleBuffer, converter: AVAudioConverter, pts: CMTime) -> CMSampleBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            print("Audio: convertWithConverter - invalid buffer or format")
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let data = dataPointer, length > 0 else {
            print("Audio: convertWithConverter - no data, length: \(length)")
            return nil
        }
        
        let floatCount = length / MemoryLayout<Float>.size
        let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = channels > 0 ? floatCount / channels : floatCount
        
        // Validate frame count
        guard frames > 0 else {
            print("Audio: convertWithConverter - zero frames, floatCount: \(floatCount), channels: \(channels)")
            return nil
        }
        
        // Create input buffer
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames))!
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        
        // Copy data based on format
        if isNonInterleaved && channels == 2 {
            // Planar: convert to interleaved
            let leftChannel = floatPtr
            let rightChannel = floatPtr.advanced(by: frames)
            guard let channelData = inputBuffer.floatChannelData else { return nil }
            for i in 0..<frames {
                channelData[0][i] = leftChannel[i]
                channelData[1][i] = rightChannel[i]
            }
        } else {
            // Interleaved: copy directly
            guard let channelData = inputBuffer.floatChannelData else { return nil }
            if channels == 2 {
                for i in 0..<frames {
                    channelData[0][i] = floatPtr[i * 2]
                    channelData[1][i] = floatPtr[i * 2 + 1]
                }
            } else {
                // Mono: duplicate
                for i in 0..<frames {
                    let s = floatPtr[i]
                    channelData[0][i] = s
                    channelData[1][i] = s
                }
            }
        }
        
        // Create output buffer
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(frames))!
        
        // Convert
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        guard status == .haveData, let int16Data = outputBuffer.int16ChannelData else {
            print("Audio: Converter failed, status: \(status), error: \(error?.localizedDescription ?? "none"), frames: \(frames)")
            return nil
        }
        
        // Create CMSampleBuffer from int16 data
        let int16Length = Int(outputBuffer.frameLength) * 2 * MemoryLayout<Int16>.size
        var newBlockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: int16Length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: int16Length,
            flags: 0,
            blockBufferOut: &newBlockBuffer
        )
        
        guard let block = newBlockBuffer else { return nil }
        
        // Copy interleaved int16 data
        var int16Interleaved = [Int16](repeating: 0, count: Int(outputBuffer.frameLength) * 2)
        for i in 0..<Int(outputBuffer.frameLength) {
            int16Interleaved[i * 2] = int16Data[0][i]
            int16Interleaved[i * 2 + 1] = int16Data[1][i]
        }
        
        CMBlockBufferReplaceDataBytes(
            with: int16Interleaved,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: int16Length
        )
        
        // Create format description
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        var outputFormatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outputASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outputFormatDesc
        )
        
        guard let format = outputFormatDesc else { return nil }
        
        // Create sample buffer - let ASBD describe the bytes-per-frame, so we don't pass explicit sample sizes.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var newSampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: CMItemCount(outputBuffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &newSampleBuffer
        )
        
        guard createStatus == noErr, let buffer = newSampleBuffer else {
            print("Audio: Failed to create sample buffer, status: \(createStatus)")
            return nil
        }
        
        return buffer
    }
    
    private func convertFloat32ToInt16(sampleBuffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let data = dataPointer, length > 0 else { return nil }
        
        let floatCount = length / MemoryLayout<Float>.size
        let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        
        // Check format
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = channels > 0 ? floatCount / channels : floatCount
        
        print("Audio: Converting - channels: \(channels), non-interleaved: \(isNonInterleaved), frames: \(frames), floatCount: \(floatCount)")
        
        // Output is always stereo interleaved
        let outputFrames = channels == 1 ? frames : frames
        var int16Data = [Int16](repeating: 0, count: outputFrames * 2)
        
        if isNonInterleaved && channels >= 2 {
            // Planar format: LLLLL...RRRRR...
            let leftChannel = floatPtr
            let rightChannel = floatPtr.advanced(by: frames)
            for i in 0..<frames {
                let left = max(-1.0, min(1.0, leftChannel[i]))
                let right = max(-1.0, min(1.0, rightChannel[i]))
                int16Data[i * 2] = Int16(left * 32767.0)
                int16Data[i * 2 + 1] = Int16(right * 32767.0)
            }
        } else if channels == 1 {
            // Mono - duplicate to stereo
            for i in 0..<frames {
                let sample = max(-1.0, min(1.0, floatPtr[i]))
                let int16Sample = Int16(sample * 32767.0)
                int16Data[i * 2] = int16Sample
                int16Data[i * 2 + 1] = int16Sample
            }
        } else {
            // Interleaved format: LRLRLR... (already stereo)
            for i in 0..<floatCount {
                let clamped = max(-1.0, min(1.0, floatPtr[i]))
                int16Data[i] = Int16(clamped * 32767.0)
            }
        }
        
        // Create int16 block buffer
        let int16Length = int16Data.count * MemoryLayout<Int16>.size
        var newBlockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: int16Length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: int16Length,
            flags: 0,
            blockBufferOut: &newBlockBuffer
        )
        
        guard let block = newBlockBuffer else { return nil }
        
        CMBlockBufferReplaceDataBytes(
            with: int16Data,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: int16Length
        )
        
        // Create format description for int16 PCM
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,  // 2 channels * 2 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        var outputFormatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outputASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outputFormatDesc
        )
        
        guard let format = outputFormatDesc else { return nil }
        
        // Create sample buffer - let ASBD/Int16 format describe layout, don't override sample sizes.
        let frameCount = outputFrames  // stereo output frames
        
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        
        var newSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &newSampleBuffer
        )
        
        guard status == noErr, let buffer = newSampleBuffer else {
            print("Audio: Failed to create sample buffer, status: \(status)")
            return nil
        }
        
        return buffer
    }
    
    func pushVideoAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              let input = videoAudioWriterInput,
              let writer = writer,
              input.isReadyForMoreMediaData,
              writer.status == .writing
        else { return }
        
        // FileTextureSource уже создаёт корректный CMSampleBuffer с непрерывными PTS.
        // Отдаём буфер напрямую, без пересчёта времени и конвертеров.
        _ = input.append(sampleBuffer)
    }

    func pushMicSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              let micInput = micWriterInput,
              let writer = writer
        else { return }
        
        guard micInput.isReadyForMoreMediaData else { return }
        guard writer.status == .writing else { return }

        // Для начала убираем всю дополнительную конвертацию:
        // `AudioCapture` уже выдаёт float32 48kHz стерео, AVAssetWriter сам сконвертирует в AAC.
        if !micInput.append(sampleBuffer) {
            print("Audio: Mic append failed, writer status: \(writer.status.rawValue)")
            if writer.status == .failed {
                print("Audio: Writer failed, error: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
    }
    
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        print("Audio: stopRecording called, state: \(state), writer: \(writer != nil), input: \(writerInput != nil)")
        
        // Check if we have a writer - if state is idle but writer exists, we need to finish it
        guard let writer = writer, let input = writerInput else {
            print("Audio: stopRecording failed - no writer or input")
            completion(.failure(NSError(domain: "RenderCapture", code: -10, userInfo: [NSLocalizedDescriptionKey: "No active recording"])))
            return
        }
        
        // If already idle, writer might be in process of finishing - check status
        if state == .idle {
            print("Audio: State is already idle, checking writer status: \(writer.status.rawValue)")
            if writer.status == .writing {
                // Writer is still writing but state was set to idle - finish it properly
                print("Audio: Writer still writing, finishing...")
            } else if writer.status == .completed {
                // Already completed, return success
                let outputURL = writer.outputURL
                self.writer = nil
                self.writerInput = nil
                self.videoAudioWriterInput = nil
                self.micWriterInput = nil
                self.pixelBufferPool = nil
                self.videoAudioConverter = nil
                self.micConverter = nil
                completion(.success(outputURL))
                return
            } else {
                // Failed or cancelled
                let error = writer.error ?? NSError(domain: "RenderCapture", code: -17, userInfo: [NSLocalizedDescriptionKey: "Writer status: \(writer.status.rawValue)"])
                completion(.failure(error))
                return
            }
        }

        // Check if writer already failed
        if writer.status == .failed {
            let error = writer.error ?? NSError(domain: "RenderCapture", code: -11, userInfo: [NSLocalizedDescriptionKey: "Writer failed during recording"])
            writer.cancelWriting()
            state = .idle
            self.writer = nil
            self.writerInput = nil
            self.videoAudioWriterInput = nil
            self.micWriterInput = nil
            self.pixelBufferPool = nil
            self.videoAudioConverter = nil
            self.micConverter = nil
            completion(.failure(error))
            return
        }

        // Check writer status before finishing
        guard writer.status == .writing else {
            print("Audio: Writer not in writing state: \(writer.status.rawValue), canceling")
            let error = writer.error ?? NSError(domain: "RenderCapture", code: -12, userInfo: [NSLocalizedDescriptionKey: "Writer not in writing state: \(writer.status.rawValue)"])
            writer.cancelWriting()
            state = .idle
            self.writer = nil
            self.writerInput = nil
            self.videoAudioWriterInput = nil
            self.micWriterInput = nil
            self.pixelBufferPool = nil
            self.videoAudioConverter = nil
            self.micConverter = nil
            completion(.failure(error))
            return
        }
        
        // Save references before changing state
        let videoAudioInput = videoAudioWriterInput
        let micInput = micWriterInput
        let outputURL = writer.outputURL
        
        state = .idle
        
        // Mark video input as finished first
        print("Audio: Marking video input as finished")
        input.markAsFinished()
        print("Audio: Video input marked as finished")
        
        if let videoAudioInput = videoAudioInput {
            videoAudioInput.markAsFinished()
        }
        if let micInput = micInput {
            print("Audio: Marking microphone input as finished")
            micInput.markAsFinished()
            print("Audio: Microphone input marked as finished")
        } else {
            print("Audio: No microphone input to mark as finished")
        }
        
        // Small delay to ensure all pending samples are processed, then finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else {
                print("Audio: Self is nil in asyncAfter")
                completion(.failure(NSError(domain: "RenderCapture", code: -14, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"])))
                return
            }
            
            // Check if writer still exists and is valid
            guard let currentWriter = self.writer, currentWriter === writer else {
                print("Audio: Writer was deallocated or changed")
                completion(.failure(NSError(domain: "RenderCapture", code: -15, userInfo: [NSLocalizedDescriptionKey: "Writer was deallocated"])))
                return
            }
            
            // Double-check writer status before finishing
            print("Audio: Checking writer status before finish: \(currentWriter.status.rawValue)")
            if currentWriter.status != .writing {
                print("Audio: Writer status changed to \(currentWriter.status.rawValue) before finish")
                let error = currentWriter.error ?? NSError(domain: "RenderCapture", code: -16, userInfo: [NSLocalizedDescriptionKey: "Writer status changed: \(currentWriter.status.rawValue)"])
                completion(.failure(error))
                return
            }
            
            self.finishWriter(writer: currentWriter, completion: completion)
        }
    }
    
    private func finishWriter(writer: AVAssetWriter, completion: @escaping (Result<URL, Error>) -> Void) {
        print("Audio: Finishing writer, status: \(writer.status.rawValue)")
        
        // Check status - if already completed, return success
        if writer.status == .completed {
            print("Audio: Writer already completed")
            let outputURL = writer.outputURL
            self.writer = nil
            self.writerInput = nil
            self.videoAudioWriterInput = nil
            self.micWriterInput = nil
            self.pixelBufferPool = nil
            self.videoAudioConverter = nil
            self.micConverter = nil
            completion(.success(outputURL))
            return
        }
        
        // If cancelled or failed, return error
        if writer.status == .cancelled || writer.status == .failed {
            print("Audio: Writer already cancelled/failed: \(writer.status.rawValue)")
            let error = writer.error ?? NSError(domain: "RenderCapture", code: -13, userInfo: [NSLocalizedDescriptionKey: "Writer status: \(writer.status.rawValue)"])
            self.writer = nil
            self.writerInput = nil
            self.videoAudioWriterInput = nil
            self.micWriterInput = nil
            self.pixelBufferPool = nil
            self.videoAudioConverter = nil
            self.micConverter = nil
            completion(.failure(error))
            return
        }
        
        // Double-check status before finishing
        guard writer.status == .writing else {
            print("Audio: Writer status changed before finish: \(writer.status.rawValue)")
            let error = writer.error ?? NSError(domain: "RenderCapture", code: -13, userInfo: [NSLocalizedDescriptionKey: "Writer status changed: \(writer.status.rawValue)"])
            writer.cancelWriting()
            self.writer = nil
            self.writerInput = nil
            self.videoAudioWriterInput = nil
            self.micWriterInput = nil
            self.pixelBufferPool = nil
            self.videoAudioConverter = nil
            self.micConverter = nil
            completion(.failure(error))
            return
        }
        
        // Finish writing - this will wait for all inputs to finish
        writer.finishWriting { [weak self, outputURL = writer.outputURL] in
            guard let self = self else {
                print("Audio: finishWriter callback - self is nil")
                return
            }
            
            print("Audio: Writer finishWriting completed, status: \(writer.status.rawValue)")
            
            // Clear references AFTER finishWriting completes
            self.writer = nil
            self.writerInput = nil
            self.videoAudioWriterInput = nil
            self.micWriterInput = nil
            self.pixelBufferPool = nil
            self.videoAudioConverter = nil
            self.micConverter = nil
            
            if let err = writer.error {
                print("Audio: Writer finished with error: \(err.localizedDescription)")
                completion(.failure(err))
            } else {
                print("Audio: Writer finished successfully")
                completion(.success(outputURL))
            }
        }
    }

    private func stopRecordingIfNeeded() {
        if state == .recording {
            writerInput?.markAsFinished()
            videoAudioWriterInput?.markAsFinished()
            micWriterInput?.markAsFinished()
            writer?.cancelWriting()
            state = .idle
        }
        writer = nil
        writerInput = nil
        videoAudioWriterInput = nil
        micWriterInput = nil
        pixelBufferPool = nil
        videoAudioConverter = nil
        micConverter = nil
    }

    // MARK: - Push frames (call once per draw)

    func pushFrame(texture: MTLTexture) {
        // ✅ Always remember last frame (for screenshot)
        lastFrameTexture = texture

        guard state == .recording,
              let writer = writer,
              writer.status == .writing,
              let input = writerInput,
              input.isReadyForMoreMediaData,
              let pool = pixelBufferPool,
              let cache = textureCache
        else { return }

        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var cvMetalTex: CVMetalTexture?
        let s2 = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvMetalTex
        )
        guard s2 == kCVReturnSuccess,
              let cvTex = cvMetalTex,
              let dstTex = CVMetalTextureGetTexture(cvTex)
        else { return }

        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder()
        else { return }

        let srcSize = MTLSize(width: min(texture.width, dstTex.width),
                              height: min(texture.height, dstTex.height),
                              depth: 1)

        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: srcSize,
                  to: dstTex,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        // Use real wall-clock time for synchronization with audio
        let elapsedSeconds = CACurrentMediaTime() - recordingStartWallTime
        guard elapsedSeconds >= 0 else {
            print("Audio: Invalid elapsed time: \(elapsedSeconds)")
            return
        }
        let pts = CMTime(seconds: elapsedSeconds, preferredTimescale: 600)
        guard CMTimeCompare(pts, .zero) >= 0 else {
            print("Audio: Invalid PTS: \(pts.seconds)")
            return
        }

        cmd.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            
            // Check state and writer status before appending
            guard self.state == .recording,
                  let currentWriter = self.writer,
                  currentWriter === writer,  // Ensure it's the same writer instance
                  currentWriter.status == .writing,
                  let currentInput = self.writerInput,
                  currentInput === input,  // Ensure it's the same input instance
                  currentInput.isReadyForMoreMediaData else {
                print("Audio: Skipping frame append - state: \(self.state), writer status: \(self.writer?.status.rawValue ?? -1), input ready: \(self.writerInput?.isReadyForMoreMediaData ?? false)")
                return
            }
            
            if CMTimeCompare(pts, self.lastVideoPTS) < 0 { return }

            // Create CMSampleBuffer from CVPixelBuffer (direct append, no adaptor)
            var formatDesc: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
            guard let format = formatDesc else { return }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(self.fps)),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let err = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            guard err == noErr, let sb = sampleBuffer else { return }

            let success = currentInput.append(sb)
            if success {
                self.lastVideoPTS = pts
            }
            if !success {
                print("Audio: Failed to append video frame at \(elapsedSeconds)s, writer status: \(currentWriter.status.rawValue)")
                if currentWriter.status == .failed {
                    let error = currentWriter.error
                    print("Audio: Writer failed: \(error?.localizedDescription ?? "unknown")")
                    // Stop recording if writer failed
                    DispatchQueue.main.async {
                        self.state = .idle
                    }
                }
            }
        }
        cmd.commit()
    }

    // MARK: - Screenshot (PNG/JPG)

    // ✅ Public convenience: screenshot last captured frame
    func saveLastFrameScreenshot(to url: URL, format: NSBitmapImageRep.FileType = .png) throws {
        guard let tex = lastFrameTexture else {
            throw NSError(domain: "RenderCapture", code: -20, userInfo: [NSLocalizedDescriptionKey: "No frame yet"])
        }
        try saveScreenshot(texture: tex, to: url, format: format)
    }

    // ✅ Safe screenshot: GPU (private) -> blit -> CPU-readable (shared) -> CGContext -> PNG/JPG
    func saveScreenshot(texture src: MTLTexture, to url: URL, format: NSBitmapImageRep.FileType = .png) throws {
        // We only support BGRA8 here (matches your video path and most MTKView setups)
        guard src.pixelFormat == .bgra8Unorm || src.pixelFormat == .bgra8Unorm_srgb else {
            throw NSError(domain: "RenderCapture", code: -29, userInfo: [NSLocalizedDescriptionKey: "Unsupported pixelFormat: \(src.pixelFormat)"])
        }

        let w = src.width
        let h = src.height

        // 1) Create CPU-readable texture
        let readback = makeReadbackTexture(width: w, height: h, pixelFormat: .bgra8Unorm)

        // 2) Blit copy src -> readback
        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder()
        else {
            throw NSError(domain: "RenderCapture", code: -28, userInfo: [NSLocalizedDescriptionKey: "Command buffer / blit create failed"])
        }

        let size = MTLSize(width: w, height: h, depth: 1)
        blit.copy(from: src,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: size,
                  to: readback,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // 3) Read bytes safely
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        let dataSize = bytesPerRow * h

        var raw = [UInt8](repeating: 0, count: dataSize)
        let region = MTLRegionMake2D(0, 0, w, h)
        readback.getBytes(&raw, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // 4) Encode
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        guard var rawMutable = raw as [UInt8]?,
              let ctx = CGContext(
                data: &rawMutable,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
              )
        else {
            throw NSError(domain: "RenderCapture", code: -30, userInfo: [NSLocalizedDescriptionKey: "CGContext create failed"])
        }

        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "RenderCapture", code: -31, userInfo: [NSLocalizedDescriptionKey: "CGImage create failed"])
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let outData = rep.representation(using: format, properties: [:]) else {
            throw NSError(domain: "RenderCapture", code: -32, userInfo: [NSLocalizedDescriptionKey: "Image encode failed"])
        }

        try outData.write(to: url, options: [.atomic])
    }

    private func makeReadbackTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared          // ✅ CPU-readable
        desc.resourceOptions = .storageModeShared
        return device.makeTexture(descriptor: desc)!
    }
}

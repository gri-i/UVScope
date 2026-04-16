import Foundation
import AVFoundation
import Metal
import CoreVideo
import CoreMedia

final class FileTextureSource: TextureSource {
    private let url: URL
    private var playing = true
    private var looping = true

    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?

    private var cache: CVMetalTextureCache?
    private var lastTex: MTLTexture?
    
    // AVAudioEngine for playback
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var wasPlayingBeforeRecording = false
    private var isRecording = false
    
    // Recording timing (for clean, click-free audio PTS)
    private var recordSampleRate: Double = 48_000
    private var recordSamplesWritten: Int64 = 0
    // Make video audio noticeably quieter than mic in final mix (configurable).
    var recordingGainDB: Float = -8.0   // ≈ 0.4x по амплитуде
    /// Optional level callback for recording (0...1 RMS-ish), called on main thread.
    var onRecordingLevel: ((Float) -> Void)?
    
    // Public URL for audio extraction
    var sourceURL: URL { url }

    init(url: URL) { self.url = url }

    func start() {
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, MTLCreateSystemDefaultDevice()!, nil, &c)
        cache = c

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        
        // Don't disable audio in AVPlayer - we'll use it for recording capture
        // AVAudioEngine will be used for normal playback
        
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(out)

        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        // Don't mute - let ScreenCaptureKit capture it during recording
        // We'll control playback through AVAudioEngine when not recording

        NotificationCenter.default.addObserver(self, selector: #selector(didEnd),
                                               name: .AVPlayerItemDidPlayToEndTime, object: item)

        player = p
        output = out

        // Setup AVAudioEngine playback
        setupAudioPlayback()

        if playing { 
            p.play()
            startAudioPlayback()
        } else { 
            p.pause()
        }
    }

    func stop() {
        stopAudioPlayback()
        
        player?.pause()
        player = nil
        output = nil
        NotificationCenter.default.removeObserver(self)
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        if playing { 
            player?.play()
            // Use AVAudioEngine when not recording, AVPlayer audio when recording
            if isRecording {
                // During recording, let AVPlayer handle audio (for ScreenCaptureKit)
                player?.isMuted = false
                audioPlayerNode?.pause()
            } else {
                // Normal playback - use AVAudioEngine
                player?.isMuted = true
                if let playerNode = audioPlayerNode {
                    if playerNode.isPlaying {
                        // Already playing, do nothing
                    } else {
                        // Need to start or resume
                        startAudioPlayback()
                    }
                }
            }
        } else { 
            player?.pause()
            audioPlayerNode?.pause()
        }
    }

    func setLooping(_ looping: Bool) { self.looping = looping }

    func currentMetalTexture(device: MTLDevice) -> MTLTexture? {
        guard let output, let item = player?.currentItem else { return lastTex }
        let t = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let cache else { return lastTex }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        if status == kCVReturnSuccess, let cvTex {
            lastTex = CVMetalTextureGetTexture(cvTex)
        }
        return lastTex
    }

    @objc private func didEnd() {
        guard looping else { return }
        player?.seek(to: .zero)
        
        // Reset audio position
        if let audioFile = audioFile {
            audioFile.framePosition = 0
            audioPlayerNode?.stop()
            if playing {
                scheduleAudioFromPosition(0)
                audioPlayerNode?.play()
            }
        }
        
        if playing { 
            player?.play()
        }
    }
    func durationSeconds() -> Double? {
        guard let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    func currentTimeSeconds() -> Double? {
        guard let t = player?.currentTime().seconds, t.isFinite else { return nil }
        return t
    }

    func canSeek() -> Bool { true }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        
        // Seek audio to match video
        if let playerNode = audioPlayerNode, let audioFile = audioFile {
            let wasPlaying = playerNode.isPlaying
            playerNode.stop()
            
            if wasPlaying && playing {
                let framePosition = AVAudioFramePosition(seconds * audioFile.processingFormat.sampleRate)
                let clampedPosition = max(0, min(framePosition, audioFile.length))
                audioFile.framePosition = clampedPosition
                
                // Schedule from current position
                scheduleAudioFromPosition(clampedPosition)
                playerNode.play()
            }
        }
    }
    
    // MARK: - AVAudioEngine Playback
    
    private func setupAudioPlayback() {
        do {
            // Load audio file
            let audioFile = try AVAudioFile(forReading: url)
            self.audioFile = audioFile
            self.audioFormat = audioFile.processingFormat
            
            // Create audio engine
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            
            engine.attach(playerNode)
            
            // Connect player node to main mixer (output)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)
            
            // Start engine
            try engine.start()
            
            self.audioEngine = engine
            self.audioPlayerNode = playerNode
            
            print("FileTextureSource: AVAudioEngine setup complete, format: \(audioFile.processingFormat)")
            
        } catch {
            print("FileTextureSource: Failed to setup audio playback: \(error)")
            // Continue without audio
        }
    }
    
    private func scheduleAudioFromPosition(_ framePosition: AVAudioFramePosition) {
        guard let audioFile = audioFile, let playerNode = audioPlayerNode else { return }
        
        audioFile.framePosition = framePosition
        
        // Schedule the entire file from current position
        let remainingFrames = audioFile.length - framePosition
        if remainingFrames > 0 {
            playerNode.scheduleSegment(audioFile, startingFrame: framePosition, frameCount: AVAudioFrameCount(remainingFrames), at: nil) { [weak self] in
                // When segment completes, loop if needed
                DispatchQueue.main.async {
                    if self?.looping == true && self?.playing == true {
                        self?.audioFile?.framePosition = 0
                        self?.scheduleAudioFromPosition(0)
                    }
                }
            }
        }
    }
    
    private func startAudioPlayback() {
        guard let playerNode = audioPlayerNode, let audioFile = audioFile, !playerNode.isPlaying else { return }
        
        // Calculate starting position based on video time
        let videoTime = player?.currentTime().seconds ?? 0
        let framePosition = AVAudioFramePosition(videoTime * audioFile.processingFormat.sampleRate)
        let clampedPosition = max(0, min(framePosition, audioFile.length))
        
        // Schedule audio from current position
        scheduleAudioFromPosition(clampedPosition)
        
        // Play
        playerNode.play()
        print("FileTextureSource: Audio playback started at frame \(clampedPosition)")
    }
    
    private func stopAudioPlayback() {
        audioPlayerNode?.stop()
        audioPlayerNode?.reset()
        // Reset file position for next play
        audioFile?.framePosition = 0
        print("FileTextureSource: Audio playback stopped")
    }
    
    // MARK: - Recording (audio tap — no ScreenCaptureKit)
    
    private var recordingTapCallback: ((CMSampleBuffer) -> Void)?
    private let tapQueue = DispatchQueue(label: "file.audio.tap")
    
    /// Install tap on mixer to capture audio for recording. Keeps AVAudioEngine running.
    func startRecordingAudioCapture(callback: @escaping (CMSampleBuffer) -> Void) {
        guard let engine = audioEngine else { return }
        let mixer = engine.mainMixerNode
        recordingTapCallback = callback
        
        // Важно: формат tap должен совпадать с outputFormat узла,
        // иначе AVAudioEngine может вести себя нестабильно.
        let format = mixer.outputFormat(forBus: 0)
        recordSampleRate = format.sampleRate
        recordSamplesWritten = 0
        
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.tapQueue.async {
                guard let sb = self?.makeSampleBuffer(from: buffer) else { return }
                self?.recordingTapCallback?(sb)
            }
        }
        print("FileTextureSource: Audio tap installed for recording")
    }
    
    func stopRecordingAudioCapture() {
        guard let engine = audioEngine else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        recordingTapCallback = nil
        recordSamplesWritten = 0
        print("FileTextureSource: Audio tap removed")
    }
    
    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        guard let channelData = pcmBuffer.floatChannelData else { return nil }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return nil }
        let channels = Int(pcmBuffer.format.channelCount)
        let dataSize = frames * channels * MemoryLayout<Float>.size
        
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }
        
        var dataPtr: UnsafeMutablePointer<Int8>?
        var length = 0
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
        guard let ptr = dataPtr else { return nil }
        
        // Planar in our block: LLL...RRR... (2 канала; для mono дублируем в оба).
        let floatPtr = UnsafeMutableRawPointer(ptr).bindMemory(to: Float.self, capacity: frames * 2)
        let left = floatPtr
        let right = floatPtr.advanced(by: frames)
        // Копируем в planar и сразу применяем понижающий gain.
        let gain = powf(10.0, recordingGainDB / 20.0)
        var sum: Float = 0
        if channels == 2 {
            for i in 0..<frames {
                let l = channelData[0][i] * gain
                let r = channelData[1][i] * gain
                sum += 0.5 * (l * l + r * r)
                left[i] = l
                right[i] = r
            }
        } else {
            for i in 0..<frames {
                let s = channelData[0][i] * gain
                sum += s * s
                left[i] = s
                right[i] = s
            }
        }
        if let onRecordingLevel {
            let rms = sqrtf(sum / Float(max(frames, 1)))
            let level = max(0, min(rms * 3, 1))
            DispatchQueue.main.async {
                onRecordingLevel(level)
            }
        }
        
        // Описываем фактический формат: sampleRate/каналы из PCM‑буфера,
        // в блоке храним planar float32 stereo.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: pcmBuffer.format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)
        guard let format = formatDesc else { return nil }
        
        // Непрерывные таймстемпы по счётчику сэмплов, как в MovH264VoiceRecorder.
        let sr = recordSampleRate
        let timescale = CMTimeScale(Int32(sr.rounded()))
        let pts = CMTime(value: recordSamplesWritten, timescale: timescale)
        let dur = CMTime(value: Int64(frames), timescale: timescale)
        
        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        if let sb = sampleBuffer {
            recordSamplesWritten += Int64(frames)
        }
        return sampleBuffer
    }

}

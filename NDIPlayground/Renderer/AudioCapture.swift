import Foundation
import AVFoundation
import CoreMedia
import AppKit

/// Microphone-only capture using AVAudioEngine tap, patterned after MovH264VoiceRecorder.
/// No ScreenCaptureKit — no screen sharing icon. Video comes from Metal renderer; mic is merged into the same file.
@available(macOS 13.0, *)
final class AudioCapture: NSObject {
    // MARK: - Public
    
    var isMicEnabled = false
    /// Called on a background queue with CMSampleBuffer carrying Float32 audio.
    var onMicSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Optional mic level callback (0...1 RMS-ish), called on main thread.
    var onMicLevel: ((Float) -> Void)?
    
    // MARK: - Engine
    
    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "AudioCapture.mic.queue")
    
    // Slight boost so голос звучит уверенно поверх видео.
    private var micGainDB: Float = 6.0  // ≈ x2 по амплитуде
    
    private var sampleRate: Double = 44_100
    private var audioSamplesWritten: Int64 = 0
    private var isRunning = false

    // Update gain from UI thread.
    func setGain(dB: Float) {
        micGainDB = dB
    }
    
    /// Stop mic capture (call when recording stops).
    func stopCapture() async {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.isRunning {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                self.engine.reset()
                self.isRunning = false
                self.audioSamplesWritten = 0
                print("AudioCapture: Mic engine stopped")
            }
        }
    }
    
    // MARK: - Microphone
    
    func startMicCapture() {
        guard isMicEnabled else {
            print("AudioCapture: Mic not enabled")
            return
        }
        if isRunning {
            return // Already running (e.g. from prewarm)
        }
        
        print("AudioCapture: Starting mic capture with AVAudioEngine...")
        
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("AudioCapture: Current microphone permission status: \(status.rawValue) (\(status))")
        
        switch status {
        case .authorized:
            setupAndStartEngine()
        case .notDetermined:
            print("AudioCapture: Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("AudioCapture: Microphone permission granted")
                        self.setupAndStartEngine()
                    } else {
                        print("AudioCapture: Microphone permission denied")
                    }
                }
            }
        case .denied, .restricted:
            print("AudioCapture: Microphone permission denied or restricted")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        @unknown default:
            print("AudioCapture: Unknown microphone permission status")
        }
    }
    
    // MARK: - Engine setup
    
    private func setupAndStartEngine() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.isRunning { return }
            
            self.engine.stop()
            self.engine.reset()
            self.audioSamplesWritten = 0
            
            let input = self.engine.inputNode
            let inFormat = input.inputFormat(forBus: 0)
            self.sampleRate = inFormat.sampleRate
            
            // No monitoring to speakers, only recording.
            self.engine.mainMixerNode.outputVolume = 0.0
            
            self.engine.connect(input, to: self.engine.mainMixerNode, format: inFormat)
            
            input.removeTap(onBus: 0)
            let tapFormat = input.outputFormat(forBus: 0)
            
            input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
                self?.handleAudioBuffer(buffer)
            }
            
            self.engine.prepare()
            do {
                try self.engine.start()
                self.isRunning = true
                print("AudioCapture: ✅ AVAudioEngine started, sampleRate=\(self.sampleRate), channels=\(tapFormat.channelCount)")
            } catch {
                self.engine.stop()
                self.engine.reset()
                self.isRunning = false
                print("AudioCapture: ❌ AVAudioEngine start failed:", error.localizedDescription)
            }
        }
    }
    
    // MARK: - Buffer handling (based on MovH264VoiceRecorder)
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            guard let sb = self.makeCMSampleBuffer(from: buffer) else { return }
            self.onMicSampleBuffer?(sb)
        }
    }
    
    private func makeCMSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let asbdPtr = pcm.format.streamDescription
        var asbd = asbdPtr.pointee
        
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mBitsPerChannel = 32
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = UInt32(4 * pcm.format.channelCount)
        asbd.mBytesPerPacket = asbd.mBytesPerFrame
        
        var fmtDesc: CMAudioFormatDescription?
        let s1 = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmtDesc
        )
        guard s1 == noErr, let formatDesc = fmtDesc else {
            print("AudioCapture: Failed to create CMAudioFormatDescription, status=\(s1)")
            return nil
        }
        
        let frames = Int(pcm.frameLength)
        if frames == 0 { return nil }
        
        guard pcm.format.commonFormat == .pcmFormatFloat32,
              let floatData = pcm.floatChannelData else { return nil }
        
        let channels = Int(pcm.format.channelCount)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        
        for c in 0..<channels {
            let src = floatData[c]
            for i in 0..<frames {
                interleaved[i * channels + c] = src[i]
            }
        }
        
        // Apply simple mic gain (with clipping protection).
        let gain = powf(10.0, micGainDB / 20.0)
        if gain != 1.0 {
            for i in interleaved.indices {
                let v = interleaved[i] * gain
                interleaved[i] = max(-1.0, min(1.0, v))
            }
        }
        
        // Rough RMS level for UI meters.
        var sum: Float = 0
        for v in interleaved {
            sum += v * v
        }
        let rms = sqrtf(sum / Float(max(interleaved.count, 1)))
        let level = max(0, min(rms * 3, 1)) // Простая нормализация
        if let onMicLevel {
            DispatchQueue.main.async {
                onMicLevel(level)
            }
        }
        
        let bytesPerFrame = MemoryLayout<Float>.size * channels
        let totalBytes = frames * bytesPerFrame
        
        var blockBuffer: CMBlockBuffer?
        let s2 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard s2 == kCMBlockBufferNoErr, let bb = blockBuffer else {
            print("AudioCapture: CMBlockBufferCreateWithMemoryBlock failed, status=\(s2)")
            return nil
        }
        
        let s3 = interleaved.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard s3 == kCMBlockBufferNoErr else {
            print("AudioCapture: CMBlockBufferReplaceDataBytes failed, status=\(s3)")
            return nil
        }
        
        let timescale = CMTimeScale(Int32(sampleRate.rounded()))
        let pts = CMTime(value: audioSamplesWritten, timescale: timescale)
        let dur = CMTime(value: Int64(frames), timescale: timescale)
        
        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        let s4 = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard s4 == noErr, let sb = sampleBuffer else {
            print("AudioCapture: CMSampleBufferCreate failed, status=\(s4)")
            return nil
        }
        
        audioSamplesWritten += Int64(frames)
        return sb
    }
}

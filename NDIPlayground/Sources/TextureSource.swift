import Metal

protocol TextureSource: AnyObject {
    func start()
    func stop()
    func setPlaying(_ playing: Bool)
    func setLooping(_ looping: Bool)

    func currentMetalTexture(device: MTLDevice) -> MTLTexture?

    // Timeline (optional)
    func durationSeconds() -> Double?
    func currentTimeSeconds() -> Double?
    func canSeek() -> Bool
    func seek(to seconds: Double)
}

extension TextureSource {
    func durationSeconds() -> Double? { nil }
    func currentTimeSeconds() -> Double? { nil }
    func canSeek() -> Bool { false }
    func seek(to seconds: Double) {}
}


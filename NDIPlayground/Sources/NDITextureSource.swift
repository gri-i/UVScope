import Metal
import Foundation

final class NDITextureSource: TextureSource {
    private let receiver: NDIReceiver

    private var playing = true
    private var looping = true

    private var tex: MTLTexture?
    private var lastW: Int = 0
    private var lastH: Int = 0

    init(receiver: NDIReceiver) {
        self.receiver = receiver
    }

    func start() {}
    func stop() {}

    func setPlaying(_ playing: Bool) { self.playing = playing }
    func setLooping(_ looping: Bool) { self.looping = looping }

    func currentMetalTexture(device: MTLDevice) -> MTLTexture? {
        guard playing else { return tex }
        guard let frame = receiver.consumeLatestFrame() else { return tex }

        if tex == nil || frame.width != lastW || frame.height != lastH {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            tex = device.makeTexture(descriptor: desc)
            lastW = frame.width
            lastH = frame.height
        }

        guard let tex else { return nil }

        frame.data.withUnsafeBytes { ptr in
            let region = MTLRegionMake2D(0, 0, frame.width, frame.height)
            tex.replace(region: region, mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: frame.stride)
        }

        return tex
    }
}

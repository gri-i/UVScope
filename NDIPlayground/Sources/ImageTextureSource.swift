import Foundation
import Metal
import MetalKit

final class ImageTextureSource: TextureSource {
    private let url: URL
    private var playing = true
    private var looping = true

    private var texture: MTLTexture?

    init(url: URL) { self.url = url }

    func start() {}
    func stop() {}

    func setPlaying(_ playing: Bool) { self.playing = playing }
    func setLooping(_ looping: Bool) { self.looping = looping }

    func currentMetalTexture(device: MTLDevice) -> MTLTexture? {
        if texture == nil {
            let loader = MTKTextureLoader(device: device)
            texture = try? loader.newTexture(URL: url, options: [
                MTKTextureLoader.Option.SRGB: false
            ])
        }
        return texture
    }
}

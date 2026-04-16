import SwiftUI
import MetalKit

struct NDIMetalView: NSViewRepresentable {
    let receiver: NDIReceiver

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }

        let view = MTKView(frame: .zero, device: device)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60

        context.coordinator.attach(to: view, receiver: receiver)

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.receiver = receiver
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var receiver: NDIReceiver?

        private var device: MTLDevice!
        private var queue: MTLCommandQueue!
        private var pipeline: MTLRenderPipelineState!

        private var sampler: MTLSamplerState!
        private var texture: MTLTexture?
        private var textureW: Int = 0
        private var textureH: Int = 0
        private var lastDataHash: Int = 0

        func attach(to view: MTKView, receiver: NDIReceiver) {
            self.receiver = receiver
            self.device = view.device
            self.queue = device.makeCommandQueue()

            let library = device.makeDefaultLibrary()
            let v = library?.makeFunction(name: "fullscreenVertex")
            let f = library?.makeFunction(name: "textureFragment")

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = v
            desc.fragmentFunction = f
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat

            self.pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            if pipeline == nil {
                fatalError("Failed to create pipeline. Check NDIShaders.metal is in target.")
            }

            let sampDesc = MTLSamplerDescriptor()
            sampDesc.minFilter = .linear
            sampDesc.magFilter = .linear
            sampDesc.sAddressMode = .clampToEdge
            sampDesc.tAddressMode = .clampToEdge
            self.sampler = device.makeSamplerState(descriptor: sampDesc)

            view.delegate = self
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard
                let drawable = view.currentDrawable,
                let rpd = view.currentRenderPassDescriptor,
                let pipeline = pipeline,
                let queue = queue
            else { return }

            // Забираем последний кадр (копия Data)
            if let frame = receiver?.consumeLatestFrame() {
                // чтобы не делать лишний replace каждый тик — грубый hash по размеру+первым байтам
                let hash = frame.width ^ frame.height ^ frame.stride ^ frame.data.count
                if hash != lastDataHash || frame.width != textureW || frame.height != textureH {
                    lastDataHash = hash
                    ensureTexture(width: frame.width, height: frame.height)
                    upload(frame: frame)
                } else {
                    // даже если hash совпал, кадры могут меняться — лучше обновлять всегда (но дороже).
                    // Если хочешь — включим всегда-апдейт.
                    upload(frame: frame)
                }
            }

            let cmd = queue.makeCommandBuffer()
            let enc = cmd?.makeRenderCommandEncoder(descriptor: rpd)

            enc?.setRenderPipelineState(pipeline)
            enc?.setFragmentSamplerState(sampler, index: 0)

            if let tex = texture {
                enc?.setFragmentTexture(tex, index: 0)
            }

            // рисуем 6 вершин (2 треугольника) без вершинного буфера
            enc?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc?.endEncoding()

            cmd?.present(drawable)
            cmd?.commit()
        }

        private func ensureTexture(width: Int, height: Int) {
            if texture != nil, textureW == width, textureH == height { return }

            textureW = width
            textureH = height

            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            td.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: td)
        }

        private func upload(frame: NDIReceiver.VideoFrame) {
            guard let tex = texture else { return }
            guard frame.width == textureW, frame.height == textureH else { return }

            frame.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let region = MTLRegionMake2D(0, 0, frame.width, frame.height)
                tex.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: frame.stride)
            }
        }
    }
}

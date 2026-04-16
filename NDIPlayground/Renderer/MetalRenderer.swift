import Foundation
import Metal
import MetalKit
import simd
import CoreMedia

final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue

    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    // Present pipeline (dynamic pixelFormat to avoid Metal asserts)
    private var presentPipeline: MTLRenderPipelineState?
    private var presentPipelinePixelFormat: MTLPixelFormat?
    private var presentPipelineSampleCount: Int = -1
    private var presentPipelineDepthFormat: MTLPixelFormat = .invalid
    private var presentPipelineStencilFormat: MTLPixelFormat = .invalid

    private var vbuf: MTLBuffer?
    private var ibuf: MTLBuffer?
    private var indexCount: Int = 0

    // Additional static "venue" meshes (rendered with gray shading, no texture)
    private var venueVbuf: MTLBuffer?
    private var venueIbuf: MTLBuffer?
    private var venueIndexCount: Int = 0

    private var textureSource: (any TextureSource)?
    private var currentTexture: MTLTexture?

    private var showUVGrid: Bool = false
    private var uvGridDensity: Float = 20
    private var faceMode: FaceMode = .both
    private var inactiveSideMode: InactiveSideMode = .gray

    // Floor grid
    private var showFloorGrid: Bool = true
    private var gridPipeline: MTLRenderPipelineState!
    private var gridDepthState: MTLDepthStencilState!
    private var gridVbuf: MTLBuffer?
    private var gridVertexCount: Int = 0


    private var pendingFit = false
    private var fitMin = SIMD3<Float>(0, 0, 0)
    private var fitMax = SIMD3<Float>(0, 0, 0)

    private var sceneRadius: Float = 1.0
    private var fovDegrees: Float = 50
    
    // Current viewport aspect ratio
    private(set) var currentAspectRatio: Float = 16.0 / 9.0

    // ✅ Camera is owned by ViewerViewModel; renderer just references it
    private weak var cameraRef: OrbitCamera?
    private let fallbackCamera = OrbitCamera()

    // Offscreen capture target (THIS is what we record/screenshot)
    private var captureTexture: MTLTexture?
    private var captureDepthTexture: MTLTexture?
    private let capture: RenderCapture

    private struct UVGridParams {
        var density: Float
        var lineWidth: Float
        var opacity: Float
        var _pad: Float
    }

    init(view: MTKView) {
        guard let d = view.device else { fatalError("No Metal device") }
        device = d
        queue = d.makeCommandQueue()!
        capture = RenderCapture(device: d, queue: queue)
        super.init()
                buildMainPipeline(view: view)
                buildGridPipeline(view: view)
                buildFloorGridGeometry()
    }

    // MARK: - Camera binding

    func setCamera(_ c: OrbitCamera?) {
        cameraRef = c
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Update aspect ratio
        if size.width > 0 && size.height > 0 {
            currentAspectRatio = Float(size.width / size.height)
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }

        let camera = cameraRef ?? fallbackCamera

        // Create/resize offscreen targets using ACTUAL drawable pixel format
        ensureCaptureTargets(size: view.drawableSize, colorFormat: drawable.texture.pixelFormat)

        guard let capTex = captureTexture,
              let capDepth = captureDepthTexture,
              let cmd = queue.makeCommandBuffer()
        else { return }

        // Update content texture (NDI/video/image)
        currentTexture = textureSource?.currentMetalTexture(device: device)

        // --------------------------
        // PASS 1: render 3D into capTex
        // --------------------------
        let capRPD = MTLRenderPassDescriptor()
        capRPD.colorAttachments[0].texture = capTex
        capRPD.colorAttachments[0].loadAction = .clear
        capRPD.colorAttachments[0].storeAction = .store
        capRPD.colorAttachments[0].clearColor = view.clearColor

        capRPD.depthAttachment.texture = capDepth
        capRPD.depthAttachment.loadAction = .clear
        capRPD.depthAttachment.storeAction = .dontCare
        capRPD.depthAttachment.clearDepth = 1.0

        // Create encoder always: we may want to draw floor grid even without mesh
        let enc = cmd.makeRenderCommandEncoder(descriptor: capRPD)!
        enc.setCullMode(.none)
        enc.setFrontFacing(.counterClockwise)

        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))

        if pendingFit, view.drawableSize.width > 1, view.drawableSize.height > 1 {
            camera.fit(min: fitMin, max: fitMax, fovDegrees: camera.fovDegrees, aspect: aspect)

            pendingFit = false
        }

        let farPlane: Float = max(500.0, sceneRadius * 50.0, camera.distance * 20.0)
        let nearPlane: Float = max(0.0001, min(0.05, farPlane / 1_000_000.0))

        let proj = perspective(
            fovy: camera.fovDegrees * .pi / 180,
            aspect: aspect,
            near: nearPlane,
            far: farPlane
        )


        let viewM = camera.viewMatrix()

        // ---- draw floor grid first (alpha blended)
        if showFloorGrid, let gridVbuf, gridVertexCount > 0 {
            // place grid slightly below bbox min Y to avoid z-fighting
            let floorY: Float = 0

            var gridModel = simd_float4x4.identity
            gridModel.columns.3 = SIMD4<Float>(0, floorY, 0, 1)
            var gridMVP = proj * viewM * gridModel

            enc.setRenderPipelineState(gridPipeline)
            enc.setDepthStencilState(gridDepthState)
            enc.setVertexBuffer(gridVbuf, offset: 0, index: 0)
            enc.setVertexBytes(&gridMVP, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }

        // ---- draw venue meshes (static gray shading, independent of source)
        if let venueVbuf, let venueIbuf, venueIndexCount > 0 {
            let model = simd_float4x4.identity
            let mvp = proj * viewM * model

            var uVenue = Uniforms(
                mvp: mvp,
                showUVGrid: 2,           // special flag: venue (no UV grid, gray shading)
                faceMode: 0,             // both sides active
                inactiveMode: 0          // gray for inactive (but both active anyway)
            )

            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)

            enc.setVertexBuffer(venueVbuf, offset: 0, index: 0)
            enc.setVertexBytes(&uVenue, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uVenue, length: MemoryLayout<Uniforms>.stride, index: 0)

            var gridParams = UVGridParams(density: 1, lineWidth: 0.0, opacity: 0.0, _pad: 0)
            enc.setFragmentBytes(&gridParams, length: MemoryLayout<UVGridParams>.stride, index: 1)

            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: venueIndexCount,
                                      indexType: .uint32,
                                      indexBuffer: venueIbuf,
                                      indexBufferOffset: 0)

            // Edge pass: draw wireframe outlines in black on top of gray fill
            enc.setTriangleFillMode(.lines)

            var uEdge = Uniforms(
                mvp: mvp,
                showUVGrid: 3,       // flag for edge pass in shader
                faceMode: 0,
                inactiveMode: 0
            )

            enc.setVertexBytes(&uEdge, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uEdge, length: MemoryLayout<Uniforms>.stride, index: 0)

            var edgeGrid = UVGridParams(density: 1, lineWidth: 0.0, opacity: 0.0, _pad: 0)
            enc.setFragmentBytes(&edgeGrid, length: MemoryLayout<UVGridParams>.stride, index: 1)

            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: venueIndexCount,
                                      indexType: .uint32,
                                      indexBuffer: venueIbuf,
                                      indexBufferOffset: 0)

            enc.setTriangleFillMode(.fill)
        }

        // ---- draw main mesh (textured)
        if let vbuf, let ibuf, indexCount > 0 {
            let model = simd_float4x4.identity
            let mvp = proj * viewM * model

            let fm: UInt32 = {
                switch faceMode {
                case .both: return 0
                case .front: return 1
                case .back: return 2
                }
            }()

            let im: UInt32 = (inactiveSideMode == .hide) ? 1 : 0

            var u = Uniforms(
                mvp: mvp,
                showUVGrid: showUVGrid ? 1 : 0,
                faceMode: fm,
                inactiveMode: im
            )

            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)

            enc.setVertexBuffer(vbuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)

            var grid = UVGridParams(density: uvGridDensity, lineWidth: 0.04, opacity: 0.6, _pad: 0)
            enc.setFragmentBytes(&grid, length: MemoryLayout<UVGridParams>.stride, index: 1)

            if let tex = currentTexture {
                enc.setFragmentTexture(tex, index: 0)
            }

            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: indexCount,
                                      indexType: .uint32,
                                      indexBuffer: ibuf,
                                      indexBufferOffset: 0)
        }

        enc.endEncoding()


        // --------------------------
        // PASS 2: present capTex to drawable (NO BLIT => no asserts)
        // --------------------------
        if let rpd = view.currentRenderPassDescriptor {
            rebuildPresentPipelineIfNeeded(for: rpd, view: view)

            if let presentPipeline = presentPipeline {
                let enc2 = cmd.makeRenderCommandEncoder(descriptor: rpd)!
                enc2.setRenderPipelineState(presentPipeline)
                enc2.setFragmentTexture(capTex, index: 0)
                enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc2.endEncoding()
            }
        }

        // --------------------------
        // Capture (recording)
        // --------------------------
        capture.pushFrame(texture: capTex)

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Public capture API (called from bridge)

    func startVideoCapture(url: URL, fps: Int, includeVideoAudio: Bool = false, includeMic: Bool = false) throws {
        guard let t = captureTexture else {
            try capture.startRecording(url: url, width: 1280, height: 720, fps: Int32(fps), includeVideoAudio: includeVideoAudio, includeMic: includeMic)
            return
        }
        try capture.startRecording(url: url, width: t.width, height: t.height, fps: Int32(fps), includeVideoAudio: includeVideoAudio, includeMic: includeMic)
    }

    func stopVideoCapture(completion: @escaping (Result<URL, Error>) -> Void) {
        capture.stopRecording(completion: completion)
    }
    
    func pushVideoAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        capture.pushVideoAudioSampleBuffer(sampleBuffer)
    }

    func pushMicSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        capture.pushMicSampleBuffer(sampleBuffer)
    }

    func saveScreenshot(url: URL) throws {
        try capture.saveLastFrameScreenshot(to: url)
    }

    // MARK: - Scene / Controls

    func setFOV(_ v: Float) {
        fovDegrees = v                // оставляем, чтобы ничего не сломать
        cameraRef?.fovDegrees = v     // ✅ истинное значение теперь в OrbitCamera
    }

    func setScene(mesh: Mesh?) {
        guard let mesh else {
            vbuf = nil
            ibuf = nil
            indexCount = 0
            sceneRadius = 1.0
            return
        }

        vbuf = device.makeBuffer(bytes: mesh.vertices,
                                 length: MemoryLayout<Vertex>.stride * mesh.vertices.count,
                                 options: [.storageModeShared])
        ibuf = device.makeBuffer(bytes: mesh.indices,
                                 length: MemoryLayout<UInt32>.stride * mesh.indices.count,
                                 options: [.storageModeShared])
        indexCount = mesh.indices.count

        var mn = SIMD3<Float>(Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude)
        var mx = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude)

        for v in mesh.vertices {
            mn = simd_min(mn, v.position)
            mx = simd_max(mx, v.position)
        }

        fitMin = mn
        fitMax = mx

        let ext = mx - mn
        let r = max(ext.x, max(ext.y, ext.z)) * 0.5
        sceneRadius = max(0.001, r)
        buildFloorGridGeometry()

    }

    /// Set additional static "venue" meshes. All meshes are merged into a single GPU buffer.
    func setVenueMeshes(_ meshes: [Mesh]) {
        guard !meshes.isEmpty else {
            venueVbuf = nil
            venueIbuf = nil
            venueIndexCount = 0
            return
        }

        var allVerts: [Vertex] = []
        var allIndices: [UInt32] = []
        allVerts.reserveCapacity(meshes.reduce(0) { $0 + $1.vertices.count })
        allIndices.reserveCapacity(meshes.reduce(0) { $0 + $1.indices.count })

        for mesh in meshes {
            let base = UInt32(allVerts.count)
            allVerts.append(contentsOf: mesh.vertices)
            allIndices.append(contentsOf: mesh.indices.map { $0 + base })
        }

        venueVbuf = device.makeBuffer(bytes: allVerts,
                                      length: MemoryLayout<Vertex>.stride * allVerts.count,
                                      options: [.storageModeShared])
        venueIbuf = device.makeBuffer(bytes: allIndices,
                                      length: MemoryLayout<UInt32>.stride * allIndices.count,
                                      options: [.storageModeShared])
        venueIndexCount = allIndices.count
    }

    func setTextureSource(_ s: (any TextureSource)?) { textureSource = s }
    func setShowUVGrid(_ v: Bool) { showUVGrid = v }
    func setUVGridDensity(_ v: Float) { uvGridDensity = max(1, min(v, 200)) }
    func setFaceMode(_ m: FaceMode) { faceMode = m }
    func setInactiveSideMode(_ m: InactiveSideMode) { inactiveSideMode = m }
    func requestFit() { pendingFit = true }

    // MARK: - Floor grid

    func setShowFloorGrid(_ v: Bool) { showFloorGrid = v }

    private func buildGridPipeline(view: MTKView) {
        let lib = device.makeDefaultLibrary()!

        let v = lib.makeFunction(name: "grid_vs")!
        let f = lib.makeFunction(name: "grid_ps")!

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = v
        desc.fragmentFunction = f
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        // Alpha blending for semi-transparent lines
        if let a = desc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .sourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        gridPipeline = try! device.makeRenderPipelineState(descriptor: desc)

        // Depth test ON, but do NOT write depth (grid shouldn't affect mesh depth)
        let d = MTLDepthStencilDescriptor()
        d.isDepthWriteEnabled = false
        d.depthCompareFunction = .lessEqual
        gridDepthState = device.makeDepthStencilState(descriptor: d)
    }

    private func buildFloorGridGeometry() {
        // Scale grid by sceneRadius (fallback: 1..)
        let half = max(1.0, sceneRadius * 4.0)          // coverage
        let step = max(0.1, sceneRadius / 10.0)         // density adapts with scene scale

        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(4096)

        // Lines along X (vary Z)
        var z: Float = -half
        while z <= half + 0.0001 {
            verts.append(SIMD3(-half, 0, z))
            verts.append(SIMD3( half, 0, z))
            z += step
        }

        // Lines along Z (vary X)
        var x: Float = -half
        while x <= half + 0.0001 {
            verts.append(SIMD3(x, 0, -half))
            verts.append(SIMD3(x, 0,  half))
            x += step
        }

        gridVertexCount = verts.count
        gridVbuf = device.makeBuffer(bytes: verts,
                                     length: MemoryLayout<SIMD3<Float>>.stride * verts.count,
                                     options: .storageModeShared)
    }

    // MARK: - Pipelines

    // MARK: - Pipelines

    private func buildMainPipeline(view: MTKView) {
        let lib = device.makeDefaultLibrary()!

        let v = lib.makeFunction(name: "uv3d_vs")!
        let f = lib.makeFunction(name: "uv3d_ps")!

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = v
        desc.fragmentFunction = f
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0

        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = 0

        vd.attributes[2].format = .float3
        vd.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
        vd.attributes[2].bufferIndex = 0

        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        desc.vertexDescriptor = vd

        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let d = MTLDepthStencilDescriptor()
        d.isDepthWriteEnabled = true
        d.depthCompareFunction = .less
        depthState = device.makeDepthStencilState(descriptor: d)
    }

    private func rebuildPresentPipelineIfNeeded(for rpd: MTLRenderPassDescriptor, view: MTKView) {
        guard let att = rpd.colorAttachments[0] else { return }
        let targetTex = att.texture ?? att.resolveTexture
        guard let targetTex = targetTex else { return }

        let colorPF = targetTex.pixelFormat
        let sampleCount = targetTex.sampleCount

        let depthPF = rpd.depthAttachment.texture?.pixelFormat ?? .invalid
        let stencilPF = rpd.stencilAttachment.texture?.pixelFormat ?? .invalid

        if presentPipeline != nil,
           presentPipelinePixelFormat == colorPF,
           presentPipelineSampleCount == sampleCount,
           presentPipelineDepthFormat == depthPF,
           presentPipelineStencilFormat == stencilPF
        {
            return
        }

        let lib = device.makeDefaultLibrary()!
        let pv = lib.makeFunction(name: "present_vs")!
        let pf = lib.makeFunction(name: "present_ps")!

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = pv
        desc.fragmentFunction = pf
        desc.colorAttachments[0].pixelFormat = colorPF
        desc.sampleCount = sampleCount
        desc.depthAttachmentPixelFormat = depthPF
        desc.stencilAttachmentPixelFormat = stencilPF

        presentPipeline = try! device.makeRenderPipelineState(descriptor: desc)
        presentPipelinePixelFormat = colorPF
        presentPipelineSampleCount = sampleCount
        presentPipelineDepthFormat = depthPF
        presentPipelineStencilFormat = stencilPF
    }

    // MARK: - Capture textures

    private func ensureCaptureTargets(size: CGSize, colorFormat: MTLPixelFormat) {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))

        if let t = captureTexture,
           let d = captureDepthTexture,
           t.width == w, t.height == h,
           d.width == w, d.height == h,
           t.pixelFormat == colorFormat {
            return
        }

        let cdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        // Render into it + read it in present_ps
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .private
        captureTexture = device.makeTexture(descriptor: cdesc)

        let ddesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        ddesc.usage = [.renderTarget]
        ddesc.storageMode = .private
        captureDepthTexture = device.makeTexture(descriptor: ddesc)
    }
}

import simd

struct Vertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
    var normal: SIMD3<Float>
}

struct Uniforms {
    var mvp: simd_float4x4
    var showUVGrid: UInt32
    var faceMode: UInt32       // 0=both, 1=front, 2=back
    var inactiveMode: UInt32   // 0=gray, 1=hide
}



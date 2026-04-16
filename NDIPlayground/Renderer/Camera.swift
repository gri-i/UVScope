import simd
import Foundation

final class OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 2.5
    var yaw: Float = 0
    var pitch: Float = 0

    /// Keep here so camera can fully restore state independently of renderer.
    var fovDegrees: Float = 50

    // MARK: - Input

    func orbit(deltaX: Float, deltaY: Float) {
        yaw += deltaX * 0.005
        pitch += deltaY * 0.005
        pitch = Swift.max(-1.2, Swift.min(1.2, pitch))
    }

    /// "Head rotation" / look-around: keep eye fixed, rotate view direction (moves target).
    func look(deltaX: Float, deltaY: Float) {
        let eye = position

        yaw += deltaX * 0.005
        pitch += deltaY * 0.005
        pitch = Swift.max(-1.2, Swift.min(1.2, pitch))

        let cx = cos(pitch), sx = sin(pitch)
        let cy = cos(yaw),   sy = sin(yaw)
        let forward = SIMD3<Float>(cy * cx, sx, sy * cx)

        // eye = target - forward * distance  =>  target = eye + forward * distance
        target = eye + forward * distance
    }

    func zoom(delta: Float) {
        let factor = exp(-delta)
        distance = Swift.max(0.001, distance * factor)
    }

    func pan(dx: Float, dy: Float) {
        let (_, right, up) = basis()

        let k: Float = 0.002 * Swift.max(0.01, distance)
        target += (-right * dx + up * dy) * k
    }

    // MARK: - Matrices

    func viewMatrix() -> simd_float4x4 {
        lookAt(eye: position, center: target, up: SIMD3<Float>(0, 1, 0))
    }

    // ✅ FIX: НЕ называем параметр "max" — иначе max() ломается
    func fit(min minV: SIMD3<Float>, max maxV: SIMD3<Float>, fovDegrees: Float, aspect: Float) {
        let center = (minV + maxV) * 0.5
        let ext = maxV - minV
        let radius = Swift.max(ext.x, Swift.max(ext.y, ext.z)) * 0.5

        target = center

        let fov = Swift.max(5.0, Swift.min(120.0, fovDegrees)) * .pi / 180.0
        let dist = radius / Swift.max(0.0001, tan(fov * 0.5))

        distance = Swift.max(0.2, dist * 1.25)
    }

    // MARK: - Derived properties

    var position: SIMD3<Float> {
        let (forward, _, _) = basis()
        return target - forward * distance
    }

    func setPositionKeepingTarget(_ eye: SIMD3<Float>) {
        let v = target - eye
        let d = Swift.max(0.0001, simd_length(v))
        let dir = v / d

        pitch = asin(Swift.max(-1.0, Swift.min(1.0, dir.y)))
        yaw = atan2(dir.z, dir.x)

        pitch = Swift.max(-1.2, Swift.min(1.2, pitch))
        distance = d
    }

    // MARK: - Internal basis

    private func basis() -> (forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        let cx = cos(pitch), sx = sin(pitch)
        let cy = cos(yaw),   sy = sin(yaw)

        let forward = SIMD3<Float>(cy * cx, sx, sy * cx)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        return (forward, right, up)
    }
}

// MARK: - Math helpers

func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovy * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(
        SIMD4<Float>( x, 0, 0, 0),
        SIMD4<Float>( 0, y, 0, 0),
        SIMD4<Float>( 0, 0, z, -1),
        SIMD4<Float>( 0, 0, z * near, 0)
    )
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)

    return simd_float4x4(
        SIMD4<Float>( s.x,  u.x, -f.x, 0),
        SIMD4<Float>( s.y,  u.y, -f.y, 0),
        SIMD4<Float>( s.z,  u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    )
}

extension simd_float4x4 {
    static var identity: simd_float4x4 { matrix_identity_float4x4 }
}

// MARK: - Persistence bridge (CameraState)

extension OrbitCamera {

    func applyImportedCamera(eye: SIMD3<Float>,
                             forward: SIMD3<Float>,
                             fovDegrees: Float,
                             keepDistance: Bool = true) {
        self.fovDegrees = fovDegrees

        let f = simd_normalize(forward)
        let d: Float = keepDistance ? Swift.max(0.001, distance) : Swift.max(0.001, simd_length(target - eye))

        target = eye + f * d
        setPositionKeepingTarget(eye)
    }

    func toState() -> CameraState {
        CameraState(
            position: position,
            target: target,
            yaw: yaw,
            pitch: pitch,
            distance: distance,
            fov: fovDegrees
        )
    }

    func apply(state: CameraState) {
        target = state.target
        fovDegrees = state.fov
        setPositionKeepingTarget(state.position)
    }

    func animateTo(_ state: CameraState, duration: Double) {
        apply(state: state)
    }
}

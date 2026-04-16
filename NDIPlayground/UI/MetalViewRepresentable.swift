// MetalViewRepresentable.swift
import SwiftUI
import MetalKit

struct MetalViewRepresentable: NSViewRepresentable {
    @ObservedObject var vm: ViewerViewModel

    func makeNSView(context: Context) -> MTKView {
        let v = InteractionMTKView()

        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.preferredFramesPerSecond = 60
        v.clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1)
        v.isPaused = false
        v.enableSetNeedsDisplay = false

        v.appearance = NSAppearance(named: .darkAqua)

        v.interactionDelegate = context.coordinator
        context.coordinator.attach(mtkView: v, vm: vm)
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.appearance = NSAppearance(named: .darkAqua)
        context.coordinator.update(vm: vm)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, InteractionMTKViewDelegate {
        private var renderer: MetalRenderer?
        private weak var vmRef: ViewerViewModel?

        // (floor grid is driven by vm.showFloorGrid)

        private var lastDrag: CGPoint?
        private var lastFitRequestID: Int = 0

        private var persistWorkItem: DispatchWorkItem?


        private func schedulePersistCamera() {
            persistWorkItem?.cancel()
            guard let vm = vmRef else { return }
            let item = DispatchWorkItem {
                Persistence.saveLastCameraState(vm.camera.toState())
            }
            persistWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }

        private func setFOVDelta(_ delta: Float) {
            guard let vm = vmRef else { return }
            let newFov = max(5, min(120, vm.fovDegrees + delta))
            vm.fovDegrees = newFov
            vm.camera.fovDegrees = newFov
            schedulePersistCamera()
        }

        func attach(mtkView: MTKView, vm: ViewerViewModel) {
            vmRef = vm

            let r = MetalRenderer(view: mtkView)
            renderer = r

            r.setCamera(vm.camera)

            r.setFOV(vm.fovDegrees)
            r.setScene(mesh: vm.mesh)
            r.setTextureSource(vm.activeSource)
            r.setVenueMeshes(vm.venues.filter { $0.visible }.map { $0.mesh })

            r.setShowUVGrid(vm.showUVGrid)
            r.setUVGridDensity(Float(vm.uvGridDensity))
            r.setFaceMode(vm.faceMode)
            r.setInactiveSideMode(vm.inactiveSideMode)

            // Floor grid
            r.setShowFloorGrid(vm.showFloorGrid)



            lastFitRequestID = vm.fitRequestID

            vm.setCaptureBridge(r)

            // Trackpad pan -> orbit/look depending on lock
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTrackpadPan(_:)))
            mtkView.addGestureRecognizer(pan)

            // Pinch -> zoom(distance) or FOV depending on lock
            let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            mtkView.addGestureRecognizer(magnify)

            mtkView.delegate = r
        }

        func update(vm: ViewerViewModel) {
            guard let r = renderer else { return }
            vmRef = vm

            r.setCamera(vm.camera)

            r.setFOV(vm.fovDegrees)
            r.setScene(mesh: vm.mesh)
            r.setTextureSource(vm.activeSource)
            r.setVenueMeshes(vm.venues.filter { $0.visible }.map { $0.mesh })

            r.setShowUVGrid(vm.showUVGrid)
            r.setUVGridDensity(Float(vm.uvGridDensity))
            r.setFaceMode(vm.faceMode)
            r.setInactiveSideMode(vm.inactiveSideMode)
            r.setShowFloorGrid(vm.showFloorGrid)


            if vm.fitRequestID != lastFitRequestID {
                lastFitRequestID = vm.fitRequestID
                r.requestFit()
                schedulePersistCamera()
            }
        }

        // MARK: - Trackpad gestures

        @objc private func handleTrackpadPan(_ g: NSPanGestureRecognizer) {
            guard let v = g.view else { return }
            guard let vm = vmRef else { return }

            let p = g.location(in: v)

            if g.state == .began { lastDrag = p }
            if g.state == .changed, let last = lastDrag {
                let dx = Float(p.x - last.x)
                let dy = Float(p.y - last.y)

                if vm.isCameraLocked {
                    vm.camera.look(deltaX: dx, deltaY: dy)
                } else {
                    vm.camera.orbit(deltaX: dx, deltaY: dy)
                }

                schedulePersistCamera()
                lastDrag = p
            }
            if g.state == .ended || g.state == .cancelled { lastDrag = nil }
        }

        @objc private func handleMagnify(_ g: NSMagnificationGestureRecognizer) {
            guard let vm = vmRef else { return }

            // g.magnification is a delta since last callback (can spike)
            var m = Float(g.magnification)
            if m == 0 { return }

            // Clamp spikes so one update can't "teleport" the camera
            let maxMagPerUpdate: Float = 0.08   // 0.05..0.12 подбирается
            if m >  maxMagPerUpdate { m =  maxMagPerUpdate }
            if m < -maxMagPerUpdate { m = -maxMagPerUpdate }

            if vm.isCameraLocked {
                // FOV: keep gentle
                setFOVDelta(-m * 18.0)          // 12..22 подбирается
            } else {
                // Distance: much gentler than before
                let d = vm.camera.distance   // если у тебя другое имя — скажи/покажи 1 строку камеры
                let distanceScale = max(0.15, min(1.0, d / 6.0))  // до 6 единиц — замедляем
                vm.camera.zoom(delta: -m * 0.35 * distanceScale)
 // 0.3..0.9 подбирается
                schedulePersistCamera()
            }
        }


        // MARK: - InteractionMTKViewDelegate (presets still work)

        func mtkViewToggleCameraLock() {
            // not used now (we toggle via menu), but keep for compatibility
            vmRef?.isCameraLocked.toggle()
        }

        func mtkViewDidScroll(deltaY: Float) {
            guard let vm = vmRef else { return }

            if vm.isCameraLocked {
                setFOVDelta(-deltaY * 0.05)
            } else {
                vm.camera.zoom(delta: deltaY * 0.01)
                schedulePersistCamera()
            }
        }

        func mtkViewMouseDown(point: CGPoint, button: Int, optionPressed: Bool, commandPressed: Bool) {
            lastDrag = point
        }

        func mtkViewMouseDragged(point: CGPoint, button: Int, optionPressed: Bool, commandPressed: Bool) {
            guard let vm = vmRef else { return }

            guard let last = lastDrag else {
                lastDrag = point
                return
            }

            let dx = Float(point.x - last.x)
            let dy = Float(point.y - last.y)

            if vm.isCameraLocked {
                // lock: ONLY head rotation
                vm.camera.look(deltaX: dx, deltaY: dy)
                schedulePersistCamera()
                lastDrag = point
                return
            }

            // normal mode
            if button == 2 {
                vm.camera.pan(dx: dx, dy: -dy)
            } else {
                if optionPressed {
                    vm.camera.pan(dx: dx, dy: dy)
                } else {
                    vm.camera.orbit(deltaX: dx, deltaY: dy)
                }
            }

            schedulePersistCamera()
            lastDrag = point
        }

        func mtkViewMouseUp(point: CGPoint, button: Int, optionPressed: Bool, commandPressed: Bool) {
            lastDrag = nil
        }

        func mtkViewSaveCameraPreset(index: Int) {
            guard let vm = vmRef else { return }
            Persistence.saveCameraPreset(index: index, state: vm.camera.toState())
            schedulePersistCamera()
        }

        func mtkViewRecallCameraPreset(index: Int) {
            guard let vm = vmRef else { return }
            guard let state = Persistence.restoreCameraPreset(index: index) else { return }
            vm.camera.animateTo(state, duration: 0.25)
            vm.fovDegrees = vm.camera.fovDegrees
            schedulePersistCamera()
        }


    }
}

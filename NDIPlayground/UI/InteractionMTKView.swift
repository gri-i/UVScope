// InteractionMTKView.swift
import MetalKit
import AppKit

// MARK: - Scroll normalization (prevents "crazy zoom" across different mice/trackpads)
private struct ScrollNormalizer {
    // Trackpad / hi-res wheels divisor. Bigger = slower.
    var preciseDivisor: Float = 12.0

    // Classic wheel divisor. Bigger = slower.
    var coarseDivisor: Float = 1.0

    // Clamp per event to avoid huge spikes
    var maxStepPerEvent: Float = 3.0

    // Ignore inertial scrolling (momentum) so zoom doesn't keep going after you stop
    var ignoreMomentum: Bool = true

    /// Returns normalized step: positive => "zoom in", negative => "zoom out"
    mutating func normalizedStep(from event: NSEvent) -> Float {
        if ignoreMomentum, event.momentumPhase != [] { return 0 }


        // macOS: scrollingDeltaY is typically negative when scrolling "up"
        // We'll invert so "scroll up" => positive step (zoom in)
        let raw = Float(-event.scrollingDeltaY)
        if raw == 0 { return 0 }

        let divisor: Float = event.hasPreciseScrollingDeltas ? preciseDivisor : coarseDivisor
        var s = -raw / max(divisor, 0.0001)


        if s >  maxStepPerEvent { s =  maxStepPerEvent }
        if s < -maxStepPerEvent { s = -maxStepPerEvent }
        return s
    }
}


final class InteractionMTKView: MTKView {
    weak var interactionDelegate: InteractionMTKViewDelegate?

    // reliable modifiers
    private var currentMods: NSEvent.ModifierFlags = []

    // ✅ global key monitor (works even when view is not first responder)
    private var keyMonitor: Any?

    // ✅ scroll normalization (stable zoom across devices)
    private var scrollNorm = ScrollNormalizer()

    // ✅ per-input zoom gain (wheel vs pinch)
    private let wheelGain: Float = 1.0      // обычно 0.8..1.4
    private let pinchGain: Float = 0.1    // обычно 0.2..0.6 (чтобы не улетало)


    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        self.appearance = NSAppearance(named: .darkAqua)

        // keep modifiers updated
        if let w = window {
            w.makeFirstResponder(self) // helpful but not required due to key monitor
        }

        installKeyMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeKeyMonitor()
        }
    }

    deinit {
        removeKeyMonitor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.appearance = NSAppearance(named: .darkAqua)
    }

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.flagsChanged(with: event)
    }

    private var optionPressed: Bool { currentMods.contains(.option) }
    private var commandPressed: Bool { currentMods.contains(.command) }

    // MARK: - Key monitor (Cmd+L + presets)

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            self.currentMods = e.modifierFlags

            guard let chars = e.charactersIgnoringModifiers, chars.count == 1 else { return e }

            // ✅ Cmd+L => toggle camera lock
            if self.commandPressed, chars.lowercased() == "l" {
                self.interactionDelegate?.mtkViewToggleCameraLock()
                return nil // swallow
            }

            // presets: Cmd 0-9 save, Opt 0-9 recall
            if let digit = Int(chars), (0...9).contains(digit) {
                if self.commandPressed {
                    self.interactionDelegate?.mtkViewSaveCameraPreset(index: digit)
                    return nil
                }
                if self.optionPressed {
                    self.interactionDelegate?.mtkViewRecallCameraPreset(index: digit)
                    return nil
                }
            }

            return e
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - Scroll / Mouse

    override func scrollWheel(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.scrollWheel(with: event)

        // Normalize to avoid huge deltas on hi-res wheels / trackpads
        let step = scrollNorm.normalizedStep(from: event)
        guard step != 0 else { return }

        interactionDelegate?.mtkViewDidScroll(deltaY: step * wheelGain)

    }
        


    // Left mouse (button 0)
    override func mouseDown(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.mouseDown(with: event)

        // helps focus on click
        window?.makeFirstResponder(self)

        let p = convert(event.locationInWindow, from: nil)
        interactionDelegate?.mtkViewMouseDown(
            point: p,
            button: 0,
            optionPressed: optionPressed,
            commandPressed: commandPressed
        )
    }

    override func mouseDragged(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.mouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        interactionDelegate?.mtkViewMouseDragged(
            point: p,
            button: 0,
            optionPressed: optionPressed,
            commandPressed: commandPressed
        )
    }

    override func mouseUp(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        interactionDelegate?.mtkViewMouseUp(
            point: p,
            button: 0,
            optionPressed: optionPressed,
            commandPressed: commandPressed
        )
    }

    // Middle mouse / other button (button 2)
    override func otherMouseDown(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.otherMouseDown(with: event)

        window?.makeFirstResponder(self)

        let p = convert(event.locationInWindow, from: nil)
        interactionDelegate?.mtkViewMouseDown(
            point: p,
            button: 2,
            optionPressed: optionPressed,
            commandPressed: commandPressed
        )
    }

    override func otherMouseDragged(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.otherMouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        interactionDelegate?.mtkViewMouseDragged(
            point: p,
            button: 2,
            optionPressed: optionPressed,
            commandPressed: commandPressed
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        currentMods = event.modifierFlags
        super.otherMouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        interactionDelegate?.mtkViewMouseUp(
            point: p,
            button: 2,
            optionPressed: optionPressed,
            commandPressed: commandPressed
        )
    }
}

@MainActor
protocol InteractionMTKViewDelegate: AnyObject {
    func mtkViewDidScroll(deltaY: Float)

    func mtkViewMouseDown(point: CGPoint, button: Int, optionPressed: Bool, commandPressed: Bool)
    func mtkViewMouseDragged(point: CGPoint, button: Int, optionPressed: Bool, commandPressed: Bool)
    func mtkViewMouseUp(point: CGPoint, button: Int, optionPressed: Bool, commandPressed: Bool)

    func mtkViewSaveCameraPreset(index: Int)
    func mtkViewRecallCameraPreset(index: Int)

    func mtkViewToggleCameraLock()
}

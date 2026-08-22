#if os(iOS) || os(macOS)

import SwiftUI
import MetalKit
import simd

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif


/// A camera action that can be bound to a held key.
private enum CameraKey {
    case forward, back, left, right, up, down
    case lookUp, lookDown, lookLeft, lookRight
}

/// MTKView subclass that turns platform input into camera moves.
/// Left-drag = orbit, right/cmd-drag = free-look (eye stays put),
/// shift/option/middle-drag = pan, scroll or pinch = zoom,
/// WASD or arrows = fly, Q/E = down/up, IJKL = look, shift = go faster.
class InteractiveMTKView: MTKView {
    weak var camera: MetalKitSceneRenderer?

    /// Movement keys are tracked as a held set and applied per-frame by the renderer,
    /// so motion is smooth and independent of the OS key-repeat rate.
    private var held: Set<CameraKey> = []

    @discardableResult
    private func setHeld(_ direction: CameraKey?, down: Bool) -> Bool {
        guard let direction else { return false }
        if down { held.insert(direction) } else { held.remove(direction) }
        publishMovement()
        return true
    }

    private func publishMovement() {
        var v = SIMD3<Float>(repeating: 0)
        if held.contains(.right)   { v.x += 1 }
        if held.contains(.left)    { v.x -= 1 }
        if held.contains(.up)      { v.y += 1 }
        if held.contains(.down)    { v.y -= 1 }
        if held.contains(.forward) { v.z += 1 }
        if held.contains(.back)    { v.z -= 1 }
        // Normalize so diagonals aren't faster than the cardinal directions.
        camera?.moveInput = (v == .zero) ? .zero : normalize(v)

        var l = SIMD2<Float>(repeating: 0)
        if held.contains(.lookRight) { l.x += 1 }
        if held.contains(.lookLeft)  { l.x -= 1 }
        if held.contains(.lookDown)  { l.y += 1 }   // +y matches mouse deltaY (down)
        if held.contains(.lookUp)    { l.y -= 1 }
        camera?.lookInput = l
#if os(macOS)
        camera?.moveBoost = NSEvent.modifierFlags.contains(.shift) ? Constants.movementBoost : 1
#endif
    }

#if os(macOS)
    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report far finer deltas than a wheel's discrete notches.
        let step: Float = event.hasPreciseScrollingDeltas ? 0.004 : 0.03
        camera?.zoom(exp(Float(-event.scrollingDeltaY) * step))
    }

    override func magnify(with event: NSEvent) {
        camera?.zoom(1 / Float(1 + event.magnification))
    }

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            camera?.look(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
            camera?.pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else {
            camera?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        camera?.look(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func otherMouseDragged(with event: NSEvent) {
        camera?.pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func keyDown(with event: NSEvent) {
        // Movement keys are positional (keyCode), so WASD stays under the left hand
        // regardless of keyboard layout.
        if setHeld(Self.direction(forKeyCode: event.keyCode), down: true) { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":       camera?.resetCamera()
        case "f":       camera?.toggleUpCalibration()
        case " ":       camera?.toggleAutoRotate()
        case "=", "+":  camera?.zoom(0.9)
        case "-", "_":  camera?.zoom(1 / 0.9)
        default:        super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if setHeld(Self.direction(forKeyCode: event.keyCode), down: false) { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        publishMovement()
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // Otherwise a key held while focus moves away stays stuck down forever.
        held.removeAll()
        publishMovement()
        return super.resignFirstResponder()
    }

    private static func direction(forKeyCode code: UInt16) -> CameraKey? {
        switch code {
        case 13, 126: return .forward   // W, up arrow
        case 1, 125:  return .back      // S, down arrow
        case 0, 123:  return .left      // A, left arrow
        case 2, 124:  return .right     // D, right arrow
        case 14, 116: return .up        // E, page up
        case 12, 121: return .down      // Q, page down
        case 34:      return .lookUp    // I
        case 40:      return .lookDown  // K
        case 38:      return .lookLeft  // J
        case 37:      return .lookRight // L
        default:      return nil
        }
    }
#elseif os(iOS)
    override var canBecomeFirstResponder: Bool { true }

    private var lastPoint: CGPoint?
    private var lastPinch: CGFloat?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = nil
        lastPinch = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = (event?.allTouches ?? touches).sorted { $0.hashValue < $1.hashValue }
        if all.count >= 2 {
            let a = all[0].location(in: self), b = all[1].location(in: self)
            let spread = hypot(b.x - a.x, b.y - a.y)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if let lastPinch, lastPinch > 0, spread > 0 {
                camera?.zoom(Float(lastPinch / spread))
            }
            if let lastPoint {
                camera?.pan(dx: Float(mid.x - lastPoint.x), dy: Float(mid.y - lastPoint.y))
            }
            lastPinch = spread
            lastPoint = mid
        } else if let touch = all.first {
            let p = touch.location(in: self)
            if let lastPoint {
                camera?.orbit(dx: Float(p.x - lastPoint.x), dy: Float(p.y - lastPoint.y))
            }
            lastPoint = p
            lastPinch = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = nil
        lastPinch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = nil
        lastPinch = nil
    }

    // Hardware keyboards attached to an iPad.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses where setHeld(Self.direction(for: press.key?.keyCode), down: true) {
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses where setHeld(Self.direction(for: press.key?.keyCode), down: false) {
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        held.removeAll()
        publishMovement()
        super.pressesCancelled(presses, with: event)
    }

    private static func direction(for usage: UIKeyboardHIDUsage?) -> CameraKey? {
        switch usage {
        case .keyboardW, .keyboardUpArrow:    return .forward
        case .keyboardS, .keyboardDownArrow:  return .back
        case .keyboardA, .keyboardLeftArrow:  return .left
        case .keyboardD, .keyboardRightArrow: return .right
        case .keyboardE, .keyboardPageUp:     return .up
        case .keyboardQ, .keyboardPageDown:   return .down
        case .keyboardI:                      return .lookUp
        case .keyboardK:                      return .lookDown
        case .keyboardJ:                      return .lookLeft
        case .keyboardL:                      return .lookRight
        default:                              return nil
        }
    }
#endif
}

struct MetalKitSceneView: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?

    class Coordinator {
        var renderer: MetalKitSceneRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

#if os(macOS)
    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#elseif os(iOS)
    func makeUIView(context: UIViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {
        let metalKitView = InteractiveMTKView()

        if let metalDevice = MTLCreateSystemDefaultDevice() {
            metalKitView.device = metalDevice
        }

        let renderer = MetalKitSceneRenderer(metalKitView)
        coordinator.renderer = renderer
        metalKitView.delegate = renderer
        metalKitView.camera = renderer

        Task {
            do {
                try await renderer?.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }

        return metalKitView
    }

#if os(macOS)
    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#elseif os(iOS)
    func updateUIView(_ view: MTKView, context: UIViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#endif

    private func updateView(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        if let view = renderer.metalKitView as? InteractiveMTKView {
#if os(macOS)
            if let window = view.window, window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
#elseif os(iOS)
            if !view.isFirstResponder { view.becomeFirstResponder() }
#endif
        }
        Task {
            do {
                try await renderer.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }
    }
}

#endif // os(iOS) || os(macOS)

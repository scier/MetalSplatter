#if os(macOS)
import MetalKit

final class InteractiveMTKView: MTKView {
    var cameraController: CameraController?
    private var lastDrag: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastDrag = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let location = event.locationInWindow
        let dx = Float(location.x - last.x)
        let dy = Float(location.y - last.y)
        cameraController?.rotate(deltaX: dx * 0.005, deltaY: dy * 0.005)
        lastDrag = location
    }

    override func scrollWheel(with event: NSEvent) {
        cameraController?.zoom(delta: Float(event.scrollingDeltaY) * 0.1)
    }
}
#endif

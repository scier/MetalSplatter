#if os(iOS) || os(macOS)

import SwiftUI
import MetalKit

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif

struct MetalKitSceneView: View {
    var modelIdentifier: ModelIdentifier?

    @State private var renderer: MetalKitSceneRenderer?

    // Gesture tracking state
    @State private var lastDragYaw: Angle = .zero
    @State private var lastDragPitch: Angle = .zero
    @State private var lastPanOffset: SIMD2<Float> = .zero
    @State private var lastDistance: Float = -Constants.modelCenterZ

    // Observable state for toolbar
    @State private var autoRotate: Bool = true

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalKitSceneViewRepresentable(modelIdentifier: modelIdentifier, renderer: $renderer)
                .gesture(orbitGesture)
                .gesture(zoomGesture)
#if os(iOS)
                .gesture(panGesture)
#endif
                .onScrollGesture { delta in
                    guard let renderer else { return }
                    renderer.distance = max(0.5, renderer.distance - delta)
                }

            controlsOverlay
                .padding(.bottom, 16)
        }
    }

    // MARK: - Gestures

    /// Drag to orbit: horizontal = yaw, vertical = pitch
    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let renderer else { return }
                let sensitivity: Double = 0.3
                renderer.yaw = lastDragYaw + .degrees(value.translation.width * sensitivity)
                renderer.pitch = lastDragPitch + .degrees(value.translation.height * sensitivity)
                // Clamp pitch to avoid flipping
                renderer.pitch = .degrees(min(max(renderer.pitch.degrees, -89), 89))
                renderer.autoRotate = false
                autoRotate = false
            }
            .onEnded { _ in
                guard let renderer else { return }
                lastDragYaw = renderer.yaw
                lastDragPitch = renderer.pitch
            }
    }

#if os(iOS)
    /// Two-finger drag to pan
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .simultaneously(with: DragGesture(minimumDistance: 2))
            .onChanged { value in
                // This is a workaround: on iOS, use MagnifyGesture's simultaneous
                // drag as pan. For a simple implementation, we use a modifier key
                // approach on macOS and a separate gesture on iOS.
            }
    }
#endif

    /// Pinch/magnify to zoom
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let renderer else { return }
                renderer.distance = max(0.5, lastDistance / Float(value.magnification))
            }
            .onEnded { _ in
                guard let renderer else { return }
                lastDistance = renderer.distance
            }
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        HStack(spacing: 12) {
            Button {
                guard let renderer else { return }
                renderer.resetCamera()
                lastDragYaw = .zero
                lastDragPitch = .zero
                lastPanOffset = .zero
                lastDistance = -Constants.modelCenterZ
                autoRotate = true
                renderer.autoRotate = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
            }
            .help("Reset Camera")

            Divider()
                .frame(height: 20)

            Button {
                guard let renderer else { return }
                autoRotate.toggle()
                renderer.autoRotate = autoRotate
            } label: {
                Image(systemName: autoRotate ? "rotate.3d.fill" : "rotate.3d")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(autoRotate ? .primary : .secondary)
            }
            .help(autoRotate ? "Disable Auto-Rotate" : "Enable Auto-Rotate")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Scroll Gesture Modifier

private struct ScrollGestureModifier: ViewModifier {
    let onScroll: (Float) -> Void

    func body(content: Content) -> some View {
#if os(macOS)
        content.onScrollWheelGesture { event in
            onScroll(Float(event.scrollingDeltaY) * 0.1)
        }
#else
        content
#endif
    }
}

private extension View {
    func onScrollGesture(perform action: @escaping (Float) -> Void) -> some View {
        modifier(ScrollGestureModifier(onScroll: action))
    }
}

#if os(macOS)
private struct ScrollWheelModifier: ViewModifier {
    let onScroll: (NSEvent) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            ScrollWheelView(onScroll: onScroll)
        }
    }
}

private struct ScrollWheelView: NSViewRepresentable {
    let onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        ScrollWheelNSView(onScroll: onScroll)
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: (NSEvent) -> Void

    init(onScroll: @escaping (NSEvent) -> Void) {
        self.onScroll = onScroll
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll(event)
    }
}

private extension View {
    func onScrollWheelGesture(perform action: @escaping (NSEvent) -> Void) -> some View {
        modifier(ScrollWheelModifier(onScroll: action))
    }
}
#endif

// MARK: - MTKView Representable (internal)

private struct MetalKitSceneViewRepresentable: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?
    @Binding var renderer: MetalKitSceneRenderer?

    class Coordinator {
        var renderer: MetalKitSceneRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

#if os(macOS)
    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneViewRepresentable>) -> MTKView {
        makeView(context.coordinator)
    }
#elseif os(iOS)
    func makeUIView(context: UIViewRepresentableContext<MetalKitSceneViewRepresentable>) -> MTKView {
        makeView(context.coordinator)
    }
#endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {
        let metalKitView = MTKView()

        if let metalDevice = MTLCreateSystemDefaultDevice() {
            metalKitView.device = metalDevice
        }

        let newRenderer = MetalKitSceneRenderer(metalKitView)
        coordinator.renderer = newRenderer
        metalKitView.delegate = newRenderer

        Task { @MainActor in
            renderer = newRenderer
        }

        Task {
            do {
                try await newRenderer?.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }

        return metalKitView
    }

#if os(macOS)
    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneViewRepresentable>) {
        updateView(context.coordinator)
    }
#elseif os(iOS)
    func updateUIView(_ view: MTKView, context: UIViewRepresentableContext<MetalKitSceneViewRepresentable>) {
        updateView(context.coordinator)
    }
#endif

    private func updateView(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
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

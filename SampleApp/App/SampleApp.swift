#if os(visionOS)
import CompositorServices
#endif
import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

#if os(visionOS)
        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = CompositorServicesSceneRenderer(layerRenderer)
                renderer.load(modelIdentifier.wrappedValue)
                renderer.startRenderLoop()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
#endif // os(visionOS)
    }
}


# MetalSplatter
Render 3D Gaussian Splats using Metal on Apple platforms (iOS/iPhone/iPad, macOS, and visionOS/Vision Pro)

![A greek-style bust of a woman made of metal, wearing aviator-style goggles while gazing toward colorful abstract metallic blobs floating in space](http://metalsplatter.com/hero.640.jpg)

This is a Swift/Metal library for rendering scenes captured via the techniques described in [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/). It will let you load up a PLY and visualize it on iOS, macOS, and visionOS (using amplification for rendering in stereo on Vision Pro). Modules include
* MetalSplatter, the core library to render a frame
* PLYIO, for reading and writing binary or ASCII PLY files; this is standalone, feel free to use it if you just have a hankering to load up some PLY files for some reason.
* SplatIO, a thin layer on top of PLYIO to interpret these PLY files (as well as .splat files) as sets of splats
* SampleApp, a mini app to demonstrate how to use the above (based on Apple template code) -- don't expect much, it's intentionally minimal, just an illustration
* SampleBoxRenderer, a drop-in replacement for MetalSplatter for debugging integration, which just renders the cube from Apple Metal template

### TODO

* Support spherical harmonics
* API documentation
* Explore possibilities for further performance optimizations. Mesh shaders? OIT? Who knows?

## Documentation

You're right, the documentation is entirely missing; it's a major TODO list item. In the meantime, feel free to try out the sample app -- just, like I said, don't expect much.

1. Get yourself a gaussian splat PLY (or .splat) file.
   a. Capture one with [Luma AI's iPhone app](https://apps.apple.com/us/app/luma-ai/id1615849914), and then export in "splat" format
   b. Or try the [scene data from the original paper](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)
   c. Go hardcore and learn to use [Nerfstudio](https://docs.nerf.studio/nerfology/methods/splat.html) to train your own locally
2. Clone the repo and open SampleApp/MetalSplatter_SampleApp.xcodeproj
3. If you want to run on iOS/visionOS, select your target and set your development team and bundle ID in Signing & Capabilities. On macOS, just have at it.
4. Make sure your scheme is set to Release mode. Loading large files in Debug is more than an order of magnitude slower.
5. Run
6. Note: framerate will be better if you run without the debugger attached (hit Stop in Xcode, and go run from the app from the Home screen)

## MetalSplatter Model Viewer

There's a simple, official [MetalSplatter model viewer app](https://apps.apple.com/us/app/metalsplatter/id6476895334) based on this library,
available on visionOS for Vision Pro (support for iOS/macOS is coming later). It's also called MetalSplatter, go figure.

## Acknowledgements

There are no external dependencies, but the math to render gaussian splats is straightforward (the basic representation has [been around for decades](https://en.wikipedia.org/wiki/Gaussian_splatting)), so there are a lot of great references around and I drew on a lot of 'em to try and understand how it works. There's really very little new here, the recent innovations are about training, not rendering. Nonetheless, I pretty much made every mistake possible while implementing it, and the existance of these three implementations was invaluable to help see what I was doing wrong:
* [Kevin Kwok's WebGL implementation](https://github.com/antimatter15/splat)
* [Aras Pranckevičius's Unity implementation](https://github.com/aras-p/UnityGaussianSplatting) and series of very insightful blog posts: [1](https://aras-p.info/blog/2023/09/05/Gaussian-Splatting-is-pretty-cool/), [2](https://aras-p.info/blog/2023/09/13/Making-Gaussian-Splats-smaller/), [3](https://aras-p.info/blog/2023/09/27/Making-Gaussian-Splats-more-smaller/)
* The original paper's [reference implementation](https://github.com/graphdeco-inria/gaussian-splatting)

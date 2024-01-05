# MetalSplatter
Render Gaussian Splats using Metal on Apple platforms (iOS/iPhone/iPad, macOS, and visionOS/Vision Pro)

This is a Swift/Metal library for rendering scenes captured via the techniques described in [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/). It will let you load up a PLY and visualize it on iOS anc macOS as well as the visionOS simulator (using amplification for rendering in stereo on Vision Pro). Modules include
* MetalSplatter, the core library to render a frame
* PLYIO, for reading binary or ASCII PLY files (not writing yet, despite the name); this is standalone, feel free to use it if you just have a hankering to load up some PLY files for some reason.
* SplatIO, a thin layer on top of PLYIO to interpret these PLY files as sets of splats
* SampleApp, a mini app to demonstrate how to use the above (based on Apple template code) -- don't expect much, it's intentionally minimal, just an illustration
* SampleBoxRenderer, a drop-in replacement for MetalSplatter for debugging integration, which just renders the cube from Apple Metal template

## Dangerously early version

There are a lot of big pieces missing here, it's still very much a work in progress, but
I'm putting this out there in case there are any brave curious souls that want to tinker with
it. Just don't expect it to be stable, or particularly robust.

### TODO / general shortcomings

* A model viewer app, which lets you move the camera interactively (and set up a correct local coordinate system and save camera positions)
* Fix colors, which currently aren't quite correct
* Reduce precision to improve memory usage
* Precompute the covariance matrix, to slightly reduce memory usage and time spent in the vertex shader
* Spherical harmonics
* Chunking up into multiple buffers for scalability past ~4m splats
* Sorting on GPS. Sorting is currently done on the CPU asynchronously at a lower framerate (~10 fps), which increases how often you'll see pops especially when the viewpoint changes quickly
* Documentation

## Documentation

You're right, the documentation is entirely missing. I mean, it's kinda embarrasing. Still, this was for fun and I'm gonna get to it eventually, after some of the higher-priority TODO items above. In the meantime, feel free to try out the sample app -- just, like I said, don't expect much.

1. Get yourself a gaussian splat PLY file. Maybe download the [scene data from the oroginal paper](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/) -- or better, train your own! This is left as an exercise to the reader. Once you have it, put it on the device (or simulator) you're going to use
2. Clone the repo and open SampleApp/MetalSplatter_SampleApp.xcodeproj
3. If you want to run on iOS/visionOS, select your target and set your development team and bundle ID in Signing & Capabilities. On macOS, just have at it.
4. Set your scheme to Release mode. Loading large PLY files is in Debug more than an order of magnitude slower.
5. Run it

## Acknowledgements

There are no external dependencies; and the basic math to render gaussian splats is straightforward (the basic representation has [been around for decades](https://en.wikipedia.org/wiki/Gaussian_splatting)), so there are a lot of great references around and I drew on a lot of 'em to try and understand how it works; there's really very little new here, the recent innovations are about training, not rendering. Nonetheless, I pretty much made every mistake possible while implementing it, and the existance of these three implementations was invaluable to help see what I was doing wrong:
* [Kevin Kwok's WebGL implementation](https://github.com/antimatter15/splat)
* [Aras Pranckevičius's Unity implementation](https://github.com/aras-p/UnityGaussianSplatting) and series of very insightful blog posts: [1](https://aras-p.info/blog/2023/09/05/Gaussian-Splatting-is-pretty-cool/), [2](https://aras-p.info/blog/2023/09/13/Making-Gaussian-Splats-smaller/), [3](https://aras-p.info/blog/2023/09/27/Making-Gaussian-Splats-more-smaller/)
* The original paper's [reference implementation](https://github.com/graphdeco-inria/gaussian-splatting)

# MetalSplatter
Render 3D Gaussian Splats using Metal on Apple platforms (iOS/iPhone/iPad, macOS, and visionOS/Vision Pro)

![A greek-style bust of a woman made of metal, wearing aviator-style goggles while gazing toward colorful abstract metallic blobs floating in space](http://metalsplatter.com/hero.640.jpg)

This is a Swift/Metal library for rendering scenes captured via the techniques described in [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/). It will let you load up a PLY and visualize it on iOS, macOS, and visionOS (using amplification for rendering in stereo on Vision Pro). Modules include
* MetalSplatter, the core library to render a frame
* PLYIO, for reading and writing binary or ASCII PLY files; this is standalone, feel free to use it if you just have a hankering to load up some PLY files for some reason.
* SplatIO, a thin layer on top of PLYIO to interpret these PLY files (as well as .splat files) as sets of splats
* SampleApp, a mini app to demonstrate how to use the above (based on Apple template code) -- don't expect much, it's intentionally minimal, just an illustration
* SampleBoxRenderer, a drop-in replacement for MetalSplatter for debugging integration, which just renders the cube from Apple Metal template

## Getting Started

You're right, the documentation is entirely missing; it's a major TODO list item. In the meantime, feel free to try out the sample app -- just, like I said, don't expect much.

1. Get yourself a gaussian splat PLY (or .splat) file (see Resources below)
2. Clone the repo and open SampleApp/MetalSplatter_SampleApp.xcodeproj
3. If you want to run on iOS/visionOS, select your target and set your development team and bundle ID in Signing & Capabilities. On macOS, just have at it.
4. Make sure your scheme is set to Release mode. Loading large files in Debug is more than an order of magnitude slower.
5. Run
6. Note: framerate will be better if you run without the debugger attached (hit Stop in Xcode, and go run from the app from the Home screen)

## Showcase: apps and projects using MetalSplatter

* The [MetalSplatter viewer](https://apps.apple.com/us/app/metalsplatter/id6476895334) is a simple, official Vision Pro app based on this library. This is different from the minimal included sample app (for instance, it has camera controls and a splat gallery). Confusingly, both the (open source) library and (non-open-source) app are called MetalSplatter, and both are by [scier](https://github.com/scier).

* [OverSoul](https://apps.apple.com/app/id6475262918) for Vision Pro: "Capture, share, and interact with spatial photos, 3D models and immersive spaces in a vibrant social ecosystem designed for the next generation of spatial computing"

* Know of another project using MetalSplatter? Let us know!

## Resources

* Looking for .splat files? Here are a few suggestions:
   * Capture your own by using a camera or drone, then use [Nerfstudio](https://docs.nerf.studio/nerfology/methods/splat.html) to train the splat
   * Capture one with [Luma AI's iPhone app](https://apps.apple.com/us/app/luma-ai/id1615849914), and export it in "splat" format
   * Use the [scene data from the original paper](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)
* [RadianceFields.com](https://radiancefields.com) is a great source to track news and articles about 3DGS, NeRFs, and related technology and tools (for instance [news about MetalSplatter](https://radiancefields.com/platforms/metalsplatter])), and the community surrounding it
* [MrNeRF's Awesome 3D Gaussian Splatting Resources](https://github.com/MrNeRF/awesome-3D-gaussian-splatting) is exactly what it says on the label - in particular, an exhaustive and frequently-updated list of 3DGS-related research
* There are a variety of other renderer implementations available with source, such as 
   * [Kevin Kwok's WebGL implementation](https://github.com/antimatter15/splat) and [online demo](https://antimatter15.com/splat/)
   * [Mark Kellogg's three.js implementation](https://github.com/mkkellogg/GaussianSplats3D) and [online demo](https://projects.markkellogg.org/threejs/demo_gaussian_splats_3d.php)
   * [Aras Pranckevičius's Unity implementation](https://github.com/aras-p/UnityGaussianSplatting) and series of very insightful blog posts: [1](https://aras-p.info/blog/2023/09/05/Gaussian-Splatting-is-pretty-cool/), [2](https://aras-p.info/blog/2023/09/13/Making-Gaussian-Splats-smaller/), [3](https://aras-p.info/blog/2023/09/27/Making-Gaussian-Splats-more-smaller/)
   * The original paper's [reference implementation](https://github.com/graphdeco-inria/gaussian-splatting)

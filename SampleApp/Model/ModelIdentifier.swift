import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable, CustomStringConvertible {
    case gaussianSplat(URL)
    case proceduralSplat
    case sampleBox

    var description: String {
        switch self {
        case .gaussianSplat(let url):
            "Gaussian Splat: \(url.path)"
        case .proceduralSplat:
            "Procedural Splat"
        case .sampleBox:
            "Sample Box"
        }
    }
}

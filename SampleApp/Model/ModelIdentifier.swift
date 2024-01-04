import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable {
    case gaussianSplat(URL)
    case sampleBox
}

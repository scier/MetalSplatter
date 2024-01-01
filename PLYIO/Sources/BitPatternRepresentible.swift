public protocol BitPatternRepresentible {
    associatedtype BitPattern
    var bitPattern: BitPattern { get }
    init(bitPattern: BitPattern)
}

extension Float: BitPatternRepresentible {}
extension Double: BitPatternRepresentible {}

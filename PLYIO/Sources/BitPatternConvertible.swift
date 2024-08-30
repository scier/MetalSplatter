public protocol BitPatternConvertible {
    associatedtype BitPattern
    var bitPattern: BitPattern { get }
    init(bitPattern: BitPattern)
}

extension Float: BitPatternConvertible {}
extension Double: BitPatternConvertible {}

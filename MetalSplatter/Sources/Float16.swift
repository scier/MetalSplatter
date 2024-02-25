//
//  Float16.swift
//  MetalSplatter SampleApp
//
//  Created by Oleksandr Fedko on 23.02.2024.
//

import Foundation

#if arch(x86_64)
public typealias OSFloat16 = BCFloat16
#else
public typealias OSFloat16 = Float16
#endif

public struct BCFloat16: Equatable {
    public let bitPattern: UInt16
    
    public init(bitPattern: UInt16) {
        self.bitPattern = bitPattern
    }
    
    public var isQuietNaN: Bool {
        (bitPattern & 0x7c00 == 0x7c00) && (bitPattern & 0x03ff != 0) && (bitPattern & 0x0200 != 0)
    }
    
    public var isNaN: Bool {
        let exponentMask: UInt16 = 0b0111110000000000
        let significandMask: UInt16 = 0b0000001111111111
        
        let exponent = (bitPattern & exponentMask) >> 10
        let significand = bitPattern & significandMask
        
        return exponent == 0b11111 && significand != 0
    }
    
    public init(_ other: Float) {
        self.bitPattern = f32bitsToF16bits(other.bitPattern)
    }
    
    public init(_ other: Double) {
        self.init(Float(other))
    }
    
    public static prefix func -(rhs: BCFloat16) -> BCFloat16 {
        BCFloat16(bitPattern: rhs.bitPattern ^ 0x8000)
    }
    
    public var isNegative: Bool { Float(self) < 0 }
    
    public var isNormal: Bool {
        let exp = bitPattern & 0x7c00
        return (exp != 0x7c00) && (exp != 0)
    }
    
    // IsInf reports whether f is an infinity (inf).
    // A sign > 0 reports whether f is positive inf.
    // A sign < 0 reports whether f is negative inf.
    // A sign == 0 reports whether f is either inf.
    public func isInf(sign: Int) -> Bool {
        ((bitPattern == 0x7c00) && sign >= 0) ||
            (bitPattern == 0xfc00 && sign <= 0)
    }
    
    // Inf returns a Float16 with an infinity value with the specified sign.
    // A sign >= 0 returns positive infinity.
    // A sign < 0 returns negative infinity.
    public static func inf(sign: Int) -> BCFloat16 {
        if sign >= 0 {
            return BCFloat16(bitPattern: 0x7c00)
        }
        return BCFloat16(bitPattern: 0x8000 | 0x7c00)
    }

    public var isFinite: Bool {
        bitPattern & 0x7c00 != 0x7c00
    }
    
    var signBit: Bool {
        bitPattern & 0x8000 != 0
    }
    
    var toString: String {
        String(Float(self))
    }

    public static let zero = BCFloat16(bitPattern: 0)
    public static let nan = BCFloat16(bitPattern: 0x7e01)
    public static let infinity = Self.inf(sign: 1)
    public static let negativeInfinity = Self.inf(sign: -1)
}

public extension Int64 {
    init?(exactly other: BCFloat16) {
        guard let result = Int64(exactly: Double(other)) else {
            return nil
        }
        self = result
    }
}

public extension UInt64 {
    init?(exactly other: BCFloat16) {
        guard let result = UInt64(exactly: Double(other)) else {
            return nil
        }
        self = result
    }
}

public extension BCFloat16 {
    init?(exactly other: UInt64) {
        guard let a = Double(exactly: other) else {
            return nil
        }
        let b = BCFloat16(a)
        guard UInt64(exactly: Double(b)) == other else {
            return nil
        }
        self = b
    }
    
    init?(exactly other: Int64) {
        guard let a = Double(exactly: other) else {
            return nil
        }
        let b = BCFloat16(a)
        guard Int64(exactly: Double(b)) == other else {
            return nil
        }
        self = b
    }
    
    init?(exactly other: Double) {
        let b = BCFloat16(other)
        guard Double(exactly: other) == other else {
            return nil
        }
        self = b
    }
}

public extension Float {
    init(_ other: BCFloat16) {
        self = Float(bitPattern: f16bitsToF32bits(other.bitPattern))
    }
}

public extension Double {
    init(_ other: BCFloat16) {
        self = Double(Float(other))
    }
}

enum Precision {
    case exact
    case unknown
    case inexact
    case underflow
    case overflow
}

func precisionFromfloat32(_ f32: Float) -> Precision {
    let u32 = f32.bitPattern
    
    if u32 == 0 || u32 == 0x80000000 {
        // +- zero will always be exact conversion
        return .exact
    }

    let COEFMASK: UInt32 = 0x7fffff
    let EXPSHIFT: UInt32 = 23
    let EXPBIAS: UInt32 = 127
    let EXPMASK: UInt32 = UInt32(0xff) << EXPSHIFT
    let DROPMASK: UInt32 = COEFMASK >> 10

    let exp = Int32(truncatingIfNeeded: ((u32 & EXPMASK) >> EXPSHIFT) &- EXPBIAS)
    let coef = u32 & COEFMASK

    if exp == 128 {
        // +- infinity or NaN
        // apps may want to do extra checks for NaN separately
        return .exact
    }

    if exp < -24 {
        return .underflow
    }
    if exp > 15 {
        return .overflow
    }
    if (coef & DROPMASK) != UInt32(0) {
        // these include subnormals and non-subnormals that dropped bits
        return .inexact
    }

    if exp < -14 {
        // Subnormals. Caller may want to test these further.
        // There are 2046 subnormals that can successfully round-trip f32->f16->f32
        // and 20 of those 2046 have 32-bit input coef == 0.
        // RFC 7049 and 7049bis Draft 12 don't precisely define "preserves value"
        // so some protocols and libraries will choose to handle subnormals differently
        // when deciding to encode them to CBOR float32 vs float16.
        return .unknown
    }

    return .exact
}

func fromBits(_ u16: UInt16) -> BCFloat16 {
    return BCFloat16(bitPattern: u16)
}

func fromFloat32(_ f32: Float) -> BCFloat16 {
    return BCFloat16(f32)
}

// fromNaN32ps converts nan to IEEE binary16 NaN while preserving both
// signaling and payload. Unlike fromFloat32, which can only return
// qNaN because it sets quiet bit = 1, this can return both sNaN and qNaN.
// If the result is infinity (sNaN with empty payload), then the
// lowest bit of payload is set to make the result a NaN.
// Returns ErrInvalidNaNValue and 0x7c01 (sNaN) if nan isn't IEEE 754 NaN.
// This function was kept simple to be able to inline.
func fromNaN32ps(_ nan: Float32) -> BCFloat16? {
    let u32 = nan.bitPattern
    let sign = u32 & 0x80000000
    let exp = u32 & 0x7f800000
    let coef = u32 & 0x007fffff

    if (exp != 0x7f800000) || (coef == 0) {
        return nil
    }

    let u16 = UInt16((sign >> 16) | UInt32(0x7c00) | (coef >> 13))

    if (u16 & 0x03ff) == 0 {
        // result became infinity, make it NaN by setting lowest bit in payload
        return BCFloat16(bitPattern: u16 | 0x0001)
    }

    return BCFloat16(bitPattern: u16)
}

// f16bitsToF32bits returns UInt32 (float32 bits) converted from specified UInt16.
func f16bitsToF32bits(_ inVal: UInt16) -> UInt32 {
    // All 65536 conversions with this were confirmed to be correct
    // by Montgomery Edwards⁴⁴⁸ (github.com/x448).

    let sign: UInt32 = UInt32(inVal & 0x8000) << 16 // sign for 32-bit
    var exp: UInt32 = UInt32(inVal & 0x7c00) >> 10  // exponent for 16-bit
    var coef: UInt32 = UInt32(inVal & 0x03ff) << 13 // significand for 32-bit

    if exp == 0x1f {
        if coef == 0 {
            // infinity
            return sign | 0x7f800000 | coef
        }
        // NaN
        return sign | 0x7fc00000 | coef
    }

    if exp == 0 {
        if coef == 0 {
            // zero
            return sign
        }

        // normalize subnormal numbers
        exp += 1
        while coef & 0x7f800000 == 0 {
            coef <<= 1
            exp &-= 1
        }
        coef &= 0x007fffff
    }

    return sign | ((exp &+ (0x7f - 0xf)) << 23) | coef
}

// f32bitsToF16bits returns UInt16 (Float16 bits) converted from the specified float32.
// Conversion rounds to nearest integer with ties to even.
func f32bitsToF16bits(_ u32: UInt32) -> UInt16 {
    // Translated from Rust to Go by Montgomery Edwards⁴⁴⁸ (github.com/x448).
    // All 4294967296 conversions with this were confirmed to be correct by x448.
    // Original Rust implementation is by Kathryn Long (github.com/starkat99) with MIT license.
    
    let sign = u32 & 0x80000000
    let exp = u32 & 0x7f800000
    let coef = u32 & 0x007fffff
    
    if exp == 0x7f800000 {
        // NaN or Infinity
        let nanBit: UInt32 = coef != 0 ? 0x0200 : 0
        return UInt16((sign >> 16) | 0x7c00 | nanBit | (coef >> 13))
    }
    
    let halfSign = sign >> 16
    
    let unbiasedExp = Int32(exp >> 23) - 127
    let halfExp = unbiasedExp + 15
    
    if halfExp >= 0x1f {
        return UInt16(halfSign | 0x7c00)
    }
    
    if halfExp <= 0 {
        if 14 - halfExp > 24 {
            return UInt16(halfSign)
        }
        let c = coef | 0x00800000
        let halfCoef = c >> UInt32(14 - halfExp)
        let roundBit = UInt32(1) << UInt32(13 - halfExp)
        if (c & roundBit) != 0 && (c & (3 * roundBit - 1)) != 0 {
            return UInt16(halfSign | halfCoef + 1)
        }
        return UInt16(halfSign | halfCoef)
    }
    
    let uHalfExp = UInt32(halfExp) << 10
    let halfCoef = coef >> 13
    let roundBit = UInt32(0x00001000)
    if (coef & roundBit) != 0 && (coef & (3 * roundBit - 1)) != 0 {
        return UInt16((halfSign | uHalfExp | halfCoef) + 1)
    }
    return UInt16(halfSign | uHalfExp | halfCoef)
    
}

import Foundation

/// Java and Kotlin number behaviour that the AAPS port has to reproduce exactly:
/// `Math.round`, `Double.toString` and `DecimalFormat` (HALF_EVEN on the exact binary value).
enum AAPSFormat {
    /// Java `Math.round(double)`: round half up (towards positive infinity). Java returns a
    /// `long`, so a negative zero comes back as plain zero, which shows in reason text.
    static func javaRound(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite { return x }
        let f = x.rounded(.down)
        return ((x - f) >= 0.5 ? f + 1 : f) + 0.0
    }

    /// AAPS DetermineBasalSMB `round(value, digits)`.
    static func round(_ value: Double, _ digits: Int) -> Double {
        if value.isNaN { return .nan }
        let scale = pow(10.0, Double(digits))
        return javaRound(value * scale) / scale
    }

    /// AAPS DetermineBasalSMB `round(value): Int` (`roundToInt`).
    static func roundInt(_ value: Double) -> Int {
        Int(javaRound(value))
    }

    /// Kotlin `Double.toString()`.
    static func kt(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }
        if x == 0 { return x.sign == .minus ? "-0.0" : "0.0" }
        let a = abs(x)
        if a >= 1E-3, a < 1E7 {
            var s = "\(x)"
            if !s.contains("."), !s.contains("e") { s += ".0" }
            return s
        }
        // Java scientific form, e.g. 1.0E-4 or 1.2345E7, from the shortest digits
        let s = String(describing: a) // Swift shortest round-trip, maybe "1e-05" or "12345678.0"
        var digits = ""
        var exponent = 0
        if let eIndex = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mantissa = String(s[s.startIndex ..< eIndex])
            exponent = Int(s[s.index(after: eIndex)...]) ?? 0
            let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = String(parts[0])
            let frac = parts.count > 1 ? String(parts[1]) : ""
            digits = intPart + frac
            exponent += intPart.count - 1
        } else {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = String(parts[0])
            let frac = parts.count > 1 ? String(parts[1]) : ""
            if intPart != "0" {
                digits = intPart + frac
                exponent = intPart.count - 1
            } else {
                let leadingZeros = frac.prefix { $0 == "0" }.count
                digits = String(frac.dropFirst(leadingZeros))
                exponent = -(leadingZeros + 1)
            }
        }
        while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
        while digits.hasPrefix("0"), digits.count > 1 { digits.removeFirst() }
        let first = digits.prefix(1)
        var rest = String(digits.dropFirst())
        if rest.isEmpty { rest = "0" }
        return (x < 0 ? "-" : "") + "\(first).\(rest)E\(exponent)"
    }

    /// Java `DecimalFormat` with HALF_EVEN rounding on the exact binary value of `x`.
    static func decimalFormat(_ x: Double, minFraction: Int, maxFraction: Int) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x > 0 ? "∞" : "-∞" }
        let negative = x.sign == .minus
        // exact decimal expansion of the double
        let exact = String(format: "%.1074f", abs(x))
        let parts = exact.split(separator: ".", omittingEmptySubsequences: false)
        var intDigits = Array(String(parts[0]))
        var fracDigits = Array(parts.count > 1 ? String(parts[1]) : "")
        let keep = fracDigits.prefix(maxFraction)
        let dropped = fracDigits.dropFirst(maxFraction)
        var kept = Array(keep)
        while kept.count < maxFraction { kept.append("0") }
        // decide rounding
        var roundUp = false
        if let firstDropped = dropped.first {
            if firstDropped > "5" {
                roundUp = true
            } else if firstDropped == "5" {
                let restNonZero = dropped.dropFirst().contains { $0 != "0" }
                if restNonZero {
                    roundUp = true
                } else {
                    let lastKept = kept.last ?? intDigits.last ?? "0"
                    roundUp = (Int(String(lastKept)) ?? 0) % 2 == 1
                }
            }
        }
        var all = intDigits + kept
        if roundUp {
            var i = all.count - 1
            var carry = true
            while carry, i >= 0 {
                if all[i] == "9" { all[i] = "0"
                    i -= 1 } else {
                    all[i] = Character(String((Int(String(all[i])) ?? 0) + 1))
                    carry = false
                }
            }
            if carry { all.insert("1", at: 0) }
        }
        intDigits = Array(all.prefix(all.count - maxFraction))
        fracDigits = Array(all.suffix(maxFraction))
        while fracDigits.count > minFraction, fracDigits.last == "0" { fracDigits.removeLast() }
        while intDigits.count > 1, intDigits.first == "0" { intDigits.removeFirst() }
        if intDigits.isEmpty { intDigits = ["0"] }
        var out = String(intDigits)
        if !fracDigits.isEmpty { out += "." + String(fracDigits) }
        return (negative ? "-" : "") + out
    }

    /// Kotlin `withoutZeros()`: DecimalFormat("0.##").
    static func withoutZeros(_ x: Double) -> String { decimalFormat(x, minFraction: 0, maxFraction: 2) }

    /// Kotlin `toFixed2()`: DecimalFormat("0.00#").format(round(this, 2)).
    static func toFixed2(_ x: Double) -> String { decimalFormat(round(x, 2), minFraction: 2, maxFraction: 3) }

    /// AAPS `convert_bg` for mg/dL: `to0Decimal` then `replace("-0.0", "0.0")`.
    static func convertBg(_ x: Double) -> String {
        decimalFormat(x, minFraction: 0, maxFraction: 0).replacingOccurrences(of: "-0.0", with: "0.0")
    }
}

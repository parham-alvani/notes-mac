import Foundation

/// naz, soft: a colour of naz with its strength capped, for the dark theme's
/// second palette (`appearance.dark_palette = "naz-soft"`, `docs/specs/look.md`
/// in notes-linux). The hue stays; the OKLCH chroma is at most 0.095 (0.14 for
/// the reds, which would turn to pink) and the lightness at most 0.90. The
/// neutrals are a table. `web/src/reader.css` has the same values, made by the
/// same rule: change one, change the other.
public enum SoftPalette {
    /// The neutrals of naz and what each becomes.
    static let neutrals: [UInt32: UInt32] = [
        0x323232: 0x2F2F2D, 0x3A3A35: 0x383835, 0x282826: 0x272725, 0xF5F5F0: 0xE2E2DD, 0x4A4A4A: 0x474744,
    ]
    /// The reds keep more of their strength.
    static let reds: Set<UInt32> = [0xFF5070, 0xFF7088]

    public static func soften(_ rgb: UInt32) -> UInt32 {
        if let neutral = neutrals[rgb] { return neutral }
        let (l, a, b) = oklab(rgb)
        let chroma = (a * a + b * b).squareRoot()
        let cap = reds.contains(rgb) ? 0.14 : 0.095
        let scale = chroma > cap ? cap / chroma : 1
        return srgb(l: min(l, 0.90), a: a * scale, b: b * scale)
    }

    static func oklab(_ rgb: UInt32) -> (Double, Double, Double) {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (linear(16), linear(8), linear(0))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    static func srgb(l: Double, a: Double, b: Double) -> UInt32 {
        let l3 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func byte(_ x: Double) -> UInt32 {
            let c = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(max(x, 0), 1 / 2.4) - 0.055
            return UInt32(max(0, min(255, (255 * c).rounded())))
        }
        let r = byte(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3)
        let g = byte(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3)
        let blue = byte(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
        return r << 16 | g << 8 | blue
    }
}

import Foundation

/// The car's 64 ambient-light colours (the mood-lamp settings' own picker). The car ignores
/// any other colour, so HMG-API sends the nearest of these; showing them lets the phone
/// offer exactly what the car can show. From HMG-API's hmgapi.vehicle.Commands (US EV6 260507).
public enum AmbientPalette {
    public static let colors: [UInt32] = [
        0x1043f4, 0x102ef2, 0x1020ef, 0x211cef, 0x2f1cef, 0x401cef, 0x521cef, 0x641cef,
        0x781cef, 0x881def, 0x9b21ef, 0xa923ef, 0xb723ea, 0xc121e0, 0xcc1fd2, 0xd51bc0,
        0xdd17ae, 0xe41399, 0xeb0e99, 0xef0a74, 0xf60660, 0xfa0451, 0xfe0145, 0xff321d,
        0xff4423, 0xff5027, 0xff6930, 0xff7835, 0xff8f3e, 0xffa646, 0xffc04f, 0xffd356,
        0xffe55c, 0xfff362, 0xfefd66, 0xffffff, 0xf4fd66, 0xe8fd66, 0xd9fd66, 0xcbfd63,
        0xb7f962, 0xa8f362, 0x95eb62, 0x84e562, 0x75df62, 0x68dd62, 0x5dde69, 0x51e176,
        0x47e785, 0x3eee98, 0x35f5a9, 0x2cfabd, 0x25facf, 0x1efae1, 0x19faed, 0x14faf9,
        0x10f4fc, 0x10e6fc, 0x10d2fc, 0x10bbfc, 0x10a3fc, 0x108afc, 0x106ffc, 0x1059f8,
    ]

    /// What the car will show for rgb: the closest palette colour (squared RGB distance, first wins).
    public static func nearest(_ rgb: UInt32) -> UInt32 {
        var best = colors[0]
        var bestD = Int.max
        for c in colors {
            let dr = Int(c >> 16 & 255) - Int(rgb >> 16 & 255)
            let dg = Int(c >> 8 & 255) - Int(rgb >> 8 & 255)
            let db = Int(c & 255) - Int(rgb & 255)
            let d = dr * dr + dg * dg + db * db
            if d < bestD { best = c; bestD = d }
        }
        return best
    }

    public static func hex(_ rgb: UInt32) -> String { String(format: "%06x", rgb & 0xffffff) }

    public static func parse(_ hex: String) -> UInt32? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return v
    }
}

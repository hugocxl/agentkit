import Foundation
import AgentCore
struct TerminalPalette {
    var background: UInt32
    var foreground: UInt32
    var colors: [UInt32]
    init(dark: Bool = true) {
        let ansi: [UInt32] = dark
            ? [0x36_3A_33, 0xEC_7B_79, 0x9A_BE_87, 0xE3_D1_70, 0xCD_A7_6B, 0xCA_9B_B4, 0x92_C2_C1, 0xD6_D8_CE,
               0x75_7A_6E, 0xFA_93_90, 0xAD_D1_99, 0xEE_E0_8D, 0xE0_BB_7D, 0xDB_AF_C7, 0xA5_D5_D5, 0xF5_F3_ED]
            : [0x25_26_20, 0xAD_35_3F, 0x49_6F_3B, 0xB7_63_00, 0x80_60_33, 0x8D_4A_6B, 0x35_74_7B, 0x55_56_4C,
               0x6E_6F_64, 0xC0_3F_49, 0x52_7E_42, 0xC4_72_12, 0x94_70_3A, 0xA0_55_7B, 0x3D_82_89, 0x16_17_12]
        background = dark ? 0x23_27_21 : 0xF5_F3_ED
        foreground = dark ? 0xCE_D0_C6 : 0x25_26_20
        colors = Self.defaultColors(ansi)
    }
    init(scheme: ColorScheme, dark: Bool) {
        self.init(dark: dark)
        if let color = scheme.background { background = color.value }
        if let color = scheme.foreground { foreground = color.value }
        for (index, color) in scheme.palette where (0..<256).contains(index) { colors[index] = color.value }
    }
    static func defaultColors(_ ansi: [UInt32]) -> [UInt32] {
        var colors = ansi
        for cube in 0..<216 {
            let level = { (value: Int) -> UInt32 in value == 0 ? 0 : UInt32(55 + 40 * value) }
            colors.append(level(cube / 36) << 16 | level(cube / 6 % 6) << 8 | level(cube % 6))
        }
        for step in 0..<24 {
            let level = UInt32(8 + 10 * step)
            colors.append(level << 16 | level << 8 | level)
        }
        return colors
    }
}

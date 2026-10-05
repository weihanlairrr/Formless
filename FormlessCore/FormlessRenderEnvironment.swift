import SwiftUI
import WidgetKit

// MARK: - 小工具的顯示環境（2026-10，規劃第 5.2、6.2、M6 節）
//
// 同一份設計會出現在主畫面（淺色、深色、透明、染色）與 StandBy。小工具上由系統決定是哪一種，
// 編輯器則用「預覽外觀」模擬。條件與「小工具環境」資料讀這裡，例如染色時換另一組圖層。

struct FormlessRenderEnvironment: Hashable, Sendable {
    /// 系統的三種畫法：全彩、透明或染色（全部變白、只留形狀）、StandBy 夜間（去色、依亮度呈現）。
    enum Mode: String, Hashable, Sendable {
        case fullColor, accented, vibrant
    }

    var dark = false
    var mode: Mode = .fullColor
    /// StandBy（背景被拿掉、放大顯示）。
    var standBy = false

    init(dark: Bool = false, mode: Mode = .fullColor, standBy: Bool = false) {
        self.dark = dark
        self.mode = mode
        self.standBy = standBy
    }

    init(colorScheme: ColorScheme, renderingMode: WidgetRenderingMode, showsBackground: Bool) {
        dark = colorScheme == .dark
        if renderingMode == .accented {
            mode = .accented
        } else if renderingMode == .vibrant {
            mode = .vibrant
        } else {
            mode = .fullColor
        }
        // 主畫面的背景只有 StandBy 會被拿掉（透明、染色是換成玻璃，屬於 accented）。
        standBy = !showsBackground && mode == .fullColor
    }
}

/// 編輯器畫布的預覽外觀。小工具本身不用這個，由系統給真實的模式。
enum FormlessPreviewAppearance: String, CaseIterable, Identifiable, Sendable {
    /// 跟著 App 目前的外觀（原本的樣子）。
    case automatic
    case light
    case dark
    /// iOS 26 主畫面「透明」：背景換成玻璃，內容全部變白。
    case clear
    /// 主畫面「染色」：背景換成染色的玻璃，內容全部變白。
    case tinted
    /// StandBy：橫放充電時，背景拿掉、放在黑底上。
    case standBy
    /// StandBy 夜間：低光源時整個變成紅色單色。
    case standByNight

    var id: String { rawValue }

    static let homeScreenCases: [FormlessPreviewAppearance] = [.automatic, .light, .dark, .clear, .tinted, .standBy, .standByNight]

    var displayName: String {
        switch self {
        case .automatic: return "跟著 App"
        case .light: return "淺色"
        case .dark: return "深色"
        case .clear: return "透明"
        case .tinted: return "染色"
        case .standBy: return "StandBy"
        case .standByNight: return "StandBy 夜間"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .clear: return "drop"
        case .tinted: return "paintbrush"
        case .standBy: return "platter.filled.bottom.iphone"
        case .standByNight: return "moon.stars"
        }
    }

    /// 這個外觀下畫布要用的深淺色；nil 是跟著 App。
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        // 透明與染色看起來都是深色的玻璃上放白色內容；StandBy 一律深色。
        case .dark, .clear, .tinted, .standBy, .standByNight: return .dark
        }
    }

    func environment(appScheme: ColorScheme) -> FormlessRenderEnvironment {
        switch self {
        case .automatic: return FormlessRenderEnvironment(dark: appScheme == .dark)
        case .light: return FormlessRenderEnvironment(dark: false)
        case .dark: return FormlessRenderEnvironment(dark: true)
        case .clear, .tinted: return FormlessRenderEnvironment(dark: true, mode: .accented)
        case .standBy: return FormlessRenderEnvironment(dark: true, standBy: true)
        case .standByNight: return FormlessRenderEnvironment(dark: true, mode: .vibrant, standBy: true)
        }
    }
}

/// 編輯器的預覽資料：實際資料、範例、全部沒有資料、很長的文字（檢查版面會不會被撐開或截斷）。
enum FormlessPreviewData: String, CaseIterable, Identifiable, Sendable {
    case actual, sample, empty, long

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .actual: return "實際資料"
        case .sample: return "範例資料"
        case .empty: return "沒有資料"
        case .long: return "很長的文字"
        }
    }

    var symbol: String {
        switch self {
        case .actual: return "checkmark.circle"
        case .sample: return "text.badge.star"
        case .empty: return "circle.dashed"
        case .long: return "text.append"
        }
    }
}

extension EnvironmentValues {
    /// 編輯器畫布的模擬外觀；nil 是不模擬（小工具、首頁縮圖）。
    @Entry var formlessPreviewAppearance: FormlessPreviewAppearance? = nil
}

// MARK: - 模擬系統的畫法（只在編輯器畫布用）

/// 透明、染色：內容依透明度變成白色（照片依亮度去色，選了保留原色的照片不變）。
/// StandBy 夜間：依亮度呈現（白色最清楚、黑色幾乎看不見），夜間是紅色。
struct FormlessRenderModeEmulation: ViewModifier {
    let environment: FormlessRenderEnvironment
    let emulates: Bool
    let isPhoto: Bool
    let keepsFullColor: Bool

    func body(content: Content) -> some View {
        if !emulates {
            content
        } else {
            switch environment.mode {
            case .fullColor:
                content
            case .accented:
                if isPhoto && keepsFullColor {
                    content
                } else if isPhoto {
                    luminance(content, color: .white)
                } else {
                    Color.white.mask(content)
                }
            case .vibrant:
                luminance(content, color: environment.standBy ? Self.nightRed : Color.white)
            }
        }
    }

    /// 依亮度呈現：亮的地方不透明、暗的地方透明，再乘上原本的透明度
    /// （`luminanceToAlpha` 不看原本的透明度，25% 的白會變成全白）。
    private func luminance(_ content: Content, color: Color) -> some View {
        color.mask(content.luminanceToAlpha()).mask(content)
    }

    /// StandBy 夜間的紅色。
    static let nightRed = Color(red: 1, green: 0.18, blue: 0.12)
}

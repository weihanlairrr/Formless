import SwiftUI
import UIKit

// MARK: - 輔助使用（2026-10，規劃第 7.3 節第 6 點、A0）
//
// 減少動態、減少透明度、增加對比、大字級、旁白共用的設定讀取與修飾器。數值在 `FormlessDesign`，
// 規則在「設計規範.md」第 8 節。畫面裡能讀 SwiftUI 環境值的地方（下面的修飾器）用環境值，設定一改畫面就跟著換；
// `FormlessDesign` 的靜態數值讀不到環境值，改讀這裡的系統設定。

/// 系統輔助使用設定的目前狀態。UIKit 規定這些設定在主執行緒讀；畫面都在主執行緒，
/// 萬一在背景讀到，回傳上一次在主執行緒讀到的值。
enum FormlessAccessibility {
    /// 設定 › 輔助使用 › 動態效果 › 減少動態。
    static var reduceMotion: Bool { current(&cache.reduceMotion) { UIAccessibility.isReduceMotionEnabled } }
    /// 設定 › 輔助使用 › 顯示與文字大小 › 減少透明度。
    static var reduceTransparency: Bool { current(&cache.reduceTransparency) { UIAccessibility.isReduceTransparencyEnabled } }
    /// 設定 › 輔助使用 › 顯示與文字大小 › 增加對比。
    static var increaseContrast: Bool { current(&cache.increaseContrast) { UIAccessibility.isDarkerSystemColorsEnabled } }

    private struct Cache {
        var reduceMotion = false
        var reduceTransparency = false
        var increaseContrast = false
    }
    nonisolated(unsafe) private static var cache = Cache()

    private static func current(_ cached: inout Bool, _ read: @MainActor () -> Bool) -> Bool {
        guard Thread.isMainThread else { return cached }
        cached = MainActor.assumeIsolated(read)
        return cached
    }
}

// MARK: - 減少動態

extension View {
    /// 從螢幕下方滑上來的工具面板（位置與大小、顏色、樣式、圖示、選擇資料、格式）：平常用面板彈簧滑進滑出；
    /// 減少動態時停在原位淡入淡出。藏起來的面板不給旁白讀。取代
    /// `.offset(y: shown ? 0 : height + 60)` 加 `.animation(BatchPositionPanel.animation, value: shown)`。
    func formlessPanelPresence(shown: Bool, height: CGFloat) -> some View {
        modifier(FormlessPanelPresence(shown: shown, height: height))
    }
}

private struct FormlessPanelPresence: ViewModifier {
    let shown: Bool
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion && !shown ? 0 : 1)
            .offset(y: shown || reduceMotion ? 0 : height + 60)
            .accessibilityHidden(!shown)
            .animation(reduceMotion ? FormlessDesign.Motion.fade : FormlessDesign.Motion.panel, value: shown)
    }
}

// MARK: - 減少透明度、增加對比

extension View {
    /// 玻璃：平常是系統玻璃（`glassEffect`）。減少透明度時在玻璃裡墊一層不透明的系統分組底色（`Palette.opaqueGlass`）
    /// 加細框線，看得出形狀；增加對比時加清楚的外框（`Palette.contrastBorder`）。按下的玻璃效果照常。
    func formlessGlass<S: InsettableShape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(FormlessGlass(glass: glass, shape: shape))
    }

    /// 自己畫的灰底、選擇格、半透明底在增加對比時加外框：沒選的是 `Palette.contrastBorder` 1 pt，
    /// 選中的是主色 `Stroke.selection`（選取除了底色還要有框線，不只靠顏色表示）。平常不加任何東西。
    func formlessContrastOutline<S: InsettableShape>(_ shape: S, selected: Bool = false) -> some View {
        modifier(FormlessContrastOutline(shape: shape, selected: selected))
    }
}

private struct FormlessGlass<S: InsettableShape>: ViewModifier {
    let glass: Glass
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency { shape.fill(FormlessDesign.Palette.opaqueGlass) }
            }
            .glassEffect(glass, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(FormlessDesign.Palette.contrastBorder, lineWidth: FormlessDesign.Stroke.contrast)
                        .allowsHitTesting(false)
                } else if reduceTransparency {
                    shape.strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct FormlessContrastOutline<S: InsettableShape>: ViewModifier {
    let shape: S
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased {
                shape.strokeBorder(selected ? FormlessDesign.Palette.accent : FormlessDesign.Palette.contrastBorder,
                                   lineWidth: selected ? FormlessDesign.Stroke.selection : FormlessDesign.Stroke.contrast)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 大字級

/// 數字框的寬度種類：一般數字（`Size.fieldShort` 72）、色碼與經緯度（`Size.fieldLong` 110）。
enum FormlessFieldWidth {
    case short, long
}

extension View {
    /// 灰底輸入框的大小，跟著字級放大：寬度（`width` 為 nil 時不限寬度）與最小高度（36；`compact` 是條列裡的 32）。
    /// 取代 `.frame(width: FormlessDesign.Size.fieldShort).frame(minHeight: FormlessDesign.Size.control)` 這類固定值；
    /// `extra` 是原本在寬度上多加的內距（例如 `fieldShort + 8`）。
    func formlessFieldFrame(_ width: FormlessFieldWidth?, extra: CGFloat = 0, compact: Bool = false) -> some View {
        modifier(FormlessFieldFrame(width: width, extra: extra, compact: compact))
    }

    /// 固定大小的介面（面板標題列、工具面板裡固定高度的控制）字級最多到 `TextSize.compactLimit`。
    func formlessCompactText() -> some View {
        dynamicTypeSize(...FormlessDesign.TextSize.compactLimit)
    }
}

private struct FormlessFieldFrame: ViewModifier {
    let width: FormlessFieldWidth?
    let extra: CGFloat
    let compact: Bool
    @Environment(\.dynamicTypeSize) private var size

    func body(content: Content) -> some View {
        let fieldWidth: CGFloat? = switch width {
        case .short?: FormlessDesign.Size.fieldShort(for: size) + extra
        case .long?: FormlessDesign.Size.fieldLong(for: size) + extra
        case nil: nil
        }
        content
            .frame(width: fieldWidth)
            .frame(minHeight: compact ? FormlessDesign.Size.compactControl(for: size) : FormlessDesign.Size.control(for: size))
    }
}

/// 「名稱左、控制右」的一般列（設計規範：新的數字設定是一般列）。平常和原本的列一樣：名稱一行、中間留白、控制靠右；
/// 輔助字級（`TextSize.stackedRows` 以上）改成名稱在上、控制在下，名稱可以換行，名稱與數字都不會被截斷。
/// 兩種排法用同一組元件（`AnyLayout`），切換時控制的狀態（例如正在輸入）不會不見。
struct FormlessAdaptiveRow<Title: View, Control: View>: View {
    /// 左右排時各元件之間的距離（`EditorStepperRow` 原本是 10）。
    var spacing: CGFloat = 10
    /// 左右排時名稱與控制之間最少再留的距離。
    var minGap: CGFloat = FormlessDesign.Space.tight
    @ViewBuilder let title: () -> Title
    @ViewBuilder let control: () -> Control
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let stacked = size >= FormlessDesign.TextSize.stackedRows
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: FormlessDesign.Space.tight))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout {
            title().lineLimit(stacked ? nil : 1)
            if !stacked { Spacer(minLength: minGap) }
            control()
        }
        // 上下兩行時和其他多行的列一樣，上下各加 `Space.rowExtra`。
        .padding(.vertical, stacked ? FormlessDesign.Space.rowExtra : 0)
    }
}

// MARK: - 旁白

extension View {
    /// 工具面板開著時：旁白只讀面板裡的東西（和點面板外會關閉一致），兩指 Z 字手勢（escape）關閉面板。
    /// 藏起來、預先建好的面板（`active` 是 false）不攔旁白。
    func formlessModalPanel(active: Bool, onClose: @escaping () -> Void) -> some View {
        accessibilityAddTraits(active ? .isModal : [])
            .accessibilityAction(.escape) { if active { onClose() } }
    }
}

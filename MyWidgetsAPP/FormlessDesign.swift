import SwiftUI
import UIKit

/// Formless 的視覺規範（2026-09-28 使用者核准）。顏色、圓角、間距、尺寸、框線、動畫都從這裡取，
/// 各畫面不再各自寫數字；要改規範只改這裡。完整說明見專案根目錄的「設計規範.md」。
/// 2026-10 加上輔助使用：減少動態、增加對比時，下面標明的數值會自己換（讀 `FormlessAccessibility`），呼叫端不用改。
enum FormlessDesign {
    // MARK: 顏色

    enum Palette {
        /// 主色：系統藍（App 本體沒有自訂主色，`Color.accentColor` 就是系統藍）。
        static var accent: Color { .accentColor }
        static let accentUI: UIColor = .systemBlue
        /// 頁面、面板、彈出面板的底色（淺灰）。
        static let page = Color(uiColor: .systemGroupedBackground)
        /// 卡片（白卡）。
        static let card = Color(uiColor: .secondarySystemGroupedBackground)
        /// 群組列。
        static let groupCard = Color(uiColor: .tertiarySystemGroupedBackground)
        /// 選取狀態的底：主色 12%。
        static var selectionFill: Color { .accentColor.opacity(0.12) }
        /// 主色小圓鈕的底：主色 15%。
        static var tintFill: Color { .accentColor.opacity(0.15) }
        /// 灰底（輸入框、灰按鈕、選擇格）：主要文字色的第四層。直接寫 `.quaternary` 在有主色的按鈕裡會變成淡藍，
        /// 放在按鈕裡的灰底要用這個。
        static var fill: some ShapeStyle { Color.primary.quaternary }
        /// 細框線：主要文字色 10%（深色模式自動反轉）；增加對比時 30%。跟著畫面的外觀與對比設定自己換。
        static let hairline = Color(uiColor: UIColor { traits in
            UIColor.label.resolvedColor(with: traits)
                .withAlphaComponent(traits.accessibilityContrast == .high ? 0.3 : 0.1)
        })
        /// 畫布上文字可用寬度的虛線：主色 30%，比多選各自的虛線（45%）與量不到內容時的圖層框（實色）淡很多。
        static var guide: Color { .accentColor.opacity(0.3) }
        /// 減少透明度時，玻璃與半透明底改用的不透明底：系統分組底色（同 `page`）。
        static let opaqueGlass = page
        /// 增加對比時加在灰底、玻璃、工具面板邊緣的外框：主要文字色 30%（線寬 `Stroke.contrast`）。
        static let contrastBorder = Color.primary.opacity(0.3)
    }

    // MARK: 圓角（全部用連續圓角）

    enum Radius {
        /// 小控制項（高 36 以下）：輸入框、灰按鈕、選擇鈕、色票、色條、圖示格。
        static let control: CGFloat = 8
        /// 中型元素：圖層列卡片、縮圖、圖片格、外觀磚、色盤。
        static let medium: CGFloat = 14
        /// 卡片：和系統表單卡片相同（實測 26）。
        static let card: CGFloat = 26
        /// 下方面板上緣：和系統彈出面板相同（實測約 34）。
        static let panel: CGFloat = 34
        /// iPhone 桌面小工具本身的圓角（實際尺寸下 22）；縮圖、尺寸預覽照縮放比例縮小，看起來才和真的小工具一樣。
        static let widget: CGFloat = 22
    }

    // MARK: 間距（4 的倍數；系統實測值例外）

    enum Space {
        /// 全 App 唯一的左右邊線：內容離螢幕邊 20（系統表單在這支手機上的邊距，也是導覽列按鈕的位置）。
        static let edge: CGFloat = 20
        /// 卡片內文字起點：卡片邊往內 20（和系統表單列相同）。
        static let cardInset: CGFloat = 20
        /// 下方面板裡卡片到面板四邊的距離。
        static let panel: CGFloat = 20
        /// 並排的小按鈕之間。
        static let tight: CGFloat = 8
        /// 並排的大元件（磚、圓鈕盤、格子）之間。
        static let loose: CGFloat = 12
        /// 列裡有多行內容時上下各加的距離：文字到分隔線剛好 18（和系統列相同）。
        static let rowExtra: CGFloat = 4
        /// 名稱與值之間最少留的距離。
        static let valueGap: CGFloat = 12
        /// 底部浮動列離螢幕底（不含安全區）。
        static let floatingBottom: CGFloat = 5
        /// 輸入框底部到鍵盤頂端。
        static let keyboardGap: CGFloat = 36
        /// 設定各頁第一張卡片上方。
        static let pageTop: CGFloat = 16
    }

    // MARK: 尺寸

    enum Size {
        /// 下方面板與半版面板的標題列。
        static let titleBar: CGFloat = 66
        /// 灰底輸入框、灰底按鈕的高度。
        static let control: CGFloat = 36
        /// 條列（漸層條、條件顏色）裡的晶片與小圓鈕。
        static let compactControl: CGFloat = 32
        /// 玻璃圓鈕。
        static let glassButton: CGFloat = 44
        /// 底部浮動列（分類列、「＋」「…」）。
        static let floatingBar: CGFloat = 48
        /// 輸入框寬度：一般數字、色碼與經緯度。
        static let fieldShort: CGFloat = 72
        static let fieldLong: CGFloat = 110
        /// 數字框依字級加寬時的上限：最窄的 iPhone（375）扣掉邊線與卡片內距還放得下。
        static let fieldMax: CGFloat = 280
        /// 下方面板佔螢幕高度的比例（使用者 2026-09-28 由 55% 改為 60%）。
        static let panelRatio: CGFloat = 0.6

        // MARK: 依字級放大（2026-10 輔助使用）

        /// 灰底輸入框、灰底按鈕的最小高度：預設字級（大）以下是 36，字更大時加上 body 多出來的行高。
        static func control(for size: DynamicTypeSize) -> CGFloat { grown(control, for: size) }
        /// 條列晶片與小圓鈕的最小高度：預設字級以下是 32，字更大時加上 subheadline 多出來的行高。
        static func compactControl(for size: DynamicTypeSize) -> CGFloat { grown(compactControl, for: size, relativeTo: .subheadline) }
        /// 數字框寬度：字更大時照 body 的比例加寬，數字不會被截斷；最多 `fieldMax`（輔助字級的列已改成上下兩行）。
        static func fieldShort(for size: DynamicTypeSize) -> CGFloat { min(fieldMax, scaled(fieldShort, for: size)) }
        static func fieldLong(for size: DynamicTypeSize) -> CGFloat { min(fieldMax, scaled(fieldLong, for: size)) }

        /// 依字級等比例放大：預設字級（大）以下維持原值，字更大時跟著 `style` 的字級放大。用在欄寬、列首圖示的大小與欄寬。
        static func scaled(_ value: CGFloat, for size: DynamicTypeSize, relativeTo style: UIFont.TextStyle = .body) -> CGFloat {
            guard size > .large else { return value }
            return UIFontMetrics(forTextStyle: style).scaledValue(for: value, compatibleWith: traits(size)).rounded()
        }

        /// 依字級加高：預設字級（大）以下維持原值，字更大時加上這個字級的行高比預設多出來的部分（字上下的留白不變）。
        /// 用在控制項的最小高度。
        static func grown(_ value: CGFloat, for size: DynamicTypeSize, relativeTo style: UIFont.TextStyle = .body) -> CGFloat {
            guard size > .large else { return value }
            let now = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits(size)).lineHeight
            let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits(.large)).lineHeight
            return value + max(0, now - base).rounded(.up)
        }

        private static func traits(_ size: DynamicTypeSize) -> UITraitCollection {
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        }
    }

    // MARK: 字級（2026-10 輔助使用）

    enum TextSize {
        /// 「名稱左、控制右」的列從這個字級起改成名稱在上、控制在下（輔助字級的第一級）。
        static let stackedRows: DynamicTypeSize = .accessibility1
        /// 固定大小的介面字級上限：面板標題列、工具面板裡固定高度的控制（條件與色階列、外觀方塊、整個顏色面板）。
        /// 和系統導覽列、控制中心一樣不再放大，面板仍放得下、不用左右捲。
        static let compactLimit: DynamicTypeSize = .xxxLarge
    }

    // MARK: 框線

    enum Stroke {
        /// 選取框：主色 2 pt，畫在內側；增加對比時 3 pt。
        static var selection: CGFloat { FormlessAccessibility.increaseContrast ? 3 : 2 }
        /// 細框線 0.5 pt；增加對比時 1 pt。
        static var hairline: CGFloat { FormlessAccessibility.increaseContrast ? 1 : 0.5 }
        /// 增加對比時加的外框（`Palette.contrastBorder`）。
        static let contrast: CGFloat = 1
        /// 畫布上文字可用寬度的虛線：0.8 pt、2 pt 線 2 pt 空（其他虛線是 1～1.2 pt、4 線 3 空）。
        static let guide: CGFloat = 0.8
        static let guideDash: [CGFloat] = [2, 2]
    }

    // MARK: 圖示

    enum Symbol {
        /// 玻璃圓鈕（44）裡的圖示。
        static let glassButton = Font.system(size: 18, weight: .medium)
        /// 主色小圓鈕（32）裡的圖示。
        static let smallCircle = Font.system(size: 14, weight: .semibold)
        /// 36 圓鈕裡的圖示。
        static let circle = Font.system(size: 16, weight: .semibold)
    }

    // MARK: 按下

    enum Press {
        /// 沒有底的圖示鈕：按下時的透明度。
        static let glyphOpacity: Double = 0.35
        /// 有底的鈕（玻璃圓鈕、方塊、磚）：縮小比例與疊上的黑色濃度。減少動態時不縮小，只疊色。
        static var scale: CGFloat { FormlessAccessibility.reduceMotion ? 1 : 0.96 }
        static let overlay: Double = 0.08
    }

    // MARK: 動畫

    /// 減少動態時（`FormlessAccessibility.reduceMotion`），推移、面板、玻璃形變都換成 0.2 秒的減速淡入淡出，
    /// 沒有回彈；會移動的轉場用 `transition(_:)` 換成淡入淡出。跟手的拖曳與跟手放開不變。
    enum Motion {
        /// 推移：鍵盤、畫布讓位、選取工具列、展開、屬性面板進出、自動捲動。
        static var pushDuration: Double { FormlessAccessibility.reduceMotion ? fadeDuration : 0.25 }
        static var push: Animation { .easeOut(duration: pushDuration) }
        /// 跟手放開（UIKit 彈簧、帶手指速度）：屬性面板右滑返回的完成與取消。減少動態時不變（手指直接帶動的）。
        static let followDuration: Double = 0.25
        /// 面板：下方面板、半版面板、畫布縮放、畫布高度彈回。
        static var panelDuration: Double { FormlessAccessibility.reduceMotion ? fadeDuration : 0.4 }
        static var panel: Animation {
            FormlessAccessibility.reduceMotion ? fade : .spring(duration: panelDuration, bounce: 0)
        }
        /// 玻璃形變：刪除確認膠囊。
        static var morph: Animation {
            FormlessAccessibility.reduceMotion ? fade : .bouncy(duration: 0.4, extraBounce: 0.05)
        }
        /// 玻璃形變裡的內容：先淡出 0.08 秒，形變到位前淡入 0.2 秒（延遲 0.07）；內容跟著縮放 0.85，減少動態時不縮放。
        static let morphContentOut: Animation = .easeOut(duration: 0.08)
        static let morphContentIn: Animation = .easeOut(duration: 0.2).delay(0.07)
        static var morphContentScale: CGFloat { FormlessAccessibility.reduceMotion ? 1 : 0.85 }
        /// 淡入淡出。
        static let fadeDuration: Double = 0.2
        static let fade: Animation = .easeOut(duration: fadeDuration)
        /// 按下。
        static let press: Animation = .easeOut(duration: 0.1)
        /// 分頁列、分類列捲動時的縮放（Core Animation 彈簧）：0.28 秒、小彈跳；減少動態時不彈跳。
        static let barScaleDuration: Double = 0.28
        static var barScaleBounce: Double { FormlessAccessibility.reduceMotion ? 0 : 0.12 }
        /// 會移動的轉場（滑入、放大），減少動態時換成淡入淡出：`.transition(FormlessDesign.Motion.transition(.move(edge: .trailing)))`。
        static func transition(_ moving: AnyTransition) -> AnyTransition {
            FormlessAccessibility.reduceMotion ? .opacity : moving
        }
        /// 等某段動畫結束才做的事：動畫時間再多 0.05 秒。
        static func after(_ duration: Double) -> Double { duration + 0.05 }
    }
}

extension View {
    /// 灰底框：輸入框、灰底按鈕、選單按鈕共用的底（圓角 8）。增加對比時加外框，灰底在白卡上才看得出範圍。
    func formlessGrayBox() -> some View {
        modifier(FormlessGrayBox())
    }

    /// 設定類頁面的標題列：置中小標題與標準返回鍵（10/03 決定：iOS 26 的返回鍵是小玻璃圓鈕，不佔版面；
    /// 看得到出口是內建 App 的基本規矩）。從左邊滑回上一頁照樣可用（`FormlessPopGestureEnabler`）。
    func formlessPageTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(FormlessPopGestureEnabler(isEnabled: true))
    }
}

/// 灰底框的實作：增加對比時多一圈 `Palette.contrastBorder`（不接觸控，不影響排版）。
private struct FormlessGrayBox: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        content
            .background(FormlessDesign.Palette.fill, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(FormlessDesign.Palette.contrastBorder, lineWidth: FormlessDesign.Stroke.contrast)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// 列尾的「>」：這一列點了會開另一個面板或頁面（和系統的換頁列、插入資料面板的列同一個樣子）。
/// 只顯示值、沒有「>」的列看起來就是資訊，使用者不會想到可以點（使用者 10/04：「圖片 17」找很久才知道能換圖）。
struct FormlessDisclosureIndicator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

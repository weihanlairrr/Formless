import SwiftUI
import Combine
import WidgetKit
import UIKit
import PhotosUI
import EventKit


// MARK: - 觸覺回饋

@MainActor
enum FormlessHaptics {

    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func rigid() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.impactOccurred()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
}


// MARK: - 共用資料夾異常

struct StorageUnavailableView: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("暫時無法讀取設計")
                .font(.headline)
            Text("請重新開啟應用程式後再試。若問題持續，請更新版本或聯絡支援；請勿先移除，以免遺失設計。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}


// MARK: - 使用說明

/// 使用說明：設定頁換頁進來（和其他設定項目一樣，左滑返回）。
struct HelpView: View {

    var body: some View {
            List {
                // 卡片不放標題（使用者規則：全 App 的卡片上方都不放標題），內容本身就說明了是什麼。
                Section {
                    Text("點選清單或畫布上的圖層即可編輯。位置、外觀與內容分開調整；整體設定可由畫布右上角的設定按鈕開啟。")
                    Text("向下拖曳畫布可放大檢視，向上拖曳可收回。修改會自動儲存；復原與重做位於畫布上方。長按圖層可多選，從圖層右側向左滑可刪除。")
                    Text("從螢幕左緣向右滑可返回設計清單。")
                }
                Section {
                    HelpStep(number: 1, text: "建立或匯入一個設計。")
                    HelpStep(number: 2, text: "回桌面長按空白處。")
                    HelpStep(number: 3, text: "點「編輯」→「加入小工具」，搜尋 Formless。")
                    HelpStep(number: 4, text: "選相同尺寸加到桌面。")
                    HelpStep(number: 5, text: "長按該小工具 → 編輯小工具 → 選設計。")
                }
                Section {
                    Text("行程、提醒事項、步數及目前位置需要對應權限。可在「設定」→「資料來源」裡各自的頁面查看與管理。")
                    Text("下拉清單可更新資料。桌面小工具的實際更新時間由系統安排，可能與預覽不同。")
                }
            }
            // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
            .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
            .formlessPageTitle("使用說明")
    }
}


struct HelpStep: View {

    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor)
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, FormlessDesign.Space.rowExtra)
    }
}

// MARK: - 圖層剪貼簿

/// 圖層以 JSON 放進系統剪貼簿，同一支 App 的任何設計都能貼上。
/// 來源設計的尺寸一起記錄：跨尺寸貼上時依參考高度換算字級與圓角，比例座標維持不變。
enum FormlessLayerClipboard {

    private static let pasteboardType = "com.weihan.formless.layers"

    private struct Payload: Codable {
        var family: FormlessWidgetFamily
        var layers: [FormlessLayer]
    }

    /// 不在畫面繪製時詢問系統剪貼簿：那是跨行程呼叫，
    /// 開了「通用剪貼簿」時還會等 Mac 回應，足以卡住主執行緒。
    nonisolated(unsafe) private static var wroteInThisSession = false

    static var hasLayers: Bool { wroteInThisSession }

    static func write(_ layers: [FormlessLayer], family: FormlessWidgetFamily) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(Payload(family: family, layers: layers)) else { return }

        UIPasteboard.general.setItems(
            [[pasteboardType: data]],
            options: [.localOnly: true]
        )

        wroteInThisSession = true
    }

    static func read(for family: FormlessWidgetFamily) -> [FormlessLayer]? {
        guard let data = UIPasteboard.general.data(forPasteboardType: pasteboardType),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }

        // 更新前複製的沒拆解年度進度元件，貼上時一樣換成一般圖層。
        let layers = FormlessTemplate.expandLegacyLayers(payload.layers, family: payload.family)

        guard payload.family != family else { return layers }

        // 跨尺寸：點數欄位依參考高度換算，畫面上大小才會一致
        let ratio = Double(family.referenceHeight / payload.family.referenceHeight)

        return layers.map { layer in
            var copy = layer
            copy.fontSize = layer.fontSize.map { $0 * ratio }
            copy.cornerRadius = layer.cornerRadius.map { $0 * ratio }
            copy.strokeWidth = layer.strokeWidth.map { $0 * ratio }
            copy.shadowRadius = layer.shadowRadius.map { $0 * ratio }
            copy.shadowOffsetY = layer.shadowOffsetY.map { $0 * ratio }
            return copy
        }
    }
}


// MARK: - 1600 座標輸入

/// 與 Widgy 相同的座標：畫布 1600 × 1600，左上角 0, 0。兩側按鈕依目前步進增減。
/// 自己處理觸控的 UIKit 控制項（方向鍵、上一步／下一步）繼承這個類別：鍵盤收著時，
/// 「點外面收鍵盤」的視窗手勢完全不參與落在它上面的觸控，按下立刻有反應。
/// 鍵盤開著時不例外：這一下只收鍵盤，控制項收不到觸控，不會誤觸。
class FormlessKeyboardPassThroughView: UIView {}

/// 輸入框的延伸範圍（例如位置與大小那顆圓，點上半／下半就編輯對應的數字）：和輸入框本身一樣，
/// 鍵盤開著時點這裡不收鍵盤，只切換正在編輯的欄位。
final class FormlessInputAreaView: UIView {}

/// 鍵盤開著時，畫面裡的控制項照樣點得到的畫面（例如新增行程面板：點日期、時間就直接打開，同時收起鍵盤）。
/// 其他畫面維持原本的規則：鍵盤開著時點輸入框以外的地方只收鍵盤、不觸發任何東西。
/// 收鍵盤由畫面自己負責（觸控放開後再收，按下的控制項不會因為畫面跟著移動而點空）。
@MainActor protocol FormlessKeyboardTapThrough: UIViewController {}

extension UIView {
    /// 這個畫面元素是否在 `FormlessKeyboardTapThrough` 的畫面裡。沿回應鏈往上找（會經過各層畫面控制器）：
    /// 只沿 superview 找不到，SwiftUI 包出來的根畫面不直接接在那個控制器上（實測）。
    @MainActor var formlessInKeyboardTapThrough: Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if current is FormlessKeyboardTapThrough { return true }
            responder = current.next
        }
        return false
    }
}

/// 靠右對齊的單行輸入框（左名稱、右輸入的列）：點文字左邊的空白處開始輸入時，系統把游標放在最前面，
/// 要改字得再點一次（使用者回報）。開始輸入時游標一律移到最後；已經在輸入時再點，照常移到點的位置。
/// 有選取範圍的（例如剛新增圖層的全選）不動。
@MainActor enum FormlessTrailingCaret {
    private static var token: NSObjectProtocol?

    static func start() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification,
                                                       object: nil, queue: .main) { note in
            let field = note.object as? UITextField
            MainActor.assumeIsolated {
                guard let field, field.textAlignment == .right else { return }
                // 開始編輯的這一輪系統還會放游標，下一輪再移。
                DispatchQueue.main.async {
                    guard let range = field.selectedTextRange, range.isEmpty,
                          field.compare(range.start, to: field.endOfDocument) != .orderedSame else { return }
                    field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
                }
            }
        }
    }
}

/// 把一塊 SwiftUI 範圍標成輸入框的延伸範圍，放在該範圍的 background。
struct FormlessInputArea: UIViewRepresentable {
    func makeUIView(context: Context) -> FormlessInputAreaView {
        let view = FormlessInputAreaView()
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: FormlessInputAreaView, context: Context) {}
}

/// 鍵盤開著時蓋在 App 視窗上方（鍵盤下方）的透明擋板視窗：點到輸入框（或標成輸入框延伸範圍的地方）就讓觸控落到
/// 底下的 App 視窗交給它；其他任何地方的觸控都由擋板接住、放開時收起鍵盤，底下的按鈕不會執行，也不會出現按下的
/// 高亮或玻璃按壓動畫。必須是獨立的視窗：系統「可互動玻璃」的按壓偵測掛在整個 App 視窗上，
/// 擋板若只是 App 視窗裡的一個子視圖，觸控仍會被它看到，按鈕照樣放大變灰。鍵盤在更上層的系統視窗，不受影響。
@MainActor
final class FormlessKeyboardShield: NSObject {
    static let shared = FormlessKeyboardShield()
    private var started = false
    private var tokens: [NSObjectProtocol] = []
    private var shieldWindow: FormlessTapShieldWindow?

    static func start() {
        let shield = shared
        guard !shield.started else { return }
        shield.started = true
        FormlessTrailingCaret.start()
        let center = NotificationCenter.default
        shield.tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shield.show() }
        })
        shield.tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shield.shieldWindow?.isHidden = true }
        })
    }

    private func show() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let appWindow = windows.first(where: { !($0 is FormlessTapShieldWindow) && Self.containsFirstResponder($0) }),
              let scene = appWindow.windowScene else { return }
        let window = shieldWindow ?? FormlessTapShieldWindow(windowScene: scene)
        shieldWindow = window
        window.appWindow = appWindow
        window.passesThrough = { view in
            // 上一步／下一步不被鍵盤擋：按下去照常執行（它自己會先收鍵盤）。
            if view is FormlessPanelShieldPassThrough { return true }
            if view?.formlessInKeyboardTapThrough == true { return true }
            var current = view
            while let node = current {
                if node is UITextField || node is UITextView || node is FormlessInputAreaView { return true }
                current = node.superview
            }
            return false
        }
        window.onTap = {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // 自我修復：鍵盤收起的通知沒收到時（欄位被移除、系統沒發通知），擋板會一直蓋著、吞掉所有點擊，
        // 看起來像面板關不掉（使用者回報，未能重現）。畫面上已經沒有正在輸入的欄位，就收起擋板、放行這一下。
        window.passesThroughPoint = { [weak window] _ in
            guard let app = window?.appWindow, Self.containsFirstResponder(app) else {
                window?.isHidden = true
                return true
            }
            return false
        }
        window.show(over: appWindow)
    }

    private static func containsFirstResponder(_ view: UIView) -> Bool {
        if view.isFirstResponder { return true }
        return view.subviews.contains { containsFirstResponder($0) }
    }

}

/// 蓋在 App 視窗上方的透明擋板視窗：`passesThrough` 認可的觸控落到底下的 App 視窗照常處理，其他觸控由擋板接住，
/// 放開時呼叫 `onTap`，底下的東西完全收不到（不執行、也不出現按下的高亮或玻璃按壓動畫）。
/// 必須是獨立的視窗：系統「可互動玻璃」的按壓偵測掛在整個 App 視窗上，同一個視窗裡的子視圖擋不住。
/// 鍵盤開著時點外面收鍵盤用它。
@MainActor
final class FormlessTapShieldWindow: UIWindow {
    weak var appWindow: UIWindow?
    var passesThrough: (UIView?) -> Bool = { _ in false }
    var onTap: () -> Void = {}
    private let catcher = Catcher()

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        catcher.frame = bounds
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.onTap = { [weak self] in self?.onTap() }
        addSubview(catcher)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 蓋在 App 視窗正上方（鍵盤在更上層）；只顯示、不成為主視窗，正在輸入的欄位不會失去焦點。
    /// `levelOffset` 決定和其他擋板的上下：鍵盤擋板（1）要在工具面板擋板（0.5）上面，鍵盤開著時點面板外先收鍵盤。
    func show(over appWindow: UIWindow, levelOffset: CGFloat = 1) {
        self.appWindow = appWindow
        frame = appWindow.frame
        windowLevel = UIWindow.Level(appWindow.windowLevel.rawValue + levelOffset)
        isHidden = false
    }

    /// 以位置判斷放行（App 視窗座標）：SwiftUI 的內容不是一個個 UIView，無法用 isDescendant 判斷是否在面板裡。
    var passesThroughPoint: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let appWindow else { return nil }
        // 系統畫在其他視窗裡的東西一律放行：文字的「貼上／拷貝」選單在 UITextEffectsWindow，層級和擋板相同，
        // 擋板後建立而蓋在它上面，點「貼上」只會收起鍵盤、貼不上（實測）。那個視窗在選單以外的地方點不到東西，
        // 其他地方照常由擋板接住。
        if let scene = windowScene {
            for window in scene.windows where window !== self && window !== appWindow
                && !(window is FormlessTapShieldWindow) && !window.isHidden
                && window.hitTest(convert(point, to: window), with: event) != nil {
                return nil
            }
        }
        // 系統選單（Menu、長按選單）開著時一律放行：它畫在 App 視窗裡（_UIContextMenuContainerView），點外面收選單
        // 靠的是它自己的手勢；擋板接走那一下的話選單收不到、留在畫面上，面板卻已經關了（使用者回報）。
        // 放行後那一下只關選單、面板不動，再點一次才關面板（和系統 sheet 上的選單一樣）。
        if contextMenuIsOpen { return nil }
        let appPoint = convert(point, to: appWindow)
        if passesThroughPoint?(appPoint) == true { return nil }
        let underneath = appWindow.hitTest(appPoint, with: event)
        return passesThrough(underneath) ? nil : catcher
    }

    /// 只看系統有沒有正在呈現選單（_UIContextMenuActionsOnlyViewController）或 App 自己的彈出清單；
    /// 選單的容器視圖關掉後還會留在視窗裡，不能拿它判斷（曾因此每一下都被放行，面板要點很多下才關得掉）。
    private var contextMenuIsOpen: Bool {
        guard let appWindow else { return false }
        var controller = appWindow.rootViewController
        while let presented = controller?.presentedViewController {
            if presented.isBeingDismissed { return false }
            if String(describing: type(of: presented)).contains("ContextMenu") { return true }
            controller = presented
        }
        return false
    }

    final class Catcher: UIView {
        var onTap: () -> Void = {}
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onTap() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onTap() }
    }
}

/// 不暗化背景的工具面板（面板開放背景互動，底下的畫布照常清楚可見）點面板外關閉：面板在畫面上時，
/// 在 App 視窗上方蓋一層透明擋板視窗，落在面板底下編輯器畫面的觸控由擋板接住、放開時關閉面板，
/// 底下的按鈕不執行，也不出現按下的效果；面板與從面板彈出的選單照常操作。放在面板內容的 background。
struct FormlessSheetOutsideTap: UIViewRepresentable {
    var onTap: () -> Void

    final class Anchor: UIView {
        var onTap: () -> Void = {}
        private var shield: FormlessTapShieldWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { install() } else { remove() }
        }

        private func install() {
            guard shield == nil, let window, let scene = window.windowScene else { return }
            let shield = FormlessTapShieldWindow(windowScene: scene)
            // 只攔面板底下的編輯器畫面；面板本身、從面板彈出的選單（系統畫在面板上方另一層，不屬於面板）
            // 以及其他彈出內容一律放行，選單才能捲動與點選，選單開著時點外面也只關選單。
            shield.passesThrough = { [weak self] view in
                guard let view, let background = self?.backgroundView else { return true }
                if view is FormlessPanelShieldPassThrough { return true }
                return !view.isDescendant(of: background)
            }
            shield.onTap = { [weak self, weak shield] in
                guard let self else { shield?.isHidden = true; return }
                self.remove()
                self.onTap()
            }
            shield.show(over: window, levelOffset: 0.5)
            self.shield = shield
        }

        func remove() {
            shield?.isHidden = true
            shield = nil
        }

        /// 面板底下的畫面：沿著回應鏈找到面板的視圖控制器，取呈現它的那一層的畫面。
        private var backgroundView: UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let presenting = controller.presentingViewController {
                    return presenting.view
                }
                responder = current.next
            }
            return nil
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.onTap = onTap
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { view.onTap = onTap }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.remove() }
}

/// 畫在編輯器畫面裡的工具面板（不是系統 sheet）點面板外關閉：放在面板的 background，量面板在視窗中的範圍；
/// 面板在畫面上時蓋一層透明擋板視窗，落在面板範圍裡的觸控照常交給面板；從面板彈出的選單不屬於 App 的主畫面
/// （系統畫在另一層），一律放行；其他地方的觸控由擋板接住、放開時關閉面板，底下的按鈕不執行也不出現按下效果。
/// 任何面板或鍵盤開著時都照樣點得到的控制項（上方的上一步／下一步，使用者：所有面板都不要封鎖上一步後一步）：
/// 點它不算「點面板外」，面板不會關；鍵盤開著時也直接執行（按鈕自己會先收鍵盤）。
@MainActor protocol FormlessPanelShieldPassThrough: UIView {}

struct FormlessPanelOutsideTap: UIViewRepresentable {
    /// 面板預先建好、藏在螢幕外時為 false：擋板不出現，點畫面不會被攔。
    var active: Bool = true
    var onTap: () -> Void

    final class Anchor: UIView {
        var onTap: () -> Void = {}
        var active = true { didSet { if active != oldValue { update() } } }
        /// 擋板視窗建一次重複使用，打開面板時只切換顯示，不在動畫開始那一格建視窗。
        private var shield: FormlessTapShieldWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            update()
        }

        private func update() {
            guard active, let window, let scene = window.windowScene else { remove(); return }
            let shield = self.shield ?? FormlessTapShieldWindow(windowScene: scene)
            if self.shield == nil {
                // 面板已經不在（這個標記視圖被釋放或離開視窗）時，擋板自己收起並放行所有點擊，
                // 不會變成一層吞掉整個畫面點擊、看起來「面板關不掉」的透明牆。
                shield.passesThroughPoint = { [weak self, weak shield] point in
                    guard let self, let window = self.window else { shield?.isHidden = true; return true }
                    return self.convert(self.bounds, to: window).contains(point)
                }
                shield.passesThrough = { view in
                    guard let view, let root = view.window?.rootViewController?.view else { return true }
                    // 上方的上一步／下一步照常可按，面板不關（使用者：調整位置時按上一步，面板被關掉了）。
                    if view is FormlessPanelShieldPassThrough { return true }
                    return !view.isDescendant(of: root)
                }
                shield.onTap = { [weak self, weak shield] in
                    guard let self else { shield?.isHidden = true; return }
                    self.remove()
                    self.onTap()
                }
                self.shield = shield
            }
            shield.show(over: window, levelOffset: 0.5)
        }

        func remove() { shield?.isHidden = true }
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.onTap = onTap
        view.active = active
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        view.onTap = onTap
        view.active = active
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.remove() }
}

/// 半高面板：內容不多的面板（新增小工具、新增圖層）只佔下半個螢幕，外觀和「位置與大小」工具面板相同
/// （底色、頂端圓角比照「小工具設定」、滿寬貼到螢幕底邊、上緣在螢幕一半），沒有「取消」，點面板外關閉，
/// 那一下不觸發底下的東西。鍵盤出現時面板不動，只捲面板裡的內容。
extension View {
    func formlessHalfPanel<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder panel: @escaping () -> Panel) -> some View {
        overlay { FormlessHalfPanelHost(isPresented: isPresented, panel: panel) }
            .animation(BatchPositionPanel.animation, value: isPresented.wrappedValue)
    }
}

/// 下半部面板（位置與大小、顏色、新增小工具、新增圖層）共用的高度：螢幕高度的 60%（使用者指定，2026-09-28 由 55% 改為 60%）。
enum FormlessPanelMetrics {
    static let heightRatio = FormlessDesign.Size.panelRatio
    @MainActor static var height: CGFloat { (FormlessSafeArea.windowHeight * heightRatio).rounded() }
}

/// 半高面板的容器：平常貼在螢幕底邊；鍵盤出現時整片面板移到鍵盤上方，輸入的內容與結果才看得到
/// （這類面板的輸入不會即時改到畫布，擋住畫布沒關係；位置與大小、顏色這種工具面板不用這個，維持固定）。
private struct FormlessHalfPanelHost<Panel: View>: View {
    @Binding var isPresented: Bool
    let panel: () -> Panel
    @StateObject private var keyboard = FormlessKeyboardObserver()

    /// 平常是半個螢幕；鍵盤出現、面板移到鍵盤上方時，高度收到頂端導覽列按鈕的下方為止，不和它們疊在一起。
    private var height: CGFloat {
        let window = FormlessSafeArea.windowHeight
        let half = FormlessPanelMetrics.height
        guard keyboard.visible else { return half }
        return min(half, window - keyboard.height - (FormlessSafeArea.top + 60))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if isPresented {
                panel()
                    .editorToolPanel(height: height) { isPresented = false }
                    .transition(.move(edge: .bottom))
            }
        }
        // 只忽略螢幕的安全區（貼到底邊），保留鍵盤的安全區：鍵盤出現時面板底邊自動停在鍵盤頂端。
        .ignoresSafeArea(.container)
        // 關閉動畫期間面板還在畫面上，再點到裡面的項目會再做一次（新增圖層曾因此一次加兩個）；一開始關就不接受點擊。
        .allowsHitTesting(isPresented)
    }
}

/// 標記一塊固定位置的面板裡的表單（例如位置與大小面板）：鍵盤出現時面板本身不動、只捲表單內容，
/// 避讓不能套用編輯器「畫布縮小造成表單下移」的位移。放在表單的 background。
struct FormlessFixedPanelScroll: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            func find(_ node: UIView) -> UIScrollView? {
                if let scroll = node as? UIScrollView, scroll.bounds.height > 80 { return scroll }
                for child in node.subviews { if let found = find(child) { return found } }
                return nil
            }
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scroll = find(candidate) { FormlessKeyboardAvoider.fixedScrolls.add(scroll); return }
                ancestor = candidate.superview
            }
        }
    }
}

/// 自己處理鍵盤的捲動區收到的通知：`onShow` 的參數是欄位還要再往上捲多少（負的表示可以往回捲）。
final class FormlessKeyboardClient {
    var onShow: (CGFloat) -> Void = { _ in }
    var onHide: () -> Void = {}
}

/// 放在 SwiftUI ScrollView 的 background：鍵盤出現時由它自己把輸入欄捲到鍵盤上方 36 pt（和全 App 相同），
/// 全域避讓不直接改這個捲動區（SwiftUI 會把內距與位移蓋回去，欄位就被鍵盤蓋住）。
struct FormlessSelfManagedKeyboardScroll: UIViewRepresentable {
    let onShow: (CGFloat) -> Void
    let onHide: () -> Void

    func makeCoordinator() -> FormlessKeyboardClient { FormlessKeyboardClient() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let client = context.coordinator
        client.onShow = onShow
        client.onHide = onHide
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            func find(_ node: UIView) -> UIScrollView? {
                if let scroll = node as? UIScrollView, scroll.bounds.height > 80 { return scroll }
                for child in node.subviews { if let found = find(child) { return found } }
                return nil
            }
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scroll = find(candidate) { FormlessKeyboardAvoider.selfManaged.setObject(client, forKey: scroll); return }
                ancestor = candidate.superview
            }
        }
    }
}

/// 鍵盤開著時，點鍵盤以外、輸入框以外的任何地方就收起鍵盤，而且這一下不觸發底下的任何動作（避免誤觸）。
/// 點輸入框（或標成輸入框延伸範圍的地方）維持鍵盤開著，只切換欄位。掛在視窗上而不是畫面上。
@MainActor
final class FormlessDismissKeyboard: NSObject, UIGestureRecognizerDelegate {

    private weak var window: UIWindow?
    private var gesture: UITapGestureRecognizer?
    private var keyboardVisible = false
    private var tokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        FormlessKeyboardShield.start()
        FormlessKeyboardAvoider.start()
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setKeyboardVisible(true) }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setKeyboardVisible(false) }
        })
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

    /// 鍵盤開著：這一下點擊獨佔。取消觸控（UIKit 控制項收到取消）、延後交付觸控（自己處理觸控的控制項在這一下
    /// 被判定為點擊時根本收不到按下，不會先觸發再被取消）。鍵盤收著：完全不影響任何觸控。
    private func setKeyboardVisible(_ visible: Bool) {
        keyboardVisible = visible
        gesture?.cancelsTouchesInView = visible
        gesture?.delaysTouchesBegan = visible
    }

    func attach(to view: UIView, retries: Int = 5) {
        guard gesture == nil else { return }

        guard let window = view.window else {
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(to: view, retries: retries - 1)
            }
            return
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
        tap.cancelsTouchesInView = keyboardVisible
        tap.delaysTouchesBegan = keyboardVisible
        tap.delegate = self
        window.addGestureRecognizer(tap)

        self.gesture = tap
        self.window = window
    }

    func detach() {
        guard let gesture else { return }
        window?.removeGestureRecognizer(gesture)
        self.gesture = nil
        self.window = nil
    }

    @objc private func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// 點在輸入框內是移動游標，不能當成結束輸入
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {

        var view = touch.view
        // 控制項照樣點得到的畫面：這個手勢完全不參與（收鍵盤由那個畫面自己做）。
        if view?.formlessInKeyboardTapThrough == true { return false }
        // 上一步／下一步：這一下交給按鈕，不當成「點外面收鍵盤」。
        if view is FormlessPanelShieldPassThrough { return false }

        while let current = view {
            // 輸入框本身與它的延伸範圍：點了是移動游標或切換欄位，鍵盤要維持開著。
            if current is UITextField || current is UITextView || current is FormlessInputAreaView { return false }
            // 自己處理觸控的控制項：鍵盤收著時手勢完全不參與，按下立刻有反應；鍵盤開著時照樣只收鍵盤。
            if current is FormlessKeyboardPassThroughView && !keyboardVisible { return false }
            view = current.superview
        }
        return true
    }

    /// 鍵盤開著時，這一下點擊要獨佔：其他手勢（按鈕、清單列）得等它失敗才能動作。
    /// 只設 cancelsTouchesInView 不夠，SwiftUI 的按鈕是靠自己的手勢辨識器，不吃觸控取消。
    /// 同類的收鍵盤手勢要排除，否則兩個互等對方失敗會一起卡住。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        !keyboardVisible || other.delegate is FormlessDismissKeyboard
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        keyboardVisible && !(other.delegate is FormlessDismissKeyboard)
    }
}


private struct FormlessDismissKeyboardInstaller: UIViewRepresentable {

    func makeCoordinator() -> FormlessDismissKeyboard { FormlessDismissKeyboard() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: FormlessDismissKeyboard) {
        coordinator.detach()
    }
}


/// 桌面小工具的重新整理：App 在前景時桌面看不到，編輯與設定期間的每次存檔先記著，離開編輯器／設定頁或 App 進背景時
/// 才一次送出。原本每次自動存檔（停手 0.65 秒）都叫所有小工具重建，小工具每次都重抓行事曆、提醒事項、天氣，很耗電。
@MainActor enum FormlessWidgetReload {
    private static var pending = false
    static func request() { pending = true }
    static func flush() {
        guard pending else { return }
        pending = false
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 清單還在滑動（慣性或回彈）時手指按下去，系統只會讓清單停下；但 SwiftUI 清單裡的按鈕與點擊手勢照樣觸發，
/// 新增圖層就曾因此多加一個圖層。這裡在視窗上記下「這次按下時底下的捲動區是否還在動」，列的動作看到就略過。
@MainActor
enum FormlessScrollStopTap {
    /// 目前這次觸碰按下時，底下有捲動區還在滑動：這一下只是讓它停下。
    private(set) static var touchStoppedScroll = false
    private static weak var window: UIWindow?

    /// 列的動作開頭呼叫：這一下是用來停下捲動的就回傳 false。
    static func allows() -> Bool { !touchStoppedScroll }

    static func install(on view: UIView, retries: Int = 10) {
        guard let target = view.window else {
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in
                if let view { install(on: view, retries: retries - 1) }
            }
            return
        }
        guard window !== target else { return }
        window = target
        target.addGestureRecognizer(Recognizer())
    }

    /// 只看按下的那一刻，不參與辨識、不取消也不延後任何觸控。
    private final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first, (event.allTouches?.count ?? 1) == touches.count {
                FormlessScrollStopTap.touchStoppedScroll = Self.moving(under: touch.view)
            }
            state = .failed
        }
        private static func moving(under view: UIView?) -> Bool {
            var node = view
            while let current = node {
                if let scroll = current as? UIScrollView, scroll.isDecelerating || scroll.isDragging { return true }
                node = current.superview
            }
            return false
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

private struct FormlessScrollStopTapInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        FormlessScrollStopTap.install(on: view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { FormlessScrollStopTap.install(on: uiView) }
}

extension View {
    /// App 的根畫面掛一次：之後所有 `formlessTapRow` 與新增圖層的列在「按下是為了停下捲動」時不觸發。
    func formlessScrollStopTapGuard() -> some View {
        background(FormlessScrollStopTapInstaller().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

extension View {

    /// 整列可點的項目用這個，不用 Button：
    /// Button 只要手指抬起時還在範圍內就算點擊，橫向滑過整列會被誤判；
    /// 點擊手勢有位移門檻，滑動就不會觸發。
    /// 清單還在滑動時按下去只會讓它停下，不觸發（`FormlessScrollStopTap`）。
    func formlessTapRow(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture { if FormlessScrollStopTap.allows() { action() } }
            .accessibilityAddTraits(.isButton)
    }

    /// 數字欄位所在的畫面掛一次即可，點欄位以外的地方就結束輸入。
    func formlessTapToDismissKeyboard() -> some View {
        background(
            FormlessDismissKeyboardInstaller()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}


extension View {
    /// 改名時暫時出現的輸入框外框：填滿名稱那一欄的寬度、淡灰底圓角（和數字輸入框同一種底），
    /// 看得出哪裡是輸入框；整塊都算輸入框的範圍，點框裡的空白處不會收起鍵盤。
    func formlessInputBox(minHeight: CGFloat = FormlessDesign.Size.control) -> some View {
        padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .formlessGrayBox()
            .background(FormlessInputArea())
    }
}

/// 就地改名（和圖層列的重新命名一樣）：名稱直接變成輸入框、鍵盤立刻出現，不另外叫出面板；
/// 按鍵盤的完成、或點別處讓鍵盤收起就套用。留空或沒改回傳 nil（不動）。
/// 從長按選單叫出時先等選單收起再聚焦，否則第一次聚焦會被選單吃掉。
struct FormlessInlineNameField: View {
    let name: String
    var font: Font = .body
    var boxHeight: CGFloat = FormlessDesign.Size.control
    let onFinish: (String?) -> Void
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(name: String, font: Font = .body, boxHeight: CGFloat = FormlessDesign.Size.control, onFinish: @escaping (String?) -> Void) {
        self.name = name
        self.font = font
        self.boxHeight = boxHeight
        self.onFinish = onFinish
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField("名稱", text: $text)
            .font(font)
            .submitLabel(.done)
            .focused($focused)
            .formlessInputBox(minHeight: boxHeight)
            .onSubmit { finish() }
            .onChange(of: focused) { _, now in if !now { finish() } }
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
            }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onFinish(trimmed.isEmpty || trimmed == name ? nil : trimmed)
    }
}

/// 所有數字欄位共用的輸入行為：開始編輯時清空、舊值以灰色佈景字提示、只出現游標，沒有系統選取把手
/// （把手會超出小欄位而被裁掉，且繪製範圍無法控制）。按鍵盤「完成」、失焦或鍵盤收起時才套用；留空或無法解析表示不改。
/// 外觀（字級、寬度、底色）由呼叫端加修飾器。
struct FormlessNumberField: View {
    /// nil 表示尚未設定，顯示 `emptyPlaceholder`。
    var value: Double?
    var emptyPlaceholder = ""
    var format: (Double) -> String
    /// 可以輸入小數：用有小數點的數字鍵盤；否則是純數字鍵盤。
    var allowsDecimal = true
    /// 可以輸入負數：鍵盤上方的工具列多一顆正負號（系統數字鍵盤沒有負號）。
    var allowsNegative = true
    var alignment: TextAlignment = .center
    /// 每加一就開始輸入：讓外面整塊（例如方向鍵中間的方塊）都能點進來輸入，不必準確點到數字。
    var focusTrigger = 0
    var onCommit: (Double) -> Void

    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var display: String { value.map(format) ?? "" }
    private var placeholder: String { value.map(format) ?? emptyPlaceholder }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(alignment)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = display }
            .onChange(of: focusTrigger) { _, _ in focused = true }
            // 用 editing 判斷而非 focused：外部先收鍵盤再改值時 FocusState 尚未更新，只看 focused 會漏掉這次顯示更新。
            .onChange(of: display) { _, next in
                if !editing { text = next }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    editing = true
                    text = ""
                } else if editing {
                    commit()
                }
            }
            // 鍵盤被收掉（點欄位外、互動捲動）時 FocusState 不一定即時更新；以鍵盤通知補上。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                guard editing else { return }
                commit()
                if focused { focused = false }
            }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if let entered = FormlessNumberKeyboard.parse(text) { onCommit(entered) }
        text = display
    }
}

/// 屬性面板的文字欄位：左邊固定名稱、右邊輸入。面板的區塊都不放標題，欄位要自己說明用途；
/// 只靠提示字的話，一打字提示就消失，看不出這格是什麼。
struct EditorTextRow: View {
    let title: String
    var placeholder: String? = nil
    @Binding var text: String
    /// 網址、格式、符號名稱這類：不自動大寫、不自動校正。
    var plain = false
    /// 由外面控制的焦點（例如剛新增文字圖層時直接叫出鍵盤）。
    var focus: FocusState<Bool>.Binding? = nil
    /// 網址欄位用網址鍵盤（英文字母與「.」「/」），不會跳出注音。
    var url = false
    /// 名稱和輸入框永遠在同一行（新增行程面板）：字很長時輸入框橫向捲動，不像 LabeledContent 換成上下兩行。
    var singleLine = false

    var body: some View {
        if singleLine {
            HStack(spacing: FormlessDesign.Space.valueGap) {
                Text(title).lineLimit(1).fixedSize()
                focusedField.frame(maxWidth: .infinity)
            }
        } else {
            LabeledContent(title) { focusedField }
        }
    }

    @ViewBuilder private var focusedField: some View {
        if let focus {
            field.focused(focus)
        } else {
            field
        }
    }

    private var field: some View {
        TextField(placeholder ?? title, text: $text)
            .multilineTextAlignment(.trailing)
            .submitLabel(.done)
            .keyboardType(url ? .URL : .default)
            .textInputAutocapitalization(plain || url ? .never : .sentences)
            .autocorrectionDisabled(plain || url)
    }
}

/// 一個功能底下的細項（只在某個選擇之下才出現，或本身就是這個功能的一部分，例如填色的顏色、外框的顏色、
/// 自訂時間的格式）和主設定放在同一列（`EditorFunctionRow`），中間不畫分隔線；互相獨立的功能之間才有分隔線
/// （使用者規則）。細項的字和一般列一樣，不另外縮小或變色（使用者：沒討論過、很醜）。
/// 一個功能的多行內容（主設定＋它的細項）放在同一列，看得到的空隙一律 18 pt：
/// 系統表單列的內距約 14、內容到分隔線看起來約 18，所以每一行都補到「看得到的內容上下各留 4」，行距 10，
/// 行與行之間（4 + 10 + 4）、第一行與最後一行到分隔線（14 + 4）都是 18。
/// 各種控制項的外框比看得到的部分高低不一（選單上下多 2、−/＋ 多 4、色票剛好），不補齊的話同樣的行距
/// 會一處擠一處鬆（使用者：漸層很擠、形狀底下一大堆空白，要研究整個 App 的慣例統一）。
enum EditorRowMetrics {
    static let lineInset: CGFloat = 4
    static let lineSpacing: CGFloat = 10
}

/// 一行裡最高的可見內容和它的外框相差多少（上下各）。
enum EditorLineKind {
    /// 選單（Picker）：文字比按鈕外框矮 2。
    case menu
    /// −/＋ 數字框：按鈕外框比數字框高 4。
    case stepper
    /// 文字輸入框、純文字、文字按鈕：字比外框矮 3。
    case text
    /// 外框就是看得到的大小：色票、開關、數字框、漸層條的 ＋。
    case control

    var slack: CGFloat {
        switch self {
        case .menu: return 2
        case .stepper: return 4
        case .text: return 3
        case .control: return 0
        }
    }
}

extension View {
    /// 同一功能列裡的一行（`EditorFunctionRow`）：補到看得到的內容上下各留 4。
    func editorLine(_ kind: EditorLineKind) -> some View {
        padding(.vertical, max(0, EditorRowMetrics.lineInset - kind.slack))
    }
}

struct EditorFunctionRow<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: EditorRowMetrics.lineSpacing) { content }
    }
}


extension View {
    /// 所有彈出面板統一用不透明的灰底（和屬性面板同色），面板裡放白色卡片。系統預設是半透明的玻璃底：
    /// 用表單或清單的面板會自己畫灰底，其他（圖片庫、圖片預覽）會透出玻璃，半高時還會透出後面的畫面，彼此不一致。
    func formlessSheetBackground() -> some View {
        presentationBackground(FormlessDesign.Palette.page)
    }
}

/// 所有數字欄位共用的鍵盤：系統數字鍵盤（要小數時帶小數點），點鍵盤以外的地方結束輸入。
/// 鍵盤外面不放任何額外按鈕（使用者要求）；數字欄位不會出現可以切到英文的完整鍵盤。
enum FormlessNumberKeyboard {
    static func toggledSign(_ text: String) -> String {
        text.hasPrefix("-") ? String(text.dropFirst()) : "-" + text
    }
    /// 小數點依地區可能是逗號，一律換成句點再解析；留空或只有負號回 nil（表示不改）。
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}


struct GridField: View {

    let title: String
    let value: Double
    let step: Double
    var minimum: Double? = nil
    var highlighted = false
    let onCommit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            EditorStepControl(title: title, value: value, step: step,
                              range: minimum.map { $0...Double.greatestFiniteMagnitude },
                              highlighted: highlighted, snapsToStep: false) { onCommit(EditorNumbers.integer($0)) }
        }
    }
}

/// 表單裡的滑桿：外觀是系統原生的 UISlider，觸控改由自己判斷，和捲動分得清楚。
/// - 手指開始移動時以水平方向為主才調整數值；以垂直方向為主就讓給表單捲動（系統滑桿會先把上下滑動抓去改值）。
/// - 只有從圓鈕附近開始拖才算，和系統滑桿一樣，點軌道不會跳值。
struct FormlessSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeUIView(context: Context) -> Container {
        let container = Container()
        configure(container)
        container.slider.value = Float(value)
        return container
    }
    func updateUIView(_ container: Container, context: Context) {
        configure(container)
        if !container.dragging, abs(Double(container.slider.value) - value) > 0.0001 {
            container.slider.value = Float(value)
        }
    }
    private func configure(_ container: Container) {
        container.slider.minimumValue = Float(range.lowerBound)
        container.slider.maximumValue = Float(range.upperBound)
        container.step = step
        container.onChange = { newValue in
            if abs(newValue - value) > 0.0001 { value = newValue }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: max(32, uiView.slider.intrinsicContentSize.height))
    }

    final class Container: UIView, UIGestureRecognizerDelegate {
        let slider = UISlider()
        var onChange: (Double) -> Void = { _ in }
        var step: Double = 1
        private(set) var dragging = false
        private var grabOffset: CGFloat = 0

        private var pan: UIPanGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            slider.isUserInteractionEnabled = false
            addSubview(slider)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            addGestureRecognizer(pan)
            self.pan = pan
            isAccessibilityElement = true
            accessibilityTraits = .adjustable
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            slider.frame = bounds
        }

        private func thumbRect() -> CGRect {
            let track = slider.trackRect(forBounds: slider.bounds)
            return slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.value)
        }

        /// 外層表單的捲動手勢也會問到這裡（觸控落在滑桿上時）：只有「從圓鈕開始的橫向拖動」由滑桿接手、
        /// 擋掉捲動；其他（例如在滑桿上往上下滑）讓捲動照常開始。原本兩種手勢都用同一個判斷，
        /// 在滑桿上往上下滑會把表單的捲動也擋掉，外觀頁就會覺得滑不動、卡。
        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let other = gesture as? UIPanGestureRecognizer else { return true }
            let velocity = other.velocity(in: self)
            let translation = other.translation(in: self)
            let start = CGPoint(x: other.location(in: self).x - translation.x, y: other.location(in: self).y - translation.y)
            let horizontal = abs(velocity.x) > abs(velocity.y) && abs(translation.x) >= abs(translation.y)
            let takes = horizontal && thumbRect().insetBy(dx: -18, dy: -18).contains(start)
            return other === pan ? takes : !takes
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            let location = pan.location(in: self)
            switch pan.state {
            case .began:
                dragging = true
                let translation = pan.translation(in: self)
                grabOffset = (location.x - translation.x) - thumbRect().midX
                apply(x: location.x - grabOffset)
            case .changed:
                apply(x: location.x - grabOffset)
            default:
                dragging = false
            }
        }

        /// 以圓鈕中心所在的 x 換算數值：圓鈕中心可走的範圍是軌道兩端各縮半顆圓鈕。
        private func apply(x: CGFloat) {
            let track = slider.trackRect(forBounds: slider.bounds)
            let minCenter = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.minimumValue).midX
            let maxCenter = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.maximumValue).midX
            guard maxCenter > minCenter else { return }
            let fraction = min(1, max(0, (x - minCenter) / (maxCenter - minCenter)))
            var newValue = Double(slider.minimumValue) + Double(fraction) * Double(slider.maximumValue - slider.minimumValue)
            if step > 0 { newValue = (newValue / step).rounded() * step }
            newValue = min(Double(slider.maximumValue), max(Double(slider.minimumValue), newValue))
            slider.value = Float(newValue)
            onChange(newValue)
        }

        override func accessibilityIncrement() { nudge(1) }
        override func accessibilityDecrement() { nudge(-1) }
        private func nudge(_ direction: Double) {
            let delta = step > 0 ? step : Double(slider.maximumValue - slider.minimumValue) / 20
            let newValue = min(Double(slider.maximumValue), max(Double(slider.minimumValue), Double(slider.value) + direction * delta))
            slider.value = Float(newValue)
            onChange(newValue)
        }
        override var accessibilityValue: String? {
            get { String(format: step < 1 ? "%.2f" : "%.0f", slider.value) }
            set {}
        }
    }
}

struct EditorNumberRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// 數字後面的單位（透明度「%」）。
    var suffix = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .lineLimit(1)
            FormlessSlider(value: $value, range: range, step: step)
                .frame(minWidth: 64, minHeight: 32)
            FormlessNumberField(value: value, format: formatted, allowsDecimal: step < 1,
                                allowsNegative: range.lowerBound < 0) { entered in
                value = min(max(entered, range.lowerBound), range.upperBound)
            }
            .font(.body.monospacedDigit())
            .padding(.horizontal, 10)
            .frame(width: FormlessDesign.Size.fieldShort)
            .frame(minHeight: FormlessDesign.Size.control)
            .formlessGrayBox()
        }
    }

    private func formatted(_ number: Double) -> String {
        if step < 0.1 { return String(format: "%.2f", number) + suffix }
        if step < 1 { return String(format: "%.1f", number) + suffix }
        return String(format: "%.0f", number) + suffix
    }
}

struct EditorIntegerField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        EditorStepperRow(title: title,
                         value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                         range: Double(range.lowerBound)...Double(range.upperBound), step: 1)
    }
}

/// 數值欄的規則（使用者規則）：大範圍、看效果拖的數值（透明度、旋轉、漸層角度、放射半徑）用滑桿＋數字框（`EditorNumberRow`）；
/// 逐步微調的數值（字級、圓角、外框、陰影、筆數、格數、微調移動）用 −/＋＋數字框，按住 −/＋ 會連續調整。
/// −/＋ 全 App 只有這一種外觀（`EditorStepControl`）。
struct EditorStepperRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        // 輔助字級時名稱在上、控制在下，名稱與數字都不會被截斷（2026-10 輔助使用）。
        FormlessAdaptiveRow {
            Text(title)
        } control: {
            EditorStepControl(title: title, value: value, step: step, range: range, fieldWidth: FormlessDesign.Size.fieldShort) { value = $0 }
        }
    }
}

/// −／數字框／＋：按一下加減一個步進（並對齊步進的倍數），按住連續調整；數字框點了直接輸入。到上下限時那一側變淡。
struct EditorStepControl: View {
    let title: String
    let value: Double
    let step: Double
    var range: ClosedRange<Double>? = nil
    /// nil 表示數字框撐滿剩下的寬度。
    var fieldWidth: CGFloat? = nil
    var highlighted = false
    /// 按 −/＋ 時對齊步進的倍數（字級 12.13 按 ＋ 得到 13）；位移類（微調部位）照位置方向鍵，直接加減一個步進。
    var snapsToStep = true
    let onCommit: (Double) -> Void

    private var decimals: Int { step < 0.1 ? 2 : (step < 1 ? 1 : 0) }
    /// 按住連續加減時每一下都要讀最新的值；按鈕的動作在按下那一刻就定了，所以把目前的值放在參考物件裡。
    private final class Current { var value: Double = 0 }
    @State private var current = Current()

    var body: some View {
        let _ = { current.value = value }()
        HStack(spacing: 2) {
            stepButton("minus", -1)
            FormlessNumberField(value: value, format: { String(format: "%.\(decimals)f", $0) },
                                allowsDecimal: step < 1, allowsNegative: (range?.lowerBound ?? -1) < 0) { apply($0) }
                .font(.body.monospacedDigit())
                .padding(.horizontal, 10)
                .frame(minWidth: fieldWidth ?? 42, maxWidth: fieldWidth ?? .infinity, minHeight: FormlessDesign.Size.control)
                .formlessGrayBox()
                .overlay {
                    RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
                        .strokeBorder(highlighted ? FormlessDesign.Palette.accent : .clear, lineWidth: FormlessDesign.Stroke.selection)
                }
            stepButton("plus", 1)
        }
    }

    private func clamp(_ number: Double) -> Double {
        guard let range else { return number }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    private func apply(_ number: Double) { onCommit(clamp(number)) }

    private func stepButton(_ symbol: String, _ direction: Double) -> some View {
        let atLimit = direction < 0 ? value <= (range?.lowerBound ?? -.infinity) : value >= (range?.upperBound ?? .infinity)
        let current = current, step = step, snaps = snapsToStep
        return EditorRepeatStepButton(symbol: symbol, enabled: !atLimit,
                                      label: direction < 0 ? title + "減少" : title + "增加") {
            let value = current.value
            guard snaps else { apply(value + direction * step); return }
            // 對齊步進的倍數：2.37 按 ＋（步進 0.5）得到 2.5，不是 2.87。
            let snapped = (value / step).rounded(direction > 0 ? .down : .up) * step
            let next = abs(snapped - value) < step * 0.001 ? value + direction * step : snapped + (direction > 0 ? step : -step)
            let result = clamp((next / step).rounded() * step)
            current.value = result
            onCommit(result)
        }
    }
}

/// −/＋ 鍵：和「位置與大小」方向鍵同一套觸控（見 `RepeatingPadButton`）——放開才算一次；按住 0.4 秒且手指沒動，
/// 才開始每 0.1 秒連續加減；手指移動或表單開始捲動就整個取消。系統按鈕在表單裡按住不會連續觸發。
private struct EditorRepeatStepButton: View {
    let symbol: String
    let enabled: Bool
    let label: String
    let action: () -> Void
    @State private var pressing = false
    @State private var holdTask: Task<Void, Never>?
    @State private var repeating = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            .opacity(pressing ? FormlessDesign.Press.glyphOpacity : 1)
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
            .overlay { if enabled { FormlessHoldObserver(onBegan: began, onEnded: ended) } }
            .animation(FormlessDesign.Motion.press, value: pressing)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { if enabled { action() } }
    }

    private func began() {
        holdTask?.cancel()
        repeating = false
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            pressing = true
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            repeating = true
            while !Task.isCancelled {
                fire()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func ended(_ tapped: Bool) {
        holdTask?.cancel()
        holdTask = nil
        let wasRepeating = repeating
        repeating = false
        guard tapped, !wasRepeating else { pressing = false; return }
        fire()
        pressing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            pressing = false
        }
    }

    private func fire() {
        // 正在輸入數字時先收鍵盤：輸入值先套用，這一下加減接在新值之後。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        action()
    }
}


// MARK: - pt 數值輸入

struct PointField: View {

    let title: String
    let value: Double
    let onCommit: (Double) -> Void

    var body: some View {
        HStack {
            Text(title)

            Spacer()

            FormlessNumberField(value: value, format: { String(format: "%.1f", $0) }, onCommit: onCommit)
                .font(.body.monospacedDigit())
                .padding(.horizontal, 10)
                .frame(width: FormlessDesign.Size.fieldShort)
                .frame(minHeight: FormlessDesign.Size.control)
                .formlessGrayBox()

            Text("pt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


// MARK: - 天氣用語與圖片

/// 天氣：設定頁換頁進來（使用者：不要從下彈出，和其他項目一樣換頁）。每個變更當下就存；
/// 離開時有改過才讓首頁更新資料、重新整理小工具。
struct WeatherStyleView: View {

    var onChange: () -> Void = {}
    /// 從「資料來源 › 天氣」進來時，溫度單位已經在上一頁，這頁只放各種天氣的文字與圖片。
    var showsUnit = true
    var title = "天氣"

    @State private var settings = FormlessWeatherStyleSettings()
    @State private var changed = false
    @State private var picking: String?
    @State private var showPicker = false
    @State private var imageError = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
            List {
                if showsUnit {
                    Section {
                        Picker("溫度單位", selection: unitBinding) {
                            Text("攝氏 °C").tag("c")
                            Text("華氏 °F").tag("f")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // 卡片不放標題（使用者規則）：天氣種類的名稱放進卡片（左名稱、右圖片），圖片與文字是同一種天氣的
                // 設定、放同一列（`EditorFunctionRow`），各種天氣之間才有分隔線，全部同一張卡片。
                Section {
                    ForEach(FormlessWeatherCondition.allCases, id: \.self) { condition in
                        EditorFunctionRow {
                            HStack(spacing: 20) {
                                Text(condition.label)
                                Spacer(minLength: 12)
                                thumbnail(condition, isDay: true)

                                // 沒有夜晚圖的天氣留一個看不見的同寬位置，白天圖才會和其他天氣的白天欄對齊。
                                if condition.hasNightVariant {
                                    thumbnail(condition, isDay: false)
                                } else {
                                    thumbnail(condition, isDay: true).hidden()
                                }
                            }
                            .editorLine(.control)

                            TextField(condition.defaultText, text: wording(condition))
                                .submitLabel(.done)
                                .textInputAutocapitalization(.never)
                                .editorLine(.text)
                        }
                    }
                }
            }
            // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
            .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
            .formlessPageTitle(title)
            .task { settings = await Task.detached { FormlessWeatherStyle.current() }.value }
            .onDisappear { if changed { onChange() } }
            .alert("無法加入圖片", isPresented: $imageError) {
                Button("確定", role: .cancel) { }
            } message: {
                Text("圖片無法讀取或儲存。請確認圖片已下載至裝置、儲存空間足夠，或改選其他圖片。")
            }
            .photosPicker(isPresented: $showPicker, selection: $picked, matching: .images)
            .onChange(of: picked) { _, value in
                guard let value, let key = picking else { return }

                Task {
                    if let data = try? await value.loadTransferable(type: Data.self),
                       let shrunk = WeatherStyleView.shrink(data),
                       let name = try? FormlessStorage.saveAsset(data: shrunk) {

                        settings.images[key] = name
                        FormlessWeatherStyle.save(settings)
                        changed = true
                        FormlessHaptics.success()
                    } else {
                        imageError = true
                    }

                    picked = nil
                    picking = nil
                }
            }
    }

    private func thumbnail(
        _ condition: FormlessWeatherCondition,
        isDay: Bool
    ) -> some View {

        let key = FormlessWeatherStyleSettings.key(condition, isDay: isDay)

        return Button {
            picking = key
            showPicker = true
        } label: {
            VStack(spacing: 6) {
                FormlessWeatherIcon(
                    name: condition.symbol,
                    assetName: condition.assetName(isDay: isDay),
                    customName: settings.images[key],
                    width: 46,
                    height: 46
                )

                Text(isDay ? "白天" : "夜晚")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .contextMenu {
            if settings.images[key] != nil {
                Button("回復預設圖片", systemImage: "arrow.counterclockwise", role: .destructive) {
                    settings.images[key] = nil
                    FormlessWeatherStyle.save(settings)
                    changed = true
                }
            }
        }
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { settings.unit ?? "c" },
            set: { newValue in
                settings.unit = newValue
                FormlessWeatherStyle.save(settings)
                changed = true
            }
        )
    }

    private func wording(_ condition: FormlessWeatherCondition) -> Binding<String> {
        Binding(
            get: { settings.words[condition.rawValue] ?? "" },
            set: { newValue in
                let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

                if clean.isEmpty {
                    settings.words[condition.rawValue] = nil
                } else {
                    settings.words[condition.rawValue] = newValue
                }

                FormlessWeatherStyle.save(settings)
                changed = true
            }
        )
    }

    private static func shrink(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return data }

        let longest = max(image.size.width, image.size.height)

        guard longest > 512 else { return image.pngData() ?? data }

        let scale = 512 / longest
        let target = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        // 512 px 就是 512 px（預設格式會乘上螢幕倍率變成 1536 px），一般色域 8 位元（2026-10，記憶體）。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: target, format: format)

        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        return resized.pngData() ?? data
    }
}


// MARK: - 測試版預設設計



// MARK: - 圖片庫

struct ImageLibraryView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var items: [FormlessAssetItem] = []
    @State private var isLoadingLibrary = true
    @State private var imageError = false
    @State private var picked: PhotosPickerItem?
    @State private var showPicker = false
    /// 正在就地改名的圖片。
    @State private var renamingID: String?
    @State private var usageItem: FormlessAssetItem?
    @State private var usage: [String: [String]] = [:]

    let current: String?
    /// 分頁模式下由首頁傳入：捲動時縮放首頁分頁列。
    var minimizeState: FormlessMinimizeState? = nil
    var isManaging = false
    /// 分頁模式下「加入」由外層工具列觸發，這裡接收開關。
    var externalAdd: Binding<Bool>? = nil
    @State private var previewItem: FormlessAssetItem?
    let onSelect: (String?) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 16)]

    private var pickerPresented: Binding<Bool> { externalAdd ?? $showPicker }

    var body: some View {
        // 分頁模式由外層的導覽堆疊接手；從編輯器彈出的選圖 sheet 才需要自己的堆疊。
        if isManaging {
            libraryContent
        } else {
            NavigationStack { libraryContent }
        }
    }

    private var libraryContent: some View {
            ScrollView {
                if isLoadingLibrary {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("建立你的圖片庫", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("加入照片後，可在任何設計中用作背景或圖片圖層。")
                    } actions: {
                        Button("從相簿加入", systemImage: "plus") { pickerPresented.wrappedValue = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            cell(item)
                        }
                    }
                    // 左右照全 App 的邊線 20；上方 16 讓第一列和其他兩個分頁的第一張卡片同高。
                    .padding(.horizontal, FormlessDesign.Space.edge)
                    .padding(.vertical, 16)
                }
            }
            // 和其他分頁一樣是淺灰底（原本沒設底色，是白的）。
            .background(FormlessDesign.Palette.page.ignoresSafeArea())
            .formlessScrollMinimizer(state: minimizeState)
            .formlessPageTitle("圖片庫")
            .toolbar {
                if !isManaging {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("加入圖片", systemImage: "plus") { showPicker = true }.labelStyle(.iconOnly)
                    }
                }

                if current != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("移除目前圖片", role: .destructive) {
                            onSelect(nil)
                            dismiss()
                        }
                    }
                }
            }
            .alert("無法加入圖片", isPresented: $imageError) {
                Button("確定", role: .cancel) { }
            } message: {
                Text("圖片無法讀取或儲存。請確認圖片已下載至裝置、儲存空間足夠，或改選其他圖片。")
            }
            .photosPicker(isPresented: pickerPresented, selection: $picked, matching: .images)
            .onChange(of: picked) { _, value in
                guard let value else { return }

                Task {
                    if let data = try? await value.loadTransferable(type: Data.self) {
                        let added = await Task.detached(priority: .userInitiated) { FormlessAssetLibrary.add(data: data) }.value
                        await reloadLibrary()

                        if let added {
                            FormlessHaptics.success()
                            if !isManaging {
                                onSelect(added.id)
                                dismiss()
                            }
                        } else {
                            imageError = true
                        }
                    } else {
                        imageError = true
                    }

                    picked = nil
                }
            }
            .task { await reloadLibrary() }
            .sheet(item: $previewItem) { item in
                NavigationStack {
                    FormlessLoadedAsset(name: item.id) { image in
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        } else {
                            ContentUnavailableView("無法讀取圖片", systemImage: "photo.badge.exclamationmark")
                        }
                    }
                    .formlessPageTitle(item.title)
                    .toolbar {
                        if !(usage[item.id] ?? []).isEmpty {
                            ToolbarItem(placement: .topBarLeading) {
                                Menu("用於 \((usage[item.id] ?? []).count) 個小工具") {
                                    ForEach(Array((usage[item.id] ?? []).enumerated()), id: \.offset) { _, name in
                                        Text(name)
                                    }
                                }
                            }
                        }
                    }
                }
                .formlessSheetBackground()
            }
            .sheet(item: $usageItem) { item in
                AssetUsageView(title: item.title, documents: usage[item.id] ?? [])
                    .formlessSheetBackground()
            }
    }

    private func cell(_ item: FormlessAssetItem) -> some View {
        let isCurrent = item.id == current

        return VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    thumbnail(item)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                    .aspectRatio(1, contentMode: .fit)
                    .background(FormlessDesign.Palette.card)
                    .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous)
                            .strokeBorder(
                                isCurrent ? FormlessDesign.Palette.accent : Color.clear,
                                lineWidth: FormlessDesign.Stroke.selection
                            )
                    )
                    // 長按選單只掛在縮圖上，抬起時是圓角的圖，不會帶出整格的方形底
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous))
                    .contextMenu {
                        if !(usage[item.id] ?? []).isEmpty {
                            Button("查看用在哪些小工具", systemImage: "square.grid.2x2") { usageItem = item }
                        }
                        Button("改名", systemImage: "pencil") { renamingID = item.id }

                        Button("刪除", systemImage: "trash", role: .destructive) {
                            Task {
                                await Task.detached { FormlessAssetLibrary.remove(item.id) }.value
                                if isCurrent { onSelect(nil) }
                                await reloadLibrary()
                                FormlessHaptics.rigid()
                            }
                        }
                    } preview: {
                        thumbnail(item)
                            .frame(width: 220, height: 220)
                            .background(FormlessDesign.Palette.card)
                            .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.card, style: .continuous))
                    }

                VStack(alignment: .leading, spacing: 1) {
                    if renamingID == item.id {
                        FormlessInlineNameField(name: item.title, font: .caption, boxHeight: 24) { newName in
                            renamingID = nil
                            guard let newName else { return }
                            FormlessAssetLibrary.rename(item.id, to: newName)
                            Task { await reloadLibrary() }
                        }
                    } else {
                        Text(item.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    }
                    // 用量寫在圖片下方，不擋住圖
                    Text(usageCaption(item))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
        }
        .formlessTapRow {
            guard renamingID != item.id else { return }
            if isManaging {
                previewItem = item
            } else {
                onSelect(item.id)
                dismiss()
            }
        }
        .accessibilityLabel(item.title + "，" + usageCaption(item))
        .accessibilityHint(isManaging ? "預覽圖片；長按可改名或刪除" : "選取圖片")
    }

    private func usageCaption(_ item: FormlessAssetItem) -> String {
        let count = usage[item.id]?.count ?? 0
        return count > 0 ? "\(count) 個小工具" : "未使用"
    }

    private func thumbnail(_ item: FormlessAssetItem) -> some View {
        EditorAssetThumbnail(item: item) { image in
            if let image { Image(uiImage: image).resizable().scaledToFill().clipped() }
            else { Color.clear }
        }
    }

    private func reloadLibrary() async {
        let snapshot = await Task.detached(priority: .utility) {
            let assets = FormlessAssetLibrary.all()
            let documents = FormlessStorage.loadAll()
            let used = Dictionary(uniqueKeysWithValues: assets.map { item in
                let names = documents.filter { document in
                    document.backgroundImageName == item.id
                        || document.layers.contains { $0.value == item.id }
                }.map(\.name)
                return (item.id, names)
            })
            return (assets, used)
        }.value
        items = snapshot.0
        usage = snapshot.1
        isLoadingLibrary = false
    }

}

struct AssetUsageView: View {
    let title: String
    let documents: [String]

    var body: some View {
        NavigationStack {
            List {
                // 卡片不放標題：說明放到卡片下方。
                Section {
                    ForEach(Array(documents.enumerated()), id: \.offset) { _, name in
                        Text(name)
                    }
                } footer: {
                    Text("這張圖片用在以上的小工具。")
                }
            }
            .formlessPageTitle(title)
        }
    }
}


// MARK: - 選取匯出

struct ExportPickerView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var picked = Set<UUID>()

    let documents: [FormlessDocument]

    private var selected: [FormlessDocument] {
        documents.filter { picked.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(documents) { document in
                    Button {
                        if picked.contains(document.id) {
                            picked.remove(document.id)
                        } else {
                            picked.insert(document.id)
                        }
                    } label: {
                        HStack {
                            Text(document.name)
                                .foregroundStyle(.primary)

                            Spacer(minLength: 12)

                            // 列尾的值：和系統列相同的內文字級、灰字。
                            Text(document.family.displayName)
                                .foregroundStyle(.secondary)

                            if picked.contains(document.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        // 整列都能點（放在按鈕外面只有文字點得到）。
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formlessPageTitle("選取匯出")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(picked.count == documents.count ? "全部取消" : "全選") {
                        picked = picked.count == documents.count
                            ? []
                            : Set(documents.map(\.id))
                    }
                }

                if !selected.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        ShareLink(
                            item: FormlessBundleExport(documents: selected),
                            preview: SharePreview(
                                FormlessBundleExport(documents: selected).fileName
                            )
                        ) {
                            Text("匯出 \(selected.count) 份")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 圖層素材選擇

struct LayerPickerView: View {
    let onSelect: (FormlessLayerType) -> Void
    /// 我的組合（2026-10）：有存組合時，面板最下面多一張卡片。
    var onSelectComponent: ((FormlessComponent) -> Void)? = nil
    /// 曲線文字：一般的文字圖層沿圓弧排（2026-10），列在文字類的最後。
    var onSelectCurvedText: (() -> Void)? = nil
    /// 半高面板：選好或點面板外就關閉，不放「取消」。
    var onClose: () -> Void = {}
    private func dismiss() { onClose() }

    /// 只列通用的圖層種類（使用者規則）：為特定內容做好的元件（事件清單、提醒清單、天氣預報列）由使用者用通用圖層
    /// 自己組出來；年度進度格、刻度軸當成圖片由使用者匯入。已經在設計裡的舊元件照常顯示與編輯。
    /// 群組也不在這裡建立：在選取模式勾選圖層後用「群組」鍵建立。
    /// 漸層不另外列：它是色塊的一種填色（色塊 › 外觀 › 填色）。
    private let types: [FormlessLayerType] = [.text, .date, .time, .liveText, .image, .remoteImage, .symbol, .shape]
    /// 呈現資料的圖層：進度、圖表（2026-10 通用化），與唯一保留的現成元件月曆格（本月日期格＋星期，
    /// 用通用圖層組不出來，使用者決定保留）。放在下面另一張卡片，不加標題。
    private let components: [FormlessLayerType] = [.progress, .chart, .clock, .calendarGrid]

    private func row(_ type: FormlessLayerType) -> some View {
        Button {
            // 清單還在滑動時按下去只是讓它停下，不新增。
            guard FormlessScrollStopTap.allows() else { return }
            onSelect(type)
            dismiss()
        } label: {
            // 每列左邊一個單色圖示（10/03 決定），一眼看出種類。
            HStack(spacing: 16) {
                Image(systemName: type.pickerSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                    .frame(width: 28)
                    // textformat 會依語系換字（繁中是「格式」）；圖示要的是「Aa」。
                    .environment(\.locale, Locale(identifier: "en_US"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.displayName).font(.headline).foregroundStyle(.primary)
                    Text(type.pickerDescription).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FormlessDesign.Space.rowExtra)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var curvedTextRow: some View {
        Button {
            guard FormlessScrollStopTap.allows() else { return }
            onSelectCurvedText?()
            dismiss()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("曲線文字").font(.headline).foregroundStyle(.primary)
                    Text("沿著圓弧排列的文字，可以夾資料").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FormlessDesign.Space.rowExtra)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 不提供搜尋（使用者要求拿掉）：項目不多，直接捲動挑選。
    var body: some View {
        List {
            Section {
                ForEach(types.prefix(4), id: \.self, content: row)
                if onSelectCurvedText != nil { curvedTextRow }
                ForEach(types.dropFirst(4), id: \.self, content: row)
            }
            Section { ForEach(components, id: \.self, content: row) }
            if let onSelectComponent {
                EditorComponentSection(onSelect: { component in
                    guard FormlessScrollStopTap.allows() else { return }
                    onSelectComponent(component)
                    dismiss()
                })
            }
        }
        // 沒有分區標題了，卡片直接接在標題列下面（和「位置與大小」面板相同）；標題列本身已經留了上下空間。
        .contentMargins(.top, 0, for: .scrollContent)
        // 兩張卡片之間、最後一張到螢幕底部安全區上方都是 20 pt，和左右邊距相同。
        .listSectionSpacing(FormlessDesign.Space.panel)
        .contentMargins(.bottom, FormlessDesign.Space.panel + FormlessSafeArea.bottom, for: .scrollContent)
        // 標題列和系統導覽列一樣半透明：內容捲到標題下方時霧化透出（使用者要求所有面板一致）。
        .safeAreaBar(edge: .top, spacing: 0) {
            Text("新增圖層")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: FormlessDesign.Size.titleBar)
        }
    }
}

extension FormlessLayerType {
    /// 新增圖層面板與圖層列的圖示（單色）。
    var pickerSymbol: String {
        switch self {
        case .text: return "textformat"
        case .date: return "calendar"
        case .time: return "clock"
        case .liveText: return "gauge.with.dots.needle.33percent"
        case .image, .bundleImage: return "photo"
        case .remoteImage: return "globe"
        case .symbol: return "star"
        case .shape, .gradient: return "square.on.circle"
        case .progress: return "circle.dashed.inset.filled"
        case .chart: return "chart.bar.xaxis"
        case .calendarGrid: return "square.grid.3x3"
        default: return symbolName
        }
    }

    var pickerDescription: String {
        switch self {
        case .text: return "輸入標題、短句或備註，也可以夾資料"
        case .date: return "隨日期更新的文字"
        case .time: return "顯示時間，並自訂格式"
        case .shape: return "單色或漸層的色塊，建立背景與視覺分區"
        case .gradient: return "由透明漸變到指定顏色的直向漸層"
        case .image: return "使用相簿或圖片庫中的照片"
        case .remoteImage: return "從網址載入圖片"
        case .symbol: return "加入可調整顏色與大小的系統圖示"
        case .bundleImage: return "舊版圖片，請改用圖片庫"
        case .liveText: return "顯示溫度、步數等即時數值"
        case .ruler: return "為版面加入刻度裝飾"
        case .calendarGrid: return "獨立排版的月份日期格"
        case .eventList: return "以卡片顯示行事曆活動"
        case .reminderList: return "顯示待完成的提醒事項"
        case .weatherForecast: return "顯示未來幾天的天氣"
        case .yearGrid: return "以格狀圖案呈現年度進度"
        case .calendar: return "日期、星期與月曆的完整組合"
        case .events: return "從行事曆顯示今日與近期行程"
        case .reminders: return "標題、圖示與待辦清單的完整組合"
        case .weather: return "目前溫度、天氣狀態與預報"
        case .steps: return "從健康資料顯示今日步數"
        case .yearProgress: return "查看今年已經過的比例"
        case .progress: return "線形、環形、弧形或分段的進度"
        case .chart: return "把一份清單畫成長條、折線或圓餅"
        case .clock: return "有時針與分針的時鐘，可選刻度、數字與時區"
        }
    }
}

// MARK: - 全域設定

/// 設定頁：第一層只放大項（資料來源、編輯器、字型……），進去才是各自的設定（使用者：以後資料來源變多，
/// 不能每個細項都擺在第一層）。所有項目都是換頁，不從下方彈出，左滑返回。
struct AppSettingsView: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void
    var onDocumentsChanged: () -> Void = {}
    /// 由首頁傳入：捲動時縮放首頁分頁列。
    var minimizeState: FormlessMinimizeState? = nil

    @State private var trashCount = 0
    @State private var fontCount = 0
    @AppStorage("formless.nudgeStep") private var nudgeStep: Double = 10
    @AppStorage("formless.canvasLocked") private var canvasLocked = false

    nonisolated static func calendarSummary() -> String {
        let all = FormlessEventsProvider.allCalendars()
        guard !all.isEmpty else { return "" }
        let excluded = FormlessCalendarSettings.current().excluded
        let used = all.filter { !excluded.contains($0.calendarIdentifier) }.count
        return used == all.count ? "全部" : "\(used) / \(all.count)"
    }

    var body: some View {
            List {
                // 資料的所有設定都在「資料來源」裡，依來源分頁（使用者：設定頁不能太長，要多一層）。
                Section {
                    FormlessDataSourcesRow(isRefreshing: isRefreshing, onRefresh: onRefresh)
                }

                // 編輯器的偏好是全 App 共用的（10/03 決定：放在單一設計的設定裡，會讓人以為只改那一份）。
                Section {
                    NavigationLink {
                        EditorPreferencesView()
                    } label: {
                        LabeledContent("編輯器", value: "步進 \(Int(nudgeStep))" + (canvasLocked ? "・畫布已鎖定" : ""))
                    }
                    // 匯入的字型（2026-10）：所有設計共用。
                    NavigationLink {
                        FormlessFontLibraryView()
                    } label: {
                        LabeledContent("字型", value: fontCount > 0 ? "\(fontCount)" : "無")
                    }
                }

                Section {
                    NavigationLink {
                        TrashView(onChange: {
                            onDocumentsChanged()
                            trashCount = FormlessStorage.trashItems().count
                        })
                    } label: {
                        LabeledContent("最近刪除", value: trashCount > 0 ? "\(trashCount)" : "無")
                    }
                } footer: {
                    Text("刪除的小工具會保留 \(FormlessStorage.trashRetentionDays) 天，期間可以復原。")
                }

                Section {
                    NavigationLink("使用說明") { HelpView() }
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .formlessScrollMinimizer(state: minimizeState)
            // 卡片沒有標題後，第一張卡片上方原本標題的位置空了出來：頂端留白改成和設計頁（頂端列到第一張卡片）相同。
            .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
            // 每次回到這一頁都重讀右邊的摘要（剛在下一層改過）。行事曆要建 EventKit 的資料庫，放到背景讀。
            .onAppear {
                fontCount = FormlessFontLibrary.installed().count
                trashCount = FormlessStorage.trashItems().count
            }
    }
}

/// 設定 › 編輯器：移動步進與鎖定畫布（原本在小工具設定，10/03 決定移到這裡）。
/// 10/05 起：移動步進也在屬性面板「版面」與「位置與大小」面板的方塊下方；鎖定畫布也在小工具設定，三處是同一個值。
struct EditorPreferencesView: View {
    @AppStorage("formless.nudgeStep") private var nudgeStep: Double = 10
    @AppStorage("formless.canvasLocked") private var canvasLocked = false

    var body: some View {
        List {
            Section {
                Picker("步進", selection: $nudgeStep) {
                    Text("小・1").tag(1.0)
                    Text("中・10").tag(10.0)
                    Text("大・50").tag(50.0)
                }
                Toggle("鎖定畫布", isOn: $canvasLocked)
            } footer: {
                Text("步進是調整圖層位置與大小時每次加減的數值；鎖定畫布後，不能上下拖曳改變畫布高度。")
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("編輯器")
    }
}

/// 挑選要讀哪幾本行事曆。行事曆 App 裡的打勾是它自己的顯示設定，系統沒有開放讀取，
/// 所以這裡要另外選一次。
struct CalendarPickerView: View {

    let onChange: () -> Void

    @State private var calendars: [EKCalendar] = []
    @State private var excluded: Set<String> = []

    private var grouped: [(String, [EKCalendar])] {
        Dictionary(grouping: calendars) { $0.source?.title ?? "其他" }
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        List {
            if calendars.isEmpty {
                Section {
                    Text("尚未取得行事曆權限，或沒有可用的行事曆。")
                        .foregroundStyle(.secondary)
                }
            }

            // 卡片不放標題（使用者規則）：帳號名稱改成跟在行事曆名稱後面的灰字（和「行程地點」同一種寫法），
            // 只有一個帳號時不顯示。
            Section {
                ForEach(grouped, id: \.0) { source, items in
                    ForEach(items, id: \.calendarIdentifier) { item in
                        Toggle(isOn: binding(for: item)) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(color(of: item))
                                    .frame(width: 10, height: 10)

                                Text(item.title)
                                if grouped.count > 1 {
                                    Text(source).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("行事曆來源")
        .task {
            calendars = FormlessEventsProvider.allCalendars()
            excluded = FormlessCalendarSettings.current().excluded
        }
    }

    private func binding(for item: EKCalendar) -> Binding<Bool> {
        Binding {
            !excluded.contains(item.calendarIdentifier)
        } set: { isOn in
            if isOn {
                excluded.remove(item.calendarIdentifier)
            } else {
                excluded.insert(item.calendarIdentifier)
            }

            var settings = FormlessCalendarSettings.current()
            settings.excluded = excluded
            FormlessCalendarSettings.save(settings)
            onChange()
        }
    }

    private func color(of item: EKCalendar) -> Color {
        guard let cgColor = item.cgColor else { return .accentColor }
        return Color(uiColor: UIColor(cgColor: cgColor))
    }
}


/// 行事曆類別的顯示名稱：左邊是行事曆本身的名稱，右邊輸入框是小工具上要顯示的名稱
/// （留空就用原本的名稱）。只列出「行事曆來源」有選取的行事曆。離開輸入框才儲存並更新小工具。
struct CalendarNamesView: View {

    let onChange: () -> Void

    @State private var calendars: [EKCalendar] = []
    @State private var names: [String: String] = [:]
    @State private var saved: [String: String] = [:]
    @FocusState private var focused: String?

    private var grouped: [(String, [EKCalendar])] {
        Dictionary(grouping: calendars) { $0.source?.title ?? "其他" }
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        List {
            if calendars.isEmpty {
                Section {
                    Text("尚未取得行事曆權限，或沒有可用的行事曆。")
                        .foregroundStyle(.secondary)
                }
            }

            // 卡片不放標題（使用者規則）：帳號名稱改成跟在行事曆名稱後面的灰字，只有一個帳號時不顯示。
            Section {
                ForEach(grouped, id: \.0) { source, items in
                    ForEach(items, id: \.calendarIdentifier) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(color(of: item))
                                .frame(width: 10, height: 10)
                            Text(item.title)
                                .lineLimit(1)
                            if grouped.count > 1 {
                                Text(source).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            TextField(item.title, text: binding(for: item))
                                .submitLabel(.done)
                                .focused($focused, equals: item.calendarIdentifier)
                                .formlessInputBox()
                                .frame(width: 170)
                        }
                    }
                }
            }
        }
        // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("類別名稱")
        // 離開欄位（按完成、點別處、換到另一格）或離開這一頁時儲存。
        .onChange(of: focused) { _, _ in save() }
        .onDisappear(perform: save)
        .task {
            let excluded = FormlessCalendarSettings.current().excluded
            calendars = FormlessEventsProvider.allCalendars().filter { !excluded.contains($0.calendarIdentifier) }
            names = FormlessCalendarNameSettings.current().names
            saved = names
        }
    }

    private func binding(for item: EKCalendar) -> Binding<String> {
        Binding {
            names[item.calendarIdentifier] ?? ""
        } set: { value in
            names[item.calendarIdentifier] = value
        }
    }

    /// 前後空白去掉；留空或和原本名稱相同就不另存（回到原本的名稱）。
    private func save() {
        var cleaned: [String: String] = [:]
        for calendar in calendars {
            let value = (names[calendar.calendarIdentifier] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != calendar.title { cleaned[calendar.calendarIdentifier] = value }
        }
        // 沒列出來的行事曆（在「行事曆來源」關掉的）保留原本的設定。
        for (id, value) in saved where !calendars.contains(where: { $0.calendarIdentifier == id }) { cleaned[id] = value }
        guard cleaned != saved else { return }
        saved = cleaned
        FormlessCalendarNameSettings.save(FormlessCalendarNameSettings(names: cleaned))
        onChange()
    }

    private func color(of item: EKCalendar) -> Color {
        guard let cgColor = item.cgColor else { return .accentColor }
        return Color(uiColor: UIColor(cgColor: cgColor))
    }
}


/// Wait for the previous system sheet to release the foreground; never add an arbitrary delay.
@MainActor
enum FormlessPermissionSequence {
    static func run(_ requests: [@MainActor () async -> Void]) async {
        for request in requests {
            let changes = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
            if UIApplication.shared.applicationState != .active {
                for await _ in changes {
                    if Task.isCancelled { return }
                    if UIApplication.shared.applicationState == .active { break }
                }
            }
            guard !Task.isCancelled else { return }
            await request()
        }
    }
}

/// 導覽列中央的搜尋欄，取代原本獨立一列的搜尋。
struct FormlessSearchField: View {
    @Binding var text: String
    let prompt: String
    /// 由外面控制的焦點（例如展開時立刻叫出鍵盤）；沒給就用自己的。
    var focus: FocusState<Bool>.Binding? = nil
    @FocusState private var ownFocus: Bool
    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focusBinding)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38)
        .formlessGlass(.regular.interactive(), in: .capsule)
        .contentShape(Capsule())
        .onTapGesture { focusBinding.wrappedValue = true }
    }
}

/// 追蹤鍵盤是否顯示，讓與輸入無關的浮動列在打字時讓位。
@MainActor
final class FormlessKeyboardObserver: ObservableObject {
    @Published var visible = false
    /// 鍵盤（含系統工具列）在視窗裡佔的高度；收起時歸零。
    @Published var height: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []
    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let height = end.map { max(0, FormlessSafeArea.windowHeight - $0.minY) } ?? 0
                // 用鍵盤自己的時長包住狀態改變：畫布縮小、下方面板上移才會和鍵盤一起滑，而不是先跳位再等鍵盤升上來。
                withAnimation(Self.animation(matching: note)) {
                    self?.visible = true
                    self?.height = height
                }
            }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // 收起時同樣帶動畫，和出現時對稱；原本這裡直接改值，內容是瞬間跳回原位。
                withAnimation(Self.animation(matching: note)) {
                    self?.visible = false
                    self?.height = 0
                }
            }
        })
    }

    /// 鍵盤推動畫面的速度和整個 app 其他上推／下回的動畫一致（`FormlessMotion.push`），出現與收起同速；
    /// 系統鍵盤自己的時長（模擬器量到 0.38 秒）比這慢，所以不跟著它。
    private static func animation(matching note: Notification) -> Animation {
        FormlessMotion.push
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// 整個 app「上推／下回」類動畫的共用速度：鍵盤推動畫面、選取模式的工具列推開畫布與清單，出現和收起同速。
enum FormlessMotion {
    static let pushDuration = FormlessDesign.Motion.pushDuration
    /// 和 UIKit 的 `.curveEaseOut` 同一條曲線，SwiftUI 與 UIKit 兩邊的推動看起來一致。
    static let push = FormlessDesign.Motion.push
}

/// 自己做鍵盤避讓：在 keyboardWillShow 當下直接捲動輸入框所在的清單或表單，欄位與鍵盤同一個動畫上移，
/// 輸入框底部固定停在鍵盤頂端上方 `margin`。整個 App 共用這一套（使用者要求所有叫出鍵盤的地方推的幅度一致，
/// 比照屬性面板的數字輸入框）；原本只有編輯器用，其他畫面交給系統，系統只推到剛好看得到輸入框，首頁改名貼著鍵盤。
@MainActor
final class FormlessKeyboardAvoider {
    static let shared = FormlessKeyboardAvoider()
    /// 輸入框底部到鍵盤頂端的距離。
    static let margin = FormlessDesign.Space.keyboardGap
    /// 固定位置的面板裡的表單（見 `FormlessFixedPanelScroll`）。
    static let fixedScrolls = NSHashTable<UIScrollView>.weakObjects()
    /// 自己捲的捲動區（見 `FormlessSelfManagedKeyboardScroll`）：SwiftUI 的 ScrollView 會把這裡設的內距與位移蓋回去，
    /// 所以只算出「欄位還要再往上多少」交給它自己捲。
    static let selfManaged = NSMapTable<UIScrollView, FormlessKeyboardClient>.weakToWeakObjects()
    private weak var activeClient: FormlessKeyboardClient?
    private weak var scroll: UIScrollView?
    private var originalInset: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []

    /// App 啟動時呼叫一次：全域監聽鍵盤，任何畫面的輸入框都走這裡。
    static func start() {
        let avoider = shared
        guard avoider.tokens.isEmpty else { return }
        let center = NotificationCenter.default
        avoider.tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { avoider.keyboardWillShow(note) }
        })
        avoider.tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { avoider.keyboardWillHide(note) }
        })
    }
    /// 鍵盤已經在畫面上：在欄位之間切換時系統會再送一次 willShow，這時版面早已被鍵盤推好，不能再算一次版面位移。
    private var keyboardShown = false
    /// 鍵盤出現時，編輯器版面（畫布縮放、頂端留白）會讓表單頂端往下移多少：輸入鍵盤高度，回傳位移（往下為正）。
    /// 避讓是在 keyboardWillShow 當下用推動前的版面算的，不加這段的話欄位會差這麼多被鍵盤蓋住。
    var editorLayoutShift: ((CGFloat) -> CGFloat)?

    func keyboardWillShow(_ note: Notification) {
        guard let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let field = Self.firstResponder(),
              let scroll = Self.enclosingScrollView(of: field),
              let window = scroll.window else { return }
        if let client = Self.selfManaged.object(forKey: scroll) {
            keyboardShown = true
            activeClient = client
            let fieldFrame = field.convert(field.bounds, to: window)
            client.onShow(fieldFrame.maxY + Self.margin - end.minY)
            return
        }
        // 編輯器本身的表單與清單忽略鍵盤安全區，底部內距由這裡補；其他畫面與彈出面板保留系統的鍵盤安全區
        // （清單照樣能捲到最底），這裡只調捲動位置。兩邊都補的話會推兩次，鍵盤升完系統又再捲一次，看起來慢半拍。
        let managesInset = editorLayoutShift != nil && !Self.isInPresentedSheet(scroll)

        let wasShown = keyboardShown
        keyboardShown = true

        if managesInset, self.scroll !== scroll {
            self.scroll = scroll
            originalInset = scroll.contentInset.bottom
        }
        let scrollFrame = scroll.convert(scroll.bounds, to: window)
        let overlap = max(0, scrollFrame.maxY - end.minY)
        let margin = Self.margin
        let fieldRect = field.convert(field.bounds, to: scroll)
        let keyboardHeight = max(0, FormlessSafeArea.windowHeight - end.minY)
        let shift = wasShown || !managesInset || Self.fixedScrolls.contains(scroll) ? 0 : (editorLayoutShift?(keyboardHeight) ?? 0)
        let visibleHeight = scroll.bounds.height - overlap - shift
        var offset = scroll.contentOffset
        let wantedMaxY = offset.y + visibleHeight - margin
        if fieldRect.maxY > wantedMaxY {
            offset.y = fieldRect.maxY - visibleHeight + margin
        } else if fieldRect.minY < offset.y + margin {
            offset.y = max(0, fieldRect.minY - margin)
        }

        // 底部內距：鍵盤蓋住的高度（再留一點邊距），和原本的內距取大的，不是相加。原本的內距（清單給右下角＋按鈕與安全區、
        // 表單給分類列的留白）本來就在鍵盤底下；相加會讓系統以為可見範圍只剩一小條，鍵盤升完後 UITextField 會自己
        // 再把欄位捲一次（scrollTextFieldToVisibleIfNecessary），看起來就是鍵盤先出來、畫面才慢半拍往上推。
        guard managesInset else {
            guard offset != scroll.contentOffset else { return }
            UIView.animate(withDuration: FormlessMotion.pushDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                scroll.contentOffset = offset
            }
            return
        }
        let keyboardInset = max(self.originalInset, overlap + 12)
        UIView.animate(withDuration: FormlessMotion.pushDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            scroll.contentInset.bottom = keyboardInset
            scroll.verticalScrollIndicatorInsets.bottom = overlap
            scroll.contentOffset = offset
        }
    }

    func keyboardWillHide(_ note: Notification) {
        keyboardShown = false
        activeClient?.onHide()
        activeClient = nil
        guard let scroll else { return }
        let inset = originalInset
        self.scroll = nil
        // 內距不是可動畫屬性：在動畫區塊裡先縮回內距，捲動視圖會立刻把超出範圍的位移夾回去，
        // 內容就瞬間跳回原位，和出現時的平滑上推不對稱。先只動畫位移，動畫結束才還原內距。
        let maxOffset = max(-scroll.adjustedContentInset.top,
                            scroll.contentSize.height - scroll.bounds.height + inset)
        let target = min(scroll.contentOffset.y, maxOffset)
        UIView.animate(withDuration: FormlessMotion.pushDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            scroll.contentOffset.y = target
        }, completion: { _ in
            scroll.contentInset.bottom = inset
            scroll.verticalScrollIndicatorInsets.bottom = 0
        })
    }

    private static func firstResponder() -> UIView? {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let found = findFirstResponder(in: window) { return found }
            }
        }
        return nil
    }

    private static func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let found = findFirstResponder(in: child) { return found }
        }
        return nil
    }

    private static func isInPresentedSheet(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller.presentingViewController != nil }
            responder = current.next
        }
        return false
    }

    private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var current = view.superview
        while let candidate = current {
            if let scroll = candidate as? UIScrollView, scroll.bounds.height > 80 { return scroll }
            current = candidate.superview
        }
        return nil
    }
}

/// 復原／重做：點一下執行，按住 0.3 秒彈出編輯紀錄，整顆按鈕都是長按範圍（不能按的那一顆也可以長按）。
/// 自己處理觸控而不用系統 Menu 的長按：系統的要按將近一秒、而且只認圖示那一小塊。
struct EditorHistoryControls: View {
    @ObservedObject var model: EditorModel
    /// 執行前先收鍵盤等。
    var beforeAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            EditorHistoryButton(symbol: "arrow.uturn.backward", label: "復原", enabled: model.canUndo,
                                action: { beforeAction(); model.undo() }, hold: showHistory)
            EditorHistoryButton(symbol: "arrow.uturn.forward", label: "重做", enabled: model.canRedo,
                                action: { beforeAction(); model.redo() }, hold: showHistory)
        }
    }

    private func showHistory(from anchor: UIView) {
        EditorHistoryPresenter.shared.present(from: anchor, model: model) { index in
            beforeAction()
            model.jumpToHistory(index)
        }
    }
}

private struct EditorHistoryButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    let hold: (UIView) -> Void
    @State private var pressing = false
    @State private var holdFired = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(pressing && enabled ? FormlessDesign.Press.glyphOpacity : 1)
            .animation(FormlessDesign.Motion.press, value: pressing)
            // 不能按（變淡）的那一顆也接觸控：長按一樣要能叫出編輯紀錄，只有點一下的動作不執行。
            .overlay {
                FormlessTouchObserver(onBegan: { view in
                    pressing = true
                    holdFired = false
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        holdFired = true
                        pressing = false
                        FormlessHaptics.light()
                        hold(view)
                    }
                }, onEnded: { inside in
                    holdTask?.cancel()
                    pressing = false
                    if !holdFired && inside && enabled { action() }
                })
            }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// 編輯紀錄用 UIKit 的 popover 呈現，不用 SwiftUI 的 `.popover`：後者關掉後緊接著再長按常常沒反應、點外面關閉也常要點兩下。
/// UIKit 的 popover 點外面一下就關、關閉中再叫會等它關完再開。
@MainActor final class EditorHistoryPresenter: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = EditorHistoryPresenter()
    private weak var presented: UIViewController?

    func present(from anchor: UIView, model: EditorModel, onJump: @escaping (Int) -> Void) {
        if let presented {
            if presented.isBeingDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.present(from: anchor, model: model, onJump: onJump)
                }
            }
            return
        }
        guard let window = anchor.window, var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        model.resolveHistoryDetails()
        let steps = Array(model.historySteps.reversed().prefix(EditorHistoryList.maxVisibleRows))
        let rowsHeight = steps.reduce(CGFloat(0)) { $0 + EditorHistoryList.height(of: $1) }
        let hosting = UIHostingController(rootView: EditorHistoryList(model: model) { [weak self] index in
            onJump(index)
            self?.dismiss()
        })
        hosting.modalPresentationStyle = .popover
        hosting.preferredContentSize = CGSize(width: EditorHistoryList.width,
                                              height: EditorHistoryList.headerHeight + rowsHeight)
        hosting.view.backgroundColor = .clear
        guard let popover = hosting.popoverPresentationController else { return }
        popover.sourceView = anchor
        popover.sourceRect = anchor.bounds
        popover.permittedArrowDirections = .up
        popover.delegate = self
        presented = hosting
        presenter.present(hosting, animated: true)
    }

    func dismiss() { presented?.dismiss(animated: true) }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}

/// 表單裡的選值選單：系統選單（UIMenu，清單外觀和系統一樣），但畫面上看到的標籤是表單裡一般的 SwiftUI 內容，
/// 選單掛在疊在標籤上的透明按鈕。系統開關選單時會把「來源」藏起來、交給轉場層畫，表單捲動時它不跟著動
/// （使用者回報：對齊基準關掉選單後立刻捲動會晚一秒、改寫後又消失兩秒）。來源是透明按鈕，被藏、被轉場都看不出來，
/// 看得到的標籤從頭到尾都留在表單裡、跟著捲動。
struct FormlessMenuOption: Identifiable {
    let id: AnyHashable
    let title: String
}

struct FormlessOptionMenu<Label: View>: View {
    let options: [FormlessMenuOption]
    let selection: AnyHashable?
    let onSelect: (AnyHashable) -> Void
    /// 接在選項後面的其他段落（字型選單的匯入字型與「管理字型…」）。
    var extra: (() -> [UIMenuElement])? = nil
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .overlay { FormlessMenuTrigger(options: options, selection: selection, onSelect: onSelect, extra: extra) }
    }
}

/// 透明的選單按鈕：只負責接點擊、叫出系統選單。
struct FormlessMenuTrigger: UIViewRepresentable {
    let options: [FormlessMenuOption]
    let selection: AnyHashable?
    let onSelect: (AnyHashable) -> Void
    var extra: (() -> [UIMenuElement])? = nil

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        let items: [UIMenuElement] = options.map { option in
            UIAction(title: option.title, state: option.id == selection ? .on : .off) { _ in onSelect(option.id) }
        }
        guard let extra else {
            button.menu = UIMenu(children: items)
            return
        }
        // 有其他段落時，原本的選項自成一段（中間有分隔線），其他段落每次打開選單時才建，內容永遠是最新的。
        button.menu = UIMenu(children: [UIMenu(options: .displayInline, children: items),
                                        UIDeferredMenuElement.uncached { completion in completion(extra()) }])
    }
}

/// 長按復原／重做出現的編輯紀錄（像 Snapseed 的檢視編輯）：由新到舊排列並編號，勾勾是目前所在的一步，
/// 勾勾以上是可重做的步驟（灰字），點任一步直接跳過去。只記這次開啟編輯器以來的操作。不放任何說明文字。
/// 版面比照系統選單：每列 50 pt（有參數說明的列 62 pt，說明是名稱下方的一行小字，同系統選單的副標）、左右 20 pt、
/// 整寬分隔線；9 步以內整份排出、完全不可捲動，超過才可捲。
private struct EditorHistoryList: View {
    @ObservedObject var model: EditorModel
    let onJump: (Int) -> Void
    static let width: CGFloat = 300
    static let headerHeight: CGFloat = 50
    static let rowHeight: CGFloat = 50
    static let detailedRowHeight: CGFloat = 62
    static let maxVisibleRows = 9
    static func height(of step: EditorModel.HistoryStep) -> CGFloat { step.detail == nil ? rowHeight : detailedRowHeight }

    var body: some View {
        let steps = Array(model.historySteps.reversed())
        VStack(spacing: 0) {
            Text("編輯紀錄")
                .font(.headline)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.headerHeight)
                .overlay(alignment: .bottom) { Divider() }
            if steps.count > Self.maxVisibleRows {
                ScrollView { rows(steps) }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                rows(steps)
            }
        }
        .frame(width: Self.width)
    }

    private func rows(_ steps: [EditorModel.HistoryStep]) -> some View {
        let current = model.historyIndex
        return VStack(spacing: 0) {
            ForEach(steps) { step in
                Button { onJump(step.index) } label: {
                    HStack(spacing: 16) {
                        Text(step.index == 0 ? "起" : "\(step.index)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.body)
                                .foregroundStyle(step.index > current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 12)
                        if step.index == current {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: Self.height(of: step))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    if step.index != steps.last?.index { Divider() }
                }
            }
        }
    }
}

/// 回報整塊矩形範圍內的按下／放開（按下時帶著這塊視圖，放開時告知手指是否還在範圍內）；鍵盤開著也收得到。
struct FormlessTouchObserver: UIViewRepresentable {
    var onBegan: (UIView) -> Void
    var onEnded: (Bool) -> Void

    final class TouchView: FormlessKeyboardPassThroughView, FormlessPanelShieldPassThrough {
        var onBegan: (UIView) -> Void = { _ in }
        var onEnded: (Bool) -> Void = { _ in }
        private var tracking = false
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !tracking else { return }
            tracking = true
            onBegan(self)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracking else { return }
            tracking = false
            let inside = touches.first.map { bounds.insetBy(dx: -12, dy: -12).contains($0.location(in: self)) } ?? false
            onEnded(inside)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracking else { return }
            tracking = false
            onEnded(false)
        }
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.onBegan = onBegan
        view.onEnded = onEnded
        return view
    }
    func updateUIView(_ view: TouchView, context: Context) {
        view.onBegan = onBegan
        view.onEnded = onEnded
    }
}

/// 真實的狀態列高度。GeometryReader 在導覽列底下讀到的安全區不可靠，改由視窗取得。
enum FormlessSafeArea {
    @MainActor static var top: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        return window?.safeAreaInsets.top ?? 59
    }
    @MainActor static var bottom: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        return window?.safeAreaInsets.bottom ?? 34
    }
    /// 視窗高度：畫布可拉的上限（螢幕一半）用。
    @MainActor static var windowHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        return window?.bounds.height ?? 844
    }
    /// 視窗寬度：量到實際列寬之前的估計值用。
    @MainActor static var windowWidth: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        return window?.bounds.width ?? 390
    }
}

/// 首頁清單的小工具縮圖快取。
/// 清單列原本每次捲進畫面都要即時繪製整份設計的所有圖層，四十幾層就會掉影格；
/// 改成算一次存成圖，之後直接貼圖。
@MainActor
final class FormlessThumbnailCache {
    static let shared = FormlessThumbnailCache()
    private var images: [String: UIImage] = [:]

    private func key(_ document: FormlessDocument, size: CGSize) -> String {
        "\(document.hashValue)@\(Int(size.width))x\(Int(size.height))"
    }

    func clear() { images.removeAll() }

    func cached(_ document: FormlessDocument, size: CGSize) -> UIImage? {
        images[key(document, size: size)]
    }

    @discardableResult
    func image(for document: FormlessDocument, live: FormlessLiveData, size: CGSize) -> UIImage? {
        let id = key(document, size: size)
        if let existing = images[id] { return existing }
        guard size.width > 0, size.height > 0 else { return nil }

        FormlessRenderContext.prepare(document)
        FormlessRenderContext.synchronousAssets = true
        defer { FormlessRenderContext.synchronousAssets = false }

        let renderer = ImageRenderer(
            content: FormlessDocumentView(document: document, live: live)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = max(2, UITraitCollection.current.displayScale)
        guard let image = renderer.uiImage else { return nil }
        if images.count > 120 { images.removeAll() }
        images[id] = image
        return image
    }
}

/// 清單列用的縮圖：有快取就直接顯示，沒有才算一次。
struct FormlessDocumentThumbnail: View {
    let document: FormlessDocument
    let live: FormlessLiveData
    let size: CGSize
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Color(formlessHex: document.backgroundColorHex, fallback: "#F4F4F4")
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            if image == nil { image = FormlessThumbnailCache.shared.image(for: document, live: live, size: size) }
        }
        .task(id: document) {
            image = FormlessThumbnailCache.shared.image(for: document, live: live, size: size)
        }
    }
}


/// 最近刪除：保留期內可復原，也可以提前永久刪除。
struct TrashView: View {
    let onChange: () -> Void
    @State private var items: [FormlessTrashItem] = []
    @State private var confirmEmpty = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if items.isEmpty {
                Section {
                    Text("沒有最近刪除的小工具。")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(items) { item in
                HStack(spacing: 10) {
                    // 名稱下面有第二行：名稱 headline、說明 subheadline 灰字（和首頁的小工具卡相同）。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.document.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(item.document.family.displayName + " · 還有 \(item.remainingDays) 天")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: FormlessDesign.Space.valueGap)
                    Button("復原") { restore(item) }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, FormlessDesign.Space.rowExtra)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("永久刪除", systemImage: "trash", role: .destructive) { remove(item) }
                }
                .contextMenu {
                    Button("復原", systemImage: "arrow.uturn.backward") { restore(item) }
                    Button("永久刪除", systemImage: "trash", role: .destructive) { remove(item) }
                }
            }
        }
        // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("最近刪除")
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("全部清除", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .confirmationDialog("永久刪除全部？", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("永久刪除", role: .destructive) {
                FormlessStorage.emptyTrash()
                reload()
                FormlessHaptics.rigid()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除後無法復原。")
        }
        .alert("無法復原", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("確定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { reload() }
    }

    private func reload() {
        items = FormlessStorage.trashItems()
    }

    private func restore(_ item: FormlessTrashItem) {
        do {
            try FormlessStorage.restoreFromTrash(id: item.id)
            reload()
            onChange()
            FormlessHaptics.success()
        } catch {
            errorMessage = error.localizedDescription
            FormlessHaptics.warning()
        }
    }

    private func remove(_ item: FormlessTrashItem) {
        FormlessStorage.removeFromTrash(id: item.id)
        reload()
        FormlessHaptics.rigid()
    }
}

/// 返回鍵隱藏後，系統會一併停用導覽堆疊的左滑返回；這裡把手勢接回來。
/// 每個頁面保有自己的 delegate，避免設定頁更新蓋掉編輯器的手勢停用狀態。
/// 根頁面與轉場途中不啟動，避免連續返回破壞導覽堆疊。
struct FormlessPopGestureEnabler: UIViewControllerRepresentable {
    let isEnabled: Bool
    /// 觸控當下再問一次（例如畫面上有面板開著就不返回）。
    var blocked: () -> Bool = { false }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.popDelegate.isEnabled = isEnabled
        controller.popDelegate.blocked = blocked
        controller.hook()
    }

    final class Controller: UIViewController {
        let popDelegate = FormlessPopGestureDelegate()
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            hook()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hook()
        }
        func hook() {
            guard let navigation = navigationController,
                  let gesture = navigation.interactivePopGestureRecognizer else { return }
            var owner: UIViewController = self
            while let parent = owner.parent, parent !== navigation { owner = parent }
            guard navigation.topViewController === owner else { return }
            popDelegate.navigation = navigation
            gesture.delegate = popDelegate
            gesture.isEnabled = true
        }
    }
}

final class FormlessPopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = true
    var blocked: () -> Bool = { false }
    weak var navigation: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled && !blocked() && (navigation?.viewControllers.count ?? 0) > 1 && navigation?.transitionCoordinator == nil
    }
}

/// 編輯器的畫布從狀態列下方開始，導覽列只有右上角幾顆玻璃按鈕浮在畫布上。系統導覽列會接下整條範圍的點擊，
/// 畫布最上面那一段（和按鈕同一排）因此點不到圖層（使用者回報）。掛上這個元件的畫面顯示時，
/// 導覽列只接落在按鈕上的點擊，空白處交給底下的畫面；離開畫面就恢復系統原本的行為。
struct FormlessNavigationBarPassThrough: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            UINavigationBar.formlessInstallPassThrough()
            UINavigationBar.formlessPassThroughBar = navigationController?.navigationBar
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if UINavigationBar.formlessPassThroughBar === navigationController?.navigationBar {
                UINavigationBar.formlessPassThroughBar = nil
            }
        }
    }
}

extension UINavigationBar {
    /// 目前讓空白處點擊穿過去的導覽列（同時只有編輯器這一個）。
    @MainActor static weak var formlessPassThroughBar: UINavigationBar?
    @MainActor private static var formlessPassThroughInstalled = false

    /// 只換導覽列這個類別的 hitTest：先把 UIView 的實作加到 UINavigationBar 身上再交換，不影響其他 view。
    @MainActor static func formlessInstallPassThrough() {
        guard !formlessPassThroughInstalled else { return }
        formlessPassThroughInstalled = true
        let original = #selector(UIView.hitTest(_:with:))
        let replacement = #selector(UINavigationBar.formlessHitTest(_:with:))
        guard let originalMethod = class_getInstanceMethod(UINavigationBar.self, original),
              let replacementMethod = class_getInstanceMethod(UINavigationBar.self, replacement) else { return }
        if class_addMethod(UINavigationBar.self, original, method_getImplementation(replacementMethod),
                           method_getTypeEncoding(replacementMethod)) {
            class_replaceMethod(UINavigationBar.self, replacement, method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    /// 交換後這裡呼叫自己就是系統原本的 hitTest。落點在按鈕（系統按鈕、放進導覽列的 SwiftUI 內容）上照常；
    /// 其餘只是導覽列的空白底層，回 nil 讓觸控落到底下的畫面。
    @objc fileprivate func formlessHitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = formlessHitTest(point, with: event)
        guard self === UINavigationBar.formlessPassThroughBar, let hit else { return hit }
        // 按鈕是 _UIButtonBarButton（UIControl），外層是玻璃底座的 PlatterContainerHostingView；空白處是 NavigationBarContentView。
        var view: UIView? = hit
        while let current = view, current !== self {
            if current is UIControl || NSStringFromClass(type(of: current)).contains("HostingView") { return hit }
            view = current.superview
        }
        return nil
    }
}

final class EditorCompactGlassTabBar: UITabBar {
    private static let visualScaleY: CGFloat = 0.88
    override func layoutSubviews() {
        super.layoutSubviews()

        // 只減少玻璃容器高度，再還原文字的縱向比例，避免字形被壓扁。
        layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: Self.visualScaleY))
        restoreTextScale(in: self)
    }

    private func restoreTextScale(in view: UIView) {
        for subview in view.subviews {
            if let label = subview as? UILabel {
                label.layer.setAffineTransform(
                    CGAffineTransform(scaleX: 1, y: 1 / Self.visualScaleY)
                )
            }
            restoreTextScale(in: subview)
        }
    }
}

/// 承載分類列的容器：SwiftUI 只排這個容器，分頁列本身是它的子視圖，縮放的 transform 只動子視圖，
/// 不會被 SwiftUI 重排時覆寫。
final class EditorCategoryTabBarContainer: UIView {
    let bar = EditorCompactGlassTabBar()
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // 尺寸完全轉發給分頁列：SwiftUI 量到的是 UITabBar 自己的原生尺寸，和原本直接承載時一樣，
    // 分頁列不會被硬塞進外層的 48 pt 而壓扁。
    override var intrinsicContentSize: CGSize { bar.intrinsicContentSize }
    override func sizeThatFits(_ size: CGSize) -> CGSize { bar.sizeThatFits(size) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize { bar.systemLayoutSizeFitting(targetSize) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                          withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {
        bar.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
                                    verticalFittingPriority: verticalFittingPriority)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // 用 bounds／center 而不是 frame：帶著 transform 時設 frame 會失真。
        bar.bounds = bounds
        bar.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// 使用與首頁底部分頁相同的系統 UITabBar，保留原生 Liquid Glass 動態與選取染色。
struct EditorCategoryTabBar: UIViewRepresentable {
    @Binding var selection: String
    let titles: [String]
    /// 整條列的縮放狀態：把分頁列的 layer 登記給它，縮放（sublayerTransform 的彈簧動畫）由它統一套用。
    var minimizeState: FormlessMinimizeState? = nil
    /// 使用者點了任一分頁時另外通知外層（縮小狀態下用來順便展開）；不影響分頁列本身。
    var onSelect: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, titles: titles) }
    func makeUIView(context: Context) -> EditorCategoryTabBarContainer {
        let container = EditorCategoryTabBarContainer()
        let bar = container.bar
        minimizeState?.register { [weak bar] in bar?.layer }
        bar.delegate = context.coordinator
        bar.itemPositioning = .fill
        bar.tintColor = FormlessDesign.Palette.accentUI
        bar.unselectedItemTintColor = .label
        bar.items = items()
        bar.selectedItem = bar.items?[titles.firstIndex(of: selection) ?? 0]
        bar.accessibilityIdentifier = "editor-category-tabs"
        return container
    }
    private func items() -> [UITabBarItem] {
        titles.enumerated().map { index, title in
            let item = UITabBarItem(title: title, image: nil, tag: index)
            item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -10)
            item.setTitleTextAttributes([
                .font: UIFont.systemFont(ofSize: 17, weight: .regular),
                .foregroundColor: UIColor.label
            ], for: .normal)
            item.setTitleTextAttributes([
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: FormlessDesign.Palette.accentUI
            ], for: .selected)
            return item
        }
    }
    func updateUIView(_ container: EditorCategoryTabBarContainer, context: Context) {
        let bar = container.bar
        context.coordinator.selection = $selection
        context.coordinator.titles = titles
        context.coordinator.onSelect = onSelect
        if bar.items?.compactMap(\.title) != titles { bar.items = items() }
        guard !context.coordinator.handlingSelection else { return }
        let index = titles.firstIndex(of: selection) ?? 0
        if bar.selectedItem?.tag != index { bar.selectedItem = bar.items?[index] }
    }
    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<String>
        var titles: [String]
        var onSelect: () -> Void = {}
        var handlingSelection = false
        init(selection: Binding<String>, titles: [String]) {
            self.selection = selection
            self.titles = titles
        }
        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            // 玻璃位移交給 UIKit 原生處理；內容在點擊當下立即切換。
            // 分頁列所在容器不會因內容切換而重建，原生動畫才能完整播完。
            commit(item)
            onSelect()
        }
        private func commit(_ item: UITabBarItem) {
            guard titles.indices.contains(item.tag) else { return }
            handlingSelection = true
            selection.wrappedValue = titles[item.tag]
            DispatchQueue.main.async { [weak self] in self?.handlingSelection = false }
        }
    }
}

/// 分頁列／分類列的縮放狀態。獨立的 ObservableObject，只讓那條列本身觀察，捲動中反覆縮放不會重繪整個畫面。
@MainActor final class FormlessMinimizeState: ObservableObject {
    /// 刻意不用 @Published：縮放是直接套在分頁列的圖層上，沒有任何畫面讀這個值。原本它一變，
    /// 擁有它的整個首頁（三個分頁一起）或分類列就重畫一次：捲到縮小的那一刻、縮小後切換分頁時，
    /// 都和分頁切換、捲動擠在同一格裡做，縮小過之後切換分頁就容易卡一下。
    private(set) var minimized = false
    /// 縮小時整條列的縮放比例（Instagram 量起來約 0.83～0.85）。
    static let minimizedScale: CGFloat = 0.85
    /// 要縮放的圖層（分頁列的 layer），由分頁列自己登記；每次狀態改變或捲動事件都重新套用一次，
    /// 分頁列被系統重建、動畫被打斷時才會自己修正回來，不會卡在半途或忘了縮。
    private var layers: [() -> CALayer?] = []

    func register(_ resolve: @escaping () -> CALayer?) {
        layers.append(resolve)
        layers.removeAll { $0() == nil }
        apply()
    }
    func set(_ minimized: Bool) {
        if self.minimized != minimized { self.minimized = minimized }
        apply()
    }
    /// 點分頁（切換分頁／分類）時用：直接定格在原尺寸，不跑縮放動畫。系統的分頁切換（鏡片滑動）動畫會和縮放的彈簧
    /// 動畫同時重繪整條玻璃，兩個疊在一起就卡；例如在捲不動的頁面回彈、分類列正在恢復時立刻點別的分類。
    func restoreForTabSwitch() {
        minimized = false
        for resolve in layers {
            guard let layer = resolve() else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "formlessMinimize")
            layer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()
        }
    }
    /// 把目前狀態套到所有登記的圖層；已經在正確狀態（或正在往正確狀態動畫）的圖層不動。
    func apply() {
        let scale = minimized ? Self.minimizedScale : 1
        for resolve in layers { if let layer = resolve() { Self.applyScale(scale, to: layer) } }
    }

    /// 把整條列的縮放套到 layer 的 sublayerTransform（縮的是所有子圖層：玻璃、標題、鏡片），
    /// 以 Core Animation 彈簧過渡。不用 view 的 transform：UITabBar 會在某些時機自己把 transform 重設回 1。
    /// 冪等：目標相同且已到位、或正在往同一目標動畫，就不重來；否則從目前畫面上的值接續動畫，不會卡在半途。
    static func applyScale(_ scale: CGFloat, to layer: CALayer, animated: Bool = true) {
        let key = "formlessMinimize"
        if let inFlight = layer.animation(forKey: key), let heading = inFlight.value(forKey: "formlessTargetScale") as? CGFloat,
           abs(heading - scale) < 0.001 { return }
        let target = CATransform3DMakeScale(scale, scale, 1)
        let current = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        let settled = abs(current.m11 - scale) < 0.002 && abs(layer.sublayerTransform.m11 - scale) < 0.002
        if settled && layer.animation(forKey: key) == nil { return }
        layer.removeAnimation(forKey: key)
        layer.sublayerTransform = target
        guard animated else { return }
        let spring = CASpringAnimation(perceptualDuration: 0.28, bounce: 0.12)
        spring.keyPath = "sublayerTransform"
        spring.fromValue = current
        spring.toValue = target
        spring.duration = spring.settlingDuration
        spring.setValue(scale, forKey: "formlessTargetScale")
        layer.add(spring, forKey: key)
    }
}

/// 內容往上捲（離開頂端）就把對應的分頁列縮小，回到最頂端才放大；中途反向捲不會放大。
/// 縮小：捲動中（手指按著或慣性）位移離開頂端 10 pt 就縮，不看方向、不看速度。
/// 放大：位移回到離頂端 6 pt 以內就放大，不等捲動停下；捲動停止時再看一次，補上幾何回報漏掉的最後幾筆。
/// 回頂端提前放大：慣性往頂端滑時，依系統減速率推算會停在頂端就先放大，這一段慣性結束前不再縮小。
/// 其他回到預設狀態的操作（切換分類、切換首頁分頁、進出屬性面板）由外面直接呼叫 `set(false)`。
struct FormlessScrollMinimizer: ViewModifier {
    let state: FormlessMinimizeState?
    @State private var tracker = Tracker()
    /// 追蹤用的參考型別：更新它不會讓頁面重繪。
    /// 手指按下／放開與慣性狀態以底下真正的 UIScrollView 為準（SwiftUI 的 onScrollPhaseChange 在某些頁面完全不回報，
    /// 例如首頁「設定」的 Form），SwiftUI 的 phase 只當備援。
    final class Tracker: NSObject {
        var phaseScrolling = false
        var phaseDecelerating = false
        /// 已判定這次放手（或這段慣性）會停在頂端而提前放大；到下一次手指按下前不再縮小。
        var holdRestored = false
        var lastOffset: CGFloat = 0
        var lastTime: TimeInterval = 0
        var contentHeight: CGFloat = -1
        var containerHeight: CGFloat = -1
        /// 上次搜尋 UIScrollView 的時間：找不到時不要每個捲動事件都掃一次視圖樹。
        var lastSearch: TimeInterval = 0
        weak var scrollView: UIScrollView?
        weak var probe: FormlessScrollViewProbe.ProbeView?
        var onRelease: ((UIScrollView, UIPanGestureRecognizer) -> Void)?

        var scrolling: Bool { phaseScrolling || (scrollView.map { $0.isDragging || $0.isDecelerating } ?? false) }
        var decelerating: Bool { phaseDecelerating || (scrollView.map { $0.isDecelerating && !$0.isTracking } ?? false) }

        /// 候選的 UIScrollView 必須和 SwiftUI 回報的捲動幾何同尺寸，才確定是這個頁面的那一個。
        func matches(_ candidate: UIScrollView) -> Bool {
            containerHeight > 0
                && abs(candidate.bounds.height - containerHeight) < 1
                && abs(candidate.contentSize.height - contentHeight) < 1
        }
        func attach(_ candidate: UIScrollView) {
            guard candidate !== scrollView else { return }
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
            scrollView = candidate
            candidate.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
            // iOS 表格的標準行為：手指碰到後先等一下，確認不是要捲動才把觸控交給裡面的控制項（滑桿、方向鍵）；
            // 手指一開始就在移動則直接捲動，從滑桿或按鈕上開始的上下滑動不會先被它們抓去。
            candidate.delaysContentTouches = true
            candidate.canCancelContentTouches = true
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            switch gesture.state {
            case .began: holdRestored = false
            case .ended, .cancelled: onRelease?(scrollView, gesture)
            default: break
            }
        }
    }
    struct Sample: Equatable {
        var offset: CGFloat
        /// 內容能捲到的最大位移；小於等於 0 表示整頁捲不動。
        var maxOffset: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }
    private static let minimizeAt: CGFloat = 10
    /// 沒有捲軸的頁面要拉開這麼多才縮：輕輕一拉只有幾 pt 的彈性位移，縮了放手又立刻放大，看起來像閃一下。
    private static let minimizeAtWithoutScroll: CGFloat = 28
    private static let restoreAt: CGFloat = 6
    /// 可捲距離不到這麼多就當成沒有捲軸（整頁放得下）。
    private static let scrollableRange: CGFloat = 6
    private static func hasNoScroll(_ maxOffset: CGFloat) -> Bool { max(maxOffset, 0) < scrollableRange }
    /// UIScrollView 一般減速率 0.998（每毫秒）：剩餘距離 ≈ 速度(pt/s) × 0.998 / (1 − 0.998) / 1000 ≈ 速度 × 0.5。
    private static let decelerationTravelPerVelocity: CGFloat = 0.499
    private static func sample(_ geometry: ScrollGeometry) -> Sample {
        Sample(offset: geometry.contentOffset.y + geometry.contentInsets.top,
               maxOffset: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height,
               contentHeight: geometry.contentSize.height,
               containerHeight: geometry.containerSize.height)
    }
    /// 放手後內容超出可捲範圍而回彈：沒有捲軸的頁面要放大；有捲軸的頁面是滑到底的回彈，不放大。
    private static func bouncesOnPageWithoutScroll(_ sample: Sample) -> Bool {
        sample.offset > sample.maxOffset && hasNoScroll(sample.maxOffset)
    }
    /// 手指放開的當下推算內容最後停在哪：超出底端且沒有往回甩 → 回彈停在底端（捲不動的頁面就是頂端）；
    /// 其餘依放手速度與系統減速率推算，再夾在可捲範圍內（超出兩端都會彈回端點）。
    private static func landing(of scrollView: UIScrollView, velocity: CGFloat) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset.y + inset.top
        let bottom = max(scrollView.contentSize.height + inset.top + inset.bottom - scrollView.bounds.height, 0)
        if offset > bottom, velocity >= 0 { return bottom }
        return min(max(offset + velocity * decelerationTravelPerVelocity, 0), bottom)
    }
    func body(content: Content) -> some View {
        content
            .background(FormlessScrollViewProbe(tracker: tracker))
            .onAppear {
                installReleaseHandler()
                syncToScrollPosition()
            }
            .onChange(of: state == nil) {
                installReleaseHandler()
                // 首頁分頁只有目前顯示的那一頁拿得到 state，nil 與非 nil 互換就是切換分頁：一律回到最上方，
                // 離開時就先捲回去，下次切回來不會看到跳動；切回來時再確認一次，並讓分頁列和實際位置一致。
                scrollToTop()
                syncToScrollPosition()
            }
            .onScrollPhaseChange { _, phase, context in
                tracker.phaseScrolling = phase != .idle
                tracker.phaseDecelerating = phase == .decelerating
                if phase == .interacting || phase == .tracking { tracker.holdRestored = false }
                guard let state else { return }
                let sample = Self.sample(context.geometry)
                if phase == .idle {
                    if sample.offset < Self.restoreAt { state.set(false) } else { state.apply() }
                } else if phase == .decelerating, Self.bouncesOnPageWithoutScroll(sample) {
                    tracker.holdRestored = true
                    state.set(false)
                }
            }
            .onScrollGeometryChange(for: Sample.self) { geometry in
                Self.sample(geometry)
            } action: { _, sample in
                let offset = sample.offset
                let now = CACurrentMediaTime()
                let dt = now - tracker.lastTime
                let velocity: CGFloat = dt > 0 && dt < 0.2 ? (offset - tracker.lastOffset) / CGFloat(dt) : 0
                tracker.lastOffset = offset
                tracker.lastTime = now
                tracker.contentHeight = sample.contentHeight
                tracker.containerHeight = sample.containerHeight
                if tracker.scrollView.map({ !tracker.matches($0) || $0.window == nil }) ?? true { tracker.probe?.resolve() }
                guard let state else { return }
                let decelerating = tracker.decelerating
                if offset < Self.restoreAt {
                    state.set(false)
                } else if decelerating, Self.bouncesOnPageWithoutScroll(sample) {
                    tracker.holdRestored = true
                    state.set(false)
                } else if decelerating, velocity < 0, offset <= sample.maxOffset,
                          offset + velocity * Self.decelerationTravelPerVelocity < Self.restoreAt {
                    // 只在內容仍在可捲範圍內、真正的慣性滑動時推算；滑到底的回彈（位移超過最大值往回彈）不算，
                    // 那是彈簧不是減速，而且它只會停在底端，不會回到頂端。
                    tracker.holdRestored = true
                    state.set(false)
                } else if tracker.scrolling, !tracker.holdRestored,
                          offset >= (Self.hasNoScroll(sample.maxOffset) ? Self.minimizeAtWithoutScroll : Self.minimizeAt) {
                    state.set(true)
                } else {
                    // 狀態沒變也重套一次：分頁列若被系統重建或動畫被打斷，會在下一次捲動事件修正回來。
                    state.apply()
                }
            }
    }
    /// 頁面出現（切換分頁、從編輯器回來、切換分類）時，分頁列一律依內容實際的位置決定大小：在頂端就原尺寸，
    /// 不在頂端就縮小。不假設「切回來一定在頂端」：例如清單正在下拉更新時不會被捲回頂端，
    /// 這時若照樣恢復原尺寸，就會變成內容停在下面、分頁列卻是大的，一滑又突然縮小。
    /// 位置優先讀底下的 UIScrollView，找不到時用捲動幾何最後回報的位移。
    private func syncToScrollPosition() {
        guard let state else { return }
        func sync() {
            let offset = tracker.scrollView.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? tracker.lastOffset
            if offset < Self.restoreAt {
                state.set(false)
            } else if offset >= Self.minimizeAt {
                state.set(true)
            } else {
                state.apply()
            }
        }
        sync()
        // 導覽返回的轉場結束後分頁列才回到視窗裡，再套一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sync() }
    }
    /// 切換分頁一律回到預設位置（和屬性面板切換分類一樣）。沒有例外：下拉更新中也捲回頂端（頂端含更新轉圈的位置）。
    /// 還沒找到底下的 UIScrollView 時先立刻找一次，不直接略過。
    private func scrollToTop() {
        if tracker.scrollView?.window == nil { tracker.probe?.resolve(force: true) }
        guard let scrollView = tracker.scrollView else { return }
        let top = -scrollView.adjustedContentInset.top
        guard abs(scrollView.contentOffset.y - top) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: top), animated: false)
    }
    /// 手指放開的那一刻就判斷：沒有捲軸的頁面一律放大；有捲軸的頁面會停在頂端（往頂端甩）才放大，不等第一筆慣性幾何。
    private func installReleaseHandler() {
        let tracker = tracker
        let state = state
        tracker.onRelease = { scrollView, gesture in
            guard let state else { return }
            let velocity = -gesture.velocity(in: scrollView).y
            let inset = scrollView.adjustedContentInset
            let maxOffset = scrollView.contentSize.height + inset.top + inset.bottom - scrollView.bounds.height
            if Self.hasNoScroll(maxOffset) || Self.landing(of: scrollView, velocity: velocity) < Self.restoreAt {
                tracker.holdRestored = true
                state.set(false)
            }
        }
    }
}

/// 找出 SwiftUI 捲動容器底下真正的 UIScrollView：放在容器的 background，往上找祖先、往下找子視圖，
/// 取和捲動幾何同尺寸的那一個交給 `FormlessScrollMinimizer.Tracker`。
struct FormlessScrollViewProbe: UIViewRepresentable {
    let tracker: FormlessScrollMinimizer.Tracker
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.tracker = tracker
        tracker.probe = view
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.tracker = tracker
        tracker.probe = view
    }
    final class ProbeView: UIView {
        weak var tracker: FormlessScrollMinimizer.Tracker?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.resolve() }
        }
        func resolve(force: Bool = false) {
            guard let tracker, window != nil else { return }
            if let current = tracker.scrollView, current.window != nil, tracker.matches(current) { return }
            guard tracker.containerHeight > 0 else { return }
            let now = CACurrentMediaTime()
            guard force || now - tracker.lastSearch > 0.3 else { return }
            tracker.lastSearch = now
            var ancestor = superview
            for _ in 0..<8 {
                guard let node = ancestor else { return }
                if let found = Self.search(node, depth: 0, tracker: tracker) {
                    tracker.attach(found)
                    return
                }
                ancestor = node.superview
            }
        }
        private static func search(_ view: UIView, depth: Int, tracker: FormlessScrollMinimizer.Tracker) -> UIScrollView? {
            if let scrollView = view as? UIScrollView, tracker.matches(scrollView) { return scrollView }
            guard depth < 6 else { return nil }
            for child in view.subviews {
                if let found = search(child, depth: depth + 1, tracker: tracker) { return found }
            }
            return nil
        }
    }
}

/// 首頁分頁列的縮放：TabView 的分頁列是系統的 UITabBar，SwiftUI 碰不到它，從視窗裡找出來登記給狀態物件，
/// 分頁列本身（項目、玻璃、選取）一概不改，只是整條變小；和屬性面板分類列的縮法一致。
struct FormlessHomeTabBarScaler: UIViewRepresentable {
    let state: FormlessMinimizeState
    func makeCoordinator() -> Coordinator { Coordinator() }
    /// 找到的 UITabBar 記起來：每次捲動事件都會套用一次縮放，原本每次都把整個視窗的視圖樹掃一遍找分頁列，
    /// 視圖越多越慢，切換分頁時一次掃好幾遍就卡頓。只有分頁列被系統換掉（離開視窗）時才重找，且最多每 0.5 秒一次。
    final class Coordinator {
        var registered = false
        weak var window: UIWindow?
        weak var bar: UITabBar?
        var lastSearch: TimeInterval = 0
        func layer() -> CALayer? {
            if let bar, bar.window != nil { return bar.layer }
            let now = CACurrentMediaTime()
            guard let window, now - lastSearch > 0.5 else { return nil }
            lastSearch = now
            bar = FormlessHomeTabBarScaler.findTabBar(in: window)
            return bar?.layer
        }
    }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.registered else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, !coordinator.registered else { return }
            coordinator.registered = true
            coordinator.window = window
            state.register { [weak coordinator] in coordinator?.layer() }
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if let window = view.window, let bar = findTabBar(in: window) {
            FormlessMinimizeState.applyScale(1, to: bar.layer, animated: false)
        }
    }
    static func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let found = findTabBar(in: subview) { return found }
        }
        return nil
    }
}

/// 屬性面板底部的分類列：獨立成小視圖、只觀察分類列自己的狀態，捲動中反覆縮放不會重繪整個編輯器。
/// 分類列本身就是原本那條系統 UITabBar，一個項目都不動；縮小只是整條列（連玻璃）以彈簧縮到 0.85，
/// 像 Instagram 那樣稍微變小，反向捲動、回到頂端或點任一分頁就彈回原尺寸。
struct EditorCategoryBarHost: View {
    /// 系統分頁列的玻璃條離自己的框左右各約 20（實測）。
    static let barGlassInset: CGFloat = 20
    /// 只是轉交給分頁列登記圖層，不觀察它：縮小／恢復不需要重畫這一列。
    let state: FormlessMinimizeState
    @Binding var selection: String
    let titles: [String]
    var body: some View {
        EditorCategoryTabBar(selection: $selection, titles: titles, minimizeState: state) {
            state.restoreForTabSwitch()
        }
        .frame(height: 48)
    }
}

extension View {
    /// 讓這個捲動視圖驅動某條列的縮放；傳 nil 則什麼都不做。
    func formlessScrollMinimizer(state: FormlessMinimizeState?) -> some View {
        modifier(FormlessScrollMinimizer(state: state))
    }

    /// 所有清單統一：手指從右往左滑，從右側展開刪除鍵，必須再點擊才刪除。
    func formlessTrailingSwipeDelete(isEnabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isEnabled {
                Button("刪除", systemImage: "trash", role: .destructive, action: action)
            }
        }
    }
}

/// 在面板容器掛水平 pan；左側 56 pt 皆可起手，垂直捲動不會觸發返回。
struct EditorPanelBackGesture: UIViewRepresentable {
    var isEnabled: Bool
    var blocked: () -> Bool = { false }
    var excludedTop: CGFloat
    var extendsToWindowTop = false
    /// 手勢成立的當下，帶著覆蓋整個面板的標記視圖回報（用來拍面板快照）。
    var onBegan: (UIView) -> Void = { _ in }
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, let window = view.window else { return }
            coordinator.marker = view
            coordinator.attach(to: window)
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.detach() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: EditorPanelBackGesture?
        weak var marker: UIView?
        weak var window: UIWindow?
        weak var touchedScrollView: UIScrollView?
        weak var lockedScrollView: UIScrollView?
        private let activationWidth: CGFloat = 56
        lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(changed(_:)))
        func attach(to window: UIWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            pan.delegate = self
            pan.cancelsTouchesInView = true
            pan.maximumNumberOfTouches = 1
            window.addGestureRecognizer(pan)
        }
        func detach() {
            unlockVerticalScroll()
            window?.removeGestureRecognizer(pan)
            window = nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let owner, owner.isEnabled, !owner.blocked(), let marker, let window else { return false }
            let rect = marker.convert(marker.bounds, to: window)
            let point = touch.location(in: window)
            let minY = owner.extendsToWindowTop ? window.safeAreaInsets.top : rect.minY + owner.excludedTop
            let acceptsTouch = point.x >= rect.minX && point.x <= rect.minX + activationWidth &&
                point.y >= minY && point.y <= rect.maxY
            if acceptsTouch {
                var view = touch.view
                while let current = view, !(current is UIScrollView) { view = current.superview }
                touchedScrollView = view as? UIScrollView
            } else {
                touchedScrollView = nil
            }
            return acceptsTouch
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: window)
            guard let owner, owner.isEnabled, !owner.blocked() else { return false }
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 0.9
        }
        /// 任何其他 pan 都當成捲動看待（不限 view 是 UIScrollView 的那一個）：清單的捲動手勢不一定掛在捲動視圖本身。
        private func isScrollPan(_ gesture: UIGestureRecognizer) -> Bool {
            gesture is UIPanGestureRecognizer && gesture !== pan
        }
        // 返回拖曳時清單不能同時上下捲動；清單的捲動要等返回手勢判定失敗才開始。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            !isScrollPan(otherGestureRecognizer)
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            isScrollPan(otherGestureRecognizer)
        }
        /// 返回拖曳一開始就把清單的捲動整個停用（isScrollEnabled），不是只停用某個 pan 手勢：
        /// 實機上清單的捲動不一定是 panGestureRecognizer 在驅動，只停用它擋不住，回滑時內容會跟著手指上下跑。
        /// 也不用「位移被改就放回去」的方式：那會和系統的捲動每一格互相拉扯，畫面在兩個位置之間跳。
        /// 放手後等返回動畫跑完才解鎖；解鎖時若位移被系統動過，一次放回原位（不動畫）。
        private var pinnedOffset: CGPoint?
        private func lockVerticalScroll() {
            guard let scroll = touchedScrollView else { return }
            lockedScrollView = scroll
            pinnedOffset = scroll.contentOffset
            scroll.isScrollEnabled = false
        }
        private func unlockVerticalScroll() {
            let scroll = lockedScrollView
            let pinned = pinnedOffset
            lockedScrollView = nil
            touchedScrollView = nil
            pinnedOffset = nil
            guard let scroll else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak scroll] in
                guard let scroll else { return }
                scroll.isScrollEnabled = true
                if let pinned, abs(scroll.contentOffset.y - pinned.y) > 0.5 {
                    scroll.setContentOffset(pinned, animated: false)
                }
            }
        }
        @objc private func changed(_ gesture: UIPanGestureRecognizer) {
            let x = gesture.translation(in: window).x
            switch gesture.state {
            case .began:
                lockVerticalScroll()
                if let marker { owner?.onBegan(marker) }
                owner?.onChanged(x)
            case .changed: owner?.onChanged(x)
            case .ended:
                unlockVerticalScroll()
                owner?.onEnded(x, gesture.velocity(in: window).x, false)
            case .cancelled, .failed:
                unlockVerticalScroll()
                owner?.onEnded(x, 0, true)
            default: break
            }
        }
    }
}

/// 旁聽所在列的長按：按住 0.25 秒回報開始、放開回報結束。掛在列的 UIKit 祖先視圖上、
/// 允許與其他辨識器同時辨識，也不取消觸控，所以不會影響 List 的整列拖曳排序。

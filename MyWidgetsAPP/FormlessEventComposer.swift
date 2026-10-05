import EventKit
import SwiftUI
import UIKit

/// 小工具的「建立行事曆行程」：打開 Formless 後直接跳出 Formless 自己的新增行程面板（`FormlessNewEventView`）。
/// 不用系統的新增行程面板：它的時間一開始收成一行、標題欄內距和其他列不同，而且都無法調整（使用者不要）。
@MainActor
final class FormlessEventComposer {
    static let shared = FormlessEventComposer()
    private let store = EKEventStore()
    /// 還沒叫出的面板是什麼時候要求的；叫出後清掉。
    private var requestedAt: Date?
    private var activationObserver: NSObjectProtocol?
    /// 目前開著的面板。面板已經開著時（例如開著面板離開 App、再點一次小工具）不再疊一個：
    /// 面板上可能還蓋著日期選擇器或選單，只看最上層的畫面判斷不出來（使用者回報出現兩個面板）。
    private weak var openHost: FormlessNewEventHost?

    /// 跳出新增行程面板；App 還沒準備好就等它準備好。
    func present() {
        if let openHost, openHost.presentingViewController != nil, !openHost.isBeingDismissed { return }
        requestedAt = Date()
        // 還沒問過行事曆權限就先問；Formless 讀行程本來就要完整權限，這裡用同一種。
        guard EKEventStore.authorizationStatus(for: .event) != .notDetermined else {
            Task {
                _ = try? await store.requestFullAccessToEvents()
                attempt(retries: 20)
            }
            return
        }
        // 已有權限就當場試，不排到下一輪：App 一啟用就能立刻滑出面板。
        attempt(retries: 20)
    }

    private func attempt(retries: Int) {
        // 超過一分鐘還沒叫出就算了，免得很久以後回到 App 才突然跳出來。
        guard let requestedAt, Date().timeIntervalSince(requestedAt) < 60 else { finish(); return }
        // App 還沒啟用（冷啟動、從背景叫起來、系統的權限詢問擋在前面）或畫面還在轉場：App 一啟用就試，轉場則稍後再試。
        // 只靠固定次數重試的話，權限詢問停留超過幾秒，這次點擊就被丟掉了（新裝的 App 實測）。
        // 面板一定用系統由下往上的動畫（使用者要求），所以要等 App 真的在畫面上（啟用）才叫，早了動畫看不到。
        guard let top = Self.topViewController(), top.transitionCoordinator == nil else {
            waitForActivation()
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.attempt(retries: retries - 1) }
            return
        }
        finish()
        if let openHost, openHost.presentingViewController != nil, !openHost.isBeingDismissed { return }
        let host = FormlessNewEventHost(rootView: AnyView(EmptyView()))
        openHost = host
        host.rootView = AnyView(FormlessNewEventView(store: store) { [weak host] added in
            host?.dismiss(animated: true)
            // 新行程要出現在小工具上：離開 App 時一起重新整理。
            if added { FormlessWidgetReload.request() }
        })
        host.sheetPresentationController?.detents = [.large()]
        top.present(host, animated: true)
    }

    private func waitForActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attempt(retries: 20) }
        }
    }

    private func finish() {
        requestedAt = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// 最上層的畫面：App 視窗的根畫面往上找已經彈出的畫面（設定頁等），面板疊在最上面。
    /// 只在 App 完全啟用後才回傳：還沒啟用時叫出的面板拿不到鍵盤（標題欄有游標卻沒有鍵盤），滑入動畫也看不到。
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// 新增行程面板的外殼，用來辨認面板是否已經開著。
/// 鍵盤開著時，面板裡的日期、時間、選單照樣點得到（使用者：不需要阻擋，照樣點擊並關閉鍵盤）：
/// 點輸入框以外的地方，觸控照常交給那個控制項，放開後才收起鍵盤。
final class FormlessNewEventHost: UIHostingController<AnyView>, FormlessKeyboardTapThrough, UIGestureRecognizerDelegate {
    /// 按下時正在輸入的欄位；放開後只收它的鍵盤。不用 endEditing：日期、時間按下去會自己成為輸入焦點，
    /// 一起收掉的話日期選擇器剛打開就被關掉。
    private weak var typingField: UIView?
    /// 點了輸入框以外的項目之後，到使用者再點輸入框之前：系統在日期選擇器、選單關掉時會自動把輸入焦點
    /// 還給原本的欄位（實測），這段期間欄位一開始輸入就收掉。
    private var blocksRefocus = false
    private var editingObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        editingObserver = NotificationCenter.default.addObserver(
            forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.blocksRefocus, let field = note.object as? UIView,
                      field.isDescendant(of: self.view) else { return }
                field.resignFirstResponder()
            }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        // 等這一下交給控制項處理完再收，控制項不會因為畫面跟著鍵盤移動而點空。
        DispatchQueue.main.async { [weak self] in
            // 面板也要忘掉「正在輸入」：只收系統的輸入焦點的話，日期選擇器、選單關掉後會把焦點還給原本的欄位，
            // 鍵盤又跳出來（使用者回報）。
            NotificationCenter.default.post(name: .formlessNewEventEndTyping, object: nil)
            self?.blocksRefocus = true
            if let field = self?.typingField, field.isFirstResponder { field.resignFirstResponder() }
            self?.typingField = nil
        }
    }

    /// 點在輸入框（或輸入範圍，例如地點建議）上是切換欄位、移動游標，不收鍵盤。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var node = touch.view
        while let current = node {
            if current is UITextField || current is UITextView || current is FormlessInputAreaView {
                // 使用者自己點了輸入框：照常開始輸入。
                blocksRefocus = false
                return false
            }
            node = current.superview
        }
        typingField = Self.firstResponder(in: view)
        return typingField != nil
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is UITextField || view is UITextView { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension Notification.Name {
    /// 新增行程面板裡點了輸入框以外的項目：結束輸入，不再把焦點還給原本的欄位。
    static let formlessNewEventEndTyping = Notification.Name("formless.newEvent.endTyping")
}

import SwiftUI
import UIKit

/// 冷啟動時，小工具帶來的網址在場景連上的那一刻就拿得到（這裡）；SwiftUI 的 onOpenURL 要等首頁畫出來才收到，
/// 慢約一秒（模擬器實測），那一秒看得到首頁停著、面板才滑出來（使用者回報的閃爍）。這裡一拿到就先登記，
/// App 一啟用面板就滑出；之後 onOpenURL 再收到同一個網址時面板已經開著，不會重複。回傳的設定不指定場景代理，SwiftUI 會用自己的。
final class FormlessAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if options.urlContexts.contains(where: { FormlessDeepLink.isCreateEvent($0.url) }) {
            FormlessEventComposer.shared.present()
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

@main
struct FormlessApp: App {
    @UIApplicationDelegateAdaptor(FormlessAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 匯入的字型先註冊，畫布、縮圖第一次畫就用得到。
        FormlessFontLibrary.registerAll()
        ResizableEditorPreview.migrateHeightsForFloatingButtons()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 全 App 的表單與清單：卡片之間的距離統一用首頁小工具列的間距（各頁面自己設的也是同一個值）。
                .listSectionSpacing(FormlessDesign.Space.cardGap)
                // 清單還在滑動時按下去只讓它停下，不觸發列的動作（全 App）。
                .formlessScrollStopTapGuard()
                // 小工具點下去帶來的網址。系統一律先打開 Formless（小工具不能直接開別的 App）：
                // 建立行事曆行程在這裡叫出面板；「開啟網址」的網址轉交系統打開（Safari 或對應的 App）。
                .onOpenURL { url in
                    if FormlessDeepLink.isCreateEvent(url) {
                        FormlessEventComposer.shared.present()
                    } else if !url.isFileURL, url.scheme != FormlessDeepLink.createEvent.scheme {
                        UIApplication.shared.open(url)
                    }
                }
        }
        // 離開 App（回桌面、切到別的 App）時，把編輯期間延後的小工具重新整理一次送出。
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { FormlessWidgetReload.flush() }
        }
    }
}

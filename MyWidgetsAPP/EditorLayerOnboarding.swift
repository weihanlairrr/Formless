import SwiftUI
import UIKit

// MARK: - 剛新增、還沒有內容的圖層（使用者規則）

extension FormlessLayer {
    /// 沒有上傳就沒有內容的圖層：圖片沒選圖、網路圖片沒網址。只要是空的，不論從清單或畫布點進去，
    /// 屬性面板都先在「內容」，找得到補上內容的地方。文字這類一建立就有預設內容的，只有剛新增的第一次進去才開在內容
    /// （`EditorNewLayerGuide`，使用者規則）。
    var editorNeedsContent: Bool {
        switch type {
        case .image:
            return (value ?? "").isEmpty
        case .remoteImage:
            let url = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return url.isEmpty || url == "https://" || url == "http://"
        default:
            return false
        }
    }
}

enum EditorNewLayerGuide {
    /// 剛新增的圖層先開哪個分頁：要先決定內容的（文字、網路圖片、日期、時間、即時文字、圖片、圖示）開在「內容」，
    /// 色塊開在「外觀」（先決定形狀與填色）；其他（月曆格）照舊。
    static func category(for type: FormlessLayerType) -> String? {
        switch type {
        case .text, .remoteImage, .date, .time, .liveText, .image, .symbol, .progress, .chart, .clock: return "內容"
        case .shape: return "外觀"
        default: return nil
        }
    }

    /// 新增後直接可以打字的圖層：鍵盤出現，原本的預設文字（「文字」、「https://」）先反白，一打字就取代。
    static func focusesInput(_ type: FormlessLayerType) -> Bool {
        type == .text || type == .remoteImage
    }
}

/// 下一個開始編輯的文字欄位整段反白（剛新增文字圖層時，一打字就取代預設的「文字」）。只作用一次；
/// 一秒內沒有欄位開始編輯就放棄，不會影響之後的輸入。
@MainActor enum EditorSelectAllOnFocus {
    private static var token: NSObjectProtocol?
    private static var generation = 0

    static func arm() {
        disarm()
        generation += 1
        let armed = generation
        token = NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification,
                                                       object: nil, queue: .main) { note in
            let field = note.object as? UITextField
            MainActor.assumeIsolated {
                disarm()
                // 開始編輯的這一輪系統還會放游標，下一輪再全選。
                DispatchQueue.main.async { field?.selectAll(nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if generation == armed { disarm() } }
    }

    private static func disarm() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

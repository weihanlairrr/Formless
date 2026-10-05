import SwiftUI

// MARK: - 編輯器畫布的預覽情境（2026-10，規劃第 6.2 節「預覽」、A2）
//
// 右上選單 › 預覽：外觀（淺色、深色、透明、染色、StandBy、StandBy 夜間）與資料（實際、範例、沒有資料、很長的文字）。
// 畫布照那個情境畫，看到的就是主畫面上的樣子；選擇不存進設計。

/// 畫布最底下：設計的底色與背景圖，或預覽情境的背景。
struct EditorCanvasBackdrop: View {
    let document: FormlessDocument
    let appearance: FormlessPreviewAppearance
    let background: UIImage?
    let canvasSize: CGSize

    var body: some View {
        switch appearance {
        case .clear:
            // 透明：系統拿掉底色、換成透出桌布的玻璃。
            ZStack {
                EditorPreviewWallpaper()
                Rectangle().fill(.ultraThinMaterial)
            }
        case .tinted:
            // 染色：桌布上蓋一層染色的玻璃。
            ZStack {
                EditorPreviewWallpaper()
                Rectangle().fill(.ultraThinMaterial)
                Color(red: 0.12, green: 0.20, blue: 0.40).opacity(0.72)
            }
        case .standBy, .standByNight:
            // StandBy：背景拿掉，放在黑底上。
            Color.black
        case .automatic, .light, .dark:
            ZStack {
                Color(formlessHex: document.backgroundColorHex, fallback: "#F4F4F4")
                if let background {
                    Image(uiImage: background).resizable().scaledToFill()
                        .frame(width: canvasSize.width, height: canvasSize.height).clipped()
                }
            }
        }
    }
}

/// 預覽透明、染色時的示意桌布。
struct EditorPreviewWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.23, green: 0.44, blue: 0.85),
                                Color(red: 0.56, green: 0.36, blue: 0.84),
                                Color(red: 0.91, green: 0.51, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// 有指定外觀時才覆寫；nil 是跟著 App。
    @ViewBuilder
    func formlessColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme {
            environment(\.colorScheme, scheme)
        } else {
            self
        }
    }
}

// MARK: - 淺色、深色兩個值（2026-10，規劃第 3.3 節）

/// 顏色面板上方：「淺色與深色分開」開關；打開後用分段控制選要調哪一個。
struct EditorDualColorRow: View {
    @Binding var isOn: Bool
    @Binding var darkSide: Bool

    var body: some View {
        VStack(spacing: FormlessDesign.Space.loose) {
            Toggle("淺色與深色分開", isOn: $isOn)
            if isOn {
                Picker("外觀", selection: $darkSide) {
                    Text("淺色").tag(false)
                    Text("深色").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

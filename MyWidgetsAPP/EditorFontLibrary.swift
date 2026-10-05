import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 字型管理

/// 字型：匯入的字型。一張卡片列出字型，每列用字型本身寫出名稱，左滑刪除（同一個字型檔的字型一起刪）；
/// 另一張卡片匯入字型（從「檔案」選，可一次選好幾個）。字型存在 App 群組，小工具延伸也讀得到（`FormlessFontLibrary`）。
struct FormlessFontLibraryView: View {
    /// 字型資料夾。平常是 App 群組的 Fonts/；預覽與測試傳暫存資料夾，不碰使用者的資料。
    var directory: URL? = FormlessFontLibrary.directoryURL

    @State private var fonts: [FormlessImportedFont] = []
    /// 字型檔名 → 用到這個檔案裡字型的小工具數（刪除前的提示用）。
    @State private var usage: [String: Int] = [:]
    @State private var showsImporter = false
    @State private var isImporting = false
    /// 要刪的字型。提示框關掉後不清掉，關閉動畫期間標題才不會變成空的。
    @State private var removalTarget: FormlessImportedFont?
    @State private var confirmsRemoval = false
    /// 匯入失敗的說明，一個檔案一行。提示框關掉後不清掉（同上）。
    @State private var failures: [String] = []
    @State private var showsFailures = false

    var body: some View {
        List {
            Section {
                if fonts.isEmpty {
                    Text("沒有匯入的字型。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(fonts.enumerated()), id: \.element.id) { index, font in
                        // 字型檔很大的提醒每個檔案只寫一次（TTC 一個檔案常有好幾個字型），寫在那個檔案的第一列。
                        let firstOfFile = fonts.firstIndex { $0.fileName == font.fileName } == index
                        FormlessImportedFontRow(font: font, warnsLargeFile: font.isLarge && firstOfFile)
                            .formlessTrailingSwipeDelete {
                                removalTarget = font
                                confirmsRemoval = true
                            }
                    }
                }
            }

            Section {
                Button {
                    showsImporter = true
                } label: {
                    HStack {
                        Text(isImporting ? "正在匯入…" : "匯入字型")
                        Spacer()
                        if isImporting { ProgressView() }
                    }
                }
                .disabled(isImporting)
            }
        }
        // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("字型")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importFonts(urls)
            case .failure(let error):
                failures = [error.localizedDescription]
                showsFailures = true
                FormlessHaptics.warning()
            }
        }
        .alert(Text("刪除「\(removalTarget?.displayName ?? "")」？"), isPresented: $confirmsRemoval, presenting: removalTarget) { font in
            Button("刪除字型", role: .destructive) { remove(font) }
            Button("取消", role: .cancel) {}
        } message: { font in
            if let message = removalMessage(for: font) {
                Text(message)
            }
        }
        .alert("無法匯入字型", isPresented: $showsFailures) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(failures.joined(separator: "\n"))
        }
        .task { await reload() }
    }

    /// 同一個檔案還有別的字型時說一起刪；有小工具用到時說會改用系統字型。都沒有就不加說明。
    private func removalMessage(for font: FormlessImportedFont) -> String? {
        let siblings = fonts.filter { $0.fileName == font.fileName }.count
        let used = usage[font.fileName] ?? 0
        var parts: [String] = []
        if siblings > 1 {
            parts.append("同一個字型檔的 \(siblings) 個字型會一起刪除。")
        }
        if used > 0 {
            parts.append("\(used) 個小工具用到\(siblings > 1 ? "這些字型" : "這個字型")，刪除後會改用系統字型。")
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    private func importFonts(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let directory = directory
        Task {
            // 中文字型檔常有 10～30 MB：複製與讀檔放到背景，畫面不卡。
            let messages = await Task.detached(priority: .userInitiated) { () -> [String] in
                var messages: [String] = []
                for url in urls {
                    do {
                        guard let directory else { throw FormlessFontLibraryError.noSharedContainer }
                        _ = try FormlessFontLibrary.importFont(at: url, into: directory)
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        // 一次選好幾個檔案時，每行前面寫是哪個檔案。
                        messages.append(urls.count > 1 ? "\(url.lastPathComponent)：\(reason)" : reason)
                    }
                }
                return messages
            }.value
            isImporting = false
            await reload()
            if messages.isEmpty {
                FormlessHaptics.success()
            } else {
                failures = messages
                showsFailures = true
                FormlessHaptics.warning()
            }
        }
    }

    private func remove(_ font: FormlessImportedFont) {
        if let directory { FormlessFontLibrary.remove(font, from: directory) }
        withAnimation(FormlessDesign.Motion.fade) {
            fonts.removeAll { $0.fileName == font.fileName }
        }
        FormlessHaptics.rigid()
        // 桌面上用到這個字型的小工具改用系統字型：離開 App 時一併重新整理。
        FormlessWidgetReload.request()
    }

    private func reload() async {
        let directory = directory
        let result = await Task.detached(priority: .userInitiated) { () -> ([FormlessImportedFont], [String: Int]) in
            guard let directory else { return ([], [:]) }
            FormlessFontLibrary.registerAll(in: directory)
            let fonts = FormlessFontLibrary.installed(in: directory)
            return (fonts, Self.usage(of: fonts))
        }.value
        withAnimation(FormlessDesign.Motion.fade) {
            fonts = result.0
        }
        usage = result.1
    }

    /// 每個字型檔被幾個小工具用到（任何一個圖層選了檔案裡的字型就算）。
    nonisolated private static func usage(of fonts: [FormlessImportedFont]) -> [String: Int] {
        let files = Dictionary(fonts.map { ($0.postScriptName, $0.fileName) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Int] = [:]
        for document in FormlessStorage.loadAll() {
            let used = Set(document.layers.compactMap { layer in
                FormlessFontLibrary.postScriptName(fromFamily: layer.fontFamily).flatMap { files[$0] }
            })
            for file in used { result[file, default: 0] += 1 }
        }
        return result
    }
}

/// 一個字型：名稱用字型本身畫（單行列名稱的字級 body）。字型檔很大時下面多一行灰字提醒。
private struct FormlessImportedFontRow: View {
    let font: FormlessImportedFont
    let warnsLargeFile: Bool

    /// body 在預設字級設定下的大小（17），交給 `.custom(_:size:relativeTo:)` 跟著動態字級縮放。
    private static let bodySize = UIFontDescriptor.preferredFontDescriptor(
        withTextStyle: .body,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize

    var body: some View {
        VStack(alignment: .leading, spacing: FormlessDesign.Space.rowExtra) {
            Text(font.displayName)
                .font(FormlessFontLibrary.isAvailable(font.postScriptName)
                      ? .custom(font.postScriptName, size: Self.bodySize, relativeTo: .body)
                      : .body)
                .lineLimit(1)
            if warnsLargeFile {
                Text("字型檔很大，小工具可能無法顯示")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        // 有第二行時上下各加 4，文字到分隔線和其他兩行的列一樣（設計規範「列內多行內容」）。
        .padding(.vertical, warnsLargeFile ? FormlessDesign.Space.rowExtra : 0)
    }
}


// MARK: - 字型選單裡的項目

/// 字型選單（Menu）裡的匯入字型：每個字型一項，打勾的是目前選中的；最後一項「管理字型…」。
/// 系統、圓體、襯線、等寬四種由外層的選單自己列。`current` 是圖層目前的 fontFamily，選了之後 `select`
/// 收到 "custom:<PostScript 名稱>"。
struct FormlessFontMenuItems: View {
    let current: String?
    let select: (String) -> Void
    let manage: () -> Void

    var body: some View {
        let fonts = FormlessFontLibrary.installed()
        if !fonts.isEmpty {
            // 選單裡用 inline 的 Picker：打勾的樣子和系統選單一樣。
            Picker(selection: Binding(get: { current ?? "" }, set: { select($0) })) {
                ForEach(fonts) { font in
                    Text(font.displayName)
                        .tag(FormlessFontLibrary.familyValue(for: font.postScriptName))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        }
        Section {
            Button("管理字型…", systemImage: "gearshape", action: manage)
        }
    }
}

extension FormlessFontMenuItems {
    /// 屬性面板的字型選單是 `FormlessOptionMenu`（UIMenu，捲動的表單裡必須用它，見設計規範），
    /// SwiftUI 的項目放不進去：同樣的兩段改用 UIMenu 元素。一段是匯入的字型（目前選中的打勾），
    /// 一段是「管理字型…」；段與段之間系統會畫分隔線。
    static func menuElements(current: String?,
                             select: @escaping (String) -> Void,
                             manage: @escaping () -> Void) -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        let fonts = FormlessFontLibrary.installed()
        if !fonts.isEmpty {
            elements.append(UIMenu(options: .displayInline, children: fonts.map { font in
                let value = FormlessFontLibrary.familyValue(for: font.postScriptName)
                return UIAction(title: font.displayName, state: value == current ? .on : .off) { _ in select(value) }
            }))
        }
        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "管理字型…", image: UIImage(systemName: "gearshape")) { _ in manage() }
        ]))
        return elements
    }
}

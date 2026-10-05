import SwiftUI
import UIKit
import Combine
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - 重用與分享（2026-10，規劃 M7）
//
// 我的組合：群組「⋯」›「儲存為我的組合」，新增圖層面板最下面一張卡片放回任何設計（FormlessComponentStore）。
// 拷貝樣式、貼上樣式：圖層「⋯」裡兩項，只貼對方用得到的欄位（FormlessLayerStyle）。
// 匯出圖片：首頁設計列的長按選單，畫成 PNG 用系統分享表分享。
// 版本紀錄：小工具設定 › 版本紀錄，列出最近 10 個版本，點了可以回復（FormlessVersionStore）。

extension FormlessDesign.Size {
    /// 我的組合列左邊的縮圖：和新增圖層面板裡兩行文字的列（名稱＋說明）一樣高，整張面板的列高一致。
    static let componentThumbnail: CGFloat = 44
    /// 組合縮圖裡內容到縮圖邊的距離：形狀貼齊範圍邊緣時不會被圓角切掉。
    static let componentThumbnailInset: CGFloat = 4
}

// MARK: - 共用狀態

/// 「儲存為我的組合」的要求：哪份設計的哪個群組、預設名稱（群組的名稱）。
struct EditorComponentSaveRequest: Identifiable, Equatable {
    let id = UUID()
    let documentID: UUID
    let groupID: UUID
    let name: String
}

/// 重用功能的共用狀態：我的組合清單與縮圖、拷貝的樣式、從「⋯」選單叫出的「儲存為我的組合」。
/// 選單裡的項目沒辦法自己掛提示框（選單一收起，裡面的內容就拆掉了），由編輯器掛一次的 `editorReusePrompts(model:)` 顯示。
@MainActor
final class EditorReuseCenter: ObservableObject {
    static let shared = EditorReuseCenter()

    /// 我的組合，新的在前。第一次用到時在背景讀進來；之後由這裡存、刪，打開新增圖層面板時不必再讀檔。
    @Published private(set) var components: [FormlessComponent] = []
    /// 拷貝的樣式（見 `copyStyle(of:)` 為什麼記在 App 自己的 UserDefaults）。
    @Published private(set) var copiedStyle: FormlessLayerStyle?
    @Published var saveRequest: EditorComponentSaveRequest?

    private var componentThumbnails: [UUID: UIImage] = [:]
    private var versionThumbnails: [String: EditorVersionImage] = [:]

    private init() {
        copiedStyle = Self.storedStyle()
        Task { await reloadComponents() }
    }

    func reloadComponents() async {
        components = await Task.detached(priority: .userInitiated) { FormlessComponentStore.all() }.value
    }

    func save(_ component: FormlessComponent) throws {
        try FormlessComponentStore.save(component)
        components.removeAll { $0.id == component.id }
        components.insert(component, at: 0)
        componentThumbnails[component.id] = nil
    }

    func delete(_ component: FormlessComponent) {
        FormlessComponentStore.delete(id: component.id)
        components.removeAll { $0.id == component.id }
        componentThumbnails[component.id] = nil
    }

    // MARK: 拷貝的樣式

    private static let styleKey = "formless.copiedLayerStyle"

    /// 記在 App 自己的 UserDefaults，不放系統剪貼簿：不會蓋掉使用者剪貼簿裡的文字或圖片、不會跳「允許貼上」、
    /// 不必跨行程問剪貼簿（開了通用剪貼簿時會等 Mac 回應，卡住畫面），選單也能直接知道有沒有樣式可貼；
    /// 樣式只有 Formless 看得懂，放進剪貼簿也沒有別的 App 用得上。換設計、關掉 App 再開都還在。
    func copyStyle(of layer: FormlessLayer) {
        let style = FormlessLayerStyle(capturing: layer)
        copiedStyle = style
        if let data = try? JSONEncoder().encode(style) { UserDefaults.standard.set(data, forKey: Self.styleKey) }
    }

    private static func storedStyle() -> FormlessLayerStyle? {
        guard let data = UserDefaults.standard.data(forKey: styleKey) else { return nil }
        return try? JSONDecoder().decode(FormlessLayerStyle.self, from: data)
    }

    // MARK: 縮圖

    /// 已經畫好的組合縮圖（再打開面板時直接顯示，不必等）。
    func cachedThumbnail(for component: FormlessComponent) -> UIImage? { componentThumbnails[component.id] }

    /// 組合的縮圖：資料在背景讀好再畫，畫好留著（組合不會改，只會刪）。
    func thumbnail(for component: FormlessComponent, side: CGFloat) async -> UIImage? {
        if let cached = componentThumbnails[component.id] { return cached }
        let document = component.previewDocument
        let live = await Self.liveData(for: document)
        guard !Task.isCancelled else { return nil }
        let image = EditorReuseRenderer.componentImage(component, document: document, live: live, side: side)
        componentThumbnails[component.id] = image
        return image
    }

    func cachedThumbnail(for version: FormlessVersion) -> EditorVersionImage? { versionThumbnails[version.id] }

    /// 版本的縮圖：讀檔、資料都在背景；照那個版本自己的尺寸畫（中途換過尺寸的舊版本也不變形）。
    /// 版本檔不會改，畫好留著。
    func thumbnail(for version: FormlessVersion) async -> EditorVersionImage? {
        if let cached = versionThumbnails[version.id] { return cached }
        let snapshot = version
        guard let document = await Task.detached(priority: .userInitiated, operation: { FormlessVersionStore.document(of: snapshot) }).value
        else { return nil }
        let live = await Self.liveData(for: document)
        guard !Task.isCancelled,
              let image = EditorReuseRenderer.documentImage(document, live: live, size: document.family.listThumbnailSize)
        else { return nil }
        let result = EditorVersionImage(image: image, family: document.family)
        versionThumbnails[version.id] = result
        return result
    }

    /// 畫設計用的資料：快取裡的實際資料（和首頁縮圖相同）；日期格式先在背景準備好，畫的時候才不會是空的。
    nonisolated static func liveData(for document: FormlessDocument) async -> FormlessLiveData {
        await Task.detached(priority: .userInitiated) {
            FormlessRenderContext.prepare(document)
            return FormlessLiveData.cached(for: document)
        }.value
    }
}

// MARK: - 編輯器的動作

enum EditorReuseError: LocalizedError {
    case emptyGroup

    var errorDescription: String? {
        switch self {
        case .emptyGroup: return "群組裡沒有圖層。"
        }
    }
}

@MainActor
extension EditorModel {
    /// 「拷貝樣式」：記下這個圖層的外觀（App 內的記憶，不動系統剪貼簿）。
    func copyStyle(_ id: UUID) {
        guard let layer = document.layers.first(where: { $0.id == id }), !layer.group else { return }
        EditorReuseCenter.shared.copyStyle(of: layer)
    }

    /// 「貼上樣式」：只改這個圖層用得到的欄位，算一步復原（編輯紀錄的細項比對前後算出）；沒有任何改變就不記。
    /// 鎖定的圖層不貼（和屬性面板一樣不能改）。
    @discardableResult
    func pasteStyle(_ id: UUID) -> Bool {
        guard let style = EditorReuseCenter.shared.copiedStyle,
              let index = document.layers.firstIndex(where: { $0.id == id }),
              !document.layers[index].group, !document.effectivelyLocked(document.layers[index]) else { return false }
        var next = document.layers[index]
        style.apply(to: &next)
        guard next != document.layers[index] else { return false }
        pushUndo("貼上樣式" + layerTitle(id))
        document.layers[index] = next
        return true
    }

    /// 「儲存為我的組合」：群組、子圖層與它們用到的資料來源、我的資料存到 Components/。名稱留空用群組的名稱。
    @discardableResult
    func saveComponent(groupID: UUID, name: String) throws -> FormlessComponent {
        guard let component = FormlessComponent(group: groupID, in: document, name: name) else {
            throw EditorReuseError.emptyGroup
        }
        try EditorReuseCenter.shared.save(component)
        return component
    }

    /// 新增圖層面板選了一個組合：整組換新的 id 加在最上層、選取這個群組；用到的資料來源與我的資料一起帶進來
    /// （id 相同的沿用這份設計已有的）。算一步復原。回傳群組的新 id。
    @discardableResult
    func insertComponent(_ component: FormlessComponent) -> UUID? {
        var next = document
        guard let groupID = next.insert(component) else { return nil }
        pushUndo("新增「\(component.name)」", detail: nil)
        document = next
        renumber()
        selectedLayerID = groupID
        return groupID
    }

    /// 回復到一個版本：先把目前的樣子也留成一個版本，再換成版本裡的設計（算一步復原，自動存檔照常寫入）。
    func restoreVersion(_ version: FormlessVersion) throws {
        var restored = try FormlessVersionStore.restore(version, replacing: document)
        restored.id = document.id
        // 和打開編輯器時一樣：依前後順序排好、重新編號。
        restored.layers.sort { $0.zIndex < $1.zIndex }
        for index in restored.layers.indices { restored.layers[index].zIndex = index }
        guard restored != document else { return }
        pushUndo("回復版本", detail: version.displayTime())
        document = restored
        repairSelection()
    }
}

// MARK: - 圖層「⋯」選單

/// 圖層「⋯」選單裡的重用項目：一般圖層是「拷貝樣式」「貼上樣式」，群組是「儲存為我的組合」。
struct EditorReuseLayerActions: View {
    @ObservedObject var model: EditorModel
    let layer: FormlessLayer
    @ObservedObject private var center = EditorReuseCenter.shared

    var body: some View {
        if layer.group {
            Button("儲存為我的組合", systemImage: "square.and.arrow.down") {
                center.saveRequest = EditorComponentSaveRequest(documentID: model.document.id, groupID: layer.id, name: layer.name)
            }
            .disabled(model.document.children(of: layer.id).isEmpty)
        } else {
            Button("拷貝樣式", systemImage: "paintbrush") {
                model.copyStyle(layer.id)
                FormlessHaptics.light()
            }
            Button("貼上樣式", systemImage: "paintbrush.fill") { model.pasteStyle(layer.id) }
                .disabled(center.copiedStyle == nil || model.document.effectivelyLocked(layer))
        }
    }
}

extension View {
    /// 編輯器掛一次：「儲存為我的組合」的命名提示框（從圖層「⋯」選單叫出）。
    func editorReusePrompts(model: EditorModel) -> some View {
        modifier(EditorReusePromptHost(model: model))
    }
}

/// 「儲存為我的組合」：系統提示框裡輸入名稱（預設是群組的名稱），「儲存」／「取消」。
struct EditorReusePromptHost: ViewModifier {
    @ObservedObject var model: EditorModel
    @ObservedObject private var center = EditorReuseCenter.shared
    @State private var name = ""
    @State private var errorMessage: String?

    /// 只回應這份設計的要求（同一時間只會有一個編輯器，這裡多一層保險）。
    private var request: EditorComponentSaveRequest? {
        guard let request = center.saveRequest, request.documentID == model.document.id else { return nil }
        return request
    }

    func body(content: Content) -> some View {
        content
            .alert("儲存為我的組合", isPresented: Binding(
                get: { request != nil },
                set: { if !$0 { center.saveRequest = nil } }
            ), presenting: request) { request in
                TextField("名稱", text: $name)
                    .submitLabel(.done)
                Button("儲存") { save(request) }
                Button("取消", role: .cancel) {}
            }
            .onChange(of: center.saveRequest?.id) { _, _ in
                if let request { name = request.name }
            }
            .alert("無法儲存組合", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("確定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func save(_ request: EditorComponentSaveRequest) {
        center.saveRequest = nil
        do {
            try model.saveComponent(groupID: request.groupID, name: name)
            FormlessHaptics.success()
        } catch {
            FormlessHaptics.warning()
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 新增圖層面板：我的組合

/// 新增圖層面板最下面的一張卡片：我的組合（有存才出現），每列左邊縮圖、右邊名稱。
/// 點一下放進目前的設計；左滑刪除（先問「刪除組合」／「取消」）。卡片上方不放標題（全 App 的規則）。
struct EditorComponentSection: View {
    let onSelect: (FormlessComponent) -> Void
    @ObservedObject private var center = EditorReuseCenter.shared
    @State private var pendingDelete: FormlessComponent?

    var body: some View {
        if !center.components.isEmpty {
            Section {
                ForEach(center.components) { component in
                    row(component)
                }
            }
        }
    }

    private func row(_ component: FormlessComponent) -> some View {
        Button {
            // 清單還在滑動時按下去只是讓它停下，不放進設計（和其他列相同）。
            guard FormlessScrollStopTap.allows() else { return }
            onSelect(component)
        } label: {
            HStack(spacing: FormlessDesign.Space.loose) {
                EditorComponentThumbnail(component: component)
                Text(component.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FormlessDesign.Space.rowExtra)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 刪除鍵不用 destructive 角色：那會讓列先滑走，按「取消」時又跳回來；確定刪除後列才離開。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { pendingDelete = component } label: { Label("刪除", systemImage: "trash") }
                .tint(.red)
        }
        .alert("刪除「\(component.name)」？", isPresented: Binding(
            get: { pendingDelete?.id == component.id },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("刪除組合", role: .destructive) {
                center.delete(component)
                FormlessHaptics.rigid()
            }
            Button("取消", role: .cancel) {}
        }
        .accessibilityAction(named: "刪除組合") { pendingDelete = component }
    }
}

/// 組合的縮圖：存的時候那份設計的底色上，只畫這組圖層的範圍（放大到填滿縮圖）。
struct EditorComponentThumbnail: View {
    let component: FormlessComponent
    @State private var image: UIImage?

    init(component: FormlessComponent) {
        self.component = component
        _image = State(initialValue: EditorReuseCenter.shared.cachedThumbnail(for: component))
    }

    private var side: CGFloat { FormlessDesign.Size.componentThumbnail }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        ZStack {
            EditorReuseRenderer.background(family: component.family, colorHex: component.backgroundColorHex)
            if let image { Image(uiImage: image).resizable() }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline))
        .accessibilityHidden(true)
        .task(id: component.id) {
            guard image == nil else { return }
            // 面板滑上來的動畫期間不畫（主執行緒畫圖會讓動畫掉格），等它停下來再畫。
            try? await Task.sleep(for: .seconds(FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)))
            guard !Task.isCancelled else { return }
            image = await EditorReuseCenter.shared.thumbnail(for: component, side: side)
        }
    }
}

// MARK: - 畫圖

/// 組合縮圖、版本縮圖、匯出圖片共用的繪製：和首頁縮圖一樣用 ImageRenderer，資源同步讀進來
/// （非同步載入的話 ImageRenderer 會拍到還沒載好的空畫面，見 `FormlessRenderContext.synchronousAssets`）。
@MainActor
enum EditorReuseRenderer {
    /// 縮圖範圍外的底：設計的底色。
    static func background(family: FormlessWidgetFamily, colorHex: String?) -> some View {
        Color(formlessHex: colorHex, fallback: "#F4F4F4")
    }

    /// 組合縮圖：把組合的範圍放大到填滿 side × side（留一點邊），中心對齊縮圖中心。
    static func componentImage(_ component: FormlessComponent, document: FormlessDocument, live: FormlessLiveData,
                               side: CGFloat) -> UIImage? {
        guard let bounds = component.bounds, side > 0 else { return nil }
        let family = component.family
        let inner = side - 2 * FormlessDesign.Size.componentThumbnailInset
        let width = max(CGFloat(bounds.width) * family.referenceWidth, 1)
        let height = max(CGFloat(bounds.height) * family.referenceHeight, 1)
        let fit = min(inner / width, inner / height)
        let canvas = CGSize(width: family.referenceWidth * fit, height: family.referenceHeight * fit)
        let centerX = CGFloat(bounds.x + bounds.width / 2) * canvas.width
        let centerY = CGFloat(bounds.y + bounds.height / 2) * canvas.height

        FormlessRenderContext.synchronousAssets = true
        defer { FormlessRenderContext.synchronousAssets = false }
        let content = ZStack(alignment: .topLeading) {
            background(family: family, colorHex: component.backgroundColorHex)
            FormlessDocumentView(document: document, live: live)
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: side / 2 - centerX, y: side / 2 - centerY)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipped()
        let renderer = ImageRenderer(content: content)
        renderer.scale = max(2, UITraitCollection.current.displayScale)
        return renderer.uiImage
    }

    /// 整份設計的縮圖（版本紀錄）：和首頁縮圖相同的畫法。
    static func documentImage(_ document: FormlessDocument, live: FormlessLiveData, size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        FormlessRenderContext.synchronousAssets = true
        defer { FormlessRenderContext.synchronousAssets = false }
        let renderer = ImageRenderer(content: FormlessDocumentView(document: document, live: live)
            .frame(width: size.width, height: size.height))
        renderer.scale = max(2, UITraitCollection.current.displayScale)
        return renderer.uiImage
    }

    /// 匯出的 PNG：設計的參考尺寸、3 倍；外框照小工具的圓角，外圍透明。
    /// 深淺色照目前的外觀（桌面上的小工具此刻就是這個樣子）。
    static func png(document: FormlessDocument, live: FormlessLiveData, dark: Bool) -> Data? {
        let family = document.family
        let size = CGSize(width: family.referenceWidth, height: family.referenceHeight)
        let outline = RoundedRectangle(cornerRadius: family.cornerRadius, style: .continuous)
        FormlessRenderContext.synchronousAssets = true
        defer { FormlessRenderContext.synchronousAssets = false }
        let content = FormlessDocumentView(document: document, live: live)
            .frame(width: size.width, height: size.height)
            .clipShape(outline)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }
}

// MARK: - 匯出圖片

enum FormlessDesignImageError: LocalizedError {
    case renderFailed

    var errorDescription: String? { "無法產生圖片。" }
}

/// 分享表的項目：真的要分享（或存到照片、檔案）時才畫，打開選單不畫。
struct FormlessDesignImageExport: Transferable {
    let document: FormlessDocument
    let dark: Bool

    var fileName: String {
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Formless" : name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")) + ".png"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await item.pngData()
        }
        .suggestedFileName { $0.fileName }
    }

    /// 實際的資料用快取（和首頁縮圖同一份），不在分享時重新抓。
    func pngData() async throws -> Data {
        let live = await EditorReuseCenter.liveData(for: document)
        guard let data = await EditorReuseRenderer.png(document: document, live: live, dark: dark) else {
            throw FormlessDesignImageError.renderFailed
        }
        return data
    }
}

/// 首頁設計列長按選單的「匯出圖片」：系統分享表（存到照片、檔案、傳給別人）。
struct FormlessExportImageMenuItem: View {
    let document: FormlessDocument
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let item = FormlessDesignImageExport(document: document, dark: colorScheme == .dark)
        // 分享表上方的預覽用首頁已經畫好的縮圖，打開選單時不另外畫。
        if let thumbnail = FormlessThumbnailCache.shared.cached(document, size: document.family.listThumbnailSize) {
            ShareLink(item: item, preview: SharePreview(document.name, image: Image(uiImage: thumbnail))) { label }
        } else {
            ShareLink(item: item, preview: SharePreview(document.name)) { label }
        }
    }

    private var label: some View {
        Label("匯出圖片", systemImage: "photo")
    }
}

// MARK: - 版本紀錄

/// 小工具設定裡的一列：「版本紀錄」與目前有幾個版本，點進去看列表。
struct EditorVersionHistoryRow: View {
    @ObservedObject var model: EditorModel
    @State private var count: Int?

    var body: some View {
        NavigationLink {
            EditorVersionHistoryPage(model: model)
        } label: {
            LabeledContent("版本紀錄", value: count.map { $0 == 0 ? "沒有" : "\($0) 個" } ?? "")
        }
        // 每次回到這一頁都重算（回復時會多留一個版本）。
        .task {
            let id = model.document.id
            count = await Task.detached { FormlessVersionStore.versions(of: id).count }.value
        }
    }
}

/// 版本紀錄：最近的版本（新的在前），每列縮圖與時間（「今天 下午 3:20」）。點一下問「回復到這個版本？」，
/// 回復前目前的樣子也留成一個版本，回復算一步復原。
struct EditorVersionHistoryPage: View {
    @ObservedObject var model: EditorModel
    @State private var versions: [FormlessVersion]?
    @State private var pending: FormlessVersion?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let versions {
                if versions.isEmpty {
                    Section {
                        Text("還沒有版本紀錄。").foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(versions) { version in
                            Button { pending = version } label: { row(version) }
                        }
                    }
                }
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .navigationTitle("版本紀錄")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .alert("回復到這個版本？", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { version in
            Button("回復") { restore(version) }
            Button("取消", role: .cancel) {}
        }
        .alert("無法回復", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("確定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ version: FormlessVersion) -> some View {
        HStack(spacing: FormlessDesign.Space.loose) {
            EditorVersionThumbnail(version: version, family: model.document.family)
            Text(version.displayTime())
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, FormlessDesign.Space.rowExtra)
        .contentShape(Rectangle())
    }

    private func reload() async {
        let id = model.document.id
        versions = await Task.detached { FormlessVersionStore.versions(of: id) }.value
    }

    private func restore(_ version: FormlessVersion) {
        pending = nil
        do {
            try model.restoreVersion(version)
            FormlessHaptics.success()
        } catch {
            FormlessHaptics.warning()
            errorMessage = error.localizedDescription
        }
        Task { await reload() }
    }
}

/// 畫好的版本縮圖與它的尺寸（版本可能是換尺寸之前的）。
struct EditorVersionImage {
    let image: UIImage
    let family: FormlessWidgetFamily
}

/// 版本的縮圖：和首頁縮圖同樣的大小與外框（圓角是小工具的 22 依縮圖比例縮小）。
/// 畫好之前先用目前設計的尺寸佔位。
struct EditorVersionThumbnail: View {
    let version: FormlessVersion
    let family: FormlessWidgetFamily
    @State private var rendered: EditorVersionImage?

    init(version: FormlessVersion, family: FormlessWidgetFamily) {
        self.version = version
        self.family = family
        _rendered = State(initialValue: EditorReuseCenter.shared.cachedThumbnail(for: version))
    }

    var body: some View {
        let shown = rendered?.family ?? family
        let size = shown.listThumbnailSize
        let radius = FormlessDesign.Radius.widget * min(size.width / shown.referenceWidth, size.height / shown.referenceHeight)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            Rectangle().fill(FormlessDesign.Palette.fill)
            if let rendered { Image(uiImage: rendered.image).resizable() }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline))
        .accessibilityHidden(true)
        .task(id: version.id) {
            guard rendered == nil else { return }
            // 換頁的推移期間不畫（主執行緒畫圖會讓動畫掉格），停下來再一張一張畫。
            try? await Task.sleep(for: .seconds(FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)))
            guard !Task.isCancelled else { return }
            rendered = await EditorReuseCenter.shared.thumbnail(for: version)
        }
    }
}

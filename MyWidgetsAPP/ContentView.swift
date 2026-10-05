import SwiftUI
import Combine
import WidgetKit
import UniformTypeIdentifiers
import CoreTransferable
import AppIntents
import PhotosUI
import UIKit

/// 舊設計以資源名稱指向 App 內圖片。把實際被圖層使用的圖片加入圖片庫，
/// 再把圖層改為一般圖片；素材清單由範本與文件取得，不另外維護一份寫死的名稱表。
private enum BundledLayerImageImport {
    static func templateNames() -> Set<String> {
        var names = Set(FormlessLayerType.allCases.flatMap { type -> [String] in
            let initial = FormlessTemplate.defaultLayer(for: type)
            let layers = [initial] + FormlessTemplate.explode(initial, family: .large)
            return layers.filter { $0.type == .bundleImage }.compactMap(\.value)
        })
        names.formUnion(FormlessWeatherCondition.allCases.flatMap { condition in
            [condition.assetName(isDay: true), condition.assetName(isDay: false)]
        })
        return names
    }

    /// 只收「設計裡真的用到」的內建圖片；不再把範本與天氣的內建圖片全部收進圖片庫
    /// （使用者：剛安裝、還沒匯入任何設計，圖片庫就有圖片，這是錯的）。
    static func assetIDs(for documents: [FormlessDocument]) -> [String: String] {
        let names = Set(documents.flatMap { $0.layers.filter { $0.type == .bundleImage }.compactMap(\.value) })
        var result: [String: String] = [:]
        for name in names.sorted() {
            guard let image = UIImage(named: name), let data = image.pngData(),
                  let item = FormlessAssetLibrary.add(data: data, title: name) else { continue }
            result[name] = item.id
        }
        return result
    }

    /// 舊版啟動時把範本與天氣的內建圖片全部收進了圖片庫。把這些沒有任何設計（含最近刪除）、天氣樣式用到的拿掉；只做一次。
    static func removeUnusedBundledImages(documents: [FormlessDocument]) {
        let defaults = UserDefaults.standard
        let flag = "formless.library.removedUnusedBundledImages"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        let bundled = templateNames()
        let all = documents + FormlessStorage.trashItems().map(\.document)
        var used = Set(FormlessWeatherStyle.current().images.values)
        for document in all {
            if let name = document.backgroundImageName { used.insert(name) }
            for layer in document.layers {
                if let value = layer.value { used.insert(value) }
                used.formUnion(layer.imageSet ?? [])
            }
        }
        for item in FormlessAssetLibrary.all() where bundled.contains(item.title) && !used.contains(item.id) {
            FormlessAssetLibrary.remove(item.id)
        }
    }

    @discardableResult
    static func migrate(_ document: inout FormlessDocument, using ids: [String: String]) -> Bool {
        var changed = false
        for index in document.layers.indices where document.layers[index].type == .bundleImage {
            guard let name = document.layers[index].value, let id = ids[name] else { continue }
            document.layers[index].type = .image
            document.layers[index].value = id
            changed = true
        }
        return changed
    }
}


// MARK: - 我的小工具

struct ContentView: View {

    @State private var documents: [FormlessDocument] = []
    @State private var showImporter = false
    @State private var showCreator = false
    @State private var errorMessage: String?
    /// 正在就地改名的小工具（和圖層列改名一樣直接在列上編輯）。
    @State private var renamingDocumentID: UUID?
    @State private var search = ""
    @State private var live = FormlessLiveData()
    @State private var previews: [UUID: FormlessLiveData] = [:]
    @State private var placement: [String: [FormlessWidgetFamily]] = [:]

    @State private var showPicker = false
    @State private var selectedTab = 0
    /// 每次切換分頁加一：讓圖片庫每次被選到都重新建立。
    @State private var tabVisit = 0
    @State private var editingDocument: FormlessDocument?
    /// 剛點進去的小工具：進入時亮起，回到首頁後淡回原色。
    @State private var highlightedDocumentID: UUID?
    /// 編輯器開著時首頁不重載、不重畫縮圖：兩者都在主執行緒逐一重繪每個小工具的縮圖（大型的一張就要幾百毫秒），
    /// 而快取更新（遠端圖片、天氣、行事曆寫進快取）、App 回到前景、定位完成、編輯器存檔都會觸發，時間點隨機，
    /// 使用者正在拖曳畫布時畫面就整個停住。首頁被推走了本來也看不到，回到首頁時再一次補上。
    @State private var pendingReload = false
    @State private var pendingPreviewRefresh = false
    /// 首頁分頁列的縮放狀態：三個分頁的捲動都會驅動它。
    @StateObject private var tabBarMinimize = FormlessMinimizeState()

    @Environment(\.scenePhase) private var scenePhase

    @State private var storageAvailable = true
    @State private var isLoading = true
    @State private var hasStarted = false
    @State private var isStarting = true
    @State private var previewGeneration = 0
    @State private var isImporting = false
    @State private var isRefreshing = false
    @State private var pendingForcedRefresh = false
    @State private var loadGeneration = 0
    @State private var contentWidth: CGFloat = 0
    @State private var showImageAdd = false

    var body: some View {
        // 導覽堆疊在 TabView 外層：推入編輯器時連標籤列一起被推走，
        // 回首頁時標籤列本來就在，不必等轉場結束才恢復。
        // 分頁內的工具列不會傳到外層導覽列，所以標題與按鈕統一掛在 TabView 上。
        NavigationStack {
        TabView(selection: $selectedTab) {
                listContent
                    .formlessTapToDismissKeyboard()
                    .scrollDismissesKeyboard(.immediately)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .tabItem { Label("設計", systemImage: "square.grid.2x2") }
            .tag(0)

            Group {
                if selectedTab == 1 {
                    // 每次切到圖片庫都是新的一頁（從頂端開始）：系統不會更新看不見的分頁，只靠 if 不會真的拆掉，
                    // 切回來會停在上次的位置。
                    ImageLibraryView(current: nil, minimizeState: selectedTab == 1 ? tabBarMinimize : nil, isManaging: true, externalAdd: $showImageAdd) { _ in }
                        .id(tabVisit)
                } else {
                    Color.clear
                }
            }
            .tabItem { Label("圖片庫", systemImage: "photo.on.rectangle") }
            .tag(1)

            AppSettingsView(
                isRefreshing: isRefreshing,
                onRefresh: { Task { await refreshData() } },
                onDocumentsChanged: { reload(); refreshWidgets() },
                minimizeState: selectedTab == 2 ? tabBarMinimize : nil
            )
            .tabItem { Label("設定", systemImage: "gearshape") }
            .tag(2)
        }
        // 往上拉時整條分頁列縮小、往下拉放大回來，和屬性面板的分類列同一套；不用系統的 tabBarMinimizeBehavior
        // （那是收合成只剩圖示，且要清單夠長才會動）。
        .background(FormlessHomeTabBarScaler(state: tabBarMinimize))
        .onChange(of: selectedTab) { _, _ in
            tabVisit += 1
            tabBarMinimize.restoreForTabSwitch()
        }
        .onChange(of: editingDocument) { _, document in
            guard document == nil else { return }
            // 返回的轉場結束、這一列回到畫面上之後才淡掉，看得到它從亮起變回原色。
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard editingDocument == nil else { return }
                withAnimation(.easeOut(duration: 0.5)) { highlightedDocumentID = nil }
            }
            let needsReload = pendingReload, needsPreviews = pendingPreviewRefresh
            pendingReload = false
            pendingPreviewRefresh = false
            Task {
                if needsReload { await loadDocuments() }
                if needsPreviews { await refreshPreviews() }
            }
        }
        // 進出編輯器不改分頁列大小：回到首頁時清單還停在原本的位置，分頁列要和它一致（捲動中就維持縮小）。
        // 原本進編輯器就先還原，回來時清單停在底部、分頁列卻是原尺寸，一滑動又突然縮小。
        // 回來時的對齊由 `FormlessScrollMinimizer` 在清單重新出現時依實際位移處理。
        .formlessPageTitle(selectedTab == 1 ? "圖片庫" : selectedTab == 2 ? "設定" : "")
        .toolbarBackgroundVisibility(selectedTab == 0 ? .hidden : .automatic, for: .navigationBar)
        .navigationDestination(item: $editingDocument) { document in
            WidgetEditorView(
                document: document,
                onSaved: { reload() },
                onPreviewUpdated: { reload() },
                onSaveError: { errorMessage = $0 }
            )
        }
        .toolbar {
            if selectedTab == 0 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("選取匯出") { showPicker = true }
                            .disabled(documents.isEmpty)
                        ShareLink(
                            item: FormlessBundleExport(documents: documents),
                            preview: SharePreview(FormlessBundleExport(documents: documents).fileName)
                        ) {
                            Text("匯出全部")
                        }
                        .disabled(documents.isEmpty)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("匯出")
                }
                ToolbarItem(placement: .principal) {
                    // 比原本長一些，但兩側留白，不與左右按鈕擠在一起。
                    FormlessSearchField(text: $search, prompt: "搜尋小工具")
                        .frame(width: max(150, contentWidth - 200))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新增小工具") { showCreator = true }
                        Button("匯入設計檔") { showImporter = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增")
                }
            } else if selectedTab == 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("加入圖片", systemImage: "plus") { showImageAdd = true }.labelStyle(.iconOnly)
                }
            }
        }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 { reload() }
        }
        .overlay {
            if isImporting {
                // 浮動提示一律是玻璃膠囊（和編輯器的提示泡泡同款）。
                ProgressView("正在匯入設計…")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .formlessGlass(.regular, in: .capsule)
            }
        }
        .disabled(isImporting)
        .task {
            await start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !isStarting else { return }

            Task {
                await loadDocuments()
                warmCaches()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FormlessCache.didUpdate)
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { _ in
                Task { await refreshPreviews() }
        }
        .onReceive(NotificationCenter.default.publisher(for: FormlessLocationProvider.didResolveLocation)
            .receive(on: RunLoop.main)) { _ in
                if !isStarting { warmCaches(force: true) }
        }
        .formlessHalfPanel(isPresented: $showCreator) {
            CreateWidgetView(onCreated: { reload() }, onClose: { showCreator = false })
        }
        .sheet(isPresented: $showPicker) {
            ExportPickerView(documents: documents).formlessSheetBackground()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(
            "發生錯誤",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("確定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var filteredDocuments: [FormlessDocument] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return documents }

        return documents.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading {
            ProgressView("載入小工具…")
        } else if !storageAvailable {
            StorageUnavailableView()
        } else if documents.isEmpty {
            ContentUnavailableView {
                Label("建立你的第一個小工具", systemImage: "square.grid.2x2")
            } description: {
                Text("建立新的小工具，或匯入現有的設計檔。")
            } actions: {
                Button("新增小工具") { showCreator = true }
                    .buttonStyle(.borderedProminent)
                Button("匯入設計檔") { showImporter = true }
            }
        } else if filteredDocuments.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List {
                ForEach(placedDocuments + unplacedDocuments) { document in
                    documentRow(document)
                }
            }
            .listStyle(.plain)
            // 只有目前顯示的分頁可以驅動分頁列縮放：TabView 會把其他分頁的清單留在畫面外，它們的捲動幾何一有變化
            // （例如版面重算）就回報「在頂端」，把正在縮小的分頁列又放大，看起來就是縮一半停住或沒縮。
            .formlessScrollMinimizer(state: selectedTab == 0 ? tabBarMinimize : nil)
            .environment(\.layoutDirection, .leftToRight)
            .scrollContentBackground(.hidden)
            // 關掉頂端的捲動邊緣霧化，內容要能直接被看見。
            .scrollEdgeEffectHidden(true, for: .top)
            // 頂端留白寫進內容裡，回彈後才不會被系統的浮動內距吃掉而變得太貼。
            .contentMargins(.top, 10, for: .scrollContent)
            // 底色延伸到狀態列，頂端才不會出現一條橫幅；清單直接捲到按鈕底下。
            .background(FormlessDesign.Palette.page.ignoresSafeArea())
            // 下拉更新只用系統的轉圈（使用者 10/04：上面再疊一個「正在更新資料…」膠囊很醜也重複）。
            .refreshable {
                await refreshData()
            }
        }
    }

    @ViewBuilder
    private func documentRow(_ document: FormlessDocument) -> some View {
        DocumentRow(
            document: document,
            live: previews[document.id] ?? live,
            placements: placements(for: document),
            highlighted: highlightedDocumentID == document.id,
            renaming: renamingDocumentID == document.id,
            onRename: { newName in
                renamingDocumentID = nil
                if let newName { rename(document, to: newName) }
            }
        )
        .formlessTapRow {
            guard renamingDocumentID != document.id else { return }
            // 點下去先亮起來再進編輯器；回來時這一列從亮起淡回原色，讓人知道剛剛點的是哪一個（和圖層列一樣）。
            highlightedDocumentID = document.id
            editingDocument = document
        }
        .listRowInsets(EdgeInsets(top: 6, leading: FormlessDesign.Space.edge, bottom: 6, trailing: FormlessDesign.Space.edge))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // 手指由右往左滑，從右側揭露刪除鍵；完整滑動也不直接刪除。
        .formlessTrailingSwipeDelete { delete(document) }
        .contextMenu {
            ShareLink(
                item: FormlessBundleExport(documents: [document]),
                preview: SharePreview(document.name)
            ) {
                Label("匯出", systemImage: "square.and.arrow.up")
            }


            Button {
                renamingDocumentID = document.id
            } label: {
                Label("改名", systemImage: "pencil")
            }

            Button {
                duplicate(document)
            } label: {
                Label("複製", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                delete(document)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    // MARK: 動作

    /// 啟動流程。全部在第一次繪製之後才做，畫面不會被擋住。
    private func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        defer { isStarting = false }
        storageAvailable = await Task.detached { FormlessStorage.sharedContainerURL != nil }.value

        guard storageAvailable else { isLoading = false; return }

        await loadDocuments()

        #if DEBUG
        // 開發用：模擬器驗證時直接打開某份設計（啟動參數 -FormlessDebugOpen <設計 id>）。交付的 Release 版沒有這段。
        if let id = UserDefaults.standard.string(forKey: "FormlessDebugOpen"),
           let document = documents.first(where: { $0.id.uuidString == id }) {
            editingDocument = document
        }
        #endif

        await requestPermissions()

        // 啟動時先用快取把畫面顯示出來，資料在背景更新
        warmCaches(force: true)
    }

    /// 四項權限一次問完，之後就不會再中途跳出來打斷操作
    private func requestPermissions() async {
        await FormlessPermissionSequence.run([
            {
                await FormlessEventsProvider.requestAccess()
                Task.detached(priority: .utility) {
                    if let events = FormlessEventsProvider.fetch() {
                        FormlessCache.save(events, name: FormlessEventsProvider.cacheName)
                    }
                }
            },
            {
                await FormlessRemindersProvider.requestAccess()
                Task.detached(priority: .utility) {
                    if let reminders = await FormlessRemindersProvider.fetch() {
                        FormlessCache.save(reminders, name: FormlessRemindersProvider.cacheName)
                    }
                }
            },
            {
                await FormlessStepsProvider.requestAccess()
                Task.detached(priority: .utility) {
                    if let steps = await FormlessStepsProvider.fetchToday() {
                        FormlessStepsCache.record(steps)
                    }
                }
            },
            {
                FormlessLocationProvider.shared.requestAccess()
                FormlessLocationProvider.shared.refresh()
            }
        ])
        // SideStore 安裝的版本沒有健康權限（簽名時被拿掉），步數改用計步器照常讀得到，不必每次跳提示。
        if let issue = FormlessStepsProvider.authorizationError, !issue.localizedCaseInsensitiveContains("entitlement") {
            errorMessage = "健康資料授權未完成：" + issue + "。可至「設定 → 資料來源 → 計步器」重試。"
        }
    }

    private func refreshPreviews() async {
        guard editingDocument == nil else { pendingPreviewRefresh = true; return }
        previewGeneration += 1
        let generation = previewGeneration
        let snapshot = documents
        let mapped = await Task.detached(priority: .utility) {
            let base = FormlessLiveData.fromCache()
            return snapshot.reduce(into: [UUID: FormlessLiveData]()) { result, document in
                result[document.id] = FormlessLiveData.cached(for: document, base: base)
            }
        }.value
        guard generation == previewGeneration, snapshot == documents else { return }
        FormlessThumbnailCache.shared.clear()
        previews = mapped
        await prewarmThumbnails()
    }

    /// 讀檔與預覽資料都在背景算好再一次套用
    private func loadDocuments() async {
        guard editingDocument == nil else { pendingReload = true; return }
        loadGeneration += 1
        let generation = loadGeneration
        let loaded = await Task.detached { () -> ([FormlessDocument], [UUID: FormlessLiveData]) in
            FormlessStorage.purgeExpiredTrash()
            var list = FormlessStorage.loadAll()
            let assetIDs = BundledLayerImageImport.assetIDs(for: list)
            for index in list.indices {
                if BundledLayerImageImport.migrate(&list[index], using: assetIDs) {
                    try? FormlessStorage.save(list[index])
                }
            }
            BundledLayerImageImport.removeUnusedBundledImages(documents: list)
            var mapped: [UUID: FormlessLiveData] = [:]
            let base = FormlessLiveData.fromCache()

            for document in list {
                mapped[document.id] = FormlessLiveData.cached(for: document, base: base)
            }

            return (list, mapped)
        }.value

        guard generation == loadGeneration else { return }
        isLoading = false
        documents = loaded.0
        previews = loaded.1
        live = FormlessLiveData.fromCache()
        refreshPlacement()
        await prewarmThumbnails()
    }

    /// 清單出現前先把縮圖算好，捲動時就不必臨時繪製。
    private func prewarmThumbnails() async {
        for document in documents {
            let size = document.family.listThumbnailSize
            guard FormlessThumbnailCache.shared.cached(document, size: size) == nil else { continue }
            FormlessThumbnailCache.shared.image(for: document, live: previews[document.id] ?? live, size: size)
            await Task.yield()
        }
    }

    private func reload() {
        Task { await loadDocuments() }
    }

    private func refreshData() async {
        // 已經在更新（例如剛進前景）：等它做完再收起下拉的轉圈，不另外再更新一次。
        guard !isRefreshing else {
            while isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        isRefreshing = true
        defer { finishRefresh() }
        await FormlessLiveData.bounded(20) {
            await FormlessLiveData.warmCaches(for: documents)
        }
        await refreshPreviews()
        refreshWidgets()
    }

    /// 讀出桌面上每一顆小工具目前選了哪個設計
    private func refreshPlacement() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let infos) = result else { return }

            var mapped: [String: [FormlessWidgetFamily]] = [:]

            for info in infos {
                var selected: String?

                if let intent = info.widgetConfigurationIntent(of: SmallWidgetIntent.self) {
                    selected = intent.selectedWidget?.id
                } else if let intent = info.widgetConfigurationIntent(of: MediumWidgetIntent.self) {
                    selected = intent.selectedWidget?.id
                } else if let intent = info.widgetConfigurationIntent(of: LargeWidgetIntent.self) {
                    selected = intent.selectedWidget?.id
                } else if let intent = info.widgetConfigurationIntent(of: ExtraLargeWidgetIntent.self) {
                    selected = intent.selectedWidget?.id
                }

                guard let selected else { continue }

                let family: FormlessWidgetFamily

                switch info.family {
                case .systemSmall: family = .small
                case .systemMedium: family = .medium
                case .systemLarge: family = .large
                case .systemExtraLargePortrait: family = .extraLarge
                default: continue
                }

                mapped[selected, default: []].append(family)
            }

            DispatchQueue.main.async {
                placement = mapped
            }
        }
    }

    private func placements(for document: FormlessDocument) -> [FormlessWidgetFamily] {
        placement[document.id.uuidString] ?? []
    }

    private var placedDocuments: [FormlessDocument] {
        filteredDocuments.filter { !placements(for: $0).isEmpty }
    }

    private var unplacedDocuments: [FormlessDocument] {
        filteredDocuments.filter { placements(for: $0).isEmpty }
    }

    private func refreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 進前景時補齊共用快取。App 在前景時的重載不算更新配額。
    private func finishRefresh() {
        isRefreshing = false
        if pendingForcedRefresh {
            pendingForcedRefresh = false
            warmCaches(force: true)
        }
    }

    private func warmCaches(force: Bool = false) {
        guard !isRefreshing else {
            pendingForcedRefresh = pendingForcedRefresh || force
            return
        }
        guard force || Date().timeIntervalSince(Self.lastWarm) > 300 else { return }
        isRefreshing = true

        Self.lastWarm = Date()
        let snapshot = documents

        Task.detached(priority: .utility) {
            FormlessAssetLibrary.adoptExisting()
            FormlessStorage.pruneAssets()
        }

        Task {
            defer { finishRefresh() }
            await FormlessLiveData.bounded(20) {
                await FormlessLiveData.warmCaches(for: snapshot)
            }

            await refreshPreviews()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static var lastWarm = Date.distantPast

    private func delete(_ document: FormlessDocument) {
        do {
            try FormlessStorage.trash(document)
            documents.removeAll { $0.id == document.id }
            reload()
            refreshWidgets()
            FormlessHaptics.rigid()
        } catch {
            FormlessHaptics.warning()
            errorMessage = error.localizedDescription
        }
    }

    private func duplicate(_ document: FormlessDocument) {
        do {
            _ = try FormlessStorage.duplicate(document)
            reload()
            refreshWidgets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename(_ document: FormlessDocument, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var copy = document
        copy.name = trimmed

        do {
            try FormlessStorage.save(copy)
            reload()
            refreshWidgets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }

            isImporting = true
            Task {
                defer { isImporting = false }
                let failed = await Task.detached(priority: .userInitiated) {
                    var failed: [String] = []
                    for url in urls {
                        do { try FormlessStorage.importDocuments(from: url) }
                        catch { failed.append(url.lastPathComponent + "：" + error.localizedDescription) }
                    }
                    return failed
                }.value
                await loadDocuments()
                refreshWidgets()
                if failed.isEmpty {
                    FormlessHaptics.success()
                } else {
                    FormlessHaptics.warning()
                    errorMessage = failed.joined(separator: "\n")
                }
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - 清單列

struct DocumentRow: View, Equatable {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let document: FormlessDocument
    var live: FormlessLiveData = FormlessLiveData()
    var placements: [FormlessWidgetFamily] = []
    /// 剛點進編輯器的那一列：底色和圖層列選取時一樣帶淺藍。
    var highlighted = false
    /// 就地改名中：名稱變成輸入框。
    var renaming = false
    var onRename: (String?) -> Void = { _ in }

    /// 清單列裡是一份完整的設計預覽。內容沒變就不重新計算，
    /// 否則首頁每次狀態變動都要重畫全部圖層。
    nonisolated static func == (lhs: DocumentRow, rhs: DocumentRow) -> Bool {
        lhs.document == rhs.document
            && lhs.live == rhs.live
            && lhs.placements == rhs.placements
            && lhs.highlighted == rhs.highlighted
            && lhs.renaming == rhs.renaming
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        // 縮圖的圓角是小工具實際的 22 依縮圖比例縮小（使用者：縮圖要和真的小工具一樣）。
        let thumbnailSize = document.family.listThumbnailSize
        let thumbnailRadius = FormlessDesign.Radius.widget * min(thumbnailSize.width / document.family.referenceWidth,
                                                                  thumbnailSize.height / document.family.referenceHeight)
        layout {
            FormlessDocumentThumbnail(document: document, live: live, size: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: thumbnailRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: thumbnailRadius, style: .continuous)
                        .strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline)
                }
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if renaming {
                    FormlessInlineNameField(name: document.name, font: .headline, onFinish: onRename)
                } else {
                    Text(document.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Text("\(document.family.displayName) · \(document.layers.filter { !$0.group }.count) 個圖層")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !placements.isEmpty {
                Text("使用中")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FormlessDesign.Palette.selectionFill, in: Capsule())
                    .accessibilityLabel("已加入桌面，使用中")
            }
        }
        .padding(12)
        // 卡片圓角和系統表單卡片相同（26 = 縮圖 14 + 內距 12，內外同心）。
        .background(FormlessDesign.Palette.card, in: RoundedRectangle(cornerRadius: FormlessDesign.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FormlessDesign.Radius.card, style: .continuous)
                .fill(FormlessDesign.Palette.selectionFill)
                .opacity(highlighted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: FormlessDesign.Radius.card, style: .continuous)
                .strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("開啟設計編輯器")
    }
}


extension FormlessWidgetFamily {
    /// 首頁清單的縮圖大小：寬 76；直式的超大型照寬 76 算會比 84 的格子高，改成高 80、寬照比例縮
    /// （小、中、大型維持原本的寬 76，大型高約 80）。
    var listThumbnailSize: CGSize {
        let height = 76 / aspectRatio
        return height <= 80 ? CGSize(width: 76, height: height) : CGSize(width: 80 * aspectRatio, height: 80)
    }
}

// MARK: - 新增小工具

/// 尺寸選單的項目。
struct FormlessFamilyOptions: View {
    var body: some View {
        ForEach(FormlessWidgetFamily.allCases, id: \.self) { item in
            Text(item.displayName).tag(item)
        }
    }
}

/// 新增小工具的尺寸示意：一顆極簡的小工具，版面語言取自 Formless 的圖示（一塊主色的大方塊加幾塊淡色方塊），
/// 小型是左邊一塊直的主色、右邊三塊；中型是左邊一塊正方形主色、右邊三條；大型是上方一塊主色、下方三條。
/// 盡量用滿面板剩下的空間（見 `scale`），換尺寸時方塊以彈簧動畫變形過去。沒有任何文字。
struct WidgetFamilyPreview: View {
    let family: FormlessWidgetFamily
    let boxHeight: CGFloat

    /// 用滿面板剩下的空間：小型與中型用同一個比例（中型剛好填滿寬度，兩者同高、小型是一半寬，比例正確）；
    /// 大型另外縮到剛好填滿高度（和中型同比例會高出面板）。
    private var scale: CGFloat {
        let boxWidth = FormlessSafeArea.windowWidth - 40
        let reference: FormlessWidgetFamily = family == .small ? .medium : family
        return min(boxWidth / reference.referenceWidth, boxHeight / reference.referenceHeight)
    }

    private struct Block: Identifiable {
        let id: Int
        let rect: CGRect
    }

    /// 在參考尺寸（pt）下排好的方塊，第 0 塊是主色。
    private var blocks: [Block] {
        let w = family.referenceWidth, h = family.referenceHeight
        let p: CGFloat = 14, g: CGFloat = 8
        let innerW = w - 2 * p, innerH = h - 2 * p
        var result: [CGRect] = []
        func rows(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [CGRect] {
            let rowH = (height - 2 * g) / 3
            return (0..<3).map { CGRect(x: x, y: y + CGFloat($0) * (rowH + g), width: width, height: rowH) }
        }
        switch family {
        case .small:
            let aw = (innerW - g) / 2
            result = [CGRect(x: p, y: p, width: aw, height: innerH)]
                + rows(x: p + aw + g, y: p, width: innerW - aw - g, height: innerH)
        case .medium:
            let aw = innerH
            result = [CGRect(x: p, y: p, width: aw, height: innerH)]
                + rows(x: p + aw + g, y: p, width: innerW - aw - g, height: innerH)
        case .large:
            let ah = (innerH * 0.42).rounded()
            result = [CGRect(x: p, y: p, width: innerW, height: ah)]
                + rows(x: p, y: p + ah + g, width: innerW, height: innerH - ah - g)
        case .extraLarge:
            let ah = (innerH * 0.32).rounded()
            result = [CGRect(x: p, y: p, width: innerW, height: ah)]
                + rows(x: p, y: p + ah + g, width: innerW, height: innerH - ah - g)
        }
        return result.enumerated().map { Block(id: $0.offset, rect: $0.element) }
    }

    var body: some View {
        let s = scale
        let outer = FormlessDesign.Radius.widget
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: outer * s, style: .continuous)
                .fill(FormlessDesign.Palette.card)
                .overlay {
                    RoundedRectangle(cornerRadius: outer * s, style: .continuous)
                        .strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline)
                }
                .frame(width: family.referenceWidth * s, height: family.referenceHeight * s)
            ForEach(blocks) { block in
                RoundedRectangle(cornerRadius: min(9, block.rect.height / 2) * s, style: .continuous)
                    .fill(block.id == 0 ? FormlessDesign.Palette.accent : FormlessDesign.Palette.tintFill)
                    .frame(width: block.rect.width * s, height: block.rect.height * s)
                    .offset(x: block.rect.minX * s, y: block.rect.minY * s)
            }
        }
        .frame(width: family.referenceWidth * s, height: family.referenceHeight * s, alignment: .topLeading)
        .animation(FormlessDesign.Motion.panel, value: family)
    }
}

struct CreateWidgetView: View {

    /// 半高面板：建立後或點面板外就關閉，不放「取消」。
    var onClose: () -> Void = {}
    private func dismiss() { onClose() }

    @State private var name = "未命名小工具"
    @State private var family: FormlessWidgetFamily = .medium
    @State private var errorMessage: String?
    /// 尺寸示意的框高上限（大型會用滿）：面板高度扣掉標題列 66、名稱與尺寸卡片 104、卡片到示意 20、
    /// 示意到底 20 與底部安全區（使用者規則：四邊等距）。小型、中型的示意是寬度先到，會比上限矮。
    @MainActor static var previewHeight: CGFloat {
        let gap = FormlessDesign.Space.panel
        return FormlessPanelMetrics.height - FormlessDesign.Size.titleBar - 104 - gap - gap - FormlessSafeArea.bottom
    }

    let onCreated: () -> Void

    init(onCreated: @escaping () -> Void, onClose: @escaping () -> Void = {}) {
        self.onCreated = onCreated
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                // 卡片不放標題（使用者規則）；名稱左名稱、右輸入，和小工具設定相同（只有提示字的話一打字就看不出這格是什麼）。
                Section {
                    EditorTextRow(title: "名稱", text: $name)

                    Picker("尺寸", selection: $family) {
                        FormlessFamilyOptions()
                    }
                }

                // 尺寸示意：用滿面板剩下的空間畫一顆極簡小工具。
                Section {
                    // 示意放在剩下的空間正中間：大型剛好用滿（上下各 20），小型、中型寬度先到，上下留一樣多。
                    WidgetFamilyPreview(family: family, boxHeight: Self.previewHeight)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.previewHeight)
                        .accessibilityHidden(true)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            // 卡片直接接在標題列下面（和新增圖層、位置與大小等面板相同，標題列本身已留好上下空間）；
            // 這裡的標題列是系統導覽列，實測 64 高，補 2 和其他面板的 66 標題列對齊。卡片到示意、示意到底都是 20。
            .contentMargins(.top, FormlessDesign.Size.titleBar - 64, for: .scrollContent)
            .listSectionSpacing(FormlessDesign.Space.panel)
            .formlessPageTitle("新增小工具")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立") { create() }
                }
            }
            .alert(
                "發生錯誤",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("確定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// 不再提供內建範本，一律從空白畫布開始。
    private var previewDocument: FormlessDocument {
        var document = FormlessTemplate.blankDocument(name: name, family: family)
        document.family = family
        return FormlessTemplate.editableDocument(document)
    }

    private func create() {
        var document = previewDocument

        document.id = UUID()
        document.family = family

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        document.name = trimmed.isEmpty ? document.name : trimmed

        let assetIDs = BundledLayerImageImport.assetIDs(for: [document])
        BundledLayerImageImport.migrate(&document, using: assetIDs)

        do {
            try FormlessStorage.save(document)
            onCreated()
            WidgetCenter.shared.reloadAllTimelines()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - 編輯器資料

/// 面板正在調哪一個條件顏色：rule 是 nil 表示平常的顏色。
struct EditorColorPreview: Equatable {
    let layerID: UUID
    let rule: Int?
}

@MainActor
final class EditorModel: ObservableObject {

    @Published var document: FormlessDocument {
        didSet {
            documentRevision &+= 1
            // 這份設計的來源與我的資料改了：畫布立刻用新的（快照由 refreshDataSnapshots 補）。
            if document.sources != oldValue.sources || document.variables != oldValue.variables {
                var next = live
                next.adopt(document)
                live = next
            }
            scheduleDataRefreshIfNeeded()
        }
    }
    /// 上一次抓資料時，這份設計用到的來源（來源 id 與設定）。
    private var dataSourceKey = ""
    private var dataRefreshTask: Task<Void, Never>?

    /// 用到的來源有變（新增圖表、文字插入資料、改地點）才抓；拖滑桿這類修改不會觸發。
    private func scheduleDataRefreshIfNeeded() {
        // 用到哪些來源，加上這份設計自己的來源設定（改地點也要重抓）。
        let used = FormlessDataCoordinator.sources(usedBy: document).map(\.id).joined(separator: "|")
        let key = used + "#" + (document.sources.map { String(describing: $0) } ?? "")
        guard key != dataSourceKey else { return }
        dataSourceKey = key
        dataRefreshTask?.cancel()
        dataRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshDataSnapshots()
        }
    }
    private(set) var documentRevision: UInt64 = 0
    @Published var selectedLayerID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var isolatedLayerID: UUID?
    /// 填色、顏色面板正在調的條件顏色：畫布上的這個圖層先顯示選中的那個顏色（不進文件、不進復原紀錄）。
    @Published var colorPreview: EditorColorPreview?
    /// 畫布的預覽外觀（淺色、深色、透明、染色、StandBy）與預覽資料（範例、沒有資料、很長的文字）；不進文件。
    @Published var previewAppearance: FormlessPreviewAppearance = .automatic
    @Published var previewData: FormlessPreviewData = .actual

    /// 畫布用的資料：依預覽資料換成範例、沒有資料或很長的文字。
    var canvasLive: FormlessLiveData {
        guard previewData != .actual else { return live }
        var copy = live
        copy.sampleMode = previewData == .sample
        copy.emptyMode = previewData == .empty
        copy.longTextMode = previewData == .long
        return copy
    }
    private struct HistoryEntry {
        let document: FormlessDocument
        var location: EditorHistoryLocation?
        /// 在這個狀態之後做的那一步編輯叫什麼（復原時退掉的就是它）；編輯紀錄清單顯示用。
        var title: String
        /// 這一步調了哪些參數（例如「上 +7」）；打開編輯紀錄時比對前後文件算出並記住，這一步還在累加時會重算。
        var detail: String?
        var detailResolved = false
    }
    weak var historySession: EditorSession?
    private var redoStack: [HistoryEntry] = []
    @Published var live = FormlessLiveData() {
        didSet { liveRevision &+= 1 }
    }
    private(set) var liveRevision: UInt64 = 0
    /// 畫布直接拖曳開始時各圖層的框（`beginCanvasDrag`）。
    var canvasDragFrames: [UUID: FormlessFrame]?
    /// 畫布在螢幕上的位置與縮放（`EditorPreview` 每次排版時更新）：拖曳時把手指位置換成畫布座標。
    var canvasMapping: (origin: CGPoint, scale: CGFloat, canvasSize: CGSize)?

    /// 螢幕上的點落在目前選取的圖層上（含外圍 10 pt）：從這裡開始拖就是移動圖層。
    func selectedLayerHit(atGlobal point: CGPoint) -> UUID? {
        guard let id = selectedLayerID, let mapping = canvasMapping, mapping.scale > 0,
              let layer = document.layers.first(where: { $0.id == id }) else { return nil }
        let local = CGPoint(x: (point.x - mapping.origin.x) / mapping.scale, y: (point.y - mapping.origin.y) / mapping.scale)
        let scale = mapping.canvasSize.height / document.family.referenceHeight
        let members = layer.group ? document.children(of: id) : [layer]
        let reach = 10 / mapping.scale
        return members.contains {
            FormlessLayerLayout.rotatedVisibleBounds(for: $0, canvasSize: mapping.canvasSize, scale: scale)
                .insetBy(dx: -reach, dy: -reach).contains(local)
        } ? id : nil
    }
    /// 選取模式下勾選的圖層；畫布據此畫框，讓使用者確認選對。
    @Published var pickedHighlight: Set<UUID> = []
    /// 對齊基準的記憶：同一群組（群組本身與其子圖層）共用一份，根層圖層共用另一份；只是編輯器狀態，不進文件也不進歷史。
    @Published var alignmentReferences: [EditorAlignmentScope: EditorAlignmentReference] = [:]
    /// 可見邊界是點陣量測，成本高；同一份文件、同一組圖層在一秒內重複查詢直接沿用結果。
    var visibleBoundsCache: [Set<UUID>: (document: UInt64, live: UInt64, at: Date, frame: FormlessFrame?)] = [:]

    private var undoStack: [HistoryEntry] = []
    private var pickingCheckpoint: (document: FormlessDocument, selectedID: UUID?,
                                    undo: [HistoryEntry], redo: [HistoryEntry],
                                    editKey: String?, editAt: Date)?
    private var savedDocument: FormlessDocument

    var hasUnsavedChanges: Bool { document != savedDocument }
    private var lastEditKey: String?
    private var lastEditAt = Date.distantPast

    init(document: FormlessDocument, selectedID: UUID? = nil) {
        var prepared = document
        prepared.layers.sort { $0.zIndex < $1.zIndex }

        for index in prepared.layers.indices {
            prepared.layers[index].zIndex = index
        }
        // 開檔時不動任何圖層的框：超出面板的圖層是設計的一部分，
        // 之前這裡會把所有框硬塞回面板內再自動存檔，等於一開檔就毀掉版面。
        self.document = prepared
        self.savedDocument = prepared
        self.selectedLayerID = selectedID.flatMap { id in
            prepared.layers.contains(where: { $0.id == id }) ? id : nil
        }
        self.live = FormlessLiveData()
    }

    func refreshLive() async {
        let snapshot = document
        live = await Task.detached { FormlessLiveData.cached(for: snapshot) }.value
        let refreshed = await FormlessLiveData.refreshed(for: snapshot)
        guard snapshot.id == document.id else { return }
        live = refreshed
    }

    var selectedLayer: FormlessLayer? {
        guard let selectedLayerID else { return nil }
        return document.layers.first { $0.id == selectedLayerID }
    }

    var designBinding: Binding<FormlessDocument> {
        Binding(
            get: { self.document },
            set: { value in
                guard value != self.document else { return }
                self.noteEdit(self.document.id)
                self.document = value
            }
        )
    }

    /// 畫布上要畫的樣子：填色、顏色面板正在調條件顏色時，這個圖層直接顯示面板選中的那個顏色。
    func previewed(_ layer: FormlessLayer) -> FormlessLayer {
        guard let preview = colorPreview, preview.layerID == layer.id,
              !(layer.colorRules ?? []).isEmpty || layer.colorScale != nil else { return layer }
        let rules = layer.colorRules ?? []
        var shown = layer
        if let index = preview.rule, rules.indices.contains(index) { shown.colorHex = rules[index].colorHex }
        if let index = preview.rule, let stop = EditorColorRuleRows.scaleStop(index), let stops = layer.colorScale?.stops,
           stops.indices.contains(stop) {
            shown.colorHex = stops[stop].colorHex
        }
        shown.colorRules = nil
        shown.colorScale = nil
        return shown
    }

    func layerBinding(_ id: UUID) -> Binding<FormlessLayer> {
        Binding(
            get: { [weak self] in
                self?.document.layers.first { $0.id == id } ?? FormlessLayer()
            },
            set: { [weak self] newValue in
                guard let self else { return }
                guard let index = self.document.layers.firstIndex(where: { $0.id == id }),
                      self.document.layers[index] != newValue else { return }
                self.noteEdit(id)
                self.document.layers[index] = newValue
            }
        )
    }

    /// 連續調同一個圖層的期間只記一次，避免每拖一格就佔一筆
    func noteEdit(_ id: UUID) {
        let location = historySession?.historyLocation(selectedLayerID: selectedLayerID)
        let key = id.uuidString + ":" + (location?.surface.rawValue ?? "") + ":" + (location?.category ?? "")
        let now = Date()
        let title = editTitle(for: id, location: location)

        if lastEditKey != key || now.timeIntervalSince(lastEditAt) > 1.5 {
            pushUndo(title)
        } else if !undoStack.isEmpty {
            undoStack[undoStack.count - 1].location = location
            undoStack[undoStack.count - 1].title = title
            undoStack[undoStack.count - 1].detailResolved = false
        }

        lastEditKey = key
        lastEditAt = now
    }

    /// 編輯紀錄裡的名稱：位置／大小看正在改的欄位，其他看所在分頁，再加上圖層名。
    private func editTitle(for id: UUID, location: EditorHistoryLocation?) -> String {
        if id == document.id { return "小工具設定" }
        let name = layerTitle(id)
        switch location?.propertyAnchor {
        case "visibleTop", "visibleLeft", "visibleRight", "visibleBottom": return "位置" + name
        case "visibleWidth", "visibleHeight": return "大小" + name
        default: break
        }
        if location?.surface == .batch { return "位置與對齊" }
        return (location?.category ?? "編輯") + name
    }
    func layerTitle(_ id: UUID) -> String {
        document.layers.first { $0.id == id }.map { "「\($0.name)」" } ?? ""
    }
    /// 編輯紀錄細項用的圖層名稱：依清單由上到下，最多列三個。
    func layerNames(_ ids: Set<UUID>) -> String {
        let names = document.layers.reversed().filter { ids.contains($0.id) }.map(\.name)
        return names.prefix(3).joined(separator: "、") + (names.count > 3 ? "…" : "")
    }
    /// 多個圖層時標題只寫「N 個圖層」，細項補上名稱；單一圖層時標題已帶名稱。
    func namesDetail(_ ids: Set<UUID>) -> String? {
        document.layers.filter { ids.contains($0.id) }.count > 1 ? layerNames(ids) : nil
    }
    func layersTitle(_ ids: Set<UUID>) -> String {
        let members = document.layers.filter { ids.contains($0.id) }
        if members.count == 1, let only = members.first { return "「\(only.name)」" }
        return " \(members.count) 個圖層"
    }

    /// 屬性、位置與大小這類編輯：細項等打開編輯紀錄時比對前後文件算出。
    func pushUndo(_ title: String) { pushUndo(title, detail: nil, resolved: false) }
    /// 結構類操作（對齊、群組、刪除、順序…）：細項在操作當下就知道，直接記下；nil 表示標題已經說完整。
    func pushUndo(_ title: String, detail: String?) { pushUndo(title, detail: detail, resolved: true) }
    private func pushUndo(_ title: String, detail: String?, resolved: Bool) {
        redoStack.removeAll()
        canRedo = false
        lastEditKey = nil
        undoStack.append(HistoryEntry(document: document,
                                      location: historySession?.historyLocation(selectedLayerID: selectedLayerID),
                                      title: title, detail: detail, detailResolved: resolved))

        if undoStack.count > 40 {
            undoStack.removeFirst()
        }

        canUndo = true
    }

    func beginPicking() {
        guard pickingCheckpoint == nil else { return }
        pickingCheckpoint = (document, selectedLayerID, undoStack, redoStack, lastEditKey, lastEditAt)
    }

    /// 選取模式中群組被清空時先保留（使用者規則：避免誤操作，例如移出後又想移回去），
    /// 結束選取模式才移除；取消選取模式會整批還原，群組自然回來。
    var defersEmptyGroupRemoval: Bool { pickingCheckpoint != nil }

    /// 結束選取模式：這次被清空的群組（進入前有圖層、或在選取模式中建立的）現在才移除；原本就空的群組不動。
    /// 不另記一筆復原：復原上一步會回到含這個群組的樣子。
    func finishPicking() {
        guard let checkpoint = pickingCheckpoint else { return }
        pickingCheckpoint = nil
        let occupiedBefore = Set(checkpoint.document.layers.compactMap(\.parentID))
        let existedBefore = Set(checkpoint.document.layers.map(\.id))
        let occupiedNow = Set(document.layers.compactMap(\.parentID))
        let emptied = Set(document.layers.filter { layer in
            layer.group && !occupiedNow.contains(layer.id)
                && (occupiedBefore.contains(layer.id) || !existedBefore.contains(layer.id))
        }.map(\.id))
        guard !emptied.isEmpty else { return }
        document.layers.removeAll { emptied.contains($0.id) }
        renumber()
        repairSelection()
    }

    func cancelPicking() {
        guard let checkpoint = pickingCheckpoint else { return }
        pickingCheckpoint = nil
        if document != checkpoint.document { document = checkpoint.document }
        selectedLayerID = checkpoint.selectedID
        undoStack = checkpoint.undo
        redoStack = checkpoint.redo
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        lastEditKey = checkpoint.editKey
        lastEditAt = checkpoint.editAt
        repairSelection()
    }

    @discardableResult func undo() -> EditorHistoryLocation? {
        guard let previous = undoStack.popLast() else { return nil }

        lastEditKey = nil
        lastEditAt = .distantPast
        var undone = previous
        if !undone.detailResolved { undone.detail = EditorHistoryDetail.describe(from: previous.document, to: document, live: live) }
        redoStack.append(HistoryEntry(document: document, location: previous.location, title: previous.title,
                                      detail: undone.detail, detailResolved: true))
        canRedo = true
        document = preservingGroupExpansion(in: previous.document)
        canUndo = !undoStack.isEmpty

        repairSelection()
        return previous.location
    }

    @discardableResult func redo() -> EditorHistoryLocation? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(HistoryEntry(document: document, location: next.location, title: next.title,
                                      detail: next.detail, detailResolved: next.detailResolved))
        document = preservingGroupExpansion(in: next.document)
        canUndo = true
        canRedo = !redoStack.isEmpty
        lastEditKey = nil
        lastEditAt = .distantPast
        repairSelection()
        return next.location
    }

    /// 本次編輯紀錄：只有這次開啟編輯器以來的步驟。第 0 步是開始編輯時的狀態，之後每一步是一次編輯；
    /// `historyIndex` 是目前所在的那一步，之後的步驟是可重做的。
    struct HistoryStep: Identifiable {
        let index: Int
        let title: String
        var detail: String?
        var id: Int { index }
    }
    var historySteps: [HistoryStep] {
        var steps = [HistoryStep(index: 0, title: "未編輯")]
        for (i, entry) in undoStack.enumerated() {
            steps.append(HistoryStep(index: i + 1, title: entry.title, detail: entry.detail))
        }
        for (j, entry) in redoStack.reversed().enumerated() {
            steps.append(HistoryStep(index: undoStack.count + 1 + j, title: entry.title, detail: entry.detail))
        }
        return steps
    }
    /// 打開編輯紀錄前補算還沒算過的參數說明：每一步的前一份文件是它自己存的狀態，後一份是下一步存的狀態
    /// （最後一步是目前的文件）；可重做的步驟存的是做完之後的狀態，前一份是再前一步的狀態。
    func resolveHistoryDetails() {
        for i in undoStack.indices where !undoStack[i].detailResolved {
            let after = i + 1 < undoStack.count ? undoStack[i + 1].document : document
            undoStack[i].detail = EditorHistoryDetail.describe(from: undoStack[i].document, to: after, live: live)
            undoStack[i].detailResolved = true
        }
        var before = document
        for j in redoStack.indices.reversed() {
            if !redoStack[j].detailResolved {
                redoStack[j].detail = EditorHistoryDetail.describe(from: before, to: redoStack[j].document, live: live)
                redoStack[j].detailResolved = true
            }
            before = redoStack[j].document
        }
    }
    var historyIndex: Int { undoStack.count }
    /// 直接跳到紀錄裡的某一步：往回就連續復原，往前就連續重做。
    func jumpToHistory(_ index: Int) {
        while undoStack.count > index, canUndo { undo() }
        while undoStack.count < index, canRedo { redo() }
    }

    /// 收合狀態是清單的檢視狀態，不跟著文件編輯紀錄倒退或前進。
    private func preservingGroupExpansion(in snapshot: FormlessDocument) -> FormlessDocument {
        var restored = snapshot
        let collapsedByID = Dictionary(uniqueKeysWithValues: document.layers.filter(\.group).map { ($0.id, $0.isCollapsed) })
        for index in restored.layers.indices where restored.layers[index].group {
            if let collapsed = collapsedByID[restored.layers[index].id] {
                restored.layers[index].isCollapsed = collapsed
            }
        }
        return restored
    }

    func repairSelection() {
        // 沒有選取就維持沒有選取；只有原本選到的圖層消失時才退回最前面的圖層。
        if let selected = selectedLayerID, !document.layers.contains(where: { $0.id == selected }) {
            selectedLayerID = document.layers.last?.id
        }
        if !document.layers.contains(where: { $0.id == isolatedLayerID }) { isolatedLayerID = nil }
    }

    /// 畫面由前到後：最上層的圖層排在清單最上面，與儲存順序相反。
    var displayRows: [FormlessLayerRow] {
        Self.rows(for: document.layers)
    }

    /// 把選取的圖層一次收進新群組。已在其他群組裡的會改掛到新群組。
    /// 群組出現在最前面那個成員原本的位置，成員依原本前後順序緊接在群組之後，前後關係不變。
    @discardableResult
    func groupLayers(_ ids: Set<UUID>) -> UUID? {
        let members = document.layers.filter { ids.contains($0.id) && !$0.group }
        guard !members.isEmpty else { return nil }

        let group = FormlessLayer(
            name: "群組",
            type: .shape,
            frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
            isGroup: true
        )
        let memberIDs = Set(members.map(\.id))
        let oldParents = Set(members.compactMap(\.parentID))

        var front = Array(document.layers.reversed())
        guard let insertAt = front.firstIndex(where: { memberIDs.contains($0.id) }) else { return nil }
        var block = front.filter { memberIDs.contains($0.id) }
        for index in block.indices { block[index].parentID = group.id }
        front.removeAll { memberIDs.contains($0.id) }
        front.insert(contentsOf: [group] + block, at: insertAt)

        var next = Array(front.reversed())
        if !defersEmptyGroupRemoval {
            let occupiedParents = Set(next.compactMap(\.parentID))
            next.removeAll { $0.group && oldParents.subtracting(occupiedParents).contains($0.id) }
        }

        pushUndo("建立群組", detail: layerNames(Set(members.map(\.id))))
        document.layers = next
        renumber()
        // 同 addGroup：新群組不設為選取，避免建立群組後清單列與畫布外框一直是藍色的。
        selectedLayerID = nil
        return group.id
    }

    func setParent(_ id: UUID, to groupID: UUID?) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !document.layers[index].group else { return }

        let oldParent = document.layers[index].parentID
        guard oldParent != groupID else { return }
        let groupName = (groupID ?? oldParent).map(layerTitle) ?? ""
        pushUndo((groupID == nil ? "移出群組" : "移入群組") + layerTitle(id),
                 detail: groupName.isEmpty ? nil : (groupID == nil ? "自" : "至") + groupName)
        document.layers[index].parentID = groupID
        if let oldParent { removeEmptiedGroups([oldParent]) }
        renumber()
        repairSelection()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id && $0.group }) else { return }
        document.layers[index].isCollapsed = !(document.layers[index].isCollapsed ?? false)
    }

    /// 直接設定群組收合狀態；收合不進復原紀錄。
    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let index = document.layers.firstIndex(where: { $0.id == id && $0.group }),
              (document.layers[index].isCollapsed ?? false) != collapsed else { return }
        document.layers[index].isCollapsed = collapsed
    }

    /// 移動群組等於一起移動裡面所有圖層
    func nudgeGroup(_ id: UUID, dx: Double, dy: Double) {
        translate([id], dx: dx * 1600, dy: dy * 1600)
    }

    func deleteGroup(_ id: UUID) {
        guard document.layers.contains(where: { $0.id == id && $0.group }) else { return }
        pushUndo("刪除群組" + layerTitle(id), detail: nil)

        for index in document.layers.indices where document.layers[index].parentID == id {
            document.layers[index].parentID = nil
        }

        document.layers.removeAll { $0.id == id }
        renumber()

        if selectedLayerID == id {
            selectedLayerID = document.layers.last?.id
        }
    }

    func toggleHidden(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }

        pushUndo(((document.layers[index].isHidden ?? false) ? "顯示" : "隱藏") + layerTitle(id), detail: nil)
        document.layers[index].isHidden = !(document.layers[index].isHidden ?? false)
    }

    func toggleLocked(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }

        pushUndo(((document.layers[index].isLocked ?? false) ? "解除鎖定" : "鎖定") + layerTitle(id), detail: nil)
        document.layers[index].isLocked = !(document.layers[index].isLocked ?? false)
    }

    /// 一次設定多個圖層的鎖定狀態，合成一筆復原；狀態已相同的略過。
    func setLocked(_ ids: Set<UUID>, _ locked: Bool) {
        let indices = document.layers.indices.filter {
            ids.contains(document.layers[$0].id) && (document.layers[$0].isLocked ?? false) != locked
        }
        guard !indices.isEmpty else { return }
        pushUndo((locked ? "鎖定" : "解除鎖定") + layersTitle(ids), detail: namesDetail(ids))
        for i in indices { document.layers[i].isLocked = locked }
    }

    func addLayer(_ type: FormlessLayerType) {
        pushUndo("新增「\(type.displayName)」", detail: nil)

        var layer = Self.newLayer(type, live: live)
        layer.id = UUID()
        layer.zIndex = document.layers.count

        let stack = FormlessTemplate.editableDocument(
            FormlessDocument(family: document.family, layers: [layer])
        ).layers
        document.layers.append(contentsOf: stack)
        renumber()
        selectedLayerID = stack.last?.id
    }

    /// 曲線文字（2026-10）：一般的文字圖層，只是沿框的內切圓排在上方；框做成正方形，圓才是正圓。
    func addCurvedText() {
        pushUndo("新增「曲線文字」", detail: nil)
        var layer = Self.newLayer(.text, live: live)
        layer.id = UUID()
        layer.zIndex = document.layers.count
        layer.name = "曲線文字"
        layer.value = "沿著圓弧排列的文字"
        layer.textArc = FormlessArcPlacement.top.rawValue
        layer.fontSize = 16
        layer.alignment = "center"
        let height = 0.8
        let width = min(0.9, height * document.family.referenceHeight / document.family.referenceWidth)
        layer.frame = FormlessFrame(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        document.layers.append(layer)
        renumber()
        selectedLayerID = layer.id
    }

    /// 新增圖層的預設內容。日期、時間、即時文字維持各自的入口，但底下都是同一種文字圖層，只是先放好
    /// 日期、時間或一段資料（10/03 決定）：之後可以在同一行加字、加別的資料。
    static func newLayer(_ type: FormlessLayerType, live: FormlessLiveData) -> FormlessLayer {
        var layer = FormlessTemplate.defaultLayer(for: type)
        let segment: FormlessTextSegment
        switch type {
        case .date:
            var format = FormlessFormat()
            format.dateStyle = "M月d日"
            segment = .data(FormlessBinding(source: "dateTime", field: "today", format: format))
        case .time:
            var format = FormlessFormat()
            format.dateStyle = "ah:mm"
            segment = .data(FormlessBinding(source: "dateTime", field: "now", format: format))
        case .liveText:
            segment = .data(FormlessBinding(source: "activity", field: "steps"))
        default:
            return layer
        }
        layer.type = .text
        layer.value = nil
        layer.editorSetSegments([segment], live: live)
        return layer
    }

    func deleteLayer(_ id: UUID) {
        guard let layer = document.layers.first(where: { $0.id == id }) else { return }
        pushUndo("刪除" + layerTitle(id), detail: nil)
        document.layers.removeAll { $0.id == id }
        removeEmptiedGroups(Set([layer.parentID].compactMap { $0 }))
        renumber()

        if selectedLayerID == id {
            selectedLayerID = document.layers.last?.id
        }
    }

    /// 複製到系統剪貼簿。群組連同子圖層一起帶走，貼到任何設計都能還原結構。
    func copyLayer(_ id: UUID) {
        guard let layer = document.layers.first(where: { $0.id == id }) else { return }

        var layers = [layer]
        if layer.group {
            layers += document.children(of: id)
        }

        FormlessLayerClipboard.write(layers, family: document.family)
    }

    /// 從剪貼簿貼上。識別碼全部重新產生，群組關係保留，貼到目前選取的位置之後。
    @discardableResult
    func pasteLayers() -> Int {
        guard let incoming = FormlessLayerClipboard.read(for: document.family), !incoming.isEmpty else { return 0 }

        var mapping: [UUID: UUID] = [:]
        for layer in incoming { mapping[layer.id] = UUID() }

        let pasted = incoming.map { layer -> FormlessLayer in
            var copy = layer
            copy.id = mapping[layer.id]!
            if let parent = layer.parentID {
                copy.parentID = mapping[parent]
            }
            return copy
        }

        let pastedNames = pasted.filter { $0.parentID == nil }.map(\.name)
        pushUndo("貼上圖層", detail: pastedNames.prefix(3).joined(separator: "、") + (pastedNames.count > 3 ? "…" : ""))

        let insertAt = selectedLayerID
            .flatMap { id in document.layers.firstIndex { $0.id == id } }
            .map { $0 + 1 } ?? document.layers.count

        document.layers.insert(contentsOf: pasted, at: insertAt)
        renumber()
        selectedLayerID = pasted.first { !$0.group }?.id ?? pasted.first?.id

        return pasted.count
    }

    // 剪貼簿只在使用者按下「貼上」時讀取。

    func duplicateLayer(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }

        pushUndo("複製" + layerTitle(id), detail: nil)

        var copy = document.layers[index]
        copy.id = UUID()
        copy.name = copy.name + " 複製"
        copy.frame.x += 0.03
        copy.frame.y += 0.03

        document.layers.insert(copy, at: index + 1)
        renumber()
        selectedLayerID = copy.id
    }

    func moveUp(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        guard index < document.layers.count - 1 else { return }

        pushUndo("上移" + layerTitle(id), detail: nil)
        document.layers.swapAt(index, index + 1)
        renumber()
    }

    func moveDown(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        guard index > 0 else { return }

        pushUndo("下移" + layerTitle(id), detail: nil)
        document.layers.swapAt(index, index - 1)
        renumber()
    }

    func updateFrame(_ id: UUID, frame: FormlessFrame) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        guard document.layers[index].frame != frame else { return }

        pushUndo("拖曳" + layerTitle(id))
        document.layers[index].frame = Self.isCircle(document.layers[index]) ? circleFrame(frame) : frame
    }

    func renumber() {
        for index in document.layers.indices {
            if document.layers[index].zIndex != index { document.layers[index].zIndex = index }
        }
    }

    func saveAsync() async throws {
        guard hasUnsavedChanges else { return }
        renumber()
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.isEmpty ? "未命名小工具" : name
        if document.name != normalizedName { document.name = normalizedName }
        let snapshot = document
        try await Task.detached(priority: .utility) { try FormlessStorage.save(snapshot) }.value
        savedDocument = snapshot
        FormlessWidgetReload.request()
    }

    func save() throws {
        guard hasUnsavedChanges else { return }
        renumber()
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.isEmpty ? "未命名小工具" : name
        if document.name != normalizedName { document.name = normalizedName }
        try FormlessStorage.save(document)
        savedDocument = document
        FormlessWidgetReload.request()
    }
}


// MARK: - 匯出

struct FormlessBundleExport: Transferable {

    let documents: [FormlessDocument]

    var fileName: String {
        if documents.count == 1 {
            let name = documents[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? "Formless" : name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")) + ".json"
        }

        return "Formless-\(documents.count)份.json"
    }

    // 用檔案交給分享表（原本是 DataRepresentation）：「儲存至檔案」拿到的是寫好的 .json 檔。
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            SentTransferredFile(try FormlessStorage.writeBundleFile(item.documents, fileName: item.fileName))
        }
    }
}


// MARK: - 編輯器

struct WidgetEditorView: View {
    @StateObject private var model: EditorModel
    @StateObject private var session: EditorSession
    /// 版面用的選取狀態（比 session.picking 晚一輪，見 EditorSession.picking）。
    @ObservedObject private var layout: EditorLayoutState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLayerPicker = false
    @State private var showDesign = false
    @State private var errorMessage: String?
    @State private var saving = false
    @StateObject private var keyboard = FormlessKeyboardObserver()
    let onSaved: () -> Void
    let onPreviewUpdated: () -> Void
    let onSaveError: (String) -> Void

    init(document: FormlessDocument, onSaved: @escaping () -> Void, onPreviewUpdated: @escaping () -> Void = {}, onSaveError: @escaping (String) -> Void = { _ in }) {
        let state = EditorSession.session(for: document.id)
        _model = StateObject(wrappedValue: EditorModel(document: document, selectedID: state.selectedID))
        _session = StateObject(wrappedValue: state)
        _layout = ObservedObject(wrappedValue: state.layout)
        self.onSaved = onSaved
        self.onPreviewUpdated = onPreviewUpdated
        self.onSaveError = onSaveError
    }

    var body: some View {
        GeometryReader { geometry in
            // 畫布延伸到螢幕頂端，導覽列只留原生 liquid glass 按鈕浮在畫布上，不再獨佔一列。
            VStack(spacing: 0) {
                ResizableEditorPreview(model: model, availableHeight: geometry.size.height,
                                       collapsed: keyboard.visible, keyboardHeight: keyboard.height,
                                       // 選取工具列只向畫布借 24 pt；工具列上下各留 12，清單在選取模式改用較小的頂端內距，
                                       // 讓按鈕到畫布、按鈕到第一列的距離差不多（約 24），不會一邊貼畫布一邊離清單很遠。
                                       selectionInset: layout.picking && !session.inspecting ? 24 : 0,
                                       toolPanels: session.toolPanels,
                                       onSelect: select)
                    .zIndex(1)
                // 工具列一直留在畫面裡，只收高、淡出、不接觸控；進出選取模式時整組拆掉／重建（四顆玻璃按鈕加選單）
                // 是最花時間的一步，會讓往回推的動畫第一格卡住（使用者回報）。
                let toolbarShown = layout.picking && !session.inspecting
                PickingLayerToolbar(model: model, session: session)
                    .frame(height: toolbarShown ? 68 : 0)
                    .clipped()
                    .opacity(toolbarShown ? 1 : 0)
                    .allowsHitTesting(toolbarShown)
                    .accessibilityHidden(!toolbarShown)
                    // 清單在選取模式往上靠到工具列底部的留白裡（見下方），工具列要在清單上面才按得到。
                    .zIndex(3)
                ZStack {
                    LayerListView(model: model, session: session, layout: layout, onAdd: { showLayerPicker = true }, onSelect: select)
                        .allowsHitTesting(!session.inspecting)
                        .accessibilityHidden(session.inspecting)
                    // 位移狀態留在屬性面板自身；拖曳時不反覆重算畫布與整份圖層清單。
                    if session.inspecting {
                        EditorInteractiveInspector(width: geometry.size.width,
                                                   isEnabled: !showDesign && !showLayerPicker,
                                                   blocked: { [session] in session.toolPanels.anyPresented }) {
                            endEditing()
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                session.inspecting = false
                                model.selectedLayerID = nil
                                session.selectedID = nil
                            }
                        } content: {
                            inspectorPanel
                        }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("editor-inspector-panel")
                            .transition(.move(edge: .trailing))
                    }
                }
                // 屬性面板進出是推移（和鍵盤、選取工具列同速 0.25 秒）。
                .animation(FormlessDesign.Motion.push, value: session.inspecting)
                // 選取模式的清單頂端間距較小：清單的內距固定不變，改由這裡往上靠，和畫布、工具列同一個動畫移動。
                // 原本是切換清單內距（UIKit 另開動畫），比 SwiftUI 動畫早一兩格開始，內容先被推下約 3 pt 再被帶上去，
                // 看起來小震一下（使用者回報）；兩套動畫的時間差不固定，延後也對不準。
                .padding(.top, layout.picking && !session.inspecting
                         ? EditorPanelUnderlap.pickingHeight - EditorPanelUnderlap.height : 0)
                .zIndex(layout.picking && !session.inspecting ? 2 : 0)
            }
            // 選取工具列出現／消失時會把畫布往上推、把清單往下推；三者在同一個動畫裡移動，不再各自跳一下。
            .animation(FormlessMotion.push, value: layout.picking && !session.inspecting)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .ignoresSafeArea(.container, edges: .top)
            // 鍵盤不縮小編輯器版面；避讓由 FormlessKeyboardAvoider 直接捲表單，和鍵盤同一個動畫。
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // GeometryReader 本身也要忽略鍵盤：否則它量到的高度會隨鍵盤縮短，畫布高度上限跟著跳一次。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // 選取模式的「位置與大小」面板與顏色面板：高度是螢幕的 60%，貼齊螢幕底邊；鍵盤出現時面板不動（只捲裡面的表單）。
        .overlay {
            EditorToolPanelLayer(model: model, session: session, panels: session.toolPanels,
                                 picking: session.picking, inspecting: session.inspecting)
        }
        // 離開屬性面板或換圖層時收起顏色面板（它綁的是原本那個圖層的欄位）。
        .onChange(of: session.inspecting) { _, inspecting in
            if !inspecting { session.toolPanels.color = nil; session.toolPanels.style = nil; session.toolPanels.symbol = nil }
        }
        .onChange(of: model.selectedLayerID) { _, _ in
            session.toolPanels.color = nil; session.toolPanels.style = nil; session.toolPanels.symbol = nil
            session.toolPanels.background = false
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        // 左上角不放返回鍵，回首頁靠左滑；隱藏返回鍵會讓系統停用左滑，用下面的元件接回來。
        .navigationBarBackButtonHidden(true)
        // 新增圖層、工具面板開著時也不能左滑回首頁（面板一律不左右滑動）。
        .background(FormlessPopGestureEnabler(isEnabled: !session.inspecting,
                                              blocked: { [session] in session.layerPickerOpen || session.toolPanels.anyPresented }))
        // 畫布延伸在導覽列底下：按鈕以外的地方要點得到畫布上的圖層。
        .background(FormlessNavigationBarPassThrough())
        // 使用系統 toolbar 項目：尺寸與首頁一致，換頁時由系統播放 liquid glass 融合轉場。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 點一下復原／重做；按住 0.3 秒出現編輯紀錄，可直接跳到任一步。
                // 復原本身不做任何標示、不切換介面：文件退回上一步，面板只反映目前的值。
                EditorHistoryControls(model: model, beforeAction: endEditing)
            }
            // 設定放左上、復原與重做留在右上（2026-10-04 使用者決定）。
            ToolbarItem(placement: .topBarLeading) {
                // 會立刻反映在畫布上的底色不放進蓋住畫布的設定頁（使用者規則）：從這裡直接開顏色面板。
                Menu {
                    Button("底色", systemImage: "paintpalette") { endEditing(); openBackgroundColor() }
                    Menu("預覽", systemImage: "eye") {
                        Picker("外觀", selection: $model.previewAppearance) {
                            ForEach(FormlessPreviewAppearance.homeScreenCases) { item in
                                Label(item.displayName, systemImage: item.symbol).tag(item)
                            }
                        }
                        .pickerStyle(.inline)
                        Picker("資料", selection: $model.previewData) {
                            ForEach(FormlessPreviewData.allCases) { item in
                                Label(item.displayName, systemImage: item.symbol).tag(item)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    Button("小工具設定", systemImage: "slider.horizontal.3") { endEditing(); showDesign = true }
                } label: {
                    Label("小工具設定", systemImage: "slider.horizontal.3")
                }
            }
        }
        .formlessHalfPanel(isPresented: $showLayerPicker) {
            LayerPickerView(onSelect: { type in
                model.addLayer(type)
                guard let id = model.selectedLayerID else { return }
                // 回到清單時停在新圖層那一列（使用者：原本停在上一次捲到的位置，不直覺）。
                session.listAnchor = id
                // 剛新增、還沒有內容的圖層先開在該做的事上（使用者規則）：要先決定內容的開在「內容」，色塊開在「外觀」。
                if let category = EditorNewLayerGuide.category(for: type) { session.beginGuidedEntry(category, layer: id) }
                // 圖片圖層一加入就讓使用者選圖；不選直接關掉也可以，之後在「內容」再選。
                if type == .image { session.pendingImagePick = id }
                // 文字、網路圖片一加入就可以打字；圖示一加入就挑圖示。
                if EditorNewLayerGuide.focusesInput(type) { session.pendingInputFocus = id }
                if type == .symbol { session.pendingSymbolPick = id }
                // 即時文字一加入就挑要哪一份資料。
                if type == .liveText { session.pendingDataPick = id }
                select(id)
            }, onSelectComponent: { component in
                // 我的組合：整組放進目前的設計，選取這個群組。
                guard let id = model.insertComponent(component) else { return }
                session.listAnchor = id
                select(id)
            }, onSelectCurvedText: {
                model.addCurvedText()
                guard let id = model.selectedLayerID else { return }
                session.listAnchor = id
                // 和文字一樣：先到「內容」，預設文字反白，一打字就取代。
                session.beginGuidedEntry("內容", layer: id)
                session.pendingInputFocus = id
                select(id)
            }, onClose: { showLayerPicker = false })
        }
        // 彈出面板一律沒有只用來關閉的「完成」：往下滑（或點面板外）關閉，改動當下就生效（使用者：要統一）。
        .sheet(isPresented: $showDesign, onDismiss: endEditing) {
            NavigationStack {
                DesignTab(model: model)
                    .navigationTitle("小工具設定")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .formlessSheetBackground()
        }
        .onAppear { model.historySession = session }
        .task { await model.refreshLive(); onPreviewUpdated() }
        #if DEBUG
        // 開發用：-FormlessDebugLayer <圖層名稱> -FormlessDebugTab <分頁> -FormlessDebugPanel data|format|design。
        .task {
            let defaults = UserDefaults.standard
            // -FormlessDebugPreview <外觀> -FormlessDebugData <資料>：直接用某個預覽情境開畫布。
            if let raw = defaults.string(forKey: "FormlessDebugPreview"), let appearance = FormlessPreviewAppearance(rawValue: raw) {
                model.previewAppearance = appearance
            }
            if let raw = defaults.string(forKey: "FormlessDebugData"), let data = FormlessPreviewData(rawValue: raw) {
                model.previewData = data
            }
            // -FormlessDebugImportFont <字型檔路徑>：從電腦匯入字型（只在自己的測試模擬器用）。
            if let path = defaults.string(forKey: "FormlessDebugImportFont") {
                do {
                    let fonts = try FormlessFontLibrary.importFont(at: URL(fileURLWithPath: path))
                    print("DEBUG imported fonts:", fonts.map { $0.postScriptName + " " + $0.displayName })
                } catch {
                    print("DEBUG import font failed:", error.localizedDescription)
                }
            }
            guard let name = defaults.string(forKey: "FormlessDebugLayer"),
                  let layer = model.document.layers.first(where: { $0.name == name }) else {
                if defaults.string(forKey: "FormlessDebugPanel") == "design" { showDesign = true }
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            if let tab = defaults.string(forKey: "FormlessDebugTab") { session.category = tab }
            select(layer.id)
            try? await Task.sleep(for: .milliseconds(700))
            switch defaults.string(forKey: "FormlessDebugPanel") {
            case "data"?: session.toolPanels.data = EditorDataPanelRequest(layerID: layer.id, target: .insertSegment(nil))
            case "format"?: session.toolPanels.format = EditorFormatPanelRequest(layerID: layer.id, slot: .segment(defaults.integer(forKey: "FormlessDebugSegment")))
            case "design"?: showDesign = true
            case "corner"?: session.toolPanels.style = EditorStylePanelRequest(layerID: layer.id, kind: .corner)
            case "text"?: session.toolPanels.style = EditorStylePanelRequest(layerID: layer.id, kind: .text)
            case "color"?:
                session.toolPanels.color = EditorColorPanelRequest(title: "顏色", supportsOpacity: true, layerID: layer.id,
                                                                   keyPath: \.colorHex, fallback: "#000000",
                                                                   rulesLayerID: layer.id, rulesFallback: "#000000")
            default: break
            }
        }
        #endif
        .onChange(of: showDesign) { _, open in session.designOpen = open }
        .onChange(of: showLayerPicker) { _, open in session.layerPickerOpen = open }
        .task(id: model.documentRevision) {
            guard model.hasUnsavedChanges else { return }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            await save()
        }
        .onChange(of: model.selectedLayerID) { _, id in session.selectedID = id }
        .onChange(of: session.picking) { _, picking in
            if picking { model.beginPicking() } else { model.finishPicking() }
            model.pickedHighlight = picking ? session.picked : []
        }
        .onChange(of: session.picked) { _, picked in
            model.pickedHighlight = session.picking ? picked : []
        }
        .onAppear {
            if session.picking { model.beginPicking() }
            model.pickedHighlight = session.picking ? session.picked : []
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { endEditing(); Task { await save(); FormlessWidgetReload.flush() } }
        }
        .onDisappear {
            endEditing()
            // 在選取模式中直接離開編輯器：等同結束選取模式（變更保留），被清空的群組在存檔前移除。
            model.finishPicking()
            session.resetForExit()
            Task { await save(); FormlessWidgetReload.flush(); onPreviewUpdated() }
        }
        .editorReusePrompts(model: model)
        .alert("儲存失敗", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("重試") { Task { await save() } }
            Button("取消", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var inspectorPanel: some View {
        // 分類固定在面板頂端（畫布正下方），內容在它下面捲動，不再浮在內容上（2026-10-05 方案 A：
        // 原本底部的浮動分類列在空間少時擋住內容，縮小後切換分類的玻璃動畫也會出錯）。
        // 分類列本身和原本一樣是系統 UITabBar 的 Liquid Glass（使用者要求保留），大小不變、不跟著捲動縮放。
        // 分類列和內容是同一個 VStack 的兄弟：切換分類時只有內容換 id，分類列不會被重建，玻璃動畫才能完整播完。
        VStack(spacing: 0) {
            EditorCategoryTabBar(selection: $session.category,
                                 titles: model.selectedLayer?.group == true ? ["版面", "其他"] : ["版面", "外觀", "內容", "其他"])
                .frame(height: 48)
                // 系統分頁列的玻璃條畫在自己框內再往內 20 的位置：框從螢幕邊開始，玻璃條左右兩緣才會都落在 20。
                .padding(.horizontal, FormlessDesign.Space.edge - EditorCategoryBarHost.barGlassInset)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .opacity(model.selectedLayer == nil ? 0 : 1)
            inspectorContent
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea(edges: .bottom))
        // 切換分類回到預設狀態：頂端淡化歸零（新分頁的 Form 剛出現時不一定會回報幾何，會沿用上一個分頁的淡化）。
        .onChange(of: session.category) { _, _ in
            endEditing()
            session.inspectorFade.update(scrollOffset: 0)
        }
    }

    private var inspectorContent: some View {
        // 必須是真正的容器：Group 會把 background／mask 套在每個子視圖上。
        ZStack {
            if let layer = model.selectedLayer {
                if layer.group {
                    EditorGroupInspector(model: model, session: session, id: layer.id, category: session.category)
                        .id(layer.id.uuidString + ":" + session.category)
                } else {
                    LayerInspector(layer: model.layerBinding(layer.id), family: model.document.family,
                                   model: model, session: session, category: session.category)
                        .id(layer.id.uuidString + ":" + session.category)
                        // 只有換分類時關掉動畫；整片面板的滑入滑出仍要照常播。
                        .transaction(value: session.category) { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                }
            } else {
                Text("目前沒有可編輯的圖層。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 只淡化捲動內容（淡出帶從分類下緣開始）；底色由外層提供，保持連續並遮住背後的圖層。
        .mask(alignment: .top) { EditorPanelMask(fade: session.inspectorFade) }
    }


    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    /// 復原／重做只改文件，不切換介面：不進出選取模式、不改勾選、不開關面板、不換分頁、不捲動、不改選取。
    /// 底色（顏色或圖片）：和其他工具一樣是由下往上的面板，畫布和上一步／下一步都看得到（使用者要求統一）。
    private func openBackgroundColor() {
        session.toolPanels.color = nil
        session.toolPanels.style = nil
        session.toolPanels.symbol = nil
        session.toolPanels.background = true
    }

    /// 只有當使用者正好停在該操作所在的面板（同一圖層、同一分頁，或位置與對齊開著）時，才短暫標示被還原的欄位。
    private func select(_ id: UUID) {
        endEditing()
        session.propertyAnchor = nil
        session.resolveGuidedEntry(for: id)
        if model.document.layers.contains(where: { $0.id == id && $0.group }),
           session.category != "版面" && session.category != "其他" {
            session.category = "版面"
        }
        // 還沒有內容的圖層（沒選圖的圖片、沒有網址的網路圖片）每次一進來都在「內容」，找得到補上內容的地方；
        // 離開後回到原本的分頁。
        if model.document.layers.contains(where: { $0.id == id && $0.editorNeedsContent }) {
            session.beginGuidedEntry("內容", layer: id, shown: true)
        }
        model.selectedLayerID = id
        if model.isolatedLayerID != nil { model.isolatedLayerID = id }
        session.selectedID = id
        // 每次進入屬性面板（含切換到另一個圖層）都從頂端開始，不沿用上次捲到的位置；
        // 同一次停留中切換分類仍各自記住位置。圖層清單與位置與對齊的記憶不受影響。
        session.scrollOffsets = session.scrollOffsets.filter { !$0.key.contains(":") }
        session.inspectorFade.update(scrollOffset: 0)
        guard !session.inspecting else { return }
        withAnimation(FormlessDesign.Motion.push) { session.inspecting = true }
    }

    @discardableResult private func save() async -> Bool {
        guard !saving else { return false }
        guard model.hasUnsavedChanges else { return true }
        saving = true
        defer { saving = false }
        do {
            repeat { try await model.saveAsync() } while model.hasUnsavedChanges
            onSaved()
            return !model.hasUnsavedChanges
        } catch {
            errorMessage = error.localizedDescription
            onSaveError(error.localizedDescription)
            return false
        }
    }
}

@MainActor private final class CanvasSelectionGuard {
    var blockedUntil: TimeInterval = 0

    var canSelect: Bool {
        ProcessInfo.processInfo.systemUptime >= blockedUntil
    }

    func blockAfterDrag() {
        blockedUntil = ProcessInfo.processInfo.systemUptime + 0.25
    }
}

struct ResizableEditorPreview: View {
    @ObservedObject var model: EditorModel
    @Environment(\.displayScale) private var displayScale
    let availableHeight: CGFloat
    /// 鍵盤出現時暫時縮成精簡高度：小工具仍看得到輸入後的變化，同時讓表單有空間把欄位捲到鍵盤上方。
    var collapsed = false
    /// 鍵盤的高度（含系統工具列）：畫布只縮到「鍵盤上方還留得下一段表單」的程度，不是一律縮到最小。
    var keyboardHeight: CGFloat = 0
    var selectionInset: CGFloat = 0
    /// 下半部工具面板（位置與大小、顏色）：開著時畫布底邊不超過面板上緣，
    /// 整個小工具都在面板上方看得到（面板佔螢幕 60%，畫布拉到最高時會被蓋住一段）。
    @ObservedObject var toolPanels: EditorToolPanelState
    private var panelTop: CGFloat? {
        toolPanels.open ? FormlessSafeArea.windowHeight - FormlessPanelMetrics.height : nil
    }
    /// 鍵盤期間畫布的最小高度：再小就看不出改動。
    private static let compactHeight: CGFloat = 200
    /// 鍵盤期間畫布下方要留給表單的高度：夠把正在輸入的欄位（含一列上下文）捲到鍵盤上方。
    private static let keyboardFormReserve: CGFloat = 176
    let onSelect: (UUID) -> Void
    @AppStorage("formless.editorPreviewHeight.small") private var smallHeight = 264.0
    @AppStorage("formless.editorPreviewHeight.medium") private var mediumHeight = 264.0
    @AppStorage("formless.editorPreviewHeight.large") private var largeHeight = 264.0
    @AppStorage("formless.editorPreviewHeight.extraLarge") private var extraLargeHeight = 264.0
    @AppStorage("formless.canvasLocked") private var canvasLocked = false
    /// 拖曳中的顯示高度與起始高度分開保存，避免 GestureState 更新順序讓首次拖曳失效。
    @State private var liveHeight: CGFloat?
    @State private var dragOrigin: CGFloat?
    /// 這一次拖曳在做什麼：nil 是還沒決定；移動圖層時記下貼齊的狀態（剛貼上時給一下觸覺）。
    private enum DragMode: Equatable { case resize, layer(snapX: Bool, snapY: Bool), ignored }
    @State private var dragMode: DragMode?

    /// 畫布從狀態列下方開始，按鈕列的空間也給畫布用；設定（左上）與復原、重做（右上）漂浮在畫布上
    /// （2026-10-04 使用者決定，取代 10/03「畫布從按鈕列下方開始」：大型、超大型的畫布太小）。
    static var canvasTop: CGFloat { FormlessSafeArea.top }

    /// 畫布改從按鈕列的位置開始後，原本記住的畫布高度各加上按鈕列的 44：畫布底邊留在原處，多出來的空間給畫布。只做一次。
    static func migrateHeightsForFloatingButtons() {
        let defaults = UserDefaults.standard
        let flag = "formless.editorPreviewHeight.floatingButtons"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        for family in ["small", "medium", "large", "extraLarge"] {
            let key = "formless.editorPreviewHeight." + family
            if let height = defaults.object(forKey: key) as? Double { defaults.set(height + 44, forKey: key) }
        }
    }
    private var contentTopPadding: CGFloat { Self.canvasTop }
    /// 鍵盤是屬性面板的欄位叫出來的才縮畫布。下方工具面板（位置與大小、顏色、樣式、圖示）開著時，鍵盤屬於面板，
    /// 只捲面板裡的內容；畫布與面板外的畫面都不動（使用者回報：在面板裡輸入時畫布也被往下推）。
    private var keyboardCollapsed: Bool { collapsed && !toolPanels.open }
    // 只記錄觸控保護，不參與 SwiftUI 排版；拖曳事件不必為時間戳重畫畫布。
    @State private var selectionGuard = CanvasSelectionGuard()

    /// 每種尺寸各自記憶畫布高度，切換尺寸不會沿用另一種尺寸的工作區。
    private var storedHeight: Double {
        get {
            switch model.document.family {
            case .small: smallHeight
            case .medium: mediumHeight
            case .large: largeHeight
            case .extraLarge: extraLargeHeight
            }
        }
        nonmutating set {
            switch model.document.family {
            case .small: smallHeight = newValue
            case .medium: mediumHeight = newValue
            case .large: largeHeight = newValue
            case .extraLarge: extraLargeHeight = newValue
            }
        }
    }

    private var limits: ClosedRange<CGFloat> {
        // 畫布高度也代表可操作區與圖層清單的分配；保留至少 100 pt 給下方面板。
        // 畫布底邊最多拉到螢幕正中間（畫布從螢幕頂端開始，所以用視窗高度的一半扣掉頂端留白），
        // 再高下方面板就沒地方操作了。
        let half = FormlessSafeArea.windowHeight / 2 - contentTopPadding
        let upper = min(max(150, availableHeight - contentTopPadding - 100), max(150, half), Self.fullWidthHeight(model.document.family))
        return min(120, upper)...upper
    }

    /// 畫布繪製用的固定高度：不含鍵盤期間多出的頂端留白，鍵盤出現時也不會變。
    private var maxRenderHeight: CGFloat {
        let top = Self.canvasTop
        let half = FormlessSafeArea.windowHeight / 2 - top
        return min(max(150, availableHeight - top - 100), max(150, half), Self.fullWidthHeight(model.document.family))
    }

    /// 小工具撐滿左右邊線時，畫布最多要多高：按鈕列（左上設定、右上復原）＋小工具＋上下各 8。
    /// 再高只會在小工具上下多出空白（中型、超大型這類扁的小工具，2026-10-05 使用者回報），所以畫布最高就到這裡；
    /// 高的小工具（小型、大型）先碰到螢幕一半的上限，不受影響。所有尺寸拉到最高時，小工具下緣到圖層清單都只隔 8。
    static func fullWidthHeight(_ family: FormlessWidgetFamily) -> CGFloat {
        let width = FormlessSafeArea.windowWidth - 2 * FormlessDesign.Space.edge
        return (EditorPreview.buttonRowReserve + width / family.aspectRatio + 2 * EditorPreview.verticalInset).rounded(.up)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, limits.lowerBound), limits.upperBound)
    }

    /// 畫布外框與下方面板共用同一個即時高度，拖動時圖層和屬性面板會跟著邊界移動。
    /// 內容仍由 EditorPreview 以拖曳起點尺寸繪製並縮放，避免每一格都重新排版畫布內容。
    /// 工具面板打開時不算進來：下方清單／屬性面板本來就被工具面板蓋住，不用跟著往上移；
    /// 原本一起縮，清單變高要多建好幾列，面板滑上來那一格卡住（使用者回報）。
    private var layoutHeight: CGFloat {
        // 拖曳中的高度不再夾到上下限：拉過頭的橡皮筋要看得到。
        let height = liveHeight ?? clamp(CGFloat(storedHeight))
        return keyboardCollapsed ? Self.collapsedHeight(height, keyboardHeight: keyboardHeight) : max(60, height - selectionInset)
    }

    /// 顯示用的高度：拖曳中即時跟著手指；工具面板打開時只縮畫面上的畫布，整個小工具留在面板上方。
    private var visualHeight: CGFloat {
        guard let panelTop else { return layoutHeight }
        return min(layoutHeight, max(60, panelTop - contentTopPadding))
    }
    /// 鍵盤期間的畫布高度：能留多少給畫布就留多少（視窗高扣掉鍵盤、頂端留白、表單保留區），但不低於精簡高度；
    /// 使用者原本就把畫布拉得比這還小時維持原高。鍵盤高度是從視窗底算起的，所以用整個視窗高度。
    private static func collapsedHeight(_ height: CGFloat, keyboardHeight: CGFloat) -> CGFloat {
        let padding = canvasTop
        let room = FormlessSafeArea.windowHeight - keyboardHeight - padding - keyboardFormReserve
        return min(height, max(compactHeight, room))
    }
    /// 鍵盤出現時表單頂端會下移多少（頂端多 44 留白、畫布縮小），交給鍵盤避讓一起算。
    private func registerKeyboardShift() {
        let resting = clamp(CGFloat(storedHeight))
        let restingTop = Self.canvasTop + max(60, resting - selectionInset)
        FormlessKeyboardAvoider.shared.editorLayoutShift = { keyboardHeight in
            Self.canvasTop + Self.collapsedHeight(resting, keyboardHeight: keyboardHeight) - restingTop
        }
    }

    var body: some View {
        Color.clear
            .frame(height: layoutHeight + contentTopPadding)
            .overlay(alignment: .top) {
                // 畫布內容一律以「可拉到的最大高度」繪製一次，任何顯示高度都只是整體縮小：拖曳中、放開後、被鍵盤或選取工具列
                // 推動時都不重畫。原本放開時會以新高度重畫整份畫布並重新量選取框，圖層多的設計在實機上一次就停住數百毫秒，
                // 接近最大值來回微調時一放手就頓一下。縮小顯示不會模糊。
                EditorPreview(model: model, renderingHeight: maxRenderHeight) { id in
                    guard selectionGuard.canSelect else { return }
                    onSelect(id)
                }
                    .padding(.top, contentTopPadding)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .frame(height: visualHeight + contentTopPadding)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if !canvasLocked && !keyboardCollapsed {
                            Capsule()
                                .fill(.secondary.opacity(dragOrigin == nil ? 0.35 : 0.6))
                                .frame(width: 42, height: 5)
                                .padding(.bottom, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    // 工具面板打開時畫布縮到面板上方，和面板滑上來同一個動畫；只動畫布，下方清單不動。
                    .animation(BatchPositionPanel.animation, value: toolPanels.open)
            }
            .contentShape(Rectangle())
            // 鎖定畫布只鎖高度：拖曳選取的圖層照樣可以（手勢裡判斷）。
            .highPriorityGesture(resizeGesture, including: .all)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-resizable-canvas")
            .accessibilityLabel(canvasLocked ? "畫布，已鎖定" : "畫布，上下拖曳可調整高度")
            .accessibilityValue("\(Int(visualHeight.rounded()))")
            .onAppear { registerKeyboardShift() }
            .onChange(of: storedHeight) { registerKeyboardShift() }
            .onChange(of: selectionInset) { registerKeyboardShift() }
            .onDisappear { FormlessKeyboardAvoider.shared.editorLayoutShift = nil }
            // 這裡不再套任何 transaction／animation。畫布被鍵盤或選取工具列往上下推時，動畫必須由「同時包住畫布與下方面板」
            // 的那一層帶進來（鍵盤：FormlessKeyboardObserver 的 withAnimation；工具列：外層 VStack 的 .animation），
            // 掛在畫布自己身上的 .animation(value:) 只會影響畫布子樹，下方面板仍是瞬間跳位；
            // 而原本整片套 disablesAnimations，更會把所有進行中的高度動畫一併截斷。拖曳改高度是逐格跟手，本來就沒有動畫。
    }

    /// 超過上下限的部分越拉越緊（和系統捲動的橡皮筋同一個公式）：拉過頭不會突然卡住，也不會無限拉長。
    static func rubberBand(_ height: CGFloat, limits: ClosedRange<CGFloat>) -> CGFloat {
        func resist(_ overshoot: CGFloat) -> CGFloat {
            let dimension: CGFloat = 300, constant: CGFloat = 0.55
            return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
        }
        if height > limits.upperBound { return limits.upperBound + resist(height - limits.upperBound) }
        if height < limits.lowerBound { return limits.lowerBound - resist(limits.lowerBound - height) }
        return height
    }

    /// 移動圖層：1:1 跟手，靠近畫布的中線或邊緣（6 pt 內）就貼上去，剛貼上時輕觸一下。
    private func dragLayer(_ value: DragGesture.Value, snapX: Bool, snapY: Bool) {
        guard let mapping = model.canvasMapping, mapping.scale > 0, let bounds = model.canvasDragBounds else { return }
        let size = mapping.canvasSize
        var dx = Double(value.translation.width / mapping.scale / size.width)
        var dy = Double(value.translation.height / mapping.scale / size.height)
        let reachX = Double(6 / mapping.scale / size.width), reachY = Double(6 / mapping.scale / size.height)
        // 左緣對畫布左緣、中線對中線、右緣對右緣（上下同理）。
        func snap(_ start: Double, _ length: Double, _ delta: inout Double, reach: Double) -> Bool {
            for (anchor, target) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0)] {
                let position = start + length * anchor + delta
                if abs(position - target) < reach {
                    delta += target - position
                    return true
                }
            }
            return false
        }
        let nowX = snap(bounds.x, bounds.width, &dx, reach: reachX)
        let nowY = snap(bounds.y, bounds.height, &dy, reach: reachY)
        if (nowX && !snapX) || (nowY && !snapY) { FormlessHaptics.light() }
        dragMode = .layer(snapX: nowX, snapY: nowY)
        model.moveCanvasDrag(dx: dx, dy: dy)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragMode == nil {
                    // 第一下決定：按在選取的圖層上就是移動它，否則是調畫布高度（鎖定畫布時不調）。
                    if let id = model.selectedLayerHit(atGlobal: value.startLocation), model.beginCanvasDrag(id) {
                        selectionGuard.blockAfterDrag()
                        dragMode = .layer(snapX: false, snapY: false)
                    } else {
                        dragMode = canvasLocked ? .ignored : .resize
                    }
                }
                if case .layer(let snapX, let snapY)? = dragMode {
                    dragLayer(value, snapX: snapX, snapY: snapY)
                    return
                }
                guard dragMode == .resize else { return }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let origin: CGFloat
                if let existing = dragOrigin {
                    origin = existing
                } else {
                    // 只在起手時更新一次；每一筆拖曳事件改寫時間戳會讓畫布多重繪。
                    selectionGuard.blockAfterDrag()
                    origin = clamp(liveHeight ?? CGFloat(storedHeight))
                    dragOrigin = origin
                }
                let nextHeight = Self.rubberBand(origin + value.translation.height, limits: limits)
                // 手勢事件可能比螢幕影格密集；忽略不足一個實體像素的重複排版。
                if abs(nextHeight - (liveHeight ?? origin)) >= 1 / max(displayScale, 1) {
                    liveHeight = nextHeight
                }
            }
            .onEnded { _ in
                selectionGuard.blockAfterDrag()
                defer { dragMode = nil }
                if case .layer? = dragMode {
                    model.endCanvasDrag()
                    return
                }
                guard dragOrigin != nil, let finalHeight = liveHeight else { return }
                let settled = clamp(finalHeight)
                // 結束事件的 translation 有時比最後顯示的一幀更遠。直接儲存使用者
                // 放手前看到的高度，避免放手後又跳動一次；三個狀態在同一交易內提交。
                guard settled != finalHeight else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        storedHeight = Double(finalHeight)
                        liveHeight = nil
                        dragOrigin = nil
                    }
                    return
                }
                // 拉過上下限：放手時用無回彈的彈簧回到界內（和面板同一種動畫）。
                withAnimation(FormlessDesign.Motion.panel) {
                    storedHeight = Double(settled)
                    liveHeight = nil
                    dragOrigin = nil
                }
            }
    }
}

struct EditorPreview: View {
    @ObservedObject var model: EditorModel
    var renderingHeight: CGFloat? = nil
    let onSelect: (UUID) -> Void
    /// 小工具上下各留的距離。
    static let verticalInset: CGFloat = 8
    /// 畫布頂端浮著的按鈕列（左上設定、右上復原與重做）的高度。
    static let buttonRowReserve: CGFloat = 44
    var body: some View {
        GeometryReader { geometry in
            // 左右照全 App 的邊線（離螢幕邊 20），上下各留 8。
            let sideInset = 2 * FormlessDesign.Space.edge
            let verticalInsets = 2 * Self.verticalInset
            let targetWidth = max(1, min(geometry.size.width - sideInset, (geometry.size.height - verticalInsets) * model.document.family.aspectRatio))
            let sourceHeight = renderingHeight ?? geometry.size.height
            let sourceWidth = max(1, min(geometry.size.width - sideInset, (sourceHeight - verticalInsets) * model.document.family.aspectRatio))
            let scale = targetWidth / sourceWidth
            // 拖曳中畫布仍以原尺寸繪製、只做縮放。外框要固定成可視區大小並置中，
            // 否則比可視區大的畫布會被貼到左上角，縮小後看起來就往下掉。
            let canvasSize = CGSize(width: sourceWidth, height: sourceWidth / model.document.family.aspectRatio)
            // 小工具已撐滿左右、上下還有空：多出來的高度先給上面的按鈕列，小工具往下移到按鈕列下方，
            // 下緣到圖層清單維持 8（和其他尺寸一樣）；超過按鈕列高度的部分才上下平分（拖過頭的橡皮筋）。
            let excess = max(0, geometry.size.height - verticalInsets - canvasSize.height * scale)
            let shift = min(excess, Self.buttonRowReserve) / 2
            ZStack {
                EditorCanvas(model: model, canvasSize: canvasSize, onSelect: onSelect)
                    .equatable()
                    .scaleEffect(scale)
                    .offset(y: shift)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // 畫布縮放後置中再往下移 shift：左上角 = 外框中心 − 縮放後尺寸的一半。
                model.canvasMapping = (CGPoint(x: frame.midX - canvasSize.width * scale / 2,
                                               y: frame.midY + shift - canvasSize.height * scale / 2), scale, canvasSize)
            }
        }.background(FormlessDesign.Palette.page)
    }
}

struct EditorCanvas: View, Equatable {
    @ObservedObject var model: EditorModel
    let canvasSize: CGSize
    var onSelect: (UUID) -> Void = { _ in }
    @State private var background: UIImage?
    @State private var renderDate = Date()
    @Environment(\.scenePhase) private var scenePhase
    @State private var measuredOutline: (key: OutlineKey, rect: CGRect, frame: FormlessFrame)?
    /// 選取模式勾選圖層的實際內容範圍（相對於圖層框），與對齊、位置欄位用的是同一套量測；
    /// 只在外觀改變時重量，純平移直接沿用。量不到的（資料不足、空字串）以虛線框顯示圖層框。
    @State private var pickedPainted: [UUID: PaintedLocal] = [:]
    /// 點擊命中用的實際內容範圍快取（相對圖層框），和選取外框用同一套量測；純平移直接沿用。
    @State private var tapPainted: [UUID: PaintedLocal] = [:]
    /// 圖層實際畫出來的範圍（畫布座標、未旋轉，旋轉中心是圖層框的中心）；資料不足或量不到時回 nil。
    private func localPaintedRect(for layer: FormlessLayer) -> CGRect? {
        var unrotated = layer
        unrotated.rotation = 0
        let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
        let signature = paintedSignature(layer)
        if let cached = tapPainted[layer.id], cached.signature == signature {
            return CGRect(origin: CGPoint(x: box.minX + cached.offset.x, y: box.minY + cached.offset.y), size: cached.size)
        }
        guard let measured = EditorPaintedBounds.measure(layers: [unrotated], canvasSize: canvasSize,
                                                         family: model.document.family, date: renderDate,
                                                         live: model.document.itemContext(for: layer, live: model.live, date: renderDate))
        else { return nil }
        tapPainted[layer.id] = PaintedLocal(signature: signature,
                                            offset: CGPoint(x: measured.minX - box.minX, y: measured.minY - box.minY),
                                            size: measured.size)
        return measured
    }
    /// 這個位置看得到的圖層，由上到下。看的是畫出來的內容，不是圖層框：
    /// - 文字類量「文字行」（和選取外框相同），點在字與字之間也算；
    /// - 其他圖層看點擊處附近有沒有畫出東西：圖片、圖示、形狀的透明處不擋住底下的圖層；
    /// - 內容小於 44 pt 的圖層，範圍放大到 44 pt 才點得到。
    private func layersVisible(at point: CGPoint) -> [FormlessLayer] {
        let reach: CGFloat = 8
        let minimum: CGFloat = 44
        return model.document.layers.reversed().compactMap { stored -> FormlessLayer? in
            let context = model.document.itemContext(for: stored, live: model.live, date: renderDate)
            guard !stored.group, !model.document.effectivelyHidden(stored), visibleInIsolation(stored),
                  FormlessDataBinding.satisfied(stored.dataIndex, live: context),
                  context.matches(stored.visibility, at: renderDate) else { return nil }
            let layer = model.previewed(stored)
            var unrotated = layer
            unrotated.rotation = 0
            let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
            // 點擊位置換到圖層自己的（未旋轉）座標。
            let angle = -CGFloat(layer.rotation * .pi / 180)
            let dx = point.x - box.midX, dy = point.y - box.midY
            let local = CGPoint(x: box.midX + dx * cos(angle) - dy * sin(angle),
                                y: box.midY + dx * sin(angle) + dy * cos(angle))
            // 量不到內容（例如圖片還沒載入）時照圖層框算。
            let painted = localPaintedRect(for: layer) ?? box
            let small = painted.width < minimum || painted.height < minimum
            let area = painted.insetBy(dx: -max(reach, (minimum - painted.width) / 2),
                                       dy: -max(reach, (minimum - painted.height) / 2))
            guard area.contains(local) else { return nil }
            if small || ([.text, .date, .time, .liveText].contains(layer.type) && layer.textArc == nil) { return stored }
            let paints = EditorPaintedBounds.paints(layer: layer, near: point, radius: reach, canvasSize: canvasSize,
                                                    family: model.document.family, date: renderDate, live: context)
            return paints == false ? nil : stored
        }
    }
    private struct PaintedLocal { let signature: Int; let offset: CGPoint; let size: CGSize }
    private struct PickedKey: Hashable {
        let ids: Set<UUID>
        let documentRevision: UInt64
        let liveRevision: UInt64
        let canvasSize: CGSize
    }
    private func paintedSignature(_ layer: FormlessLayer) -> Int {
        var copy = layer
        copy.frame = FormlessFrame(x: 0, y: 0, width: layer.frame.width, height: layer.frame.height)
        copy.rotation = 0
        // 時間、日期、即時文字畫出來的寬度會隨畫布時間改變（每分鐘換一次），點選與選取的量測快取要跟著換。
        guard [.time, .date, .liveText].contains(layer.type) || layer.segments != nil || layer.usesDataSystem else { return copy.hashValue }
        var hasher = Hasher()
        hasher.combine(copy)
        hasher.combine(renderDate)
        return hasher.finalize()
    }
    private struct PickedOutline {
        let layer: FormlessLayer
        let outline: (rect: CGRect, measured: Bool)
    }
    private var pickedOutlines: [PickedOutline] {
        model.pickedHighlight.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let layer = model.document.layers.first(where: { $0.id == id }),
                  let outline = pickedRect(for: layer) else { return nil }
            return PickedOutline(layer: layer, outline: outline)
        }
    }
    /// 多選的整體邊界：每個框依旋轉換成外接框後聯集，和對齊用的可見聯集是同一個範圍。
    private func pickedUnion(_ items: [PickedOutline]) -> CGRect? {
        var result: CGRect?
        for item in items {
            let center = outlineCenter(for: item.layer, rect: item.outline.rect)
            let angle = item.layer.group ? 0 : CGFloat(item.layer.rotation * .pi / 180)
            let width = abs(cos(angle)) * item.outline.rect.width + abs(sin(angle)) * item.outline.rect.height
            let height = abs(sin(angle)) * item.outline.rect.width + abs(cos(angle)) * item.outline.rect.height
            let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }
    private func pickedRect(for layer: FormlessLayer) -> (rect: CGRect, measured: Bool)? {
        if let local = pickedPainted[layer.id], local.signature == paintedSignature(layer) {
            var unrotated = layer
            unrotated.rotation = 0
            let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
            return (CGRect(origin: CGPoint(x: box.minX + local.offset.x, y: box.minY + local.offset.y), size: local.size), true)
        }
        return outlineRect(for: layer).map { ($0, false) }
    }

    private struct OutlineKey: Hashable {
        let selectedID: UUID?
        let documentRevision: UInt64
        let canvasSize: CGSize
        let liveRevision: UInt64
        let date: Date
    }

    static func == (lhs: EditorCanvas, rhs: EditorCanvas) -> Bool {
        lhs.model === rhs.model && lhs.canvasSize == rhs.canvasSize
    }
    var body: some View {
        let outlineKey = OutlineKey(selectedID: model.selectedLayerID, documentRevision: model.documentRevision,
                                    canvasSize: canvasSize, liveRevision: model.liveRevision, date: renderDate)
        ZStack {
            // 底：設計的底色與背景圖；預覽透明、染色、StandBy 時換成那個情境的背景。
            EditorCanvasBackdrop(document: model.document, appearance: model.previewAppearance,
                                 background: background, canvasSize: canvasSize)
            Group {
                ForEach(model.document.renderedLayers(
                    model.document.layers.filter { !$0.group && !model.document.effectivelyHidden($0) && visibleInIsolation($0) },
                    live: model.canvasLive, date: renderDate)) { item in
                    FormlessLayerView(layer: model.previewed(item.layer), canvasSize: canvasSize,
                                      scale: canvasSize.height / model.document.family.referenceHeight,
                                      date: renderDate, live: item.live)
                        .allowsHitTesting(false)
                }
            }
            // 模擬系統的畫法：透明與染色全部變白、StandBy 夜間依亮度呈現。
            .environment(\.formlessPreviewAppearance, model.previewAppearance)
            if let id = model.selectedLayerID,
               let layer = model.document.layers.first(where: { $0.id == id }),
               let rect = currentOutlineRect(for: layer, key: outlineKey) {
                // 外框畫在內容外面：往外推一個線寬，白邊與藍線都不壓到內容。原本筆畫置中在邊界上，
                // 貼著邊界的筆畫被白邊蓋掉（使用者回報：選取星期列時「日」少了左邊那一豎，看起來像被切掉）。
                let line: CGFloat = 0.8
                let radius = outlineCornerRadius(for: layer)
                // 文字的可用寬度：左右是框的左右緣、上下和文字行（選取框）一樣，淡色虛線畫在選取框底下。只是顯示，不影響點選與量測。
                if !layer.group, [.text, .date, .time, .liveText].contains(layer.type), layer.textArc == nil {
                    let box = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
                    let lane = CGRect(x: box.minX, y: rect.minY, width: box.width, height: rect.height)
                    Rectangle()
                        .stroke(FormlessDesign.Palette.guide,
                                style: StrokeStyle(lineWidth: FormlessDesign.Stroke.guide, dash: FormlessDesign.Stroke.guideDash))
                        .frame(width: lane.width + line * 2, height: lane.height + line * 2)
                        .rotationEffect(.degrees(layer.rotation))
                        .position(outlineCenter(for: layer, rect: lane))
                        .allowsHitTesting(false)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: radius > 0 ? radius + line : 0, style: .continuous)
                        .stroke(Color.white.opacity(0.9), lineWidth: line * 2)
                    RoundedRectangle(cornerRadius: radius > 0 ? radius + line : 0, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: line)
                }
                .frame(width: rect.width + line * 2, height: rect.height + line * 2)
                .rotationEffect(.degrees(layer.group ? 0 : layer.rotation))
                .position(outlineCenter(for: layer, rect: rect))
                .allowsHitTesting(false)
            }
            // 選取模式：每個勾選的圖層都畫框，確認選到的是哪些。框用的是實際內容範圍（與對齊相同）；量不到內容的畫圖層框。
            // 勾了多個時整批當成一個圖層（對齊、移動都一起走），所以外面再畫一個包住所有邊界的實線藍框，
            // 各自的框改成淡色虛線，像一張圖片裡的內容（使用者要求）；只勾一個時維持原本的實線框加淡填色。
            let picked = pickedOutlines
            ForEach(picked, id: \.layer.id) { item in
                let multi = picked.count > 1
                // 框線同樣畫在內容外面（往外推半個線寬），不壓到貼邊的筆畫。
                let lineWidth: CGFloat = multi ? 1 : 1.2
                let base = item.outline.measured ? 0 : outlineCornerRadius(for: item.layer)
                let radius = base > 0 ? base + lineWidth / 2 : 0
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(multi ? Color.clear : FormlessDesign.Palette.selectionFill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.accentColor.opacity(multi ? 0.45 : 1),
                                style: StrokeStyle(lineWidth: lineWidth,
                                                   dash: multi || !item.outline.measured ? [4, 3] : [])))
                    .frame(width: item.outline.rect.width + lineWidth, height: item.outline.rect.height + lineWidth)
                    .rotationEffect(.degrees(item.layer.group ? 0 : item.layer.rotation))
                    .position(outlineCenter(for: item.layer, rect: item.outline.rect))
                    .allowsHitTesting(false)
            }
            if picked.count > 1, let union = pickedUnion(picked) {
                // 只畫框線不填色：填色會蓋在內容上影響閱讀（使用者要求）。
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1.2)
                    .frame(width: union.width + 1.2, height: union.height + 1.2)
                    .position(x: union.midX, y: union.midY)
                    .allowsHitTesting(false)
            }
        }
        .task(id: PickedKey(ids: model.pickedHighlight, documentRevision: model.documentRevision,
                            liveRevision: model.liveRevision, canvasSize: canvasSize)) {
            for id in model.pickedHighlight.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let layer = model.document.layers.first(where: { $0.id == id }), !layer.group else { continue }
                let signature = paintedSignature(layer)
                if pickedPainted[id]?.signature == signature { continue }
                guard FormlessDataBinding.satisfied(layer.dataIndex, live: model.live) else { pickedPainted[id] = nil; continue }
                var unrotated = layer
                unrotated.rotation = 0
                guard let rect = EditorPaintedBounds.measure(layers: [unrotated], canvasSize: canvasSize,
                                                             family: model.document.family, date: renderDate, live: model.live) else {
                    pickedPainted[id] = nil
                    continue
                }
                let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
                pickedPainted[id] = PaintedLocal(signature: signature,
                                                 offset: CGPoint(x: rect.minX - box.minX, y: rect.minY - box.minY), size: rect.size)
                await Task.yield()
                if Task.isCancelled { return }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        // 畫布是真的小工具的樣子：圓角是小工具實際的 22 依畫布比例縮放（和首頁縮圖相同），看到的就是主畫面上的樣子。
        .clipShape(RoundedRectangle(cornerRadius: model.document.family.cornerRadius
                                        * min(canvasSize.width / model.document.family.referenceWidth,
                                              canvasSize.height / model.document.family.referenceHeight),
                                    style: .continuous))
        // 預覽淺色、深色時畫布用那個外觀（淺色與深色兩個值的顏色跟著換）。
        .formlessColorScheme(model.previewAppearance.colorScheme)
        .contentShape(Rectangle())
        .onTapGesture { point in
            let hits = layersVisible(at: point)
            // 點在目前選取的圖層上、底下還有別的圖層：換到它下面那一層，最底層之後回到最上層。
            // 不必點同一個位置、也不限時間（原本要在 14 pt、5 秒內連點，稍微點偏就回到最上層，使用者回報不好用）。
            if let selected = hits.firstIndex(where: { $0.id == model.selectedLayerID }), hits.count > 1 {
                onSelect(hits[(selected + 1) % hits.count].id)
            } else if let first = hits.first {
                onSelect(first.id)
            }
        }
        .task(id: model.documentRevision) {
            let snapshot = model.document
            await Task.detached { FormlessRenderContext.prepare(snapshot) }.value
            guard !Task.isCancelled else { return }
            // 只有時鐘走到下一秒才換日期：同一秒內的連續編輯（拖滑桿、按住 ＋）不必讓每個圖層再畫一次、選取外框再量一次
            // （原本每一次編輯都換，整張畫布畫兩遍）。顯示的時間仍然精確到秒。
            let now = Date()
            if now.timeIntervalSince1970.rounded(.down) != renderDate.timeIntervalSince1970.rounded(.down) { renderDate = now }
        }
        // 畫布上的時間跟著時鐘走：編輯器開著時每到整分鐘換一次，從背景回來立刻換。原本只有編輯圖層時才換，
        // 放著不動或離開一陣子再回來，畫布上的時鐘會停在打開時那一分鐘（2026-10-03 模擬器實測）。
        .task {
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let nextMinute = (now / 60).rounded(.down) * 60 + 60
                try? await Task.sleep(for: .seconds(nextMinute - now + 0.05))
                guard !Task.isCancelled else { return }
                renderDate = Date()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { renderDate = Date() }
        }
        .task(id: model.document.activeBackgroundImageName) {
            let name = model.document.activeBackgroundImageName
            background = await Task.detached { name.flatMap { FormlessAssetCache.shared.image(named: $0) } }.value
        }
        .task(id: outlineKey) {
            guard let id = outlineKey.selectedID,
                  let selected = model.document.layers.first(where: { $0.id == id }) else { return }
            let layers: [FormlessLayer]
            if selected.group {
                layers = model.document.children(of: id).filter {
                    !model.document.effectivelyHidden($0) && FormlessDataBinding.satisfied($0.dataIndex, live: model.live)
                }
            } else {
                var unrotated = selected
                unrotated.rotation = 0
                layers = [unrotated]
            }
            guard !layers.isEmpty else { return }
            if measuredOutline?.key.selectedID == id {
                do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let context = layers.first.map { model.document.itemContext(for: $0, live: model.live, date: renderDate) } ?? model.live
            if let rect = EditorPaintedBounds.measure(layers: layers, canvasSize: canvasSize,
                                                       family: model.document.family, date: renderDate, live: context),
               !Task.isCancelled {
                measuredOutline = (outlineKey, rect, selected.frame)
            }
        }
        .accessibilityLabel("畫布，點選內容可編輯圖層")
        .accessibilityHint("再次點選重疊位置可切換圖層")
    }
    /// 量測完成前不要退回幾何框（文字的幾何框比實際內容大很多，會看到外框突然放大又縮回）。
    /// 同一圖層有舊的量測結果時，依框的位移與縮放平移舊框；完全沒有時才用幾何框。
    private func currentOutlineRect(for layer: FormlessLayer, key: OutlineKey) -> CGRect? {
        guard let measured = measuredOutline, measured.key.selectedID == layer.id else { return outlineRect(for: layer) }
        if measured.key == key { return measured.rect }
        // 畫布尺寸改變（被鍵盤或工具列推動、拖曳放手）時，內容整體等比縮放，量到的框直接照比例換算，
        // 不走下面依圖層框推算的路，否則重新量到之前那一格會跳到錯的位置。
        if measured.key.canvasSize != canvasSize, measured.key.canvasSize.height > 0 {
            let ratio = canvasSize.height / measured.key.canvasSize.height
            let base = CGRect(x: measured.rect.minX * ratio, y: measured.rect.minY * ratio,
                              width: measured.rect.width * ratio, height: measured.rect.height * ratio)
            guard !layer.group, measured.frame != layer.frame, measured.frame.width > 0, measured.frame.height > 0 else { return base }
            let sx = layer.frame.width / measured.frame.width, sy = layer.frame.height / measured.frame.height
            var previous = layer
            previous.frame = measured.frame
            let oldBox = FormlessLayerLayout.rect(for: previous, canvasSize: canvasSize)
            let newBox = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
            return CGRect(x: newBox.minX + (base.minX - oldBox.minX) * sx, y: newBox.minY + (base.minY - oldBox.minY) * sy,
                          width: base.width * sx, height: base.height * sy)
        }
        guard !layer.group, measured.frame.width > 0, measured.frame.height > 0 else { return measured.rect }
        let sx = layer.frame.width / measured.frame.width, sy = layer.frame.height / measured.frame.height
        var previous = layer
        previous.frame = measured.frame
        let oldBox = FormlessLayerLayout.rect(for: previous, canvasSize: canvasSize)
        let newBox = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
        return CGRect(x: newBox.minX + (measured.rect.minX - oldBox.minX) * sx,
                      y: newBox.minY + (measured.rect.minY - oldBox.minY) * sy,
                      width: measured.rect.width * sx, height: measured.rect.height * sy)
    }
    private func visibleInIsolation(_ layer: FormlessLayer) -> Bool {
        guard let id = model.isolatedLayerID else { return true }
        return layer.id == id || layer.parentID == id
    }
    private func outlineRect(for layer: FormlessLayer) -> CGRect? {
        if layer.group {
            let members = model.document.children(of: layer.id)
            guard let first = members.first else { return nil }
            let scale = canvasSize.height / model.document.family.referenceHeight
            return members.dropFirst().reduce(
                FormlessLayerLayout.rotatedVisibleBounds(for: first, canvasSize: canvasSize, scale: scale)
            ) { bounds, member in
                bounds.union(FormlessLayerLayout.rotatedVisibleBounds(for: member, canvasSize: canvasSize, scale: scale))
            }
        }
        return FormlessLayerLayout.visibleRect(for: layer, canvasSize: canvasSize,
                                              scale: canvasSize.height / model.document.family.referenceHeight)
    }

    private func outlineCornerRadius(for layer: FormlessLayer) -> CGFloat {
        guard !layer.group else { return 3 }
        switch layer.type {
        case .shape, .image, .remoteImage:
            // 圓角只屬於矩形：其他形狀的外框用直角，才不會切過碰到框角的形狀（直角三角形、梯形、扇形……）。
            if layer.type == .shape && layer.shapeKind != .rectangle { return 0 }
            // 四個角分開時外框用直角，不會和內容的直角對不上。
            if layer.cornerRadii != nil { return 0 }
            let scale = canvasSize.height / model.document.family.referenceHeight
            let box = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
            let visible = FormlessLayerLayout.visibleRect(for: layer, canvasSize: canvasSize, scale: scale)
            return max(0, (layer.cornerRadius ?? 0) * scale + (visible.width - box.width) / 2)
        default:
            return 0
        }
    }

    private func outlineCenter(for layer: FormlessLayer, rect: CGRect) -> CGPoint {
        guard !layer.group && layer.rotation != 0 else { return CGPoint(x: rect.midX, y: rect.midY) }
        let box = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
        let angle = CGFloat(layer.rotation * .pi / 180)
        let dx = rect.midX - box.midX, dy = rect.midY - box.midY
        return CGPoint(x: box.midX + dx * cos(angle) - dy * sin(angle),
                       y: box.midY + dx * sin(angle) + dy * cos(angle))
    }
}

/// 量測指定圖層的實際內容；文字、等比例圖片與複合元件的透明留白不算進邊界。
@MainActor
enum EditorPaintedBounds {
    /// 可見範圍：文字類圖層量「文字行」（見 `EditorTextLine`），形狀與漸層用框本身，其他圖層（圖片、圖示、元件）量實際畫出來的像素。
    /// 位置與大小的數字、對齊、畫布選取框與點選範圍都用這一個函式，四者一致。
    static func measure(layers: [FormlessLayer], canvasSize: CGSize, family: FormlessWidgetFamily,
                        date: Date, live: FormlessLiveData) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0, !layers.isEmpty else { return nil }
        let scale = canvasSize.height / family.referenceHeight
        var lines: [CGRect] = []
        var painted: [FormlessLayer] = []
        for layer in layers {
            // 形狀與漸層是精確的幾何圖形，直接用框（含外框粗細）：量像素會把邊緣抗鋸齒的半透明像素算進去，
            // 框完全相同的色點因為落在不同的次像素位置，量出 30 或 31（使用者回報），照著改數字反而把框改大。
            if layer.type == .shape || layer.type == .gradient {
                lines.append(FormlessLayerLayout.rotatedVisibleBounds(for: layer, canvasSize: canvasSize, scale: scale))
                continue
            }
            switch EditorTextLine.bounds(for: layer, canvasSize: canvasSize, scale: scale, date: date, live: live) {
            case .line(let rect): lines.append(rect)
            case .truncated(let line):
                var unrotated = layer
                unrotated.rotation = 0
                let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
                let pixels = measurePixels(layers: [unrotated], canvasSize: canvasSize, family: family, date: date, live: live)
                let rect = pixels.map { CGRect(x: $0.minX, y: line.minY, width: $0.width, height: line.height) } ?? line
                lines.append(EditorTextLine.rotated(rect, in: box, degrees: layer.rotation))
            case .empty: break
            case .notText:
                // 計時器、倒數、相對時間的字每秒在變：左右量實際畫出來的像素，上下和其他時間一樣用參考字（`EditorTextLine.referenceInk`）。
                if layer.type == .time,
                   let reference = EditorTextLine.referenceInk(for: layer, fontSize: max(1, CGFloat(layer.fontSize ?? 22) * scale)) {
                    var unrotated = layer
                    unrotated.rotation = 0
                    if let pixels = measurePixels(layers: [unrotated], canvasSize: canvasSize, family: family, date: date, live: live) {
                        let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
                        let rect = CGRect(x: pixels.minX, y: box.midY + reference.top,
                                          width: pixels.width, height: reference.bottom - reference.top)
                        lines.append(EditorTextLine.rotated(rect, in: box, degrees: layer.rotation))
                    }
                } else {
                    painted.append(layer)
                }
            }
        }
        let text = lines.dropFirst().reduce(lines.first) { $0?.union($1) }
        guard !painted.isEmpty else { return text }
        guard let pixels = measurePixels(layers: painted, canvasSize: canvasSize, family: family, date: date, live: live) else {
            return text
        }
        return text.map { $0.union(pixels) } ?? pixels
    }

    /// 點擊處附近（半徑 radius 內）有沒有畫出看得見的內容：只畫這一小塊，和量邊界一樣以完全不透明、不含陰影來量，
    /// 只算不透明度 25% 以上的像素。畫不出來時回 nil（呼叫端照範圍算）。
    static func paints(layer: FormlessLayer, near point: CGPoint, radius: CGFloat, canvasSize: CGSize,
                       family: FormlessWidgetFamily, date: Date, live: FormlessLiveData) -> Bool? {
        guard canvasSize.width > 0, canvasSize.height > 0, radius > 0 else { return nil }
        let scale = canvasSize.height / family.referenceHeight
        var opaque = layer
        opaque.opacity = 1
        let side = radius * 2
        let renderer = ImageRenderer(content:
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    FormlessLayerView(layer: opaque, canvasSize: canvasSize, scale: scale,
                                      date: date, live: live, showsShadow: false)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .offset(x: radius - point.x, y: radius - point.y)
            }
            .frame(width: side, height: side, alignment: .topLeading)
            .clipped()
        )
        renderer.scale = 2
        let previousAssetMode = FormlessRenderContext.synchronousAssets
        FormlessRenderContext.synchronousAssets = true
        defer { FormlessRenderContext.synchronousAssets = previousAssetMode }
        guard let image = renderer.uiImage?.cgImage else { return nil }
        let width = image.width, height = image.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // 圓形範圍：離點擊處 radius 以內的像素。
        let cx = CGFloat(width) / 2, cy = CGFloat(height) / 2
        let limit = CGFloat(width) / 2
        for y in 0..<height {
            for x in 0..<width where hypot(CGFloat(x) + 0.5 - cx, CGFloat(y) + 0.5 - cy) <= limit {
                if pixels[y * rowBytes + x * 4 + 3] > 64 { return true }
            }
        }
        return false
    }

    private static func measurePixels(layers: [FormlessLayer], canvasSize: CGSize, family: FormlessWidgetFamily,
                                      date: Date, live: FormlessLiveData) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0, !layers.isEmpty else { return nil }
        let scale = canvasSize.height / family.referenceHeight
        /// 文字類圖層的字形常超出圖層框（字級大於框高、上下伸部）；擷取範圍至少要涵蓋一個行高，否則突出的部分被裁掉，
        /// 量到的邊界比實際字形小，對齊後數字對稱、畫面卻偏一邊（使用者的卡片內容置中後上邊距 30 px、下邊距 34 px）。
        func expectedBounds(_ layer: FormlessLayer) -> CGRect {
            var rect = FormlessLayerLayout.rotatedVisibleBounds(for: layer, canvasSize: canvasSize, scale: scale)
            if [.text, .date, .time, .liveText].contains(layer.type) {
                let lineHeight = (layer.fontSize ?? 22) * scale * 1.4
                if lineHeight > rect.height { rect = rect.insetBy(dx: 0, dy: -(lineHeight - rect.height) / 2) }
            }
            return rect
        }
        let geometric = layers.dropFirst().reduce(expectedBounds(layers[0])) { $0.union(expectedBounds($1)) }
        // 再多留一段安全邊（至少 16 pt，最多 48 pt，避免整張畫布大小的圖層超過下方的點陣限制）。
        let margin = min(48, max(16, min(geometric.width, geometric.height) * 0.5))
        let capture = geometric.insetBy(dx: -margin, dy: -margin).integral
        guard capture.width > 0, capture.height > 0,
              capture.width.isFinite, capture.height.isFinite else { return nil }
        // 成員相距極遠時分開量測，避免為中間的空白配置巨大點陣圖。
        if layers.count > 1 && capture.width * capture.height > 2_000_000 {
            let individual = layers.compactMap {
                measurePixels(layers: [$0], canvasSize: canvasSize, family: family, date: date, live: live)
            }
            return individual.dropFirst().reduce(individual.first) { $0?.union($1) }
        }
        guard capture.width * capture.height <= 2_000_000 else { return nil }
        let renderer = ImageRenderer(content:
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    // 以完全不透明量：圖層本身調淡時，像素一樣要算得到（只量形狀，不量透明度）。
                    ForEach(layers.map { layer -> FormlessLayer in var opaque = layer; opaque.opacity = 1; return opaque }) { layer in
                        FormlessLayerView(layer: layer, canvasSize: canvasSize, scale: scale,
                                          date: date, live: live, showsShadow: false)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .offset(x: -capture.minX, y: -capture.minY)
            }
            .frame(width: capture.width, height: capture.height, alignment: .topLeading)
            .clipped()
        )
        renderer.scale = 2
        let previousAssetMode = FormlessRenderContext.synchronousAssets
        FormlessRenderContext.synchronousAssets = true
        defer { FormlessRenderContext.synchronousAssets = previousAssetMode }
        guard let image = renderer.uiImage?.cgImage else { return nil }

        let width = image.width, height = image.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 從四個邊往內掃，碰到第一個看得見的像素就停；內容通常貼近擷取範圍，遠比掃完整張快。
        // 只算不透明度 25% 以上的像素：圖片素材常帶很淡的柔和陰影（天氣圖示四周約一成寬），
        // 肉眼幾乎看不到卻會把邊界撐大；實心邊緣的抗鋸齒不到一個像素，不受影響。整張都很淡的圖才退回算所有像素。
        var threshold: UInt8 = 64
        func rowPainted(_ y: Int) -> Bool {
            let base = y * rowBytes + 3
            var x = 0
            while x < width { if pixels[base + x * 4] > threshold { return true }; x += 1 }
            return false
        }
        func columnPainted(_ x: Int, from top: Int, to bottom: Int) -> Bool {
            let column = x * 4 + 3
            var y = top
            while y <= bottom { if pixels[y * rowBytes + column] > threshold { return true }; y += 1 }
            return false
        }
        var top = 0
        while top < height, !rowPainted(top) { top += 1 }
        if top == height {
            threshold = 0
            top = 0
            while top < height, !rowPainted(top) { top += 1 }
        }
        guard top < height else { return nil }
        var bottom = height - 1
        while bottom > top, !rowPainted(bottom) { bottom -= 1 }
        var left = 0
        while left < width, !columnPainted(left, from: top, to: bottom) { left += 1 }
        var right = width - 1
        while right > left, !columnPainted(right, from: top, to: bottom) { right -= 1 }
        guard right >= left, bottom >= top else { return nil }
        let xScale = capture.width / CGFloat(width)
        let yScale = capture.height / CGFloat(height)
        return CGRect(x: capture.minX + CGFloat(left) * xScale, y: capture.maxY - CGFloat(bottom + 1) * yScale,
                      width: CGFloat(right - left + 1) * xScale, height: CGFloat(bottom - top + 1) * yScale)
    }
}

/// 文字類圖層（文字、日期、時間、即時文字）的「文字行」範圍：量這一行字排在哪裡，不量筆畫。
/// - 左右：從文字行開始排的位置到結束的位置。靠左的文字左緣就是框的左緣、靠右的右緣就是框的右緣、置中的中線就是框的中線；
///   寬度是這一行字的排版寬度（字太長縮小或截斷時照實際排版）。
/// - 上下：這個字級、字型的一行高度，在框內垂直置中（和繪製時一樣）；和寫了什麼字無關。
/// 量筆畫會讓數字跟著字形變：同樣左 237 的兩個標題，「教師節」量到 239、「寒露」量到 240，行事曆換一天數字就亂（使用者回報）。
@MainActor
enum EditorTextLine {
    /// truncated：截斷的字，上下已算好（未旋轉），左右要量像素。
    enum Result { case line(CGRect), truncated(CGRect), empty, notText }

    static func bounds(for layer: FormlessLayer, canvasSize: CGSize, scale: CGFloat,
                       date: Date, live: FormlessLiveData) -> Result {
        // 曲線文字不是一行字：選取框照實際畫出的範圍量（和圖示、圖片一樣）。
        guard [.text, .date, .time, .liveText].contains(layer.type), layer.textArc == nil else { return .notText }
        guard let content = string(for: layer, date: date, live: live) else { return .notText }
        guard !content.isEmpty else { return .empty }
        var unrotated = layer
        unrotated.rotation = 0
        let box = FormlessLayerLayout.rect(for: unrotated, canvasSize: canvasSize)
        let fontSize = max(1, CGFloat(layer.fontSize ?? 22) * scale)
        let font = FormlessTextInk.font(size: fontSize, weight: layer.fontWeight, family: layer.fontFamily)
        // 與繪製相同：溫度帶次要色時不縮不截；「縮小文字」最多縮到 0.4 倍；「以省略號截斷」排滿到框的右緣才截斷。
        let fixed = layer.type == .liveText && FormlessLiveSource(rawValue: layer.value ?? "") == .weatherTemp
            && layer.secondaryColorHex != nil
        // 左右是筆畫的位置：畫的時候已去掉字形兩側自帶的空白（`FormlessTextInk`），靠左時筆畫就從框的左緣開始，
        // 數字跟著框走、不隨換字改變。上下維持一行的高度。
        let ink = FormlessTextInk.layout(content, font: font, alignment: layer.alignment, boxWidth: box.width,
                                         autoShrink: layer.autoShrink, fixed: fixed)
        let height = font.lineHeight * ink.factor
        var rect = CGRect(x: box.minX + ink.inkX, y: box.midY - height / 2, width: ink.inkWidth, height: height)
        if let reference = referenceInk(for: layer, fontSize: fontSize) {
            rect.origin.y = box.midY + reference.top
            rect.size.height = reference.bottom - reference.top
        }
        // 截斷後的字由系統決定切在哪裡：左右改量實際畫出來的筆畫，上下照上面的算法。
        if FormlessTextInk.truncates(content, font: font, boxWidth: box.width, autoShrink: layer.autoShrink, fixed: fixed) {
            return .truncated(rect)
        }
        return .line(rotated(rect, in: box, degrees: layer.rotation))
    }

    /// 旋轉後的外接框（以框的中心旋轉）。
    static func rotated(_ rect: CGRect, in box: CGRect, degrees: Double) -> CGRect {
        guard degrees != 0 else { return rect }
        let angle = CGFloat(degrees * .pi / 180)
        let dx = rect.midX - box.midX, dy = rect.midY - box.midY
        let center = CGPoint(x: box.midX + dx * cos(angle) - dy * sin(angle),
                             y: box.midY + dx * sin(angle) + dy * cos(angle))
        let rotatedWidth = abs(cos(angle)) * rect.width + abs(sin(angle)) * rect.height
        let rotatedHeight = abs(sin(angle)) * rect.width + abs(cos(angle)) * rect.height
        return CGRect(x: center.x - rotatedWidth / 2, y: center.y - rotatedHeight / 2,
                      width: rotatedWidth, height: rotatedHeight)
    }

    /// 內容會隨資料或時間變動的文字（即時文字、日期、時間）上下緣不量實際的字，改量參考字「國」在同字型、字級、字重下
    /// 畫在框裡的筆畫上下緣（相對於框的垂直中線），換內容時上／下的數字不變。原本量文字行，行程標題「縮小文字」時
    /// 行高跟著縮放比例變，換一筆行程上／下就差 1 格左右，五張卡片填一樣的數字也對不齊（使用者回報）。一般文字維持量文字行。
    static func referenceInk(for layer: FormlessLayer, fontSize: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        guard [.date, .time, .liveText].contains(layer.type) || (layer.type == .text && layer.segments != nil) else { return nil }
        let key = "\(layer.fontWeight ?? "")|\(layer.fontFamily ?? "")|\((fontSize * 100).rounded())"
        if let hit = referenceCache[key] { return hit }
        // 用繪製本身畫「國」再量像素，和畫面上的位置一致；框夠寬，不會被縮小或截斷。
        let side = max(8, (fontSize * 3).rounded(.up))
        let reference = FormlessLayer(type: .text, value: "國", colorHex: "#000000", fontSize: Double(fontSize),
                                      fontWeight: layer.fontWeight, fontFamily: layer.fontFamily, alignment: "center")
        let renderer = ImageRenderer(content:
            FormlessLayerContentView(layer: reference, boxSize: CGSize(width: side, height: side), scale: 1)
                .frame(width: side, height: side)
        )
        renderer.scale = min(4, max(1, 1200 / side))
        guard let image = renderer.uiImage?.cgImage else { return nil }
        let width = image.width, height = image.height, rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // 不翻轉：記憶體第 0 列就是圖的最上面一列。
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // 和量像素相同：只算不透明度 25% 以上的像素。
        func painted(_ y: Int) -> Bool { (0..<width).contains { pixels[y * rowBytes + $0 * 4 + 3] > 64 } }
        guard let top = (0..<height).first(where: painted), let bottom = (0..<height).last(where: painted) else { return nil }
        let pixel = side / CGFloat(height)
        let result = (top: CGFloat(top) * pixel - side / 2, bottom: CGFloat(bottom + 1) * pixel - side / 2)
        referenceCache[key] = result
        return result
    }
    private static var referenceCache: [String: (top: CGFloat, bottom: CGFloat)] = [:]

    /// 畫面上實際顯示的那一行字；計時器、倒數、相對時間每秒都在變，回 nil 改量筆畫。
    private static func string(for layer: FormlessLayer, date: Date, live: FormlessLiveData) -> String? {
        switch layer.type {
        case .text:
            // 多行文字、系統即時走動的時間：量實際畫出來的筆畫。
            guard layer.textLineLimit == 1 else { return nil }
            if let segments = layer.segments, !segments.isEmpty {
                let pieces = live.pieces(segments, at: date)
                if pieces.contains(where: { if case .live = $0 { return true } else { return false } }) { return nil }
                return pieces.map { $0.sample(at: date) }.joined()
            }
            return layer.value ?? ""
        case .date:
            return formlessFormatted(layer.value ?? "yyyy/MM/dd", date: date)
        case .time:
            let raw = layer.value ?? FormlessTimeStyle.auto.rawValue
            switch FormlessTimeStyle(rawValue: raw) {
            case .auto: return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            case .day: return DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none)
            case .timer, .countdown, .relative: return nil
            case .none: return formlessFormatted(raw, date: date)
            }
        case .liveText:
            let source = FormlessLiveSource(rawValue: layer.value ?? "")
            if source == .weatherPlace, let name = layer.locationName, !name.isEmpty { return name }
            if source == .weatherTemp, layer.secondaryColorHex != nil { return (live.weather?.temperatureText ?? "－") + "°" }
            return source?.text(live: live, date: date, dataIndex: layer.dataIndex) ?? "－"
        default:
            return nil
        }
    }
}

/// 編輯器所有座標欄位與對齊操作共用的可見邊界；以畫布寬、高各 1600 格表示。
@MainActor
enum EditorVisibleGeometry {
    static func bounds(document: FormlessDocument, ids: Set<UUID>, live: FormlessLiveData,
                       date: Date = Date()) -> FormlessFrame? {
        let family = document.family
        // 點陣輸出兩倍解析度；兩軸至少各有 1600 像素，座標可精確到畫布的一格。
        let height = max(800, 800 / family.aspectRatio)
        let canvasSize = CGSize(width: family.aspectRatio * height, height: height)
        let selected = document.layers.filter { ids.contains($0.id) }
        let expanded = ids.union(document.layers.filter { $0.parentID.map(ids.contains) ?? false }.map(\.id))
        let candidates = document.layers.filter { expanded.contains($0.id) && !$0.group && !document.effectivelyHidden($0) }
        let members = candidates.filter { FormlessDataBinding.satisfied($0.dataIndex, live: live) }
        // 資料不足而畫不出內容的圖層（例如只有一筆提醒時的第二、三列）以圖層框計入。
        // 不然它們會被對齊與量測略過：整批對齊只看得到有字的那一列，其他列跟著平移卻沒被算進去，看起來整批偏掉。
        let unmeasurable = candidates.filter { !FormlessDataBinding.satisfied($0.dataIndex, live: live) }
        let single = selected.count == 1 ? selected.first.flatMap { $0.group ? nil : $0 } : nil
        guard !members.isEmpty || !unmeasurable.isEmpty || single != nil else { return nil }
        let scale = canvasSize.height / family.referenceHeight

        var painted: CGRect?
        if let layer = single {
            var unrotated = layer
            unrotated.rotation = 0
            painted = EditorPaintedBounds.measure(layers: [unrotated], canvasSize: canvasSize,
                                                   family: family, date: date, live: live).map { rect in
                guard layer.rotation != 0 else { return rect }
                let box = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
                let angle = CGFloat(layer.rotation * .pi / 180)
                let dx = rect.midX - box.midX, dy = rect.midY - box.midY
                let center = CGPoint(x: box.midX + dx * cos(angle) - dy * sin(angle),
                                     y: box.midY + dx * sin(angle) + dy * cos(angle))
                return CGRect(x: center.x - (abs(cos(angle)) * rect.width + abs(sin(angle)) * rect.height) / 2,
                              y: center.y - (abs(sin(angle)) * rect.width + abs(cos(angle)) * rect.height) / 2,
                              width: abs(cos(angle)) * rect.width + abs(sin(angle)) * rect.height,
                              height: abs(sin(angle)) * rect.width + abs(cos(angle)) * rect.height)
            }
            // 量不到任何內容（空字串、資料不足）：改用圖層框，位置與大小照樣能調。
            if painted == nil {
                painted = FormlessLayerLayout.rotatedVisibleBounds(for: layer, canvasSize: canvasSize, scale: scale)
            }
        } else {
            if !members.isEmpty {
                painted = EditorPaintedBounds.measure(layers: members, canvasSize: canvasSize,
                                                       family: family, date: date, live: live)
                if painted == nil {
                    painted = members.dropFirst().reduce(
                        FormlessLayerLayout.rotatedVisibleBounds(for: members[0], canvasSize: canvasSize, scale: scale)
                    ) { $0.union(FormlessLayerLayout.rotatedVisibleBounds(for: $1, canvasSize: canvasSize, scale: scale)) }
                }
            }
            for layer in unmeasurable {
                let rect = FormlessLayerLayout.rotatedVisibleBounds(for: layer, canvasSize: canvasSize, scale: scale)
                painted = painted.map { $0.union(rect) } ?? rect
            }
        }
        guard let painted else { return nil }
        return FormlessFrame(x: Double(painted.minX / canvasSize.width),
                             y: Double(painted.minY / canvasSize.height),
                             width: Double(painted.width / canvasSize.width),
                             height: Double(painted.height / canvasSize.height))
    }
}


// MARK: - 圖層清單

struct FormlessLayerRow: Identifiable {
    let id: UUID
    let layer: FormlessLayer
    let indent: Int
}


struct LayerListView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    @ObservedObject var layout: EditorLayoutState
    var onAdd: () -> Void
    var onSelect: (UUID) -> Void
    @State private var message: String?
    var body: some View {
        VStack(spacing: 0) {
            layerList.overlay(alignment: .bottom) {
                if !session.picking { addButton }
            }
        }
        .overlay(alignment: .bottom) {
            if let message {
                Button {
                    withAnimation(FormlessDesign.Motion.fade) { self.message = nil }
                } label: {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .contentShape(Capsule())
                        .formlessGlass(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 68)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityHint("點一下關閉")
            }
        }
        .task(id: message) {
            guard message != nil else { return }
            do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(FormlessDesign.Motion.fade) { message = nil }
        }
    }

    /// 右下角的「＋」：和屬性面板右下角的「…」同一個位置、同一種按鈕（底部浮動列高 48、離邊 20、離底 5）。
    private var addButton: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Label("新增圖層", systemImage: "plus").frame(width: 20, height: 20)
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
            // 和「…」一樣往上 7：對齊分類列玻璃條的中線（系統分頁列的玻璃畫在框的中線上方）。
            .offset(y: -7)
            .contextMenu {
                Button("貼上圖層", systemImage: "doc.on.clipboard", action: pasteLayers)
            }
            .accessibilityAction(named: "貼上圖層", pasteLayers)
        }
        .buttonStyle(.glass)
        .frame(height: FormlessDesign.Size.floatingBar)
        .padding(.horizontal, FormlessDesign.Space.edge)
        .padding(.vertical, FormlessDesign.Space.floatingBottom)
    }

    /// UIKit 清單（LayerCollectionList）：一般模式滑動刪除、長按進入選取；選取模式長按整列拖曳排序，
    /// 依手指水平位置決定進出群組。拖群組時群組先收合、整組一起移動，放下後維持收合。
    private var layerList: some View {
        LayerCollectionList(model: model, session: session, onSelect: onSelect)
            .ignoresSafeArea(edges: .bottom)
            .background(EditorScrollMemory(session: session, key: "圖層清單"))
            // 選取模式下清單頂端內距較小（工具列已經隔開了），淡出帶也跟著縮短，第一列不會被淡掉。
            // 頂端淡化帶跟著 session.picking 而不是版面狀態：換遮罩會讓整份清單重新合成（模擬器量到約 50 ms），
            // 放在進出選取模式的版面動畫之外（進入時在動畫前那一格、退出時在動畫結束後），動畫本身才不會卡。
            .mask(alignment: .top) { EditorPanelMask(fade: session.listFade, topFade: session.picking ? EditorPanelUnderlap.height + 12 : nil) }
    }

    private func pasteLayers() {
        if model.pasteLayers() == 0 {
            withAnimation(FormlessDesign.Motion.fade) {
                message = "剪貼簿沒有可貼上的圖層。"
            }
        } else {
            message = nil
        }
    }
}

/// 下半部工具面板（選取模式的「位置與大小」、屬性面板的顏色）：只有這一層觀察 `EditorToolPanelState`，
/// 開關面板時編輯器的其他部分（圖層清單、屬性面板）不重畫。高度是螢幕的 60%，貼齊螢幕底邊；
/// 整層忽略所有安全區，鍵盤出現時安全區改變也不會把面板頂高（只捲裡面的表單）。
struct EditorToolPanelLayer: View {
    let model: EditorModel
    let session: EditorSession
    @ObservedObject var panels: EditorToolPanelState
    let picking: Bool
    let inspecting: Bool

    var body: some View {
        let height = FormlessPanelMetrics.height
        // 面板上緣固定在螢幕座標（視窗高 − 面板高）：原本靠底部對齊，鍵盤出現時安全區改變，整片面板被推高約 32 pt。
        GeometryReader { geometry in
            panelStack(height: height)
                .frame(width: geometry.size.width, height: height, alignment: .top)
                .offset(y: FormlessSafeArea.windowHeight - height - geometry.frame(in: .global).minY)
        }
        .ignoresSafeArea()
        // 位置與大小：進入選取模式、畫面穩定後就先在螢幕外建好（建立整張表單與玻璃按鈕約 0.1 秒），
        // 按下按鈕時只做滑上來的動畫；原本按下的那一格才建，第一格卡住，面板和畫布都頓一下（使用者回報）。
        .task(id: picking) {
            guard picking else { panels.positionMounted = false; panels.positionShown = false; return }
            try? await Task.sleep(for: .milliseconds(450))
            if picking { panels.positionMounted = true }
        }
        .onChange(of: panels.positionOpen) { _, open in
            guard open else { panels.positionShown = false; return }
            if panels.positionMounted {
                // 先量好勾選圖層的實際範圍（量的結果會暫存），下一格才滑上來：量的時間不落在動畫裡。
                _ = model.visibleBounds(of: session.picked)
                FormlessNextFrame.run { [panels] in panels.positionShown = panels.positionOpen }
            } else {
                // 預先建立還沒完成（剛進選取模式就按）：這一格先建在螢幕外，下一格才滑上來。
                panels.positionMounted = true
                FormlessNextFrame.run { [panels] in panels.positionShown = panels.positionOpen }
            }
        }
        // 顏色面板：先在螢幕外建好（系統調色盤），下一格才滑上來，建立的時間不落在動畫裡。
        .onChange(of: panels.color?.id) { _, id in
            guard id != nil else { panels.colorShown = false; panels.eyedropping = false; return }
            panels.colorShown = false
            FormlessNextFrame.run { [panels] in panels.colorShown = panels.color != nil }
        }
        // 圖示面板：和顏色面板一樣先建好、下一格才滑上來。
        .onChange(of: panels.symbol) { _, id in
            guard id != nil else { panels.symbolShown = false; return }
            panels.symbolShown = false
            FormlessNextFrame.run { [panels] in panels.symbolShown = panels.symbol != nil }
        }
        // 底色面板：和顏色面板一樣先建好、下一格才滑上來。
        .onChange(of: panels.background) { _, open in
            guard open else { panels.backgroundShown = false; panels.eyedropping = false; return }
            panels.backgroundShown = false
            FormlessNextFrame.run { [panels] in panels.backgroundShown = panels.background }
        }
        // 外觀的細項面板：和顏色面板一樣先建好、下一格才滑上來。
        .onChange(of: panels.style?.id) { _, id in
            guard id != nil else { panels.styleShown = false; panels.eyedropping = false; return }
            panels.styleShown = false
            FormlessNextFrame.run { [panels] in panels.styleShown = panels.style != nil }
        }
        // 選擇資料、格式面板：同樣先建好、下一格才滑上來。
        .onChange(of: panels.data?.id) { _, id in
            guard id != nil else { panels.dataShown = false; return }
            panels.dataShown = false
            FormlessNextFrame.run { [panels] in panels.dataShown = panels.data != nil }
        }
        .onChange(of: panels.format?.id) { _, id in
            guard id != nil else { panels.formatShown = false; return }
            panels.formatShown = false
            FormlessNextFrame.run { [panels] in panels.formatShown = panels.format != nil }
        }
    }

    private func panelStack(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if panels.positionMounted && picking {
                BatchPositionPanel(model: model, session: session, height: height, shown: panels.positionShown)
                    .allowsHitTesting(panels.positionShown)
                    .formlessPanelPresence(shown: panels.positionShown, height: height)
            }
            if let request = panels.color, inspecting {
                let shown = panels.colorShown && !panels.eyedropping
                EditorColorPanel(model: model, request: request, height: height, shown: shown,
                                 onEyedropper: { deliver in startEyedropper(request.id, deliver: deliver) }, onClose: { closeColor() },
                                 openData: { [panels] next in
                                     panels.closeInspectorPanels()
                                     panels.data = next
                                 })
                    .id(request.id)
                    .allowsHitTesting(shown)
                    // 平常從下方滑進滑出；減少動態時停在原位淡入淡出（2026-10 輔助使用）。
                    .formlessPanelPresence(shown: shown, height: height)
            }
            if panels.background {
                let shown = panels.backgroundShown && !panels.eyedropping
                WidgetBackgroundPanel(model: model, height: height, shown: shown,
                                      onEyedropper: { deliver in startEyedropper(EditorToolPanelState.backgroundPanelID, deliver: deliver) },
                                      onClose: { closeBackground() })
                    .allowsHitTesting(shown)
                    // 平常從下方滑進滑出；減少動態時停在原位淡入淡出（2026-10 輔助使用）。
                    .formlessPanelPresence(shown: shown, height: height)
            }
            if let request = panels.style, inspecting {
                let shown = panels.styleShown && !panels.eyedropping
                EditorStylePanel(model: model, request: request, height: height, shown: shown,
                                 onEyedropper: { deliver in startEyedropper(request.id, deliver: deliver) }, onClose: { closeStyle() })
                    .id(request.id)
                    .allowsHitTesting(shown)
                    // 平常從下方滑進滑出；減少動態時停在原位淡入淡出（2026-10 輔助使用）。
                    .formlessPanelPresence(shown: shown, height: height)
            }
            if let id = panels.symbol, inspecting {
                let shown = panels.symbolShown
                EditorSymbolPanel(model: model, layerID: id, height: height, shown: shown, onClose: { closeSymbol() })
                    .id(id)
                    .allowsHitTesting(shown)
                    // 平常從下方滑進滑出；減少動態時停在原位淡入淡出（2026-10 輔助使用）。
                    .formlessPanelPresence(shown: shown, height: height)
            }
            if let request = panels.data, inspecting {
                let shown = panels.dataShown
                EditorDataPanel(model: model, request: request, height: height, shown: shown, onClose: { closeData() })
                    .id(request.id)
                    .allowsHitTesting(shown)
                    // 平常從下方滑進滑出；減少動態時停在原位淡入淡出（2026-10 輔助使用）。
                    .formlessPanelPresence(shown: shown, height: height)
            }
            if let request = panels.format, inspecting {
                let shown = panels.formatShown
                EditorFormatPanel(model: model, request: request, height: height, shown: shown,
                                  onReplace: { replaceData(request) }, onClose: { closeFormat() })
                    .id(request.id)
                    .allowsHitTesting(shown)
                    // 平常從下方滑進滑出；減少動態時停在原位淡入淡出（2026-10 輔助使用）。
                    .formlessPanelPresence(shown: shown, height: height)
            }
        }
    }

    private func closeData() {
        panels.dataShown = false
        let id = panels.data?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            if panels.data?.id == id, !panels.dataShown { panels.data = nil }
        }
    }

    private func closeFormat() {
        panels.formatShown = false
        let id = panels.format?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            if panels.format?.id == id, !panels.formatShown { panels.format = nil }
        }
    }

    /// 格式面板的「更換」：收起格式面板，換成選擇資料面板（一次只開一個）。
    private func replaceData(_ request: EditorFormatPanelRequest) {
        let kinds: Set<FormlessValueKind>?
        switch request.slot {
        case .progress, .colorRuleThreshold: kinds = [.number, .duration]
        case .symbol: kinds = [.symbol]
        case .color: kinds = [.color]
        case .url: kinds = [.text]
        default: kinds = nil
        }
        panels.format = nil
        panels.data = EditorDataPanelRequest(layerID: request.layerID, target: .slot(request.slot), kinds: kinds,
                                             wantsList: request.slot == .chartSeries || request.slot == .repeatCollection)
    }

    /// 滴管：面板先滑下去、畫布回到原本大小，整個畫面露出來後才拍畫面讓使用者取色；取完面板再滑回來。
    /// 放大鏡從畫布中間開始（取色多半是取畫布上的顏色）。
    private func startEyedropper(_ id: UUID, deliver: @escaping (UIColor) -> Void) {
        panels.eyedropping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            guard panels.eyedropping else { return }
            let start = CGPoint(x: FormlessSafeArea.windowWidth / 2,
                                y: FormlessSafeArea.top + (FormlessSafeArea.windowHeight / 2 - FormlessSafeArea.top) / 2)
            FormlessEyedropper.present(start: start) { color in
                if let color, panels.color?.id == id || panels.style?.id == id
                    || (panels.background && id == EditorToolPanelState.backgroundPanelID) { deliver(color) }
                panels.eyedropping = false
            }
        }
    }

    /// 顏色面板先滑下去，動畫結束才拿掉（直接拿掉會沒有收起的動畫）。
    private func closeColor() {
        panels.colorShown = false
        let id = panels.color?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            if panels.color?.id == id, !panels.colorShown { panels.color = nil }
        }
    }

    private func closeBackground() {
        panels.backgroundShown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            if !panels.backgroundShown { panels.background = false }
        }
    }

    private func closeSymbol() {
        panels.symbolShown = false
        let id = panels.symbol
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            if panels.symbol == id, !panels.symbolShown { panels.symbol = nil }
        }
    }

    private func closeStyle() {
        panels.styleShown = false
        let id = panels.style?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)) { [panels] in
            if panels.style?.id == id, !panels.styleShown { panels.style = nil }
        }
    }
}

/// 選取模式的「位置與大小」工具面板：畫在編輯器畫面裡，不是系統 sheet（系統的半高 sheet 會縮小浮起，
/// 和「小工具設定」的滿版面板長得不一樣）。底色、頂端圓角、滑上來的方式比照「小工具設定」；
/// 上緣固定在螢幕一半（畫布最高只拉到螢幕一半，面板永遠不擋畫布），標題列和其他半高面板相同，點面板外關閉。
/// 方塊和屬性面板一樣大，內容比半個螢幕高時可以捲動；移動步進在方塊下方那一列。
struct BatchPositionPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    /// 面板總高度（含螢幕底部安全區）。
    let height: CGFloat
    /// 正在畫面上（預先建好藏在螢幕外時為 false，點外面關閉的擋板不出現）。
    var shown = true
    /// 卡片到面板四邊的距離。
    static let margin = FormlessDesign.Space.panel
    /// 和「小工具設定」面板相同的頂端圓角（實測約 34 pt 的連續曲線）。
    static let cornerRadius = FormlessDesign.Radius.panel
    /// 系統面板滑上來的方式（無回彈的彈簧）。
    static let animation = FormlessDesign.Motion.panel
    /// 標題列的高度：和其他半高面板（新增小工具、新增圖層）一樣。
    static let titleBar = FormlessDesign.Size.titleBar

    var body: some View {
        Form {
            EditorGeometryControls(model: model, ids: session.picked, session: session, measures: shown)
        }
        .scrollContentBackground(.hidden)
        // 位置與大小、對齊是兩張卡片，中間的距離和其他面板相同。
        .listSectionSpacing(FormlessDesign.Space.panel)
        .contentMargins(.horizontal, Self.margin, for: .scrollContent)
        // 標題列本身已在標題字下方留了約 22 pt（標題和其他面板同一個位置），卡片直接接在標題列下面，
        // 標題字到卡片的距離就和卡片到左右邊的 20 pt 差不多；再加一段邊距會多出一塊空白（使用者指出）。
        .contentMargins(.top, 0, for: .scrollContent)
        // 底部只留一個邊距加螢幕底部安全區：面板高度（螢幕 60%）放得下全部內容，不需要捲動（使用者要求）。
        // 內容放得下就不會有捲動軸；拖動仍會回彈（和其他清單一樣），也保留給鍵盤避讓把欄位捲到鍵盤上方。
        .contentMargins(.bottom, Self.margin + FormlessSafeArea.bottom, for: .scrollContent)
        .scrollIndicators(.hidden)
        .background(FormlessFixedPanelScroll())
        // 標題列和系統導覽列一樣半透明：內容捲到標題下方時霧化透出（使用者要求所有面板一致）。
        .safeAreaBar(edge: .top, spacing: 0) {
            Text("位置與大小")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: Self.titleBar)
        }
        .editorToolPanel(height: height, active: shown) { session.batchPositionOpen = false }
    }
}

extension View {
    /// 編輯器工具面板的共同外觀（位置與大小、顏色）：固定高度、底色與頂端圓角比照「小工具設定」、淡陰影分出邊界
    /// （背景不暗化，要邊看畫布邊調）、點面板外關閉且不觸發底下的東西。
    func editorToolPanel(height: CGFloat, active: Bool = true, onClose: @escaping () -> Void) -> some View {
        modifier(EditorToolPanelChrome(height: height, active: active, onClose: onClose))
    }
}

/// 工具面板的外觀與關閉方式：點面板外關閉；從標題列往下拉也能關（10/03 決定），放手依拉的距離與速度決定
/// 關閉或彈回。只從標題列中間開始拖才算（兩側留給返回、滴管這類圓鈕），面板內容照常上下捲動，不會被誤關。
struct EditorToolPanelChrome: ViewModifier {
    let height: CGFloat
    let active: Bool
    let onClose: () -> Void
    @State private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(FormlessDesign.Palette.page)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: BatchPositionPanel.cornerRadius,
                                              topTrailingRadius: BatchPositionPanel.cornerRadius, style: .continuous))
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: BatchPositionPanel.titleBar)
                    .padding(.horizontal, FormlessDesign.Size.glassButton + BatchPositionPanel.margin + 8)
                    .contentShape(Rectangle())
                    .gesture(dismissDrag)
            }
            .shadow(color: .black.opacity(0.1), radius: 18, x: 0, y: 0)
            // 用畫面效果位移，不用 .offset：.offset 改的是位置，面板裡的清單（系統元件）會晚一格才跟上，
            // 往上拉放手回彈時標題列和清單錯開，看起來像殘影（使用者 10/04 錄影）。畫面效果是整塊一起平移。
            .visualEffect { [dragOffset] content, _ in content.offset(y: dragOffset) }
            .background(FormlessPanelOutsideTap(active: active, onTap: onClose))
            // 旁白：面板開著時只讀面板裡的東西，兩指 Z 字手勢關閉（和點面板外關閉一致）。
            .formlessModalPanel(active: active, onClose: onClose)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let distance = value.translation.height
                // 往下 1:1 跟手；往上越拉越緊（面板不會被拉高）。
                dragOffset = distance >= 0 ? distance : -(abs(distance) * 30) / (30 + abs(distance))
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                if value.translation.height > height * 0.3 || projected > height * 0.6 {
                    // 從手指放開的位置接著滑下去（父層的關閉動畫接手），不跳回原位。
                    withAnimation(FormlessDesign.Motion.panel) { dragOffset = 0 }
                    onClose()
                } else {
                    withAnimation(FormlessDesign.Motion.panel) { dragOffset = 0 }
                }
            }
    }
}

/// 角度圓盤：線指向漸層前進的方向（0° 往上、90° 往右），繞著圓心拖動就轉；點一下直接指向那個方向。
struct EditorAngleDial: View {
    @Binding var angle: Double
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            // 圓點放在指針末端（指向的那一端）；放在圓心的話縮小看會像反方向的箭頭。
            ZStack {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: size / 2 - 6)
                    .offset(y: -(size / 2 - 6) / 2)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .offset(y: -(size / 2 - 6))
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        // 手勢交給 UIKit（`FormlessScrollSafeDrag`）：從圓盤上開始的拖動才轉角度（圓周方向不限），
        // 其他地方開始的滑動照常捲動表單；點一下直接指向那個方向。
        .overlay {
            FormlessScrollSafeDrag(
                canBegin: { start in hypot(start.x - 6 - size / 2, start.y - 6 - size / 2) <= size / 2 + 6 },
                requiresHorizontalStart: false,
                onTap: { point($0) },
                onBegan: { point($0) },
                onChanged: { location, _ in point(location) },
                onEnded: {}
            )
            .padding(-6)
        }
        .accessibilityLabel("角度圓盤")
        .accessibilityValue("\(Int(angle)) 度")
    }

    /// `location` 是手勢層的座標（比圓盤四周多 6 pt）。
    private func point(_ location: CGPoint) {
        let dx = location.x - 6 - size / 2, dy = location.y - 6 - size / 2
        guard hypot(dx, dy) > 3 else { return }
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let next = degrees.rounded().truncatingRemainder(dividingBy: 360)
        if next != angle { angle = next }
    }
}

/// 漸層條：一條橫向的漸層預覽（棋盤格底看得出透明），顏色點是條上的圓鈕；選中的圓鈕有藍框。
/// 點條上：選取最近的圓鈕（不新增）；拖圓鈕：改位置；把圓鈕往下拖離漸層條：刪除（至少留兩點）。
struct EditorGradientBar: View {
    @Binding var stops: [FormlessGradientStop]
    @Binding var selected: Int
    @State private var dragging: Int?
    @State private var removing = false

    private static let knob: CGFloat = 26
    private static let barHeight: CGFloat = 28
    private static let removeDistance: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            let inset = Self.knob / 2
            let track = max(1, geometry.size.width - Self.knob)
            let sorted = stops.sorted { $0.location < $1.location }
            let knobX = { (location: Double) in inset + CGFloat(min(max(location, 0), 1)) * track }
            let nearest = { (x: CGFloat) -> Int? in stops.indices.min { abs(knobX(stops[$0].location) - x) < abs(knobX(stops[$1].location) - x) } }
            ZStack(alignment: .leading) {
                ZStack {
                    EditorCheckerboard()
                    LinearGradient(stops: sorted.map { Gradient.Stop(color: Color(formlessHex: $0.colorHex, fallback: "#000000"),
                                                                      location: min(max($0.location, 0), 1)) },
                                   startPoint: .leading, endPoint: .trailing)
                }
                .frame(height: Self.barHeight)
                .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
                    .strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline))
                .padding(.horizontal, inset)
                ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                    EditorStopSwatch(hex: stop.colorHex, size: Self.knob, border: 3)
                        .overlay {
                            // 選中的藍框畫在圓鈕的白邊上、不往外長，0% 與 100% 的圓鈕才不會超出列的左右邊界。
                            if index == min(selected, stops.count - 1) {
                                Circle().strokeBorder(FormlessDesign.Palette.accent, lineWidth: FormlessDesign.Stroke.selection)
                            }
                        }
                        // 把手陰影：和調色盤的把手相同。
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .opacity(removing && dragging == index ? 0.25 : 1)
                        .offset(x: knobX(stop.location) - Self.knob / 2,
                                y: removing && dragging == index ? Self.removeDistance / 2 : 0)
                        .animation(FormlessDesign.Motion.fade, value: removing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // 拖曳中顯示位置（放開就消失）：面板不再常駐一個位置欄位，數字只在需要時出現。
            // 標籤由外層畫在圓鈕上方的最上層（見 `EditorDragLabelKey`）；原本畫在圓鈕下方，正好被手指擋住（使用者回報）。
            .anchorPreference(key: EditorDragLabelKey.self, value: .bounds) { anchor in
                guard let index = dragging, stops.indices.contains(index), !removing else { return [] }
                return [EditorDragLabel(text: "\(Int((stops[index].location * 100).rounded()))%", anchor: anchor,
                                        x: knobX(stops[index].location))]
            }
            // 手勢交給 UIKit（`FormlessScrollSafeDrag`，和 App 的滑桿同一套規則）：表單捲動優先——
            // 從圓鈕附近開始、一開始是橫向的拖動才移動圓鈕；從圓鈕上直接往下拖是刪除；其他滑動都是捲動。
            // 點一下（手指沒移動）選取最近的圓鈕，不新增。原本用 SwiftUI 零距離拖曳，捲動時常被當成點條、捲動也卡。
            .overlay {
                FormlessScrollSafeDrag(
                    canBegin: { start in
                        guard let near = nearest(start.x) else { return false }
                        return abs(knobX(stops[near].location) - start.x) <= Self.knob / 2 + 12
                    },
                    canBeginVertically: { start, downward in
                        guard downward, stops.count > 2, let near = nearest(start.x) else { return false }
                        return hypot(knobX(stops[near].location) - start.x, geometry.size.height / 2 - start.y) <= Self.knob / 2 + 4
                    },
                    onTap: { point in
                        if let near = nearest(point.x), selected != near { selected = near }
                    },
                    onBegan: { start in
                        guard let near = nearest(start.x) else { return }
                        dragging = near
                        if selected != near { selected = near }
                    },
                    onChanged: { location, translation in
                        guard let index = dragging, stops.indices.contains(index) else { return }
                        let away = stops.count > 2 && translation.height > Self.removeDistance
                        if away != removing { removing = away }
                        guard !away else { return }
                        let next = (Double(min(max((location.x - inset) / track, 0), 1)) * 100).rounded() / 100
                        if stops[index].location != next { stops[index].location = next }
                    },
                    onEnded: {
                        defer { dragging = nil; removing = false }
                        if removing, let index = dragging, stops.indices.contains(index), stops.count > 2 {
                            let location = stops[index].location
                            stops.remove(at: index)
                            selected = stops.indices.min { abs(stops[$0].location - location) < abs(stops[$1].location - location) } ?? 0
                        }
                    }
                )
            }
        }
        .frame(height: 32)
        .accessibilityLabel("漸層顏色點")
    }

    /// 漸層在某個位置的顏色（前後兩個顏色點依位置內插，含透明度）。
    static func color(at location: Double, in stops: [FormlessGradientStop]) -> String {
        let sorted = stops.sorted { $0.location < $1.location }
        guard let first = sorted.first, let last = sorted.last else { return "#000000FF" }
        if location <= first.location { return EditorRGBA(hex: first.colorHex)?.hex8 ?? first.colorHex }
        if location >= last.location { return EditorRGBA(hex: last.colorHex)?.hex8 ?? last.colorHex }
        guard let upper = sorted.firstIndex(where: { $0.location >= location }), upper > 0 else { return first.colorHex }
        let a = sorted[upper - 1], b = sorted[upper]
        guard let ca = EditorRGBA(hex: a.colorHex), let cb = EditorRGBA(hex: b.colorHex) else { return a.colorHex }
        let t = b.location > a.location ? (location - a.location) / (b.location - a.location) : 0
        return EditorRGBA(r: ca.r + (cb.r - ca.r) * t, g: ca.g + (cb.g - ca.g) * t,
                          b: ca.b + (cb.b - ca.b) * t, a: ca.a + (cb.a - ca.a) * t).hex8
    }
}

/// 拖曳中的數值標籤（漸層顏色點的位置）：由拖曳的元件回報自己的範圍與圓鈕的橫向位置，
/// 外層（顏色面板）用 `editorDragLabels()` 畫在所有內容與標題列之上、圓鈕正上方，手指擋不到。
struct EditorDragLabel {
    let text: String
    let anchor: Anchor<CGRect>
    /// 圓鈕中心相對元件左緣的距離。
    let x: CGFloat
}

struct EditorDragLabelKey: PreferenceKey {
    static var defaultValue: [EditorDragLabel] { [] }
    static func reduce(value: inout [EditorDragLabel], nextValue: () -> [EditorDragLabel]) { value += nextValue() }
}

extension View {
    func editorDragLabels() -> some View {
        overlayPreferenceValue(EditorDragLabelKey.self) { labels in
            GeometryReader { proxy in
                ForEach(labels.indices, id: \.self) { index in
                    let label = labels[index]
                    let rect = proxy[label.anchor]
                    Text(label.text)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .fixedSize()
                        // 圓鈕上緣再往上 8 pt；左右不超出面板。
                        .position(x: min(max(rect.minX + label.x, 30), proxy.size.width - 30), y: rect.midY - 31)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// 漸層顏色點的色票：只有顏色本身（透明的部分透出棋盤格），外圍白邊，不加彩虹圈（使用者：會干擾判斷顏色）。
struct EditorStopSwatch: View {
    let hex: String
    var size: CGFloat = 28
    var border: CGFloat = 0
    var body: some View {
        EditorCheckerboard()
            .overlay(Color(formlessHex: hex, fallback: "#000000"))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(border > 0 ? Color.white : FormlessDesign.Palette.hairline,
                                           lineWidth: border > 0 ? border : FormlessDesign.Stroke.hairline))
            .frame(width: size, height: size)
    }
}

/// 放在捲動表單裡的拖曳控制（漸層條、角度圓盤）用的手勢層，規則和 `FormlessSlider` 相同：表單捲動優先。
/// - 拖曳只有在 `canBegin`（起點）成立、而且一開始是橫向時才由控制項接手（`requiresHorizontalStart` 為 false 時方向不限）；
///   `canBeginVertically` 可另外允許從特定位置直接往上／下拖（例如從圓鈕上往下拖刪除）。其餘滑動都交給表單捲動。
/// - 點一下（手指沒移動）另外回報；清單還在滑動時按下去只是讓它停下，不算點（`FormlessScrollStopTap`）。
/// SwiftUI 的零距離拖曳在表單裡會先吃掉觸控：捲動常被當成點擊，捲動本身也會卡。
struct FormlessScrollSafeDrag: UIViewRepresentable {
    var canBegin: (CGPoint) -> Bool
    var requiresHorizontalStart = true
    var canBeginVertically: (_ start: CGPoint, _ downward: Bool) -> Bool = { _, _ in false }
    var onTap: (CGPoint) -> Void
    var onBegan: (CGPoint) -> Void
    var onChanged: (_ location: CGPoint, _ translation: CGSize) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .clear
        view.handlers = self
        return view
    }

    func updateUIView(_ view: Surface, context: Context) { view.handlers = self }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var handlers: FormlessScrollSafeDrag?
        private var pan: UIPanGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            addGestureRecognizer(pan)
            self.pan = pan
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            addGestureRecognizer(tap)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// 這個方法也會被外層表單的捲動手勢問到（觸控落在這個視圖上時）：控制項要接手這次拖曳時，
        /// 自己的拖曳開始、捲動不開始；否則反過來，捲動照常。和 UISlider 擋捲動的做法相同。
        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let other = gesture as? UIPanGestureRecognizer else { return true }
            let takes = controlTakes(other)
            return other === pan ? takes : !takes
        }

        private func controlTakes(_ recognizer: UIPanGestureRecognizer) -> Bool {
            guard let handlers else { return false }
            let velocity = recognizer.velocity(in: self)
            let translation = recognizer.translation(in: self)
            let location = recognizer.location(in: self)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let horizontal = abs(velocity.x) > abs(velocity.y) && abs(translation.x) >= abs(translation.y)
            if handlers.canBegin(start), horizontal || !handlers.requiresHorizontalStart { return true }
            return !horizontal && handlers.canBeginVertically(start, velocity.y > 0 || translation.y > 0)
        }

        @objc private func handleTap(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, FormlessScrollStopTap.allows() else { return }
            handlers?.onTap(tap.location(in: self))
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            let location = pan.location(in: self)
            let translation = pan.translation(in: self)
            switch pan.state {
            case .began:
                handlers?.onBegan(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
                handlers?.onChanged(location, CGSize(width: translation.x, height: translation.y))
            case .changed:
                handlers?.onChanged(location, CGSize(width: translation.x, height: translation.y))
            default:
                handlers?.onEnded()
            }
        }
    }
}

/// 顏色工具面板：和「位置與大小」同一種工具面板（下半部、不暗化、點外面關閉），
/// 裡面放 App 自己的調色盤（功能比照系統、剛好放進面板不用捲動），選的顏色即時套用到圖層。
struct EditorColorPanel: View {
    @ObservedObject var model: EditorModel
    let request: EditorColorPanelRequest
    let height: CGFloat
    var shown = true
    let onEyedropper: (@escaping (UIColor) -> Void) -> Void
    let onClose: () -> Void
    /// 打開選擇資料面板（色階的數字、取用資料的顏色）；一次只開一個面板，顏色面板會先關。
    var openData: ((EditorDataPanelRequest) -> Void)? = nil
    /// 有條件顏色時調色盤改哪個顏色：nil 是平常的顏色，數字是第幾條條件。
    @State private var selectedRule: Int?
    /// 淺色、深色分開設定時，調色盤改的是深色那個值。
    @State private var darkSide = false
    /// 打開面板前畫布的預覽外觀：調淺色、深色時畫布跟著切換，關掉面板再換回來。
    @State private var appearanceBefore: FormlessPreviewAppearance?

    var body: some View {
        let rule = request.rulesLayerID.flatMap { EditorColorRuleRows.valid(selectedRule, in: model.layerBinding($0).wrappedValue) }
        EditorColorPicker(title: request.title, supportsOpacity: request.supportsOpacity,
                          selection: selection(rule), height: height, onEyedropper: onEyedropper,
                          header: header(rule), selectionKey: AnyHashable(rule.map { "rule\($0)" } ?? (darkSide ? "dark" : "base")))
            .editorToolPanel(height: height, active: shown, onClose: onClose)
            // 面板開著時，畫布上的這個圖層顯示選中的那個顏色（條件現在不成立也一樣），看得到自己在調什麼。
            .onAppear {
                preview()
                appearanceBefore = model.previewAppearance
                if isDual { showSideOnCanvas() }
            }
            .onChange(of: selectedRule) { _, _ in preview() }
            .onChange(of: darkSide) { _, _ in showSideOnCanvas() }
            .onDisappear {
                if let id = request.rulesLayerID, model.colorPreview?.layerID == id { model.colorPreview = nil }
                if let appearanceBefore, model.previewAppearance != appearanceBefore { model.previewAppearance = appearanceBefore }
            }
    }

    /// 這個面板調的那個顏色欄位（淺色、深色兩個值都在裡面）。
    private var baseHex: Binding<String?> {
        request.backgroundOfDocument
            ? model.designBinding.backgroundColorHex
            : model.layerBinding(request.layerID)[dynamicMember: request.keyPath]
    }

    private var isDual: Bool { FormlessDualColor.split(baseHex.wrappedValue) != nil }

    /// 調淺色時畫布用淺色外觀、調深色時用深色外觀，看得到正在調的那一個。
    private func showSideOnCanvas() {
        let next: FormlessPreviewAppearance = darkSide ? .dark : .light
        if model.previewAppearance != next { model.previewAppearance = next }
    }

    private func selection(_ rule: Int?) -> Binding<Color> {
        guard request.rulesLayerID == nil || rule == nil else {
            return EditorColorRuleRows.colorBinding(model.layerBinding(request.rulesLayerID!), rule!)
        }
        let base = baseHex, fallback = request.fallback, dark = darkSide
        guard isDual else { return hexColorBinding(base, fallback: fallback) }
        return Binding(
            get: {
                let pair = FormlessDualColor.split(base.wrappedValue)
                return Color(formlessHex: dark ? pair?.dark : pair?.light, fallback: fallback)
            },
            set: { color in
                let pair = FormlessDualColor.split(base.wrappedValue) ?? (fallback, fallback)
                base.wrappedValue = dark
                    ? FormlessDualColor.join(light: pair.light, dark: color.formlessHex)
                    : FormlessDualColor.join(light: color.formlessHex, dark: pair.dark)
            })
    }

    /// 「淺色、深色分開設定」：打開時兩個值先一樣，再分別調；關掉時留下淺色那個值。
    private var dualBinding: Binding<Bool> {
        let base = baseHex, fallback = request.fallback
        return Binding(
            get: { FormlessDualColor.split(base.wrappedValue) != nil },
            set: { on in
                let current = FormlessDualColor.light(base.wrappedValue) ?? fallback
                base.wrappedValue = on ? FormlessDualColor.join(light: current, dark: current) : current
                darkSide = false
                if on { showSideOnCanvas() } else if let appearanceBefore { model.previewAppearance = appearanceBefore }
            })
    }

    private func header(_ rule: Int?) -> AnyView? {
        let automatic = request.automatic
            ? Toggle("跟隨資料顏色", isOn: editorAutomaticColorBinding(model.layerBinding(request.layerID))) : nil
        let usesData = request.automatic && model.layerBinding(request.layerID).wrappedValue.editorUsesAutomaticColor
        // 淺色與深色：調的是平常的顏色時才有（條件顏色與跟隨資料顏色各自只有一個值）。
        let dual = rule == nil && !usesData ? AnyView(EditorDualColorRow(isOn: dualBinding, darkSide: $darkSide)) : nil
        guard let id = request.rulesLayerID else {
            if automatic == nil && dual == nil { return nil }
            return AnyView(VStack(spacing: 16) { automatic; dual })
        }
        return AnyView(VStack(spacing: 16) {
            automatic
            EditorColorRuleRows(layer: model.layerBinding(id), selected: $selectedRule, fallback: request.rulesFallback,
                                dataSources: EditorRuleSource.all(model), live: model.live, openData: openData)
            dual
        })
    }

    /// 只在圖層有條件顏色時才預覽，而且值變了才寫：改 model 會讓整個編輯器重畫，打開面板的那一格不能多這一次。
    private func preview() {
        guard let id = request.rulesLayerID else { return }
        let layer = model.layerBinding(id).wrappedValue
        let next = (layer.colorRules ?? []).isEmpty && layer.colorScale == nil ? nil
            : EditorColorPreview(layerID: id, rule: EditorColorRuleRows.valid(selectedRule, in: layer))
        if model.colorPreview != next { model.colorPreview = next }
    }
}

/// 把系統調色盤（UIColorPickerViewController）放進工具面板裡；邊選邊寫回綁定。
struct EditorSystemColorPicker: UIViewControllerRepresentable {
    let selection: Binding<Color>
    let supportsAlpha: Bool
    let title: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = supportsAlpha
        picker.selectedColor = UIColor(selection.wrappedValue)
        picker.title = title
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: EditorSystemColorPicker
        init(_ parent: EditorSystemColorPicker) { self.parent = parent }
        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor,
                                       continuously: Bool) {
            parent.selection.wrappedValue = Color(uiColor: color)
        }
        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.onFinish()
        }
    }
}

/// 選取工具列占用畫布縮出的空間；清單以 List 的 onMove 整列拖曳排序。
struct PickingLayerToolbar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession

    var body: some View {
        toolbar
            // 位置與大小開著時暫時隱藏這排按鈕，兩個層級的按鈕同時出現會讓人不知道該按哪個。
            // 只隱藏不移除，畫布高度不會跳動；關閉面板後恢復。
            .modifier(HiddenWhilePositionPanel(panels: session.toolPanels))
    }

    /// 只有這一層觀察面板狀態：開關面板時工具列的按鈕不必重畫。
    private struct HiddenWhilePositionPanel: ViewModifier {
        @ObservedObject var panels: EditorToolPanelState
        func body(content: Content) -> some View {
            content
                .opacity(panels.positionOpen ? 0 : 1)
                .allowsHitTesting(!panels.positionOpen)
                .animation(FormlessDesign.Motion.fade, value: panels.positionOpen)
        }
    }

    private var canGroup: Bool {
        model.document.layers.contains { session.picked.contains($0.id) && !$0.group }
    }

    private func exit() { session.exitPicking() }
    /// 刪除鍵按下後、等待確認中。
    @State private var confirmingDelete = false

    /// 選取的圖層（含群組成員）是否全部顯示中／全部鎖定：兩顆切換鍵的圖示顯示目前狀態，點一下切到另一個狀態。
    private var pickedLayers: [FormlessLayer] {
        let members = model.expandedIDs(session.picked)
        return model.document.layers.filter { members.contains($0.id) }
    }
    private var allVisible: Bool { !pickedLayers.isEmpty && pickedLayers.allSatisfy(\.visible) }
    private var allLocked: Bool { !pickedLayers.isEmpty && pickedLayers.allSatisfy(\.locked) }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Button {
                session.exitPicking { model.cancelPicking() }
            } label: { control("xmark", width: FormlessDesign.Size.glassButton).formlessGlass(.regular.interactive(), in: .circle) }
                .accessibilityLabel("取消選取操作")
            Spacer(minLength: 0)
            // 左右各一顆獨立的圓鍵（✕ 取消、✓ 完成），中間的功能合成一條玻璃長條、置中（使用者要求）。
            centerBar
            Spacer(minLength: 0)
            Button(action: exit) { control("checkmark", width: FormlessDesign.Size.glassButton).formlessGlass(.regular.interactive(), in: .circle) }
                .accessibilityLabel("完成")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FormlessDesign.Space.edge)
        .onChange(of: session.picked) { _, picked in if picked.isEmpty { setConfirmingDelete(false) } }
        .onChange(of: session.picking) { _, picking in if !picking { confirmingDelete = false } }
    }

    /// 玻璃伸縮的彈簧：和系統 Liquid Glass 元件變形同一種帶一點回彈的動畫。
    private static let glassMorph: Animation = .bouncy(duration: 0.4, extraBounce: 0.05)
    private static let contentOut: Animation = .easeOut(duration: 0.08)
    private static let contentIn: Animation = .easeOut(duration: 0.2).delay(0.07)
    private func setConfirmingDelete(_ value: Bool) {
        guard confirmingDelete != value else { return }
        withAnimation(Self.glassMorph) { confirmingDelete = value }
    }
    /// 「刪除 N 個圖層」的自然寬度（含左右留白），玻璃長條確認時伸縮到這個寬度。
    @State private var confirmWidth: CGFloat = 200
    /// 功能長條的寬度：五顆鍵各 46 pt。
    private static let barWidth: CGFloat = 46 * 5

    /// 中間的玻璃長條。刪除要再確認一次：按垃圾桶後，同一塊玻璃以彈簧伸縮成「🗑 刪除 N 個圖層」的寬度，
    /// 圖示與文字交叉淡入淡出；位置在工具列正中間、內容置中。點它才刪除，點其他任何地方就縮回功能長條
    /// （擋板視窗接住，底下不動作）。系統選單的項目固定靠左、選單位置跟著按鈕走（使用者指出不置中）；
    /// 確認對話框是帶箭頭的泡泡；兩塊玻璃互換的 glassEffectID 變形在這裡不會動畫（實測直接跳過），所以用同一塊玻璃伸縮。
    /// 刪除後留在選取模式、只清掉已經不存在的勾選，可以接著選別的圖層（使用者指正：刪除不該順便結束選取）。
    private var centerBar: some View {
        ZStack {
            // 內容不交疊：要離開的先在 0.1 秒內淡出，要出現的等它淡完才淡入（兩層同時半透明會疊成一團）。
            // 淡出時往中間縮一點，玻璃縮小時兩端的圖示不會被邊緣切到。
            functionBar
                .fixedSize()
                .scaleEffect(confirmingDelete ? 0.85 : 1)
                .opacity(confirmingDelete ? 0 : 1)
                .animation(confirmingDelete ? Self.contentOut : Self.contentIn, value: confirmingDelete)
                .allowsHitTesting(!confirmingDelete)
                .accessibilityHidden(confirmingDelete)
            Button {
                model.deleteLayers(session.picked)
                session.picked = []
            } label: {
                Label("刪除" + model.layersTitle(session.picked), systemImage: "trash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { confirmWidth = min($0, 300) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Capsule())
            }
            .scaleEffect(confirmingDelete ? 1 : 0.85)
            .opacity(confirmingDelete ? 1 : 0)
            .animation(confirmingDelete ? Self.contentIn : Self.contentOut, value: confirmingDelete)
            .allowsHitTesting(confirmingDelete)
            .accessibilityHidden(!confirmingDelete)
        }
        .frame(width: confirmingDelete ? confirmWidth : Self.barWidth, height: 44)
        .clipShape(Capsule())
        .formlessGlass(.regular.interactive(), in: .capsule)
        .background(FormlessPanelOutsideTap(active: confirmingDelete) { setConfirmingDelete(false) })
    }

    private var functionBar: some View {
        let hasSelection = !session.picked.isEmpty
        // 刪除放在長條最前面，離「完成」最遠，降低誤點。
        return HStack(spacing: 0) {
                Button { setConfirmingDelete(true) } label: { control("trash", enabled: hasSelection) }
                    .accessibilityLabel("刪除選取圖層")
                    .disabled(!hasSelection)
                // 群組：建立群組與移至群組合在同一顆。
                Menu {
                    Button("建立群組", systemImage: "folder.badge.plus") {
                        if let id = model.groupLayers(session.picked) {
                            session.exitPicking { session.renamingLayerID = id }
                        }
                    }
                    .disabled(!canGroup)
                    Section("移至群組") {
                        Button("移出群組", systemImage: "arrow.up.to.line") { model.moveToGroup(session.picked, parent: nil) }
                        ForEach(model.document.groups) { group in
                            Button(group.name, systemImage: "folder") { model.moveToGroup(session.picked, parent: group.id) }
                        }
                    }
                } label: { control("folder", enabled: hasSelection) }
                    .accessibilityLabel("群組")
                    .disabled(!hasSelection)
                Button { session.batchPositionOpen = true } label: {
                    control("arrow.up.and.down.and.arrow.left.and.right", enabled: hasSelection)
                }
                    .accessibilityLabel("位置與大小")
                    .disabled(!hasSelection)
                // 鎖定：鎖定與解除鎖定合在同一顆。圖示是目前狀態（全部鎖定才顯示上鎖），點一下切換；部分鎖定時點一下全部鎖定。
                Button { model.setLocked(session.picked, !allLocked) } label: {
                    control(allLocked ? "lock.fill" : "lock.open", enabled: hasSelection)
                }
                    .accessibilityLabel(allLocked ? "解除鎖定" : "鎖定圖層")
                    .disabled(!hasSelection)
                // 顯示：顯示與隱藏合在同一顆。圖示是目前狀態（和圖層列的眼睛一樣），點一下切換；部分隱藏時點一下全部顯示。
                Button { model.setVisibility(session.picked, hidden: allVisible) } label: {
                    control(allVisible || !hasSelection ? "eye" : "eye.slash", enabled: hasSelection)
                }
                    .accessibilityLabel(allVisible ? "隱藏" : "顯示")
                    .disabled(!hasSelection)
            }
    }

    /// 不能按的時候圖示明顯變淡（玻璃本身已經半透明，只靠 disabled 幾乎看不出差別，使用者會一直點）。
    /// 左右兩顆獨立的圓鍵是 44×44 的玻璃圓鈕；中間長條裡每格 46 寬。
    private func control(_ symbol: String, enabled: Bool = true, width: CGFloat = 46) -> some View {
        Image(systemName: symbol)
            .font(FormlessDesign.Symbol.glassButton)
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
            .frame(width: width, height: FormlessDesign.Size.glassButton)
            .contentShape(Rectangle())
    }
}

struct EditorListRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    /// 右邊的眼睛、「…」是 44 寬的點擊區，圖示本身比點擊區窄約 13：卡片右側只留 7，圖示看起來就離右緣約 20。
    static let trailingInset: CGFloat = 7
    let row: FormlessLayerRow
    let onSelect: () -> Void
    /// 拖曳中由清單指定的內縮（0 根層、1 群組內），用來即時預告放下後會在群組內還是外；nil 依資料。
    var indentOverride: Int? = nil
    /// 拖曳中：放手就會放進這個（收合中的）群組。標題列亮起並多一個 ＋，像 Files 拖檔案到資料夾上。
    var dropTarget = false
    private var indent: Int { indentOverride ?? row.indent }
    /// 名稱、顯示、鎖定、收合一律讀模型的即時狀態，不用 `row` 裡的快照：
    /// 列是 UIKit cell 承載的 SwiftUI 內容，重設列時快照雖然更新了，SwiftUI 內容不一定重繪（復原鎖定後標籤曾停在舊狀態）。
    private var layer: FormlessLayer { model.document.layers.first(where: { $0.id == row.id }) ?? row.layer }
    @State private var renaming = false
    @FocusState private var renameFocused: Bool
    private func toggleCollapsed() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.toggleCollapsed(row.id) }
    }
    private enum GroupPickState { case none, some, all }
    private var groupChildIDs: [UUID] { model.document.children(of: row.id).filter { !$0.group }.map(\.id) }
    private var groupPickState: GroupPickState {
        let picked = groupChildIDs.filter { session.picked.contains($0) }.count
        if picked == 0 { return .none }
        return picked == groupChildIDs.count ? .all : .some
    }
    private var groupPickSymbol: String {
        switch groupPickState {
        case .none: return "circle"
        case .some: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }
    /// 全選時取消整組，其餘情況把整組補齊。
    private func toggleGroupPick() {
        let ids = groupChildIDs
        guard !ids.isEmpty else { return }
        if groupPickState == .all {
            ids.forEach { session.picked.remove($0) }
        } else {
            ids.forEach { session.picked.insert($0) }
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            if layer.group {
                Button(action: toggleCollapsed) {
                    // 展開箭頭：footnote 半粗、灰（和 App 其他展開箭頭相同）。
                    // 群組不放類型圖示，箭頭本身就表示群組（使用者 10/04）：箭頭放在一般圖層的類型圖示那一格，
                    // 群組名稱照樣和一般圖層的名稱對齊。點擊範圍是卡片邊線到名稱之間整段。
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(layer.collapsed ? .zero : .degrees(90))
                        .contentTransition(.identity)
                        .frame(width: 22, height: 44)
                        .padding(.leading, FormlessDesign.Space.cardInset)
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .accessibilityLabel(layer.collapsed ? "展開群組" : "收合群組")
            }
            // 勾選圈用點擊手勢而不是 Button：清單是 UIScrollView，Button 的觸控會被「先等一下判斷是不是要捲動」延後約 0.15 秒
            // 才送到，勾勾填滿看起來比點名稱慢一拍（使用者回報）；手勢辨識器不受這個延遲影響，和點名稱一樣快。
            if session.picking && !layer.group {
                let picked = session.picked.contains(row.id)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if picked { session.picked.remove(row.id) } else { session.picked.insert(row.id) }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(picked ? "取消選取" : "選取")
            }
            // 群組列的三態勾選圈：一次選取／取消整組的子圖層。群組本身仍不是選取對象，選的是裡面的圖層。
            if session.picking && layer.group {
                Image(systemName: groupPickSymbol)
                    .foregroundStyle(groupChildIDs.isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleGroupPick() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(groupPickState == .all ? "取消選取整組" : "選取整組")
            }
            if renaming {
                TextField("名稱", text: model.layerBinding(row.id).name)
                    .focused($renameFocused).submitLabel(.done)
                    .formlessInputBox()
                    .frame(minHeight: 44)
                    .padding(.trailing, 8)
                    .onSubmit { finishRenaming() }
            } else if session.picking {
                // 選取模式：整條列都交給長按拖曳排序，名稱上只接單擊（不能掛長按手勢，
                // 否則按在名稱上就拖不動）。點名稱＝切換選取；群組列是整組切換，展開收合只留給左邊的箭頭。
                titleLabel
                    .onTapGesture {
                        if layer.group {
                            toggleGroupPick()
                        } else if session.picked.contains(row.id) {
                            session.picked.remove(row.id)
                        } else {
                            session.picked.insert(row.id)
                        }
                    }
            } else {
                titleLabel
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.30, maximumDistance: 10)
                            .exclusively(before: SpatialTapGesture())
                            .onEnded { result in
                                switch result {
                                case .first(true):
                                    // 長按只是進入選取模式，不代表按住的那一列就是要選的對象；要選什麼進模式後再點。
                                    session.picking = true
                                    FormlessHaptics.light()
                                case .second(let tap):
                                    onSelect()
                                default: break
                                }
                            }
                    )
            }
            if session.picking {
                // 選取模式沒有眼睛與「…」鍵，改在同樣的兩個位置標示狀態（只有隱藏、鎖定時才出現），
                // 選取時看得出哪些圖層是隱藏或鎖定的（使用者要求）。只是標示，不接觸控，長按拖曳排序照常。
                Group {
                    Image(systemName: "eye.slash")
                        .frame(width: 44, height: 44)
                        .opacity(layer.visible ? 0 : 1)
                    Image(systemName: "lock.fill")
                        .frame(width: 44, height: 44)
                        .opacity(layer.locked ? 1 : 0)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if !session.picking {
                // 眼睛與「…」用灰色（10/03 決定）：八個藍色圖示會和作品搶注意力。用固定的灰（secondaryLabel），
                // 階層式的 .secondary 在有主色的按鈕裡會變成淡藍。
                Button { model.toggleHidden(row.id) } label: {
                    Image(systemName: layer.visible ? "eye" : "eye.slash")
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel(layer.visible ? "隱藏" : "顯示")
                Menu {
                    Button("重新命名", systemImage: "pencil") { beginRenaming() }
                    EditorLayerActions(model: model, layer: layer)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(layer.group ? "群組操作" : "圖層操作")
            }
        }
        .buttonStyle(.borderless)
        // 卡片內：文字離左緣 20（和系統表單列相同）；右邊是 44 寬的圖示鍵，圖示本身離右緣約 20，左右看起來等距。
        // 群組列的箭頭就佔這 20，群組名稱才和一般圖層的名稱對齊。
        .padding(.leading, layer.group ? 0 : FormlessDesign.Space.cardInset)
        .padding(.trailing, Self.trailingInset)
        .background(
            model.selectedLayerID == row.id || dropTarget
                ? FormlessDesign.Palette.selectionFill
                : (layer.group ? FormlessDesign.Palette.groupCard : FormlessDesign.Palette.card),
            in: RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous)
        )
        .animation(FormlessDesign.Motion.fade, value: dropTarget)
        // 卡片離螢幕邊 20（全 App 的邊線）；子圖層的卡片左緣再內縮一個箭頭寬（44），文字才和群組名稱對齊。
        .padding(.leading, indent > 0 ? FormlessDesign.Space.edge + 44 : FormlessDesign.Space.edge)
        .padding(.trailing, FormlessDesign.Space.edge)
        // 拖曳中進出群組時卡片縮短／變長，讓人清楚現在會落在群組內還是外。
        .animation(FormlessDesign.Motion.fade, value: indent)
        .accessibilityAction(named: "進入選取模式") {
            session.picking = true
        }
        .accessibilityAction(named: "刪除圖層") { model.deleteLayers([row.id]) }
        .accessibilityValue(model.selectedLayerID == row.id ? "已選取" : "")
        .onAppear {
            if session.renamingLayerID == row.id { beginRenaming() }
        }
        .onChange(of: session.renamingLayerID) { _, id in
            if id == row.id { beginRenaming() }
        }
        .onChange(of: renameFocused) { _, focused in
            if !focused && renaming { finishRenaming() }
        }
    }

    private var titleLabel: some View {
        HStack(spacing: 8) {
            // 類型圖示（灰色）：一眼看出是文字、圖片還是色塊。群組沒有，它的箭頭就在同一格（使用者 10/04）。
            if !layer.group {
                Image(systemName: layer.type.pickerSymbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(width: 22)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .accessibilityHidden(true)
            }
            Text(layer.name).lineLimit(1)
                .fontWeight(layer.group ? .semibold : .regular)
                // 隱藏的圖層名稱變淡（和劃線的眼睛一起表示隱藏）。
                .opacity(layer.visible ? 1 : 0.4)
            if layer.group {
                Text("\(model.document.children(of: row.id).count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if dropTarget {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if layer.locked && !session.picking {
                Text("已鎖定").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .accessibilityIdentifier("layer-title-" + row.id.uuidString)
    }

    private func beginRenaming() {
        renaming = true
        // 從選單叫出時先等選單收起，否則第一個 focus 請求會被選單吃掉。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if renaming { renameFocused = true }
        }
    }

    private func finishRenaming() {
        renaming = false
        renameFocused = false
        if session.renamingLayerID == row.id { session.renamingLayerID = nil }
    }
}

struct EditorLayerActions: View {
    @ObservedObject var model: EditorModel
    let layer: FormlessLayer
    var body: some View {
        Button(layer.locked ? "解除鎖定" : "鎖定圖層",
               systemImage: layer.locked ? "lock.open" : "lock") { model.toggleLocked(layer.id) }
        Button(model.isolatedLayerID == layer.id ? "顯示全部" : "單獨預覽",
               systemImage: model.isolatedLayerID == layer.id ? "eye" : "eye.square") {
            model.isolatedLayerID = model.isolatedLayerID == layer.id ? nil : layer.id
        }
        Button("複製至剪貼簿", systemImage: "doc.on.clipboard") { model.copyLayer(layer.id) }
        if !layer.group {
            Button("製作副本", systemImage: "plus.square.on.square") { model.duplicateLayer(layer.id) }
            Menu("移至群組", systemImage: "folder") {
                Button("移出群組", systemImage: "arrow.up.to.line") { model.moveToGroup([layer.id], parent: nil) }
                ForEach(model.document.groups) { group in
                    Button(group.name, systemImage: "folder") { model.moveToGroup([layer.id], parent: group.id) }
                }
            }
        } else {
            Button("解散群組", systemImage: "square.stack.3d.up") {
                model.deleteGroup(layer.id)
            }
        }
        // 拷貝／貼上樣式，群組是「儲存為我的組合」（2026-10）。
        EditorReuseLayerActions(model: model, layer: layer)
    }
}


// MARK: - 設計設定

/// 小工具設定：只放不會立刻反映在畫布上的設定。底色與背景圖片在小工具本身的屬性面板（點畫布空白處或右上角選單）。
struct DesignTab: View {

    @ObservedObject var model: EditorModel
    /// 和「設定 › 編輯器」同一個開關（所有小工具共用），編輯時不必離開編輯器就能切換（2026-10-05）。
    @AppStorage("formless.canvasLocked") private var canvasLocked = false
    /// 小工具的記憶體估算（2026-10）：超過才顯示警告。
    @State private var memory: FormlessMemoryEstimate?

    var body: some View {
        Form {
            if let memory, memory.level != .ok {
                memoryWarning(memory)
            }
            // 卡片不放標題（使用者規則：全 App 的卡片上方都不放標題）。
            Section {
                // 左名稱、右輸入（和屬性面板的文字欄位同一種），只靠提示字的話一打字就看不出這格是什麼。
                EditorTextRow(title: "名稱", text: model.designBinding.name)

                Picker("尺寸", selection: model.designBinding.family) {
                    FormlessFamilyOptions()
                }
            }

            // 編輯時常用：緊接在名稱與尺寸之後（使用者：相對重要，不放最下面）。
            Section {
                Toggle("鎖定畫布", isOn: $canvasLocked)
            } footer: {
                Text("鎖定後，不能上下拖曳改變畫布高度。")
            }

            // 這份設計用到的資料與我的資料（2026-10 通用化），整份設計的字型與顏色。
            Section {
                EditorDesignDataRows(model: model)
                EditorDesignStyleRow(model: model)
                EditorVersionHistoryRow(model: model)
            }

            Section {
                // 開啟網址時要開的網址是點擊動作的細項：同一列（`EditorFunctionRow`）。
                EditorFunctionRow {
                    Picker("點一下小工具", selection: tapActionBinding) {
                        ForEach(FormlessTapAction.allCases) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .editorLine(.menu)
                    if model.document.effectiveTapAction == .openURL {
                        EditorTextRow(title: "網址", placeholder: "https://", text: optionalString(model.designBinding.tapURL), url: true)
                            .editorLine(.text)
                    }
                }
            }

            // 每個小工具都有這一列；沒用到行程或提醒資料時停用。
            Section {
                let needs = FormlessLiveData.needs(of: model.document)
                Toggle("保留今天已過的行程與提醒", isOn: Binding(
                    get: { model.document.showsPastItems ?? false },
                    set: { model.designBinding.wrappedValue.showsPastItems = $0 ? true : nil }
                ))
                .disabled(!(needs.events || needs.reminders))
            }

            Section {
                Picker("自動更新", selection: refreshBinding) {
                    Text("5 分鐘").tag(5)
                    Text("15 分鐘（建議）").tag(15)
                    Text("30 分鐘").tag(30)
                    Text("1 小時").tag(60)
                    Text("2 小時").tag(120)
                    Text("4 小時").tag(240)
                }
            } footer: {
                Text("實際更新時間由系統依電量與使用情況安排。")
            }
        }
        // 讀圖片檔頭、算用量放在背景；設計改了才重算。
        .task(id: model.documentRevision) {
            let snapshot = model.document
            memory = await Task.detached(priority: .utility) { FormlessMemoryEstimate.estimate(snapshot) }.value
        }
    }

    /// 圖片太大時的警告：小工具的記憶體上限約 30 MB，超過就整個空白。列出占用最多的圖層。
    private func memoryWarning(_ estimate: FormlessMemoryEstimate) -> some View {
        let megabytes = { (bytes: Int) in String(format: "%.0f MB", Double(bytes) / Double(FormlessMemoryEstimate.megabyte)) }
        return Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(estimate.level == .tooHigh ? "圖片太大，小工具可能無法顯示" : "圖片偏大，小工具可能無法顯示")
                    Text("估計用量 \(megabytes(estimate.totalBytes))，上限約 \(megabytes(FormlessMemoryEstimate.limitBytes))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ForEach(estimate.items.prefix(3)) { item in
                LabeledContent(item.name, value: megabytes(item.bytes))
            }
        }
    }

    private var tapActionBinding: Binding<FormlessTapAction> {
        Binding(
            get: { model.document.effectiveTapAction },
            set: { model.designBinding.wrappedValue.tapAction = $0 }
        )
    }

    private var refreshBinding: Binding<Int> {
        Binding(
            get: { model.document.effectiveRefreshMinutes },
            set: { model.designBinding.wrappedValue.refreshMinutes = $0 }
        )
    }

}


/// 小工具的底色面板（右上角選單或點畫布空白處）：和圖層的顏色面板同一種由下往上的工具面板，畫布和上一步都看得到。
/// 標題「底色」，上面兩個方塊「顏色」「圖片」：兩種設定都保留，方塊只是切換目前用哪一個（使用者：可以同時設定、隨心情切換）；
/// 下面的內容跟著方塊走——選「顏色」是調色盤（可調透明度），選「圖片」是目前用的圖片（點它換圖）。
/// 兩種模式用同一個面板版面（`EditorColorPicker` 的 replacement），切換時標題與方塊的位置完全不動。
struct WidgetBackgroundPanel: View {
    @ObservedObject var model: EditorModel
    let height: CGFloat
    var shown = true
    let onEyedropper: (@escaping (UIColor) -> Void) -> Void
    let onClose: () -> Void
    @State private var showLibrary = false
    /// 目前設定的背景圖片（原圖，不是縮圖：有些圖片沒有縮圖檔，方塊曾經一片空白）。
    @State private var image: UIImage?

    private var usesImage: Bool { model.document.backgroundUsesImage ?? (model.document.backgroundImageName != nil) }

    var body: some View {
        EditorColorPicker(title: "底色", supportsOpacity: true,
                          selection: hexColorBinding(model.designBinding.backgroundColorHex, fallback: "#F4F4F4"),
                          height: height, onEyedropper: onEyedropper, header: AnyView(tiles),
                          replacement: usesImage ? AnyView(imageArea) : nil)
            .editorToolPanel(height: height, active: shown, onClose: onClose)
            .task(id: model.document.backgroundImageName) {
                let name = model.document.backgroundImageName
                image = await Task.detached { name.flatMap { FormlessAssetCache.shared.image(named: $0) } }.value
            }
            .sheet(isPresented: $showLibrary) {
                ImageLibraryView(current: model.document.backgroundImageName) { name in
                    var document = model.designBinding.wrappedValue
                    document.backgroundImageName = name
                    document.backgroundUsesImage = name != nil
                    model.designBinding.wrappedValue = document
                }
                .formlessSheetBackground()
            }
    }

    /// 「圖片」模式下面的內容：目前用的圖片，點它換圖；還沒有圖片就顯示圖片庫的圖示。
    private var imageArea: some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous)
        return Button { showLibrary = true } label: {
            ZStack {
                shape.fill(FormlessDesign.Palette.card)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(FormlessDesign.Space.panel)
                } else {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("換圖片")
    }

    private var tiles: some View {
        HStack(spacing: 12) {
            Button { setUsesImage(false) } label: {
                EditorAppearanceTileLabel(caption: "顏色", selected: !usesImage) { colorPreview }
            }
            .buttonStyle(EditorTileButtonStyle())
            .accessibilityLabel("顏色")
            .accessibilityAddTraits(usesImage ? [] : .isSelected)
            Button {
                setUsesImage(true)
                if model.document.backgroundImageName == nil { showLibrary = true }
            } label: {
                EditorAppearanceTileLabel(caption: "圖片", selected: usesImage) { imagePreview }
            }
            .buttonStyle(EditorTileButtonStyle())
            .accessibilityLabel("圖片")
            .accessibilityAddTraits(usesImage ? .isSelected : [])
        }
    }

    /// 切換目前用的是哪一個；另一個的設定留著。
    private func setUsesImage(_ value: Bool) {
        guard usesImage != value else { return }
        model.designBinding.wrappedValue.backgroundUsesImage = value
    }

    /// 和外觀方塊的色票相同：棋盤格上畫目前的底色（看得出透明度）。
    private var colorPreview: some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        return ZStack {
            EditorCheckerboard()
            Color(formlessHex: model.document.backgroundColorHex, fallback: "#F4F4F4")
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline))
    }

    /// 方塊只放示意圖示：方塊太小放不下圖片，圖片本身顯示在下面（使用者要求）。
    private var imagePreview: some View {
        Image(systemName: "photo").font(.system(size: 22, weight: .regular)).foregroundStyle(.secondary)
    }
}

// MARK: - 圖層屬性

/// 「點一下圖層」：圖層自己的點擊動作，蓋過「點一下小工具」。開啟網址時的網址是細項，同一列（`EditorFunctionRow`）。
struct EditorTapActionRow: View {
    @Binding var layer: FormlessLayer
    var variables: [FormlessVariable] = []
    var live = FormlessLiveData()
    @Environment(\.editorDataPanelOpener) private var openData
    @Environment(\.editorFormatPanelOpener) private var openFormat

    var body: some View {
        // 動作的參數（網址、捷徑名稱、我的資料、加減多少）是動作的細項：同一列。
        EditorFunctionRow {
            Picker("點一下圖層", selection: Binding(
                get: { layer.effectiveTapAction },
                set: { layer.setTapAction($0) }
            )) {
                Text("跟隨小工具").tag(FormlessLayerTapAction?.none)
                ForEach(FormlessLayerTapAction.allCases) { action in
                    Text(action.displayName).tag(Optional(action))
                }
            }
            .editorLine(.menu)
            switch layer.effectiveTapAction {
            case .openURL?:
                if let binding = layer.bindings?[FormlessBindableProperty.url.rawValue] {
                    HStack {
                        Text("網址")
                        Spacer(minLength: 12)
                        Button { openFormat?(EditorFormatPanelRequest(layerID: layer.id, slot: .url)) } label: {
                            let label = EditorDataLabels.label(for: binding, live: live)
                            EditorDataCapsule(symbol: label.symbol, title: label.title)
                        }
                        .buttonStyle(.plain)
                    }
                    .editorLine(.control)
                } else {
                    EditorTextRow(title: "網址", placeholder: "https://", text: optionalString($layer.actionURL), url: true)
                        .editorLine(.text)
                    Button {
                        openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.url), kinds: [.text]))
                    } label: {
                        Label("網址取用資料", systemImage: "link").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .editorLine(.text)
                }
            case .runShortcut?:
                EditorTextRow(title: "捷徑名稱", placeholder: "捷徑 App 裡的名稱", text: optionalString($layer.tapTarget))
                    .editorLine(.text)
            case .toggleVariable?, .adjustVariable?:
                let toggling = layer.effectiveTapAction == .toggleVariable
                let usable = variables.filter { toggling ? $0.kind == .bool : $0.kind == .number }
                Picker("我的資料", selection: Binding(get: { layer.tapTarget ?? "" }, set: { layer.tapTarget = $0.isEmpty ? nil : $0 })) {
                    Text(usable.isEmpty ? (toggling ? "沒有是非的我的資料" : "沒有數字的我的資料") : "請選擇").tag("")
                    ForEach(usable) { Text($0.name).tag($0.id.uuidString) }
                }
                .editorLine(.menu)
                if !toggling {
                    EditorStepperRow(title: "每次加", value: Binding(get: { layer.tapAmount ?? 1 }, set: { layer.tapAmount = $0 }),
                                     range: -10_000...10_000, step: 1)
                        .editorLine(.stepper)
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - 群組屬性

struct LayerInspector: View {
    @Binding var layer: FormlessLayer
    let family: FormlessWidgetFamily
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    @State private var showLibrary = false
    /// 圖片庫選好的圖片加進相簿輪播（不是換掉原本那張）。
    @State private var addingSlide = false
    @State private var selectedPart = ""
    @State private var assetTitle = "未選擇"
    @State private var dateSamples: [String: String] = [:]
    /// 「內容」的主要輸入欄位（文字、圖片網址）：剛新增的圖層直接叫出鍵盤。
    @FocusState private var contentInputFocused: Bool
    /// 文字（可以夾資料膠囊的輸入框）：剛新增的文字圖層叫出鍵盤並全選。
    @State private var textFocusRequest = false
    @AppStorage("formless.nudgeStep") private var nudgeStep: Double = 10

    /// 由外層的原生分頁列決定要顯示哪一類。
    let category: String

    var body: some View {
        Group {
              Form {
                switch category {
                case "版面":
                    EditorGeometryControls(model: model, ids: [layer.id], session: session)
                    partSection
                case "外觀":
                    EditorAppearanceSection(layer: $layer, family: family)
                case "內容":
                    contentSection
                    if layer.type != .liveText { EditorVisibilitySection(layer: $layer, live: model.live) }
                    componentSection
                default:
                    Section {
                        EditorTextRow(title: "名稱", text: $layer.name)
                        LabeledContent("種類", value: layer.type.editorCategoryName)
                    }
                    Section {
                        EditorTapActionRow(layer: $layer, variables: model.document.variables ?? [],
                                           live: model.document.itemContext(for: layer, live: model.live, date: Date()))
                    } footer: {
                        if !tapFooter.isEmpty { Text(tapFooter) }
                    }
                }
            }
              .background(EditorScrollMemory(session: session, key: layer.id.uuidString + ":" + category))
              .scrollDismissesKeyboard(.interactively)
              // 屬性面板所有區塊都不放標題，頂端統一補上標題原本自帶的留白（分類下緣到第一張卡片）。
              .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: EditorPanelUnderlap.formHeadlessHeight) }
              .scrollEdgeEffectHidden(true, for: .top)
              .contentMargins(.top, 0, for: .scrollContent)
              // 表單不畫自己的底色、延伸到螢幕底部並關掉底部邊緣效果，
              // 拉動內容時不會在安全區交界露出一條橫線；底部留白讓最後幾列能捲出分頁上方。
              .scrollContentBackground(.hidden)
              .scrollEdgeEffectHidden(true, for: .bottom)
              .ignoresSafeArea(edges: .bottom)
              .contentMargins(.bottom, EditorPanelUnderlap.formBottom + FormlessSafeArea.bottom, for: .scrollContent)
        }
        .formlessTapToDismissKeyboard()
        // 一次只開一個面板：開顏色時收起細項面板，反之亦然。
        .environment(\.editorColorPanelOpener) { request in
            session.toolPanels.closeInspectorPanels()
            session.toolPanels.color = request
        }
        .environment(\.editorStylePanelOpener) { [id = layer.id] kind in
            session.toolPanels.closeInspectorPanels()
            session.toolPanels.style = EditorStylePanelRequest(layerID: id, kind: kind)
        }
        .environment(\.editorDataPanelOpener) { request in
            session.toolPanels.closeInspectorPanels()
            session.toolPanels.data = request
        }
        .environment(\.editorFormatPanelOpener) { request in
            session.toolPanels.closeInspectorPanels()
            session.toolPanels.format = request
        }
        .sheet(isPresented: $showLibrary, onDismiss: { addingSlide = false }) {
            ImageLibraryView(current: addingSlide ? nil : layer.value) { name in
                if addingSlide {
                    if let name { layer.imageSet = (layer.imageSet ?? []) + [name] }
                    addingSlide = false
                    return
                }
                if layer.type == .bundleImage { layer.type = .image }
                layer.value = name
                Task { await fitFrameToImage(named: name) }
            }
            .formlessSheetBackground()
        }
        // 剛新增的圖層：等新增圖層的面板收完、屬性面板滑進來後，圖片打開圖片庫、文字與網路圖片叫出鍵盤。
        .task {
            guard category == "內容" else { return }
            if session.pendingImagePick == layer.id {
                session.pendingImagePick = nil
                try? await Task.sleep(for: .seconds(FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)))
                guard !Task.isCancelled else { return }
                showLibrary = true
            } else if session.pendingSymbolPick == layer.id {
                session.pendingSymbolPick = nil
                try? await Task.sleep(for: .seconds(FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)))
                guard !Task.isCancelled else { return }
                openSymbolPanel()
            } else if session.pendingDataPick == layer.id {
                session.pendingDataPick = nil
                try? await Task.sleep(for: .seconds(FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)))
                guard !Task.isCancelled else { return }
                // 即時文字：先放了一段資料，一加入就挑要哪一份（換掉那一段）。
                session.toolPanels.closeInspectorPanels()
                session.toolPanels.data = EditorDataPanelRequest(layerID: layer.id, target: .slot(.segment(0)))
            } else if session.pendingInputFocus == layer.id {
                session.pendingInputFocus = nil
                try? await Task.sleep(for: .seconds(FormlessDesign.Motion.after(FormlessDesign.Motion.panelDuration)))
                guard !Task.isCancelled else { return }
                // 預設的「文字」、「https://」先反白，一打字就取代。
                if layer.type == .text {
                    textFocusRequest = true
                } else {
                    EditorSelectAllOnFocus.arm()
                    contentInputFocused = true
                }
            }
        }
        .task(id: layer.value) {
            let name = layer.value
            assetTitle = await Task.detached { FormlessAssetLibrary.item(named: name)?.title ?? "未選擇" }.value
            dateSamples = await Task.detached {
                Dictionary(uniqueKeysWithValues: formlessDateFormatSamples.map { ($0.id, formlessFormatted($0.id, date: Date())) })
            }.value
        }
    }

    private var tapFooter: String {
        switch layer.effectiveTapAction {
        case .refresh?, .toggleVariable?, .adjustVariable?: return "在小工具上按了直接執行，不打開 App。"
        case .completeReminder?: return "放在重複排列的提醒事項群組裡：點哪一筆就完成哪一筆，不打開 App。"
        case .runShortcut?: return "會先打開 Formless，再交給捷徑 App 執行。"
        default: return ""
        }
    }

    /// 一次只開一個面板：開圖示面板時收起顏色與細項面板。
    private func openSymbolPanel() {
        session.toolPanels.closeInspectorPanels()
        session.toolPanels.symbol = layer.id
    }

    /// 圖片在圖層框裡等比例縮放，框和圖比例不同就會留下按不到的空白。
    /// 選圖時把框調成圖片的比例，寬度不變、只改高度。
    private func fitFrameToImage(named name: String?) async {
        let loaded = await Task.detached { FormlessAssetLibrary.item(named: name) }.value
        guard let item = loaded,
              item.width > 0, item.height > 0 else { return }

        let aspect = Double(family.aspectRatio)
        let wanted = layer.frame.width * aspect * Double(item.height) / Double(item.width)

        guard wanted.isFinite, wanted > 0, layer.value == name else { return }
        var frame = layer.frame
        if wanted > 1 {
            frame.width *= 1 / wanted
            frame.height = 1
        } else {
            frame.height = wanted
        }
        model.setGeometry([layer.id], frame: frame)
    }

    private var timeStyleBinding: Binding<String> {
        Binding(
            get: {
                let raw = layer.value ?? FormlessTimeStyle.auto.rawValue
                return FormlessTimeStyle(rawValue: raw) != nil ? raw : "custom"
            },
            set: { newValue in
                if newValue == "custom" {
                    if FormlessTimeStyle(rawValue: layer.value ?? "") != nil || layer.value == nil {
                        layer.value = "HH:mm"
                    }
                } else {
                    layer.value = newValue
                }
            }
        )
    }

    // MARK: 內容

    private var displayConditionSection: some View {
        Section {
            Picker("何時顯示", selection: Binding(
                get: { layer.dataIndex ?? "" },
                set: { layer.dataIndex = $0.isEmpty ? nil : $0 }
            )) {
                Text("永遠顯示").tag("")
                Section("行程") {
                    Text("沒有行程時").tag("event0")
                    ForEach(1...5, id: \.self) { index in
                        Text("第 \(index) 筆行程存在時").tag("event\(index)")
                    }
                }
                Section("提醒事項") {
                    Text("沒有提醒事項時").tag("reminder0")
                    ForEach(1...3, id: \.self) { index in
                        Text("第 \(index) 筆提醒事項存在時").tag("reminder\(index)")
                    }
                }
                Section("天氣預報") {
                    Text("沒有預報時").tag("forecast0")
                    ForEach(1...5, id: \.self) { index in
                        Text("第 \(index) 天預報存在時").tag("forecast\(index)")
                    }
                }
            }
        }
    }

    /// 圖片列：右邊是目前那張圖的縮圖和「>」，看得出點了可以換圖（原本只有「圖片 17」灰字，像是資訊，使用者 10/04）。
    private var imagePickerRow: some View {
        let side = FormlessDesign.Size.compactControl
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        return HStack {
            Text("圖片").foregroundStyle(.primary)
            Spacer(minLength: 12)
            if let name = layer.value, !name.isEmpty {
                Group {
                    if layer.type == .bundleImage {
                        if let image = UIImage(named: name) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.2)
                        }
                    } else {
                        FormlessLoadedAsset(name: name, drawnSize: CGSize(width: side, height: side), fill: true) { image in
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                    }
                }
                .frame(width: side, height: side)
                .clipShape(shape)
            } else {
                Text("選擇圖片").foregroundStyle(.secondary)
            }
            FormlessDisclosureIndicator()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("圖片")
        .accessibilityValue(assetTitle)
        .accessibilityHint("點兩下更換圖片")
    }

    /// 相簿輪播（2026-10）：原本那張之後再加幾張，依時間輪流顯示。
    @ViewBuilder private var slideshowSection: some View {
        let extra = layer.imageSet ?? []
        Section {
            ForEach(Array(extra.enumerated()), id: \.offset) { index, name in
                HStack(spacing: FormlessDesign.Space.loose) {
                    FormlessLoadedAsset(name: name, drawnSize: CGSize(width: 36, height: 36), fill: true) { image in
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous))
                    Text("第 \(index + 2) 張")
                    Spacer(minLength: 0)
                }
                .swipeActions {
                    Button("移除", role: .destructive) {
                        var next = extra
                        guard next.indices.contains(index) else { return }
                        next.remove(at: index)
                        layer.imageSet = next.isEmpty ? nil : next
                    }
                }
            }
            Button {
                addingSlide = true
                showLibrary = true
            } label: {
                Label("加入輪播照片", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if !extra.isEmpty {
                Picker("每張顯示", selection: Binding(get: { layer.imageInterval ?? 60 },
                                                    set: { layer.imageInterval = $0 == 60 ? nil : $0 })) {
                    Text("15 分鐘").tag(15)
                    Text("30 分鐘").tag(30)
                    Text("1 小時").tag(60)
                    Text("3 小時").tag(180)
                    Text("每天").tag(1440)
                }
            }
        }
    }

    /// 主畫面選「透明」或「染色」時，照片預設跟系統一起去色；打開就維持原本的顏色（適合專輯封面這類代表內容的圖）。
    private var keepsFullColorToggle: some View {
        Toggle("透明與染色時保留原色", isOn: Binding(
            get: { layer.keepsFullColor == true },
            set: { layer.keepsFullColor = $0 ? true : nil }))
    }

    @ViewBuilder
    private var contentSection: some View {
        switch layer.type {

        case .text:
            EditorTextContentSection(layer: $layer, live: model.document.itemContext(for: layer, live: model.live, date: Date()),
                                     focusRequest: $textFocusRequest)

        case .progress:
            EditorProgressSection(layer: $layer, live: model.live)

        case .chart:
            EditorChartSection(layer: $layer, live: model.live)

        case .clock:
            EditorClockSection(layer: $layer)

        case .time:
            Section {
                // 自訂格式的格式字串是時間樣式的細項：同一列。
                EditorFunctionRow {
                    Picker("時間樣式", selection: timeStyleBinding) {
                        ForEach(FormlessTimeStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }

                        Text("自訂格式").tag("custom")
                    }
                    .editorLine(.menu)
                    if FormlessTimeStyle(rawValue: layer.value ?? "") == nil {
                        EditorTextRow(title: "格式", placeholder: "HH:mm", text: optionalString($layer.value, fallback: "HH:mm"), plain: true)
                            .editorLine(.text)
                    }
                }
            } footer: {
                Text("計時器、倒數、相對時間由系統即時走動；時鐘約每 5 分鐘換一次，這是系統對小工具更新的限制。")
            }

        case .date:
            Section {
                // 常用格式是填進日期格式的選項：同一列。同一列裡有好幾顆按鈕，要用 borderless，
                // 否則點一下整列會把每一顆都觸發。
                EditorFunctionRow {
                    EditorTextRow(title: "日期格式", placeholder: "格式", text: optionalString($layer.value), plain: true)
                        .editorLine(.text)
                    ForEach(formlessDateFormatSamples) { sample in
                        Button {
                            layer.value = sample.id
                        } label: {
                            // 目前用的格式打勾：看得出這是一組選項，點了會換成那個格式。
                            HStack {
                                Text(sample.displayName)
                                Spacer()
                                Text(dateSamples[sample.id] ?? "")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(layer.value == sample.id ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .accessibilityAddTraits(layer.value == sample.id ? .isSelected : [])
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .editorLine(.text)
                    }
                }
            }

        case .remoteImage:
            Section {
                EditorTextRow(title: "圖片網址", placeholder: "https://", text: optionalString($layer.value),
                              focus: $contentInputFocused, url: true)
                keepsFullColorToggle
            }

        case .image:
            Section {
                Button {
                    showLibrary = true
                } label: {
                    // 整列都能點（contentShape 要放在列本身，放在按鈕外面只有文字點得到，中間的空白點了沒反應）。
                    imagePickerRow
                }
                .buttonStyle(.plain)
                keepsFullColorToggle
            }
            slideshowSection

        case .events:
            Section {
                EditorTextRow(title: "標題文字", text: optionalString($layer.value, fallback: "Today's Events"))

                EditorIntegerField(
                    title: "顯示筆數",
                    value: intBinding($layer.maxItems, fallback: 5),
                    range: 1...5
                )
            }

        case .steps:
            Section {
                EditorTextRow(title: "下方文字", text: optionalString($layer.value, fallback: "步數"))
            }

        case .bundleImage:
            Section {
                Button {
                    showLibrary = true
                } label: {
                    imagePickerRow
                }
                .buttonStyle(.plain)
            }

        case .symbol:
            // 點選挑圖示（使用者：不必自己打系統圖示的名稱）；「跟著天氣」在面板的天氣分類裡。
            // 也可以取用資料的圖示（天氣圖示、月相…），取用時以資料為準。
            Section {
                if let binding = layer.bindings?[FormlessBindableProperty.symbol.rawValue] {
                    let label = EditorDataLabels.label(for: binding, live: model.live)
                    Button {
                        session.toolPanels.closeInspectorPanels()
                        session.toolPanels.format = EditorFormatPanelRequest(layerID: layer.id, slot: .symbol)
                    } label: {
                        HStack {
                            Text("圖示").foregroundStyle(.primary)
                            Spacer(minLength: 12)
                            EditorDataCapsule(symbol: label.symbol, title: label.title)
                            FormlessDisclosureIndicator()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    EditorSymbolRow(value: layer.value) { openSymbolPanel() }
                    Button {
                        session.toolPanels.closeInspectorPanels()
                        session.toolPanels.data = EditorDataPanelRequest(layerID: layer.id, target: .slot(.symbol), kinds: [.symbol])
                    } label: {
                        Label("取用資料的圖示", systemImage: "link").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                if layer.bindings?[FormlessBindableProperty.symbol.rawValue] == nil {
                    Text("取用資料時，圖示跟著資料變，例如天氣圖示、月相。")
                }
            }
            if (layer.value ?? "") != formlessAutoWeatherSymbol {
                // 上色方式（2026-10）：調色盤用「外觀」的顏色與第二顏色。
                Section {
                    Picker("上色方式", selection: Binding(get: { layer.symbolMode ?? "" },
                                                        set: { layer.symbolMode = $0.isEmpty ? nil : $0 })) {
                        ForEach(FormlessSymbolStyle.options, id: \.name) { option in
                            Text(option.name).tag(option.value ?? "")
                        }
                    }
                }
            }

        case .liveText:
            // 第幾筆是資料來源（行程、提醒事項、預報這類有好幾筆的）的細項：和資料來源同一列，不再另外一張卡片。
            let indexKind = FormlessLiveSource(rawValue: layer.value ?? "")?.editorIndexKind
            Section {
                EditorFunctionRow {
                    Picker(
                        "資料來源",
                        selection: Binding(
                            get: { layer.value ?? FormlessLiveSource.eventCount.rawValue },
                            set: { value in
                                layer.value = value
                                if let kind = FormlessLiveSource(rawValue: value)?.editorIndexKind {
                                    let index = max(1, FormlessDataBinding.parse(layer.dataIndex)?.index ?? 1)
                                    layer.dataIndex = kind + String(index)
                                }
                            }
                        )
                    ) {
                        ForEach(["行事曆", "提醒事項", "健康", "天氣服務", "系統日期"], id: \.self) { category in
                            Section(category) {
                                ForEach(FormlessLiveSource.allCases.filter { $0.editorCategory == category }) { source in
                                    Text(source.displayName).tag(source.rawValue)
                                }
                            }
                        }
                    }
                    .editorLine(.menu)

                    if let kind = indexKind {
                        EditorIntegerField(
                            title: "第幾筆",
                            value: Binding(
                                get: { max(1, FormlessDataBinding.parse(layer.dataIndex)?.index ?? 1) },
                                set: { layer.dataIndex = kind + String($0) }
                            ),
                            range: 1...9
                        )
                        .editorLine(.stepper)
                    }
                }
            } footer: {
                if indexKind != nil { Text("第 1 筆是最近的一筆。") }
            }

        case .calendarGrid:
            // 顯示內容與週一開始都是月曆的內容，放同一張卡片（一張卡片一個主題）。
            Section {
                Picker("顯示內容", selection: optionalString($layer.value, fallback: "all")) {
                    Text("星期與日期").tag("all")
                    Text("只顯示星期").tag("weekdays")
                    Text("只顯示日期").tag("days")
                }
                Toggle("週一開始", isOn: boolBinding($layer.weekStartsOnMonday, fallback: false))
            }
            EditorCalendarGridOptionsSection(layer: $layer, live: model.live)

        case .ruler:
            Section {
                EditorIntegerField(
                    title: "刻度格數",
                    value: intBinding($layer.maxItems, fallback: 70),
                    range: 10...140
                )
            }

        case .eventList, .reminderList, .weatherForecast:
            Section {
                EditorIntegerField(
                    title: "顯示筆數",
                    value: intBinding($layer.maxItems, fallback: 5),
                    range: 1...5
                )
            }

        case .reminders:
            Section {
                EditorTextRow(title: "標題", text: optionalString($layer.value, fallback: "Reminders"))

                EditorIntegerField(
                    title: "顯示筆數",
                    value: intBinding($layer.maxItems, fallback: 3),
                    range: 1...3
                )
            }

        default:
            Section {
                Text("此圖層沒有可調整的內容。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 進階元件

    @ViewBuilder
    /// 內容分頁的元件設定：只留開關與地點（顏色搬到外觀的顏色卡片、字級與字重搬到樣式卡片）。
    private var hasComponentSettings: Bool {
        [.calendar, .reminders].contains(layer.type) || holdsWeatherLocation
    }

    @ViewBuilder
    private var componentSection: some View {
        if hasComponentSettings {
            Section {
                switch layer.type {
                case .calendar:
                    Toggle("顯示左側大日期", isOn: boolBinding($layer.showsPanel, fallback: true))
                    Toggle("週一開始", isOn: boolBinding($layer.weekStartsOnMonday, fallback: false))
                case .reminders:
                    Toggle("顯示外框背景", isOn: boolBinding($layer.showsPanel, fallback: true))
                default:
                    EmptyView()
                }
                weatherSettings
            }
        }
    }

    /// 天氣地點放在主天氣圖示那一層（拆解後）或天氣元件本身
    private var holdsWeatherLocation: Bool { layer.editorHoldsWeatherLocation }

    @ViewBuilder
    private var weatherSettings: some View {
        if holdsWeatherLocation {
            // 不用目前位置時自己指定的地點（地點名稱、常用地點、緯度、經度）都是它的細項：同一列。
            EditorFunctionRow {
                Toggle("使用目前位置", isOn: boolBinding($layer.useCurrentLocation, fallback: true))
                    .editorLine(.control)

                if !(layer.useCurrentLocation ?? true) {
                    EditorTextRow(title: "地點名稱", text: optionalString($layer.locationName))
                        .editorLine(.text)

                    Picker("常用地點", selection: cityBinding) {
                        ForEach(formlessCityOptions) { city in
                            Text(city.displayName).tag(city.id)
                        }
                    }
                    .editorLine(.menu)

                    HStack {
                        Text("緯度")
                        Spacer()
                        FormlessNumberField(value: layer.latitude, emptyPlaceholder: "25.0330",
                                            format: { String(format: "%.4f", $0) }) { layer.latitude = $0 }
                            .font(.body.monospacedDigit())
                            .padding(.horizontal, 10)
                            .frame(width: FormlessDesign.Size.fieldLong)
                            .frame(minHeight: FormlessDesign.Size.control)
                            .formlessGrayBox()
                    }
                    .editorLine(.control)

                    HStack {
                        Text("經度")
                        Spacer()
                        FormlessNumberField(value: layer.longitude, emptyPlaceholder: "121.5654",
                                            format: { String(format: "%.4f", $0) }) { layer.longitude = $0 }
                            .font(.body.monospacedDigit())
                            .padding(.horizontal, 10)
                            .frame(width: FormlessDesign.Size.fieldLong)
                            .frame(minHeight: FormlessDesign.Size.control)
                            .formlessGrayBox()
                    }
                    .editorLine(.control)
                }
            }
        }
    }

    private var cityBinding: Binding<String> {
        Binding(
            get: { layer.locationName ?? "" },
            set: { newValue in
                guard let city = formlessCityOptions.first(where: { $0.id == newValue }) else { return }
                layer.locationName = city.displayName
                layer.latitude = city.latitude
                layer.longitude = city.longitude
            }
        )
    }

    // MARK: 位置

    // MARK: 元件內部微調

    private var parts: [FormlessPart] {
        FormlessParts.list(for: layer.type)
    }

    private var activePart: String {
        if parts.contains(where: { $0.id == selectedPart }) {
            return selectedPart
        }

        return parts.first?.id ?? ""
    }

    private var partStepX: Double {
        1 / (1600 * max(0.000625, layer.frame.width))
    }

    private var partStepY: Double {
        1 / (1600 * max(0.000625, layer.frame.height))
    }

    @ViewBuilder
    private var partSection: some View {
        if !parts.isEmpty {
            Section {
              // 移動與重設都是針對選的部位：和微調部位同一列。
              EditorFunctionRow {
                Picker(
                    "微調部位",
                    selection: Binding(
                        get: { activePart },
                        set: { selectedPart = $0 }
                    )
                ) {
                    ForEach(parts) { part in
                        Text(part.displayName).tag(part.id)
                    }
                }
                .editorLine(.menu)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    GridField(
                        title: "水平移動",
                        value: layer.offset(activePart).x / partStepX, step: nudgeStep
                    ) { newValue in
                        var offset = layer.offset(activePart)
                        offset.x = newValue * partStepX
                        layer.setOffset(offset, for: activePart)
                    }

                    GridField(
                        title: "垂直移動",
                        value: layer.offset(activePart).y / partStepY, step: nudgeStep
                    ) { newValue in
                        var offset = layer.offset(activePart)
                        offset.y = newValue * partStepY
                        layer.setOffset(offset, for: activePart)
                    }
                }
                .editorLine(.text)

                Menu("重設") {
                    Button("目前部位") {
                        layer.setOffset(FormlessOffset(), for: activePart)
                    }
                    Button("全部部位") {
                        layer.partOffsets = nil
                    }
                }
                .buttonStyle(.borderless)
                .editorLine(.text)
              }
            }
        }
    }


}


// MARK: - 綁定小工具

func optionalString(_ source: Binding<String?>, fallback: String = "") -> Binding<String> {
    Binding(
        get: { source.wrappedValue ?? fallback },
        set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}

func doubleBinding(_ source: Binding<Double?>, fallback: Double) -> Binding<Double> {
    Binding(
        get: { source.wrappedValue ?? fallback },
        set: { source.wrappedValue = $0 }
    )
}

func intBinding(_ source: Binding<Int?>, fallback: Int) -> Binding<Int> {
    Binding(
        get: { source.wrappedValue ?? fallback },
        set: { source.wrappedValue = $0 }
    )
}

func boolBinding(_ source: Binding<Bool?>, fallback: Bool) -> Binding<Bool> {
    Binding(
        get: { source.wrappedValue ?? fallback },
        set: { source.wrappedValue = $0 }
    )
}

func hexColorBinding(_ source: Binding<String?>, fallback: String) -> Binding<Color> {
    Binding(
        get: { Color(formlessHex: source.wrappedValue, fallback: fallback) },
        set: { source.wrappedValue = $0.formlessHex }
    )
}


#Preview {
    ContentView()
}


/// 拖曳位移只更新屬性面板容器，畫布及圖層清單不跟著重新計算。
/// 回滑時畫面上移動的是面板的靜態快照，不是活的面板：活的面板在滑動期間隱藏，
/// 它裡面的清單不管被系統怎麼重排、位移怎麼被改，都不會被看到；放手取消時快照滑回原位再換回活的面板。
/// 實機上（模擬器未重現）拖動活的面板時內容會自己往下推，鎖捲動、釘位移都擋不住，乾脆不讓它上場。
@MainActor final class EditorPanelSlideSnapshot: ObservableObject {
    @Published private(set) var active = false
    private var snapshot: UIView?
    func begin(marker: UIView) {
        guard snapshot == nil, let window = marker.window else { return }
        let rect = marker.convert(marker.bounds, to: window)
        guard let view = window.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return }
        view.frame = rect
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        snapshot = view
        active = true
    }
    func move(to x: CGFloat) {
        snapshot?.transform = CGAffineTransform(translationX: max(0, x), y: 0)
    }
    /// 放手後滑出：跟手放開的彈簧（0.25 秒、無回彈），並帶入放手時的手指速度，用力滑就更快出去。
    func finish(to x: CGFloat, velocity: CGFloat = 0, completion: @escaping () -> Void) {
        guard let view = snapshot else { completion(); return }
        let remaining = max(1, x - view.transform.tx)
        let initialVelocity = max(0, velocity / remaining)
        UIView.animate(springDuration: FormlessDesign.Motion.followDuration, bounce: 0, initialSpringVelocity: initialVelocity, delay: 0, options: [.beginFromCurrentState]) {
            view.transform = CGAffineTransform(translationX: x, y: 0)
        } completion: { _ in
            completion()
            view.removeFromSuperview()
            self.snapshot = nil
            self.active = false
        }
    }
    func cancel() {
        guard let view = snapshot else { active = false; return }
        UIView.animate(springDuration: FormlessDesign.Motion.followDuration, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.beginFromCurrentState]) {
            view.transform = .identity
        } completion: { _ in
            // 先讓活的面板顯示，下一輪再拿掉快照，中間不會閃到後面的清單。
            self.active = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                view.removeFromSuperview()
                self.snapshot = nil
            }
        }
    }
}

struct EditorInteractiveInspector<Content: View>: View {
    let width: CGFloat
    let isEnabled: Bool
    /// 觸控當下再問一次能不能返回（工具面板開著時不行）；不用重畫就能反映最新狀態。
    var blocked: () -> Bool = { false }
    let onReturn: () -> Void
    let content: Content
    @State private var returning = false
    @StateObject private var slide = EditorPanelSlideSnapshot()

    init(width: CGFloat, isEnabled: Bool, blocked: @escaping () -> Bool = { false }, onReturn: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.width = width
        self.isEnabled = isEnabled
        self.blocked = blocked
        self.onReturn = onReturn
        self.content = content()
    }

    var body: some View {
        content
            // 滑動期間活的面板隱藏（透明），畫面上滑的是快照；後面的圖層清單因此看得到。
            .opacity(slide.active ? 0 : 1)
            .allowsHitTesting(!returning && !slide.active)
            .overlay {
                EditorPanelBackGesture(
                    isEnabled: isEnabled && !returning,
                    blocked: blocked,
                    excludedTop: 0,
                    extendsToWindowTop: true,
                    onBegan: { marker in slide.begin(marker: marker) },
                    onChanged: { translation in slide.move(to: min(width, translation)) },
                    onEnded: { translation, velocity, cancelled in
                        if !cancelled && (translation > width * 0.35 || (translation > 24 && velocity > 450)) {
                            returning = true
                            slide.finish(to: width, velocity: velocity) { onReturn() }
                        } else {
                            slide.cancel()
                        }
                    }
                )
                .allowsHitTesting(false)
            }
    }
}

/// 面板容器的遮罩：上下兩端漸層淡出、左右照邊界；底部延伸到安全區以下讓清單滿版。
struct EditorPanelMask: View {
    /// 頂端淡出的強度來源（跟著捲動位移）；nil 表示一直是完整的淡出帶。
    var fade: EditorEdgeFade? = nil
    /// 頂端淡出帶的高度；nil 用預設 `EditorPanelFade.length`。
    var topFade: CGFloat? = nil
    var body: some View {
        if let fade {
            EditorPanelMaskBody(fade: fade, topFade: topFade)
        } else {
            EditorPanelMaskBody(fade: EditorEdgeFade(reach: .infinity), topFade: topFade)
        }
    }
}

private struct EditorPanelMaskBody: View {
    @ObservedObject var fade: EditorEdgeFade
    var topFade: CGFloat?
    var body: some View {
        let bottomSafeArea = FormlessSafeArea.bottom
        // 頂端淡出帶的高度等於內容往上捲的距離（最多到完整長度）：停在初始位置時是 0，完全不淡；
        // 內容與畫布之間原本有約 28 pt 留白，捲了多少、淡出帶就往下長多少，內容碰到畫布邊緣時交界處已經在淡出帶裡。
        let fadeHeight: CGFloat = min(topFade ?? EditorPanelFade.length, fade.topReach)
        VStack(spacing: 0) {
            LinearGradient(stops: EditorPanelFade.stops(from: .top), startPoint: .top, endPoint: .bottom)
                .frame(height: fadeHeight)
            Color.black
            // 底部同一條曲線倒過來，一路延伸到安全區底部，避免提前全透明造成一整條空白橫幅。
            LinearGradient(stops: EditorPanelFade.stops(from: .bottom), startPoint: .top, endPoint: .bottom)
                .frame(height: EditorPanelFade.length + bottomSafeArea)
        }
        .padding(.bottom, -bottomSafeArea)
    }
}

/// 整個 app 的清單／面板邊緣淡化共用一條曲線：60 pt 內從全透明到全顯示，前 40% 幾乎透明、中段加速。
/// `strength` 0 表示完全不淡（所有停點都不透明），1 是完整曲線。
enum EditorPanelFade {
    static let length: CGFloat = 60
    enum Edge { case top, bottom }
    static func stops(from edge: Edge, strength: CGFloat = 1) -> [Gradient.Stop] {
        let curve: [(CGFloat, Double)] = [(0, 0), (0.3, 0.1), (0.6, 0.55), (0.85, 0.92), (1, 1)]
        func opacity(_ base: Double) -> Double { 1 - Double(strength) * (1 - base) }
        switch edge {
        case .top: return curve.map { .init(color: .black.opacity(opacity($0.1)), location: $0.0) }
        case .bottom: return curve.reversed().map { .init(color: .black.opacity(opacity($0.1)), location: 1 - $0.0) }
        }
    }
}

/// 頂端淡出帶要長多高，由捲動位移決定：位移 0（停在初始位置）為 0，捲多少就長多少。
/// 淡化是用來處理內容和畫布邊緣的交界：內容一碰到邊緣就要在淡出帶裡，停在初始位置時不該有淡化。
@MainActor final class EditorEdgeFade: ObservableObject {
    @Published var topReach: CGFloat
    init(reach: CGFloat = 0) { topReach = reach }
    func update(scrollOffset: CGFloat) {
        let next = min(EditorPanelFade.length, max(0, scrollOffset))
        guard abs(next - topReach) >= 0.5 || (next == 0) != (topReach == 0) || (next == EditorPanelFade.length) != (topReach == EditorPanelFade.length) else { return }
        topReach = next
    }
}

/// 畫布與下方內容之間的留白。整個 app 統一：畫布底到第一個看得到的東西約 30 pt。
enum EditorPanelUnderlap {
    /// 圖層清單的頂端內距（第一張卡片自己還有約 5 pt 的外距）。
    static let height: CGFloat = 24
    /// 選取模式下清單頂端到第一張卡片的距離：上面已有工具列隔開，只留一點（清單內距不變，整個清單往上靠）。
    /// 工具列下緣到第一個圖層的視覺距離要等於畫布底到工具列上緣（約 20 pt）；8 的時候下面多了 4 pt（使用者指出）。
    /// 淡化遮罩掛在清單上，跟著清單一起移動，淡出帶相對內容不變。
    static let pickingHeight: CGFloat = 4
    /// 屬性面板 Form 的底部內距（不含安全區）：分類改到頂端後，底部只留一段邊距（原本 58 + 28 讓開浮動分類列）。
    static let formBottom: CGFloat = 20
    /// 屬性面板頂端內距（區塊都沒有標題）：分類下緣到第一張卡片約 12 pt（Form 第一張卡片自己還帶一點外距）。
    static let formHeadlessHeight: CGFloat = 4
    /// 屬性面板 Form 的頂端內距：Form 第一個分段標題本身就帶約 20 pt 的上方留白，補到和清單一樣約 28 pt；
    /// 原本兩份疊在一起有 56 pt，離畫布太遠、浪費空間。
    static let formHeight: CGFloat = 8
}

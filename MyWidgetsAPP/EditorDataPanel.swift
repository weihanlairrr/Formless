import SwiftUI
import EventKit

// MARK: - 選擇資料面板（2026-10 通用化，規劃第 6.4 節）
//
// 和「位置與大小」「顏色」同一種面板：螢幕 60% 高、畫布不擋、點外面是取消。最上面是這份設計已經用到的資料，
// 下面依類別列出所有資料，每列一個單色圖示（10/03 決定）。點類別換頁（標題列左邊返回鍵，不左右滑），
// 第二層只列合用的欄位，右邊灰字是目前的值；選了欄位就寫入圖層並關閉面板，可以復原。

struct EditorDataPanel: View {
    @ObservedObject var model: EditorModel
    let request: EditorDataPanelRequest
    let height: CGFloat
    var shown = true
    let onClose: () -> Void

    enum Page: Hashable {
        case category(FormlessDataCategory)
        /// 一個來源的欄位。
        case source(String)
        /// 一個清單欄位的第幾筆、哪個欄位。
        case list(source: String, field: String)
        /// 這份設計自己的來源設定（地點、行事曆、網址…）。
        case settings(String)
        case newVariable
    }

    @State private var path: [Page] = []
    @State private var forward = true
    @State private var search = ""
    @State private var fetched: [String: FormlessSnapshot] = [:]
    @State private var loading: Set<String> = []
    @State private var itemIndex = 1

    var body: some View {
        ZStack {
            page(path.last)
                .id(path.count)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                                        removal: .move(edge: forward ? .leading : .trailing)))
        }
        .clipped()
        .safeAreaBar(edge: .top, spacing: 0) { titleBar }
        .editorToolPanel(height: height, active: shown, onClose: onClose)
    }

    // MARK: 導覽

    private func push(_ page: Page) {
        forward = true
        withAnimation(FormlessDesign.Motion.push) { path.append(page) }
    }

    private func pop() {
        forward = false
        withAnimation(FormlessDesign.Motion.push) { _ = path.popLast() }
    }

    private var title: String {
        switch path.last {
        case nil: return "選擇資料"
        case .category(let category)?: return category.displayName
        case .source(let id)?: return source(id).map(EditorDataLabels.name) ?? "資料"
        case .list(let id, let field)?:
            guard let source = source(id) else { return "資料" }
            return FormlessProviders.provider(source.provider)?.field(field, source: source)?.name ?? "資料"
        case .settings?: return "設定"
        case .newVariable?: return "新增我的資料"
        }
    }

    private var titleBar: some View {
        ZStack {
            Text(title).font(.headline).lineLimit(1).padding(.horizontal, 64)
            HStack {
                if !path.isEmpty {
                    Button(action: pop) {
                        Image(systemName: "chevron.left")
                            .font(FormlessDesign.Symbol.glassButton)
                            .frame(width: FormlessDesign.Size.glassButton, height: FormlessDesign.Size.glassButton)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .formlessGlass(.regular.interactive(), in: .circle)
                    .accessibilityLabel("返回")
                }
                Spacer()
            }
            .padding(.horizontal, BatchPositionPanel.margin)
        }
        .frame(maxWidth: .infinity)
        .frame(height: BatchPositionPanel.titleBar)
    }

    @ViewBuilder private func page(_ page: Page?) -> some View {
        switch page {
        case nil: rootPage
        case .category(let category)?: categoryPage(category)
        case .source(let id)?: sourcePage(id)
        case .list(let id, let field)?: listPage(id, field: field)
        case .settings(let id)?: EditorSourceSettingsForm(model: model, sourceID: id, onDelete: { pop() })
        case .newVariable?: EditorNewVariableForm(model: model) { variable in
            choose(.variable(variable.id))
        }
        }
    }

    private func panelForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .scrollContentBackground(.hidden)
            .listSectionSpacing(FormlessDesign.Space.cardGap)
            .contentMargins(.horizontal, BatchPositionPanel.margin, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, BatchPositionPanel.margin + FormlessSafeArea.bottom, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(FormlessFixedPanelScroll())
    }

    // MARK: 資料

    /// 預覽值用的資料：編輯器目前的資料，加上面板裡剛抓到的。
    private var live: FormlessLiveData {
        var data = model.live
        data.adopt(model.document)
        data.snapshots.merge(fetched) { _, new in new }
        return data
    }

    private func source(_ id: String) -> FormlessSource? {
        live.source(id)
    }

    private func snapshot(_ source: FormlessSource) -> FormlessSnapshot? {
        guard let provider = FormlessProviders.provider(source.provider) else { return nil }
        let key = provider.cacheKey(for: source)
        return fetched[key] ?? model.live.snapshots[key] ?? FormlessSnapshotStore.load(key)
    }

    /// 點進一份資料時：沒有資料或過期就抓一次，抓到的值馬上出現在列上。
    private func load(_ source: FormlessSource) {
        guard let provider = FormlessProviders.provider(source.provider), provider.fetches else { return }
        let key = provider.cacheKey(for: source)
        if let old = snapshot(source) {
            fetched[key] = old
            if Date().timeIntervalSince(old.fetchedAt) < FormlessWebRefresh.lifetime(for: source, provider: provider),
               old.status == .ok || old.status == .empty { return }
        }
        guard loading.insert(key).inserted else { return }
        Task {
            let result = await provider.fetch(source)
            if let result { FormlessSnapshotStore.save(result, key: key) }
            await MainActor.run {
                loading.remove(key)
                if let saved = FormlessSnapshotStore.load(key) { fetched[key] = saved }
            }
        }
    }

    private func matches(_ spec: FormlessFieldSpec) -> Bool {
        if request.wantsList { return spec.kind == .list }
        guard let kinds = request.kinds else { return true }
        if kinds.contains(spec.kind) { return true }
        // 清單可以再選第幾筆的欄位；一筆資料可以選它的欄位。
        if spec.kind == .list || spec.kind == .record { return spec.itemFields.contains { kinds.contains($0.kind) } }
        // 數字可以當文字顯示；日期、時間長度也可以。
        if kinds.contains(.text) { return true }
        return false
    }

    private func choose(_ binding: FormlessBinding) {
        model.applyData(binding, request: request)
        onClose()
    }

    private func usage(of source: FormlessSource) -> Int {
        model.document.layers.filter { layer in layer.dataBindings.contains { $0.source == source.id } }.count
    }

    /// 這份設計用到的來源（含 App 預設）與自己設定、還沒用到的。
    private var designSources: [FormlessSource] {
        var result = FormlessDataCoordinator.sources(usedBy: model.document)
        for own in model.document.sources ?? [] where !result.contains(where: { $0.id == own.id }) { result.append(own) }
        return result
    }

    // MARK: 第一層

    private var rootPage: some View {
        panelForm {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋資料", text: $search)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: FormlessDesign.Size.control)
                .formlessGrayBox()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                if let item = repeatItem {
                    Section {
                        ForEach(item.fields.filter(matches)) { field in
                            let binding = FormlessBinding(source: FormlessBindingSource.item, field: field.id)
                            Button { choose(binding) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "list.bullet").font(.system(size: 18)).frame(width: 26)
                                    Text("這一筆・" + field.name).foregroundStyle(.primary).lineLimit(1)
                                    Spacer(minLength: FormlessDesign.Space.valueGap)
                                    Text(FormlessValueFormatter.text(item.live.value(binding, at: Date()), format: nil, spec: field, at: Date()))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("這個圖層在重複排列的群組裡：「這一筆」是清單裡的每一筆，第一份顯示第一筆。")
                    }
                }
                if !designSources.isEmpty {
                    Section {
                        ForEach(designSources) { source in designSourceRow(source) }
                    }
                }
                Section {
                    // 沒有任何資料的類別不列（照片輪播在圖片圖層裡設定）；我的資料一定列（可以新增）。
                    ForEach(FormlessDataCategory.allCases.filter { $0 == .mine || $0 == .web || !FormlessProviders.providers(in: $0).isEmpty }) { category in
                        navigationRow(symbol: category.symbol, title: category.displayName) { open(category) }
                    }
                }
            } else {
                searchResults
            }
        }
    }

    /// 圖層在重複排列的群組裡：那份清單每一筆的欄位，與帶著第一筆的預覽資料。
    private var repeatItem: (fields: [FormlessFieldSpec], live: FormlessLiveData)? {
        guard let id = request.layerID, let layer = model.document.layer(id),
              let group = model.document.layer(layer.parentID), let spec = group.repeatSpec,
              let list = live.fieldSpec(spec.collection), !list.itemFields.isEmpty else { return nil }
        return (list.itemFields, model.document.itemContext(for: layer, live: live, date: Date()))
    }

    private func open(_ category: FormlessDataCategory) {
        let providers = FormlessProviders.providers(in: category)
        // 一類只有一種資料、也不能另外設定一份（裝置、健康與活動）：直接列欄位。
        if category != .mine, providers.count == 1, let only = providers.first, !only.allowsInstances {
            push(.source(only.id))
        } else {
            push(.category(category))
        }
    }

    private func designSourceRow(_ source: FormlessSource) -> some View {
        let provider = FormlessProviders.provider(source.provider)
        let count = usage(of: source)
        var detail: [String] = []
        if count > 0 { detail.append("\(count) 個圖層使用") }
        if let snapshot = snapshot(source), snapshot.fetchedAt > .distantPast, provider?.fetches == true {
            detail.append(EditorDataLabels.updated(snapshot.fetchedAt))
        } else if !source.isAppDefault, let provider {
            let summary = provider.summary(for: source)
            if !summary.isEmpty { detail.append(summary) }
        }
        let main = provider?.fields(for: source, snapshot: snapshot(source)).first { $0.kind != .list && $0.kind != .record }
        let value = main.map { FormlessValueFormatter.text(live.value(FormlessBinding(source: source.id, field: $0.id), at: Date()),
                                                            format: nil, spec: $0, at: Date()) }
        return navigationRow(symbol: EditorDataLabels.symbol(of: source), title: EditorDataLabels.name(of: source),
                             subtitle: detail.joined(separator: "・"), value: value) { push(.source(source.id)) }
    }

    /// 一列：左邊單色圖示、名稱（可有第二行小字），右邊灰字的值與「›」。整列都能點。
    private func navigationRow(symbol: String, title: String, subtitle: String? = nil, value: String? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: FormlessDesign.Space.valueGap)
                if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 搜尋

    @ViewBuilder private var searchResults: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let results = searchMatches(query)
        Section {
            if results.isEmpty {
                Text("找不到「\(search)」").foregroundStyle(.secondary)
            } else {
                ForEach(results, id: \.binding) { result in
                    fieldRow(title: result.title, spec: result.spec, binding: result.binding, source: result.source)
                }
            }
        }
    }

    private struct SearchMatch {
        let title: String
        let spec: FormlessFieldSpec
        let binding: FormlessBinding
        let source: FormlessSource
    }

    private func searchMatches(_ query: String) -> [SearchMatch] {
        var sources = designSources
        for provider in FormlessProviders.all where !sources.contains(where: { $0.id == provider.id }) {
            sources.append(.appDefault(provider.id))
        }
        var results: [SearchMatch] = []
        for source in sources {
            guard let provider = FormlessProviders.provider(source.provider) else { continue }
            let sourceName = EditorDataLabels.name(of: source)
            for spec in provider.fields(for: source, snapshot: snapshot(source)) where matches(spec) {
                if spec.name.lowercased().contains(query) || sourceName.lowercased().contains(query) {
                    results.append(SearchMatch(title: sourceName + "・" + spec.name, spec: spec,
                                               binding: FormlessBinding(source: source.id, field: spec.id), source: source))
                }
            }
        }
        return Array(results.prefix(60))
    }

    // MARK: 類別

    private func categoryPage(_ category: FormlessDataCategory) -> some View {
        panelForm {
            if category == .mine { variablesSection }
            if category == .web {
                webSections
            } else {
                providerSections(category)
            }
        }
    }

    /// 網路資料：這份設計已經加的網址、選了就能用的資料範本、自己貼網址。網路資料沒有「App 預設」那一份。
    @ViewBuilder private var webSections: some View {
        let own = (model.document.sources ?? []).filter { FormlessWebRefresh.providerIDs.contains($0.provider) }
        if !own.isEmpty {
            Section {
                ForEach(own) { source in
                    let provider = FormlessProviders.provider(source.provider)
                    navigationRow(symbol: provider?.symbol ?? "globe", title: EditorDataLabels.name(of: source),
                                  subtitle: provider?.name) {
                        push(.source(source.id))
                    }
                }
            }
        }
        Section {
            ForEach(FormlessDataTemplates.all) { template in
                navigationRow(symbol: template.symbol, title: template.name, subtitle: template.detail) {
                    addTemplate(template)
                }
            }
        }
        Section {
            ForEach(FormlessProviders.providers(in: .web), id: \.id) { provider in
                Button { addInstance(provider) } label: {
                    Label("加入\(provider.name)網址", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// 用範本建立這份設計自己的一份資料，接著列出它的欄位（抓到就看得到目前的值）。
    private func addTemplate(_ template: FormlessDataTemplate) {
        var next = model.document
        let source = FormlessDataTemplates.source(for: template)
        next.sources = (next.sources ?? []) + [source]
        model.designBinding.wrappedValue = next
        push(.source(source.id))
    }

    @ViewBuilder private func providerSections(_ category: FormlessDataCategory) -> some View {
            ForEach(FormlessProviders.providers(in: category), id: \.id) { provider in
                Section {
                    let own = (model.document.sources ?? []).filter { $0.provider == provider.id }
                    ForEach([FormlessSource.appDefault(provider.id)] + own) { source in
                        let summary = provider.summary(for: source)
                        navigationRow(symbol: provider.symbol, title: EditorDataLabels.name(of: source),
                                      subtitle: source.isAppDefault ? (summary.isEmpty ? nil : summary) : nil) {
                            push(.source(source.id))
                        }
                    }
                    if provider.allowsInstances {
                        Button { addInstance(provider) } label: {
                            Label("另外設定一份\(provider.name)", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
    }

    /// 選了 variable 會不會讓正在設定的我的資料取用到自己（直接或經過其他份我的資料）。
    private func wouldCycle(_ variable: FormlessVariable) -> Bool {
        guard case .slot(.variable(let editing)) = request.target else { return false }
        let variables = model.document.variables ?? []
        var visited: Set<UUID> = []
        var pending = [variable.id]
        while let id = pending.popLast() {
            if id == editing { return true }
            guard visited.insert(id).inserted, let current = variables.first(where: { $0.id == id }) else { continue }
            for binding in current.binding?.allBindings ?? [] where binding.isVariable {
                if let next = UUID(uuidString: binding.field) { pending.append(next) }
            }
        }
        return false
    }

    /// 我的資料：這份設計的具名值；點了就用它，最下面可以新增。
    @ViewBuilder private var variablesSection: some View {
        Section {
            ForEach(model.document.variables ?? []) { variable in
                let binding = FormlessBinding.variable(variable.id)
                let spec = live.fieldSpec(binding)
                // 正在設定的那一份我的資料，以及取用它的其他份不列出：選了會互相取用、永遠沒有值。
                if spec.map(matches) ?? true, !wouldCycle(variable) {
                    Button { choose(binding) } label: {
                        HStack {
                            Image(systemName: "pencil").font(.system(size: 18)).frame(width: 26)
                            Text(variable.name).foregroundStyle(.primary)
                            Spacer(minLength: FormlessDesign.Space.valueGap)
                            Text(live.text(binding, at: Date())).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { push(.newVariable) } label: {
                Label("新增我的資料", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        } footer: {
            Text("我的資料是這份設計裡自己取名的值，例如每日目標。同一份資料可以同時用在文字、進度與條件。")
        }
    }

    private func addInstance(_ provider: any FormlessDataProvider) {
        var next = model.document
        var source = FormlessSource(provider: provider.id)
        for spec in provider.settings where !spec.defaultValue.isEmpty { source.settings[spec.id] = spec.defaultValue }
        if provider.settings.contains(where: { $0.kind == .location }) {
            // 另外設定的地點：從臺北開始，使用者再改（App 預設已經是目前位置）。
            source.settings[FormlessPlace.settingKeys.current] = .bool(false)
            source.settings[FormlessPlace.settingKeys.name] = .text("臺北")
            source.settings[FormlessPlace.settingKeys.latitude] = .number(25.0330, .none)
            source.settings[FormlessPlace.settingKeys.longitude] = .number(121.5654, .none)
        }
        next.sources = (next.sources ?? []) + [source]
        model.designBinding.wrappedValue = next
        push(.source(source.id))
        push(.settings(source.id))
    }

    // MARK: 一份資料

    private func sourcePage(_ id: String) -> some View {
        panelForm {
            if let source = source(id), let provider = FormlessProviders.provider(source.provider) {
                let snapshot = snapshot(source)
                if !source.isAppDefault {
                    Section {
                        navigationRow(symbol: "slider.horizontal.3", title: "設定", value: provider.summary(for: source)) {
                            push(.settings(id))
                        }
                    }
                }
                Section {
                    ForEach(provider.fields(for: source, snapshot: snapshot).filter(matches)) { spec in
                        fieldRow(title: spec.name, spec: spec, binding: FormlessBinding(source: id, field: spec.id), source: source)
                    }
                } footer: {
                    sourceFooter(source, provider: provider, snapshot: snapshot)
                }
            } else {
                Section { Text("找不到這份資料").foregroundStyle(.secondary) }
            }
        }
        .onAppear { if let source = source(id) { load(source) } }
    }

    @ViewBuilder private func sourceFooter(_ source: FormlessSource, provider: any FormlessDataProvider,
                                           snapshot: FormlessSnapshot?) -> some View {
        let status = provider.fetches ? (snapshot?.status ?? provider.availability(for: source)) : .ok
        let key = provider.cacheKey(for: source)
        VStack(alignment: .leading, spacing: 8) {
            if loading.contains(key) && snapshot == nil {
                Text("正在取得資料…")
            } else if let text = EditorDataLabels.status(status, provider: provider) {
                Text(status == .ok || status == .loading ? text : (snapshot?.message ?? text))
                if status == .unauthorized {
                    Button("允許取用") { Task { await requestAccess(provider); load(source) } }
                        .font(.footnote.weight(.semibold))
                }
            }
            if let snapshot, snapshot.fetchedAt > .distantPast, provider.fetches {
                Text([snapshot.attribution.map { "資料來自 " + $0 }, EditorDataLabels.updated(snapshot.fetchedAt)]
                    .compactMap { $0 }.joined(separator: "・"))
            }
        }
    }

    @MainActor private func requestAccess(_ provider: any FormlessDataProvider) async {
        switch provider.id {
        case "calendar": await FormlessEventsProvider.requestAccess()
        case "reminders": await FormlessRemindersProvider.requestAccess()
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
        }
    }

    /// 欄位列：名稱左、目前的值右（灰字）；清單是「N 筆 ›」，點進去選第幾筆。
    @ViewBuilder private func fieldRow(title: String, spec: FormlessFieldSpec, binding: FormlessBinding,
                                       source: FormlessSource) -> some View {
        let value = live.value(binding, at: Date())
        if (spec.kind == .list || spec.kind == .record) && !request.wantsList {
            let count = value.listValue?.count
            navigationRow(symbol: "list.bullet", title: title, value: count.map { "\($0) 筆" }) {
                itemIndex = 1
                push(.list(source: source.id, field: spec.id))
            }
        } else {
            Button { choose(binding) } label: {
                HStack {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: FormlessDesign.Space.valueGap)
                    Text(spec.kind == .list ? "\(value.listValue?.count ?? 0) 筆"
                         : FormlessValueFormatter.text(value, format: nil, spec: spec, at: Date()))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 清單的第幾筆

    private func listPage(_ id: String, field: String) -> some View {
        panelForm {
            if let source = source(id), let provider = FormlessProviders.provider(source.provider),
               let spec = provider.field(field, source: source, snapshot: snapshot(source)) {
                let isRecord = spec.kind == .record
                let items = live.value(FormlessBinding(source: id, field: field), at: Date()).listValue ?? []
                if !isRecord {
                    Section {
                        EditorStepperRow(title: "第幾筆", value: Binding(get: { Double(itemIndex) }, set: { itemIndex = Int($0) }),
                                         range: 1...Double(max(items.count, 10, itemIndex)), step: 1)
                    } footer: {
                        Text(items.isEmpty ? "目前沒有資料；有資料時會顯示第 \(itemIndex) 筆。" : "第 1 筆是最近的一筆，目前有 \(items.count) 筆。")
                    }
                }
                Section {
                    ForEach(spec.itemFields.filter { request.kinds == nil || request.kinds!.contains($0.kind) || request.kinds!.contains(.text) }) { item in
                        let binding = FormlessBinding(source: id, field: field, index: isRecord ? nil : itemIndex, itemField: item.id)
                        Button { choose(binding) } label: {
                            HStack {
                                Text(item.name).foregroundStyle(.primary)
                                Spacer(minLength: FormlessDesign.Space.valueGap)
                                Text(FormlessValueFormatter.text(live.value(binding, at: Date()), format: nil, spec: item, at: Date()))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 來源設定

/// 這份設計自己的來源設定：名稱、地點、行事曆、範圍、網址……依供應者宣告的設定項目產生。
struct EditorSourceSettingsForm: View {
    @ObservedObject var model: EditorModel
    let sourceID: String
    var onDelete: () -> Void = {}
    @State private var confirmDelete = false

    private var index: Int? { model.document.sources?.firstIndex { $0.id == sourceID } }

    private var sourceBinding: Binding<FormlessSource> {
        Binding(
            get: { model.document.sources?.first { $0.id == sourceID } ?? FormlessSource(provider: "") },
            set: { value in
                var next = model.document
                guard let index = next.sources?.firstIndex(where: { $0.id == sourceID }), next.sources?[index] != value else { return }
                next.sources?[index] = value
                model.designBinding.wrappedValue = next
                Task { await model.refreshDataSnapshots() }
            }
        )
    }

    var body: some View {
        Form {
            if index != nil, let provider = FormlessProviders.provider(sourceBinding.wrappedValue.provider) {
                Section {
                    EditorTextRow(title: "名稱", placeholder: provider.name + "・" + provider.summary(for: sourceBinding.wrappedValue),
                                  text: Binding(get: { sourceBinding.wrappedValue.name ?? "" },
                                                set: { sourceBinding.wrappedValue.name = $0.isEmpty ? nil : $0 }))
                }
                ForEach(provider.settings) { spec in
                    Section {
                        EditorSettingRow(spec: spec, source: sourceBinding)
                    } footer: {
                        if let footer = spec.footer { Text(footer) }
                    }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("刪除這份資料").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("用到它的圖層會顯示「找不到這份資料」，可以再重新選擇。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(FormlessDesign.Space.cardGap)
        .contentMargins(.horizontal, BatchPositionPanel.margin, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, BatchPositionPanel.margin + FormlessSafeArea.bottom, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .background(FormlessFixedPanelScroll())
        .alert("刪除這份資料？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) {
                var next = model.document
                next.sources?.removeAll { $0.id == sourceID }
                if next.sources?.isEmpty == true { next.sources = nil }
                model.designBinding.wrappedValue = next
                onDelete()
            }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 一個設定項目。
struct EditorSettingRow: View {
    let spec: FormlessSettingSpec
    @Binding var source: FormlessSource

    var body: some View {
        switch spec.kind {
        case .location:
            EditorLocationSettingRow(source: $source)
        case .text(let placeholder):
            EditorTextRow(title: spec.name, placeholder: placeholder, text: text(spec.id))
        case .url:
            EditorTextRow(title: spec.name, placeholder: "https://", text: text(spec.id), url: true)
        case .number(let min, let max, let step):
            EditorStepperRow(title: spec.name, value: Binding(
                get: { source.number(spec.id) ?? spec.defaultValue.numberValue ?? 0 },
                set: { source[spec.id] = .number($0, .none) }), range: min...max, step: step)
        case .toggle:
            Toggle(spec.name, isOn: Binding(
                get: { source.flag(spec.id) ?? spec.defaultValue.boolValue ?? false },
                set: { source[spec.id] = .bool($0) }))
        case .choice(let options):
            Picker(spec.name, selection: Binding(
                get: { source.text(spec.id) ?? spec.defaultValue.rawString ?? options.first?.id ?? "" },
                set: { source[spec.id] = .text($0) })) {
                ForEach(options) { option in Text(option.name).tag(option.id) }
            }
        case .date, .dateTime:
            DatePicker(spec.name, selection: Binding(
                get: { source.date(spec.id) ?? Date() },
                set: { source[spec.id] = .date($0, allDay: spec.kind == .date) }),
                       displayedComponents: spec.kind == .date ? [.date] : [.date, .hourAndMinute])
        case .lines:
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.name)
                TextEditor(text: Binding(
                    get: { source.list(spec.id).joined(separator: "\n") },
                    set: { text in source[spec.id] = .list(text.components(separatedBy: "\n").map { .text($0) }) }))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .formlessGrayBox()
            }
            .padding(.vertical, 4)
        case .calendars:
            EditorCalendarChoiceRow(title: spec.name, entity: .event, source: $source, key: spec.id)
        case .reminderLists:
            EditorCalendarChoiceRow(title: spec.name, entity: .reminder, source: $source, key: spec.id)
        }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { source.text(key) ?? "" }, set: { source[key] = $0.isEmpty ? .empty : .text($0) })
    }
}

/// 地點：使用目前位置，或指定地點（名稱、常用地點、經緯度），和天氣元件原本的地點設定同一套。
struct EditorLocationSettingRow: View {
    @Binding var source: FormlessSource
    private typealias Keys = FormlessPlace

    var body: some View {
        let useCurrent = source.flag(Keys.settingKeys.current) ?? true
        EditorFunctionRow {
            Toggle("使用目前位置", isOn: Binding(get: { useCurrent }, set: { source[Keys.settingKeys.current] = .bool($0) }))
                .editorLine(.control)
            if !useCurrent {
                EditorTextRow(title: "地點名稱", text: Binding(
                    get: { source.text(Keys.settingKeys.name) ?? "" },
                    set: { source[Keys.settingKeys.name] = $0.isEmpty ? .empty : .text($0) }))
                    .editorLine(.text)
                Picker("常用地點", selection: Binding(
                    get: { source.text(Keys.settingKeys.name) ?? "" },
                    set: { name in
                        guard let city = formlessCityOptions.first(where: { $0.id == name }) else { return }
                        source[Keys.settingKeys.name] = .text(city.displayName)
                        source[Keys.settingKeys.latitude] = .number(city.latitude, .none)
                        source[Keys.settingKeys.longitude] = .number(city.longitude, .none)
                    })) {
                    ForEach(formlessCityOptions) { city in Text(city.displayName).tag(city.id) }
                }
                .editorLine(.menu)
                coordinate("緯度", key: Keys.settingKeys.latitude, placeholder: "25.0330")
                coordinate("經度", key: Keys.settingKeys.longitude, placeholder: "121.5654")
            }
        }
    }

    private func coordinate(_ title: String, key: String, placeholder: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            FormlessNumberField(value: source.number(key), emptyPlaceholder: placeholder,
                                format: { String(format: "%.4f", $0) }) { source[key] = .number($0, .none) }
                .font(.body.monospacedDigit())
                .padding(.horizontal, 10)
                .frame(width: FormlessDesign.Size.fieldLong)
                .frame(minHeight: FormlessDesign.Size.control)
                .formlessGrayBox()
        }
        .editorLine(.control)
    }
}

/// 選幾本行事曆或幾個提醒事項清單：列出全部，打勾的就讀；都沒勾是用 App 的設定。
struct EditorCalendarChoiceRow: View {
    let title: String
    let entity: EKEntityType
    @Binding var source: FormlessSource
    let key: String
    @State private var calendars: [(id: String, title: String, color: Color)] = []

    var body: some View {
        let chosen = Set(source.list(key))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text(chosen.isEmpty ? "依 App 設定" : "\(chosen.count) 個").foregroundStyle(.secondary)
            }
            if calendars.isEmpty {
                Text("沒有權限或沒有可讀的項目").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(calendars, id: \.id) { calendar in
                Button {
                    var next = chosen
                    if next.contains(calendar.id) { next.remove(calendar.id) } else { next.insert(calendar.id) }
                    source[key] = next.isEmpty ? .empty : .list(next.sorted().map { .text($0) })
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(calendar.color).frame(width: 12, height: 12)
                        Text(calendar.title).foregroundStyle(.primary)
                        Spacer()
                        if chosen.contains(calendar.id) {
                            Image(systemName: "checkmark").foregroundStyle(FormlessDesign.Palette.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .task {
            let status = EKEventStore.authorizationStatus(for: entity)
            guard status == .fullAccess else { return }
            calendars = EKEventStore().calendars(for: entity)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { ($0.calendarIdentifier, $0.title, Color(cgColor: $0.cgColor)) }
        }
    }
}

// MARK: - 新增我的資料

struct EditorNewVariableForm: View {
    @ObservedObject var model: EditorModel
    let onCreate: (FormlessVariable) -> Void
    @State private var name = ""
    @State private var kind: FormlessValueKind = .number
    @State private var number: Double = 10_000
    @State private var text = ""
    @State private var date = Date()
    @State private var flag = true

    static let kinds: [FormlessValueKind] = [.number, .text, .date, .bool]

    var body: some View {
        Form {
            Section {
                EditorTextRow(title: "名稱", placeholder: "例如：每日目標", text: $name)
                Picker("種類", selection: $kind) {
                    ForEach(Self.kinds, id: \.self) { Text($0.displayName).tag($0) }
                }
                switch kind {
                case .number:
                    HStack {
                        Text("值")
                        Spacer()
                        FormlessNumberField(value: number, format: { FormlessValueFormatter.fixed($0, decimals: $0.rounded() == $0 ? 0 : 2, grouping: false) }) {
                            number = $0
                        }
                        .font(.body.monospacedDigit())
                        .padding(.horizontal, 10)
                        .frame(width: FormlessDesign.Size.fieldLong)
                        .frame(minHeight: FormlessDesign.Size.control)
                        .formlessGrayBox()
                    }
                case .text: EditorTextRow(title: "值", text: $text)
                case .date: DatePicker("值", selection: $date, displayedComponents: [.date, .hourAndMinute])
                default: Toggle("值", isOn: $flag)
                }
            }
            Section {
                Button {
                    let value: FormlessValue
                    switch kind {
                    case .number: value = .number(number, .none)
                    case .text: value = .text(text)
                    case .date: value = .date(date)
                    default: value = .bool(flag)
                    }
                    let variable = FormlessVariable(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "我的資料" : name,
                                                    kind: kind, value: value)
                    var next = model.document
                    next.variables = (next.variables ?? []) + [variable]
                    model.designBinding.wrappedValue = next
                    onCreate(variable)
                } label: {
                    Text("加入並使用").frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(FormlessDesign.Space.cardGap)
        .contentMargins(.horizontal, BatchPositionPanel.margin, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, BatchPositionPanel.margin + FormlessSafeArea.bottom, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .background(FormlessFixedPanelScroll())
    }
}

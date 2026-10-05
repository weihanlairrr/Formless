import SwiftUI

// MARK: - 小工具設定 › 資料、我的資料（2026-10 通用化，規劃第 6.2 節）
//
// 資料：列出這份設計用到的來源，名稱、目前狀態、更新時間、被幾個圖層使用；點進去改地點、行事曆、範圍。
// 我的資料：一列一個具名值，名稱左、值右；新增時先選種類。

/// 小工具設定第一層的兩列。
struct EditorDesignDataRows: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let sources = EditorDesignSourcesPage.sources(model.document)
        let variables = model.document.variables ?? []
        NavigationLink {
            EditorDesignSourcesPage(model: model)
        } label: {
            LabeledContent("資料", value: sources.isEmpty ? "沒有使用" : "\(sources.count) 份")
        }
        NavigationLink {
            EditorVariablesPage(model: model)
        } label: {
            LabeledContent("我的資料", value: variables.isEmpty ? "沒有" : "\(variables.count) 個")
        }
    }
}

struct EditorDesignSourcesPage: View {
    @ObservedObject var model: EditorModel

    static func sources(_ document: FormlessDocument) -> [FormlessSource] {
        var result = FormlessDataCoordinator.sources(usedBy: document)
        for own in document.sources ?? [] where !result.contains(where: { $0.id == own.id }) { result.append(own) }
        return result
    }

    var body: some View {
        let sources = Self.sources(model.document)
        Form {
            if sources.isEmpty {
                Section {
                    Text("這份設計還沒有用到資料。在文字的「內容」點「插入資料」，或在進度、圖表、條件裡選擇資料。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(sources) { source in
                        NavigationLink {
                            EditorSourceDetailPage(model: model, sourceID: source.id)
                        } label: {
                            row(source)
                        }
                    }
                }
            }
            Section {
                Menu {
                    ForEach(FormlessProviders.all.filter(\.allowsInstances), id: \.id) { provider in
                        Button(provider.name) { add(provider) }
                    }
                } label: {
                    Label("新增一份資料", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text("另外設定的資料可以有自己的地點、行事曆或範圍，例如同一份設計同時放臺北與東京的天氣。")
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .navigationTitle("資料")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ source: FormlessSource) -> some View {
        let provider = FormlessProviders.provider(source.provider)
        let snapshot = provider.flatMap { FormlessSnapshotStore.load($0.cacheKey(for: source)) }
        let count = model.document.layers.filter { $0.dataBindings.contains { $0.source == source.id } }.count
        var detail: [String] = []
        detail.append(count > 0 ? "\(count) 個圖層使用" : "沒有圖層使用")
        if provider?.fetches == true {
            let status = snapshot?.status ?? provider?.availability(for: source) ?? .ok
            if let text = EditorDataLabels.status(status, provider: provider) { detail.append(text) }
            else if let snapshot { detail.append(EditorDataLabels.updated(snapshot.fetchedAt)) }
        }
        return HStack(spacing: 14) {
            Image(systemName: EditorDataLabels.symbol(of: source)).font(.system(size: 18)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(EditorDataLabels.name(of: source)).lineLimit(1)
                Text(detail.joined(separator: "・")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func add(_ provider: any FormlessDataProvider) {
        var next = model.document
        var source = FormlessSource(provider: provider.id)
        for spec in provider.settings where !spec.defaultValue.isEmpty { source.settings[spec.id] = spec.defaultValue }
        if provider.settings.contains(where: { $0.kind == .location }) {
            source.settings[FormlessPlace.settingKeys.current] = .bool(false)
            source.settings[FormlessPlace.settingKeys.name] = .text("臺北")
            source.settings[FormlessPlace.settingKeys.latitude] = .number(25.0330, .none)
            source.settings[FormlessPlace.settingKeys.longitude] = .number(121.5654, .none)
        }
        next.sources = (next.sources ?? []) + [source]
        model.designBinding.wrappedValue = next
    }
}

/// 一份來源：自己設定的可以改；App 預設的說明它跟著 App 的設定。
struct EditorSourceDetailPage: View {
    @ObservedObject var model: EditorModel
    let sourceID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.document.sources?.contains(where: { $0.id == sourceID }) == true {
                EditorSourceSettingsForm(model: model, sourceID: sourceID, onDelete: { dismiss() })
                    .scrollContentBackground(.automatic)
            } else {
                Form {
                    Section {
                        Text("這是 App 預設的\(FormlessProviders.provider(sourceID)?.name ?? "資料")，設定跟著 App 的「設定」頁（例如目前位置、設定頁選的行事曆）。要不同的地點或範圍，請在上一頁「新增一份資料」。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .navigationTitle(model.live.source(sourceID).map(EditorDataLabels.name) ?? "資料")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EditorVariablesPage: View {
    @ObservedObject var model: EditorModel
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ForEach(model.document.variables ?? []) { variable in
                    NavigationLink {
                        EditorVariableEditPage(model: model, id: variable.id)
                    } label: {
                        LabeledContent(variable.name, value: model.live.text(.variable(variable.id), at: Date()))
                    }
                }
                .onDelete { offsets in
                    var next = model.document
                    next.variables?.remove(atOffsets: offsets)
                    if next.variables?.isEmpty == true { next.variables = nil }
                    model.designBinding.wrappedValue = next
                }
                Button { adding = true } label: {
                    Label("新增我的資料", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text("我的資料是這份設計裡自己取名的值，例如每日目標、考試日期。文字、進度、條件都可以用它；改一處，用到的地方一起變。")
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .navigationTitle("我的資料")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $adding) {
            EditorNewVariableForm(model: model) { _ in adding = false }
                .scrollContentBackground(.automatic)
                .navigationTitle("新增我的資料")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct EditorVariableEditPage: View {
    @ObservedObject var model: EditorModel
    let id: UUID

    private var variable: Binding<FormlessVariable> {
        Binding(
            get: { model.document.variables?.first { $0.id == id } ?? FormlessVariable(name: "", kind: .text, value: .empty) },
            set: { value in
                var next = model.document
                guard let index = next.variables?.firstIndex(where: { $0.id == id }) else { return }
                next.variables?[index] = value
                model.designBinding.wrappedValue = next
            }
        )
    }

    var body: some View {
        Form {
            Section {
                EditorTextRow(title: "名稱", text: variable.name)
                LabeledContent("種類", value: variable.wrappedValue.kind.displayName)
                switch variable.wrappedValue.kind {
                case .number:
                    HStack {
                        Text("值")
                        Spacer()
                        FormlessNumberField(value: variable.wrappedValue.value.numberValue ?? 0,
                                            format: { FormlessValueFormatter.fixed($0, decimals: $0.rounded() == $0 ? 0 : 2, grouping: false) }) {
                            variable.wrappedValue.value = .number($0, .none)
                        }
                        .font(.body.monospacedDigit())
                        .padding(.horizontal, 10)
                        .frame(width: FormlessDesign.Size.fieldLong)
                        .frame(minHeight: FormlessDesign.Size.control)
                        .formlessGrayBox()
                    }
                case .date:
                    DatePicker("值", selection: Binding(
                        get: { variable.wrappedValue.value.dateValue ?? Date() },
                        set: { variable.wrappedValue.value = .date($0) }), displayedComponents: [.date, .hourAndMinute])
                case .bool:
                    Toggle("值", isOn: Binding(
                        get: { variable.wrappedValue.value.boolValue ?? false },
                        set: { variable.wrappedValue.value = .bool($0) }))
                default:
                    EditorTextRow(title: "值", text: Binding(
                        get: { variable.wrappedValue.value.rawString ?? "" },
                        set: { variable.wrappedValue.value = .text($0) }))
                }
            } footer: {
                if let binding = variable.wrappedValue.binding {
                    Text("目前取用「\(EditorDataLabels.label(for: binding, live: model.live).title)」。")
                }
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .navigationTitle(variable.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

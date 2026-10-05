import SwiftUI

// MARK: - 何時顯示（2026-10 通用化，規劃第 4.3、6.2 節）
//
// 參考提醒事項的智慧型列表：一列一條「資料 › 比較 › 值」，比較依資料的型別出現；兩條以上可選全部符合或任一符合。
// 舊的「第 N 筆行程存在時」照樣可以選（舊設計用到的不會變）。

struct EditorVisibilitySection: View {
    @Binding var layer: FormlessLayer
    let live: FormlessLiveData
    @Environment(\.editorDataPanelOpener) private var openData

    private var conditions: [FormlessCondition] { layer.visibility?.conditions ?? [] }

    private var mode: Binding<String> {
        Binding(
            get: { !conditions.isEmpty ? "conditions" : (layer.dataIndex ?? "") },
            set: { value in
                switch value {
                case "conditions":
                    if conditions.isEmpty {
                        if layer.dataIndex != nil { layer.dataIndex = nil }
                        openData?(EditorDataPanelRequest(layerID: layer.id, target: .newCondition))
                    }
                case "":
                    var next = layer
                    next.dataIndex = nil
                    next.visibility = nil
                    layer = next
                default:
                    var next = layer
                    next.dataIndex = value
                    next.visibility = nil
                    layer = next
                }
            }
        )
    }

    var body: some View {
        Section {
            Picker("何時顯示", selection: mode) {
                Text("永遠顯示").tag("")
                Text("符合條件時").tag("conditions")
                Section("行程") {
                    Text("沒有行程時").tag("event0")
                    ForEach(1...5, id: \.self) { index in Text("第 \(index) 筆行程存在時").tag("event\(index)") }
                }
                Section("提醒事項") {
                    Text("沒有提醒事項時").tag("reminder0")
                    ForEach(1...3, id: \.self) { index in Text("第 \(index) 筆提醒事項存在時").tag("reminder\(index)") }
                }
                Section("天氣預報") {
                    Text("沒有預報時").tag("forecast0")
                    ForEach(1...5, id: \.self) { index in Text("第 \(index) 天預報存在時").tag("forecast\(index)") }
                }
            }
            if !conditions.isEmpty {
                if conditions.count >= 2 {
                    Picker("符合方式", selection: Binding(
                        get: { layer.visibility?.matchAll ?? true },
                        set: { layer.visibility?.matchAll = $0 })) {
                        Text("全部符合").tag(true)
                        Text("任一符合").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.vertical, 4)
                }
                ForEach(conditions) { condition in
                    EditorConditionRow(layer: $layer, condition: condition, live: live)
                }
                Button {
                    openData?(EditorDataPanelRequest(layerID: layer.id, target: .newCondition))
                } label: {
                    Label("加入條件", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            if !conditions.isEmpty {
                Text("目前結果：" + (live.matches(layer.visibility, at: Date()) ? "顯示" : "不顯示"))
            }
        }
    }
}

/// 一條條件：上面是資料（點了換資料），下面是比較與值；右上角移除。
struct EditorConditionRow: View {
    @Binding var layer: FormlessLayer
    let condition: FormlessCondition
    let live: FormlessLiveData
    @Environment(\.editorDataPanelOpener) private var openData

    private func update(_ change: (inout FormlessCondition) -> Void) {
        guard var set = layer.visibility, let index = set.conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        change(&set.conditions[index])
        layer.visibility = set
    }

    var body: some View {
        let spec = live.fieldSpec(condition.subject)
        let kind = spec?.kind ?? live.value(condition.subject, at: Date()).kind
        let label = EditorDataLabels.label(for: condition.subject, live: live)
        EditorFunctionRow {
            HStack(spacing: 8) {
                Button {
                    openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.conditionSubject(condition.id))))
                } label: {
                    EditorDataCapsule(symbol: label.symbol, title: label.title, menu: true)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button {
                    var next = layer
                    next.visibility?.conditions.removeAll { $0.id == condition.id }
                    if next.visibility?.conditions.isEmpty == true { next.visibility = nil }
                    layer = next
                } label: {
                    Image(systemName: "minus")
                        .font(FormlessDesign.Symbol.smallCircle)
                        .frame(width: FormlessDesign.Size.compactControl, height: FormlessDesign.Size.compactControl)
                        .background(FormlessDesign.Palette.tintFill, in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除條件")
            }
            .editorLine(.control)
            HStack(spacing: 8) {
                FormlessOptionMenu(options: FormlessComparison.options(for: kind).map { FormlessMenuOption(id: AnyHashable($0.rawValue), title: $0.displayName) },
                                   selection: AnyHashable(condition.comparison.rawValue),
                                   onSelect: { id in
                                       guard let raw = id.base as? String, let comparison = FormlessComparison(rawValue: raw) else { return }
                                       update { item in
                                           item.comparison = comparison
                                           if comparison == .timeOfDay {
                                               // 時段先放晚上 10 點到早上 6 點，再自己改。
                                               item.operand = .number(22 * 60)
                                               item.upper = .number(6 * 60)
                                           } else if comparison.takesOperand,
                                                     item.operand == nil
                                                     || (kind == .date && item.operand?.binding == nil && item.operand?.constant?.dateValue == nil) {
                                               // 從時段換回日期比較時，原本的分鐘數換成一個日期；和另一份資料比的保留。
                                               item.operand = kind == .text ? .value(.text("")) : kind == .date ? .value(.date(Date())) : .number(0)
                                           }
                                       }
                                   }) {
                    EditorDataCapsule(symbol: nil, title: condition.comparison.displayName, menu: true)
                }
                if condition.comparison == .timeOfDay {
                    timeField(condition.operand?.constant?.numberValue ?? 0) { minutes in update { $0.operand = .number(minutes) } }
                    Text("到").foregroundStyle(.secondary)
                    timeField(condition.upper?.constant?.numberValue ?? 0) { minutes in update { $0.upper = .number(minutes) } }
                } else if condition.comparison.takesOperand {
                    operandControl(kind: kind)
                    if condition.comparison == .between {
                        Text("到").foregroundStyle(.secondary)
                        numberField(condition.upper?.constant?.numberValue ?? 0) { value in update { $0.upper = .number(value) } }
                    }
                }
                Spacer(minLength: 0)
            }
            .editorLine(.control)
        }
    }

    @ViewBuilder private func operandControl(kind: FormlessValueKind?) -> some View {
        if let bound = condition.operand?.binding {
            let label = EditorDataLabels.label(for: bound, live: live)
            Button {
                openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.conditionOperand(condition.id))))
            } label: {
                EditorDataCapsule(symbol: label.symbol, title: label.title, menu: false)
            }
            .buttonStyle(.plain)
        } else {
            switch kind {
            case .text?, .symbol?, .color?, .image?:
                TextField("文字", text: Binding(
                    get: { condition.operand?.constant?.rawString ?? "" },
                    set: { text in update { $0.operand = .value(.text(text)) } }))
                    .submitLabel(.done)
                    .padding(.horizontal, 10)
                    .frame(minHeight: FormlessDesign.Size.compactControl)
                    .formlessGrayBox()
            case .date?:
                DatePicker("", selection: Binding(
                    get: { condition.operand?.constant?.dateValue ?? Date() },
                    set: { date in update { $0.operand = .value(.date(date)) } }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            default:
                numberField(condition.operand?.constant?.numberValue ?? 0) { value in update { $0.operand = .number(value) } }
            }
            // 和另一份資料比（例如「步數 ≥ 每日目標」）。
            Button {
                openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.conditionOperand(condition.id)),
                                                 kinds: kind.map { [$0] }))
            } label: {
                Image(systemName: "link")
                    .frame(width: FormlessDesign.Size.compactControl, height: FormlessDesign.Size.compactControl)
                    .formlessGrayBox()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("和一份資料比較")
        }
    }

    /// 時段的時間（時:分），存成從午夜起的分鐘數。
    private func timeField(_ minutes: Double, onCommit: @escaping (Double) -> Void) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        return DatePicker("", selection: Binding(
            get: { today.addingTimeInterval(minutes * 60) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                onCommit(Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
    }

    private func numberField(_ value: Double, onCommit: @escaping (Double) -> Void) -> some View {
        FormlessNumberField(value: value, format: { FormlessValueFormatter.fixed($0, decimals: $0.rounded() == $0 ? 0 : 2, grouping: false) },
                            onCommit: onCommit)
            .font(.body.monospacedDigit())
            .padding(.horizontal, 8)
            .frame(width: FormlessDesign.Size.fieldShort + 8)
            .frame(minHeight: FormlessDesign.Size.compactControl)
            .formlessGrayBox()
    }
}

/// 灰底膠囊：資料（圖示＋名稱）或比較方式；可以點的選單在右邊加上下箭頭。
struct EditorDataCapsule: View {
    let symbol: String?
    let title: String
    var menu = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.subheadline) }
            Text(title).lineLimit(1)
            if menu {
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(minHeight: FormlessDesign.Size.compactControl)
        .background(FormlessDesign.Palette.fill, in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
    }
}

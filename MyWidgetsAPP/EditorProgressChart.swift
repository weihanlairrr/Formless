import SwiftUI

// MARK: - 進度與圖表的內容、樣式（2026-10 通用化，規劃第 6.2 節）

extension FormlessLayer {
    /// 外觀方塊用：進度的軌道顏色。
    var progressTrackColorHex: String? {
        get { progress?.trackColorHex }
        set { var spec = progress ?? FormlessProgressSpec(); spec.trackColorHex = newValue; progress = spec }
    }

    /// 外觀方塊用：圖表的次要色（標籤、格線、圓餅的其他區塊）。
    var chartSecondaryColorHex: String? {
        get { chart?.secondaryColorHex }
        set { var spec = chart ?? FormlessChartSpec(); spec.secondaryColorHex = newValue; chart = spec }
    }
}

/// 一個數值：右邊是數字框，或取用的資料膠囊（點了開格式面板）；數字框旁的連結鈕改成取一份資料。
struct EditorOperandRow: View {
    let title: String
    let layerID: UUID
    let slot: EditorBindingSlot
    let operand: FormlessOperand?
    let fallback: Double
    let live: FormlessLiveData
    let onConstant: (Double) -> Void
    @Environment(\.editorDataPanelOpener) private var openData
    @Environment(\.editorFormatPanelOpener) private var openFormat

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: FormlessDesign.Space.tight)
            if let binding = operand?.binding {
                let label = EditorDataLabels.label(for: binding, live: live)
                Button { openFormat?(EditorFormatPanelRequest(layerID: layerID, slot: slot)) } label: {
                    EditorDataCapsule(symbol: label.symbol, title: label.title)
                }
                .buttonStyle(.plain)
                Text(live.text(binding, at: Date())).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else {
                FormlessNumberField(value: operand?.constant?.numberValue ?? fallback,
                                    format: { FormlessValueFormatter.fixed($0, decimals: $0.rounded() == $0 ? 0 : 2, grouping: false) },
                                    onCommit: onConstant)
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 10)
                    .frame(width: FormlessDesign.Size.fieldLong)
                    .frame(minHeight: FormlessDesign.Size.control)
                    .formlessGrayBox()
                Button {
                    openData?(EditorDataPanelRequest(layerID: layerID, target: .slot(slot), kinds: [.number, .duration]))
                } label: {
                    Image(systemName: "link")
                        .frame(width: FormlessDesign.Size.control, height: FormlessDesign.Size.control)
                        .formlessGrayBox()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + "取用資料")
            }
        }
    }
}

struct EditorProgressSection: View {
    @Binding var layer: FormlessLayer
    let live: FormlessLiveData

    private func change(_ edit: (inout FormlessProgressSpec) -> Void) {
        var spec = layer.progress ?? FormlessProgressSpec()
        edit(&spec)
        layer.progress = spec
    }

    var body: some View {
        let spec = layer.progress ?? FormlessProgressSpec()
        let percent = Int((FormlessProgressView.fraction(spec, live: live, date: Date()) * 100).rounded())
        Section {
            EditorOperandRow(title: "值", layerID: layer.id, slot: .progress("value"), operand: spec.value, fallback: 0, live: live) { value in
                change { $0.value = .number(value) }
            }
            EditorOperandRow(title: "目標", layerID: layer.id, slot: .progress("goal"), operand: spec.goal, fallback: 100, live: live) { value in
                change { $0.goal = .number(value) }
            }
            EditorOperandRow(title: "起點", layerID: layer.id, slot: .progress("minimum"), operand: spec.minimum, fallback: 0, live: live) { value in
                change { $0.minimum = value == 0 ? nil : .number(value) }
            }
        } footer: {
            Text("目前 \(percent)%。值、目標、起點可以填數字，或用右邊的連結鈕取一份資料（例如步數，與我的資料裡的每日目標）。")
        }
    }
}

struct EditorChartSection: View {
    @Binding var layer: FormlessLayer
    let live: FormlessLiveData
    @Environment(\.editorDataPanelOpener) private var openData

    private func change(_ edit: (inout FormlessChartSpec) -> Void) {
        var spec = layer.chart ?? FormlessChartSpec()
        edit(&spec)
        layer.chart = spec
    }

    var body: some View {
        let spec = layer.chart ?? FormlessChartSpec()
        let fields = spec.series.flatMap { live.fieldSpec($0)?.itemFields } ?? []
        Section {
            HStack(spacing: 8) {
                Text("資料")
                Spacer(minLength: FormlessDesign.Space.tight)
                Button {
                    openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.chartSeries), wantsList: true))
                } label: {
                    if let series = spec.series {
                        let label = EditorDataLabels.label(for: series, live: live)
                        EditorDataCapsule(symbol: label.symbol, title: label.title, menu: true)
                    } else {
                        EditorDataCapsule(symbol: "plus", title: "選擇資料")
                    }
                }
                .buttonStyle(.plain)
            }
            if !fields.isEmpty {
                Picker("數值", selection: Binding(get: { spec.valueField ?? "" }, set: { id in change { $0.valueField = id.isEmpty ? nil : id } })) {
                    ForEach(fields.filter { $0.kind == .number }) { Text($0.name).tag($0.id) }
                }
                Picker("標籤", selection: Binding(get: { spec.labelField ?? "" }, set: { id in change { $0.labelField = id.isEmpty ? nil : id } })) {
                    Text("自動").tag("")
                    ForEach(fields.filter { [.date, .text].contains($0.kind) }) { Text($0.name).tag($0.id) }
                }
            }
            EditorIntegerField(title: "最多幾筆", value: Binding(get: { spec.maxPoints ?? 12 }, set: { count in change { $0.maxPoints = count } }),
                               range: 1...60)
            Toggle("自訂範圍", isOn: Binding(
                get: { spec.minimum != nil || spec.maximum != nil },
                set: { custom in
                    let points = FormlessChartView.points(spec, live: live, date: Date()).map(\.value)
                    change {
                        $0.minimum = custom ? (points.min().map { min(0, $0.rounded(.down)) } ?? 0) : nil
                        $0.maximum = custom ? (points.max().map { $0.rounded(.up) } ?? 100) : nil
                    }
                }))
            if spec.minimum != nil || spec.maximum != nil {
                EditorStepperRow(title: "最小值", value: Binding(get: { spec.minimum ?? 0 }, set: { value in change { $0.minimum = value } }),
                                 range: -1_000_000...1_000_000, step: 1)
                EditorStepperRow(title: "最大值", value: Binding(get: { spec.maximum ?? 100 }, set: { value in change { $0.maximum = value } }),
                                 range: -1_000_000...1_000_000, step: 1)
            }
        } footer: {
            Text(spec.series == nil ? "選一份清單，例如計步器的每日紀錄、天氣的逐時預報。" : "沒有自訂範圍時，長條與面積從 0 開始，折線與點依資料的高低。")
        }
    }
}

// MARK: - 樣式面板的列

/// 進度的樣式：線形、環形、弧形、分段；粗細、端點、分段數。
struct EditorProgressStyleRows: View {
    @Binding var layer: FormlessLayer
    let padInsets: EdgeInsets

    private func change(_ edit: (inout FormlessProgressSpec) -> Void) {
        var spec = layer.progress ?? FormlessProgressSpec()
        edit(&spec)
        layer.progress = spec
    }

    var body: some View {
        let spec = layer.progress ?? FormlessProgressSpec()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(FormlessProgressSpec.Style.allCases) { style in
                Button { change { $0.style = style } } label: {
                    EditorAppearanceTileLabel(caption: style.displayName, selected: spec.style == style, previewHeight: 32) {
                        EditorProgressGlyph(style: style)
                    }
                }
                .buttonStyle(EditorTileButtonStyle())
                .accessibilityLabel(style.displayName)
                .accessibilityAddTraits(spec.style == style ? .isSelected : [])
            }
        }
        .listRowInsets(padInsets)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        EditorStepPad(title: "粗細", value: Binding(
            get: { spec.thickness ?? 0 },
            set: { value in change { $0.thickness = value <= 0 ? nil : value } }), range: 0...80, step: 1)
            .frame(maxWidth: .infinity)
            .listRowInsets(padInsets)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        if spec.style == .segments {
            HStack(spacing: 12) {
                EditorStepPad(title: "分段", value: Binding(
                    get: { Double(spec.segmentCount ?? 10) },
                    set: { value in change { $0.segmentCount = Int(value) } }), range: 2...60, step: 1)
                EditorStepPad(title: "間隔", value: Binding(
                    get: { spec.segmentGap ?? 3 },
                    set: { value in change { $0.segmentGap = value } }), range: 0...20, step: 0.5)
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(padInsets)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        HStack(spacing: 8) {
            EditorChoiceButton("圓頭", selected: spec.roundCaps ?? true) { change { $0.roundCaps = true } }
            EditorChoiceButton("平頭", selected: !(spec.roundCaps ?? true)) { change { $0.roundCaps = false } }
        }
        .padding(.vertical, 4)
    }
}

/// 進度樣式的小圖。
struct EditorProgressGlyph: View {
    let style: FormlessProgressSpec.Style

    var body: some View {
        switch style {
        case .linear:
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2)).frame(width: 34, height: 6)
                Capsule().fill(Color.primary).frame(width: 22, height: 6)
            }
        case .ring:
            ZStack {
                Circle().stroke(Color.primary.opacity(0.2), lineWidth: 4)
                Circle().trim(from: 0, to: 0.65).stroke(Color.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24)
        case .arc:
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Circle().trim(from: 0, to: 0.45).stroke(Color.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .rotationEffect(.degrees(135))
            .frame(width: 24, height: 24)
        case .segments:
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule().fill(index < 3 ? Color.primary : Color.primary.opacity(0.2)).frame(width: 5, height: 8)
                }
            }
        }
    }
}

/// 圖表的樣式：種類、線條粗細、間隔、標籤、格線、字級。
struct EditorChartStyleRows: View {
    @Binding var layer: FormlessLayer
    let padInsets: EdgeInsets

    private func change(_ edit: (inout FormlessChartSpec) -> Void) {
        var spec = layer.chart ?? FormlessChartSpec()
        edit(&spec)
        layer.chart = spec
    }

    var body: some View {
        let spec = layer.chart ?? FormlessChartSpec()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(FormlessChartSpec.Kind.allCases) { kind in
                Button { change { $0.kind = kind } } label: {
                    EditorAppearanceTileLabel(caption: kind.displayName, selected: spec.kind == kind, previewHeight: 32) {
                        Image(systemName: kind.symbol).font(.system(size: 22)).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(EditorTileButtonStyle())
                .accessibilityLabel(kind.displayName)
                .accessibilityAddTraits(spec.kind == kind ? .isSelected : [])
            }
        }
        .listRowInsets(padInsets)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        if spec.kind != .pie && spec.kind != .ring {
            HStack(spacing: 12) {
                EditorStepPad(title: spec.kind == .bar ? "圓角" : "粗細", value: Binding(
                    get: { spec.lineWidth ?? 2 },
                    set: { value in change { $0.lineWidth = value } }), range: 0.5...20, step: 0.5)
                if spec.kind == .bar {
                    EditorStepPad(title: "間隔", value: Binding(
                        get: { ((spec.spacing ?? 0.3) * 100).rounded() },
                        set: { value in change { $0.spacing = value / 100 } }), range: 0...90, step: 5, suffix: "%")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(padInsets)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            HStack(spacing: 8) {
                EditorChoiceButton("標籤", selected: spec.showsLabels == true) { change { $0.showsLabels = $0.showsLabels == true ? nil : true } }
                EditorChoiceButton("格線", selected: spec.showsGrid == true) { change { $0.showsGrid = $0.showsGrid == true ? nil : true } }
            }
            .padding(.vertical, 4)
            if spec.showsLabels == true {
                EditorStepPad(title: "字級", value: Binding(
                    get: { layer.fontSize ?? 10 },
                    set: { layer.fontSize = $0 }), range: 5...40, step: 0.5)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(padInsets)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
        }
    }
}

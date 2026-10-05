import SwiftUI

// MARK: - 指針時鐘與曲線文字的設定（2026-10，規劃第 3.2 節）

/// 時鐘 › 內容：刻度、數字、時區、粗細。顏色在「外觀」（時針、分針、刻度、錶盤）。
struct EditorClockSection: View {
    @Binding var layer: FormlessLayer

    private var spec: FormlessClockSpec { layer.clock ?? FormlessClockSpec() }

    private func update(_ change: (inout FormlessClockSpec) -> Void) {
        var next = spec
        change(&next)
        layer.clock = next
    }

    var body: some View {
        Section {
            Picker("刻度", selection: Binding(
                get: { spec.marks.flatMap(FormlessClockMarks.init(rawValue:)) ?? .hours },
                set: { value in update { $0.marks = value.rawValue } })) {
                ForEach(FormlessClockMarks.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("數字", selection: Binding(
                get: { spec.numerals.flatMap(FormlessClockNumerals.init(rawValue:)) ?? FormlessClockNumerals.none },
                set: { value in update { $0.numerals = value.rawValue } })) {
                ForEach(FormlessClockNumerals.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("時區", selection: Binding(
                get: { spec.timeZone ?? "" },
                set: { value in update { $0.timeZone = value.isEmpty ? nil : value } })) {
                ForEach(FormlessDateTimeProvider.timeZones) { zone in Text(zone.name).tag(zone.id) }
            }
            EditorStepperRow(title: "粗細", value: Binding(
                get: { spec.weight ?? 1 },
                set: { value in update { $0.weight = abs(value - 1) < 0.001 ? nil : value } }),
                             range: 0.5...2, step: 0.1)
        }
    }
}

/// 文字的排列：直線、沿圓弧上方、沿圓弧下方。圓是圖層框的內切圓，框越大越平。
struct EditorTextArcRow: View {
    let layer: Binding<FormlessLayer>

    private static let options: [(value: String?, name: String)] = [
        (nil, "直線"), (FormlessArcPlacement.top.rawValue, "上弧"), (FormlessArcPlacement.bottom.rawValue, "下弧")
    ]

    var body: some View {
        let current = layer.wrappedValue.textArc
        HStack(spacing: FormlessDesign.Space.tight) {
            ForEach(Self.options, id: \.name) { option in
                EditorChoiceButton(option.name, selected: current == option.value) {
                    layer.wrappedValue.textArc = option.value
                }
            }
        }
    }
}

// MARK: - 月曆格的延伸設定（2026-10，規劃第 3.2 節）

/// 月曆格 › 內容的第二張卡片：顯示哪個月、農曆、週數、依資料上色。週末顏色在「外觀」。
struct EditorCalendarGridOptionsSection: View {
    @Binding var layer: FormlessLayer
    let live: FormlessLiveData
    @Environment(\.editorDataPanelOpener) private var openData

    private var options: FormlessCalendarOptions { layer.calendarOptions ?? FormlessCalendarOptions() }

    private func update(_ change: (inout FormlessCalendarOptions) -> Void) {
        var next = options
        change(&next)
        layer.calendarOptions = next.isEmpty ? nil : next
    }

    private static let months: [(Int, String)] = [(-2, "上 2 個月"), (-1, "上個月"), (0, "這個月"), (1, "下個月"), (2, "下 2 個月"), (3, "下 3 個月")]

    var body: some View {
        Section {
            Picker("月份", selection: Binding(get: { options.monthOffset ?? 0 },
                                            set: { value in update { $0.monthOffset = value == 0 ? nil : value } })) {
                ForEach(Self.months, id: \.0) { Text($0.1).tag($0.0) }
            }
            Toggle("顯示農曆", isOn: Binding(get: { options.showsLunar == true },
                                          set: { on in update { $0.showsLunar = on ? true : nil } }))
            Toggle("顯示週數", isOn: Binding(get: { options.showsWeekNumbers == true },
                                          set: { on in update { $0.showsWeekNumbers = on ? true : nil } }))
            heatmapRows
        }
    }

    /// 依資料上色：選一份清單（行程、提醒、每日預報、步數紀錄…），每天依筆數或數值加深底色。
    @ViewBuilder private var heatmapRows: some View {
        if let binding = options.heatmap {
            let label = EditorDataLabels.label(for: binding, live: live)
            Button {
                openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.calendarHeatmap), wantsList: true))
            } label: {
                HStack {
                    Text("依資料上色").foregroundStyle(.primary)
                    Spacer(minLength: FormlessDesign.Space.valueGap)
                    Text(label.title).foregroundStyle(.secondary).lineLimit(1)
                    FormlessDisclosureIndicator()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let numbers = live.fieldSpec(binding)?.itemFields.filter { $0.kind == .number } ?? []
            Picker("依據", selection: Binding(get: { options.heatmapField ?? "" },
                                            set: { value in update { $0.heatmapField = value.isEmpty ? nil : value } })) {
                Text("筆數").tag("")
                ForEach(numbers) { Text($0.name).tag($0.id) }
            }
            Button("不依資料上色", role: .destructive) { update { $0.heatmap = nil; $0.heatmapField = nil } }
        } else {
            Button {
                openData?(EditorDataPanelRequest(layerID: layer.id, target: .slot(.calendarHeatmap), wantsList: true))
            } label: {
                HStack {
                    Text("依資料上色").foregroundStyle(.primary)
                    Spacer(minLength: FormlessDesign.Space.valueGap)
                    Text("選擇資料").foregroundStyle(.secondary)
                    FormlessDisclosureIndicator()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

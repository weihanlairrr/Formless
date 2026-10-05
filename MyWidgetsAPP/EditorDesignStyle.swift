import SwiftUI

// MARK: - 整份設計換字型、換顏色（2026-10，規劃 M7）
//
// 小工具設定 › 字型與顏色：一次把所有文字換成同一種字型，或把設計用到的某個顏色全部換成另一個顏色。
// 每一次更換是一步，可以復原。

/// 小工具設定裡的一列，點進去是字型與顏色頁。
struct EditorDesignStyleRow: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        NavigationLink {
            EditorDesignStylePage(model: model)
                .navigationTitle("字型與顏色")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent("字型與顏色", value: "\(EditorDesignStyle.colors(in: model.document).count) 種顏色")
        }
    }
}

enum EditorDesignStyle {
    /// 會畫字的圖層。
    static let textTypes: Set<FormlessLayerType> = [.text, .date, .time, .liveText, .calendarGrid, .eventList, .reminderList,
                                                    .weatherForecast, .calendar, .events, .reminders, .weather, .steps, .yearProgress]

    /// 顏色欄位（底色在設計本身）。
    static let colorKeys: [WritableKeyPath<FormlessLayer, String?>] = [
        \.colorHex, \.secondaryColorHex, \.textColorHex, \.panelColorHex, \.strokeColorHex, \.shadowColorHex
    ]

    /// 統一成大寫、不透明時去掉 FF，讓同一個顏色只算一次。auto（跟隨資料）與淺色深色兩個值不列入。
    static func normalized(_ hex: String?) -> String? {
        guard let hex, !hex.isEmpty, hex.lowercased() != "auto", FormlessDualColor.split(hex) == nil else { return nil }
        var clean = hex.uppercased()
        if !clean.hasPrefix("#") { clean = "#" + clean }
        if clean.count == 9, clean.hasSuffix("FF") { clean = String(clean.dropLast(2)) }
        guard clean.count == 7 || clean.count == 9 else { return nil }
        return clean
    }

    /// 設計用到的顏色，依出現次數由多到少。
    static func colors(in document: FormlessDocument) -> [(hex: String, count: Int)] {
        var counts: [String: Int] = [:]
        func add(_ hex: String?) { if let key = normalized(hex) { counts[key, default: 0] += 1 } }
        add(document.backgroundColorHex)
        for layer in document.layers where !layer.group {
            for key in colorKeys { add(layer[keyPath: key]) }
            for stop in layer.gradientStops ?? [] { add(stop.colorHex) }
            for rule in layer.colorRules ?? [] { add(rule.colorHex) }
            for stop in layer.colorScale?.stops ?? [] { add(stop.colorHex) }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.hex < $1.hex }
    }

    /// 把設計裡所有 from 換成 to（透明度跟著新的顏色）。
    static func replace(_ from: String, with to: String, in document: inout FormlessDocument) {
        func swap(_ hex: inout String?) { if normalized(hex) == from { hex = to } }
        func swapValue(_ hex: inout String) { if normalized(hex) == from { hex = to } }
        swap(&document.backgroundColorHex)
        for index in document.layers.indices where !document.layers[index].group {
            for key in colorKeys { swap(&document.layers[index][keyPath: key]) }
            if var stops = document.layers[index].gradientStops {
                for i in stops.indices { swapValue(&stops[i].colorHex) }
                document.layers[index].gradientStops = stops
            }
            if var rules = document.layers[index].colorRules {
                for i in rules.indices { swapValue(&rules[i].colorHex) }
                document.layers[index].colorRules = rules
            }
            if var scale = document.layers[index].colorScale {
                for i in scale.stops.indices { swapValue(&scale.stops[i].colorHex) }
                document.layers[index].colorScale = scale
            }
        }
    }
}

struct EditorDesignStylePage: View {
    @ObservedObject var model: EditorModel

    private var textLayers: [FormlessLayer] {
        model.document.layers.filter { !$0.group && EditorDesignStyle.textTypes.contains($0.type) }
    }

    /// 所有文字目前的字型；不一樣時是 nil（顯示「混合」）。
    private var currentFamily: String? {
        let families = Set(textLayers.map { $0.fontFamily ?? "system" })
        return families.count == 1 ? families.first : nil
    }

    var body: some View {
        Form {
            Section {
                Picker("所有文字的字型", selection: Binding(
                    get: { currentFamily ?? "" },
                    set: { family in
                        guard !family.isEmpty else { return }
                        var next = model.document
                        for index in next.layers.indices where !next.layers[index].group
                            && EditorDesignStyle.textTypes.contains(next.layers[index].type) {
                            next.layers[index].fontFamily = family == "system" ? nil : family
                        }
                        model.designBinding.wrappedValue = next
                    })) {
                    if currentFamily == nil { Text("混合").tag("") }
                    ForEach(formlessFontFamilyOptions) { option in Text(option.displayName).tag(option.id) }
                    ForEach(FormlessFontLibrary.installed()) { font in
                        Text(font.displayName).tag(FormlessFontLibrary.familyValue(for: font.postScriptName))
                    }
                }
                .disabled(textLayers.isEmpty)
            }
            Section {
                ForEach(EditorDesignStyle.colors(in: model.document), id: \.hex) { item in
                    ColorPicker(selection: Binding(
                        get: { Color(formlessHex: item.hex) },
                        set: { color in
                            var next = model.document
                            EditorDesignStyle.replace(item.hex, with: color.formlessHex, in: &next)
                            model.designBinding.wrappedValue = next
                        })) {
                        LabeledContent(item.hex, value: "\(item.count) 處")
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("換掉一個顏色時，設計裡所有用到它的地方一起換。")
            }
        }
    }
}

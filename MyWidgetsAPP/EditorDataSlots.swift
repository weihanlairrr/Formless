import SwiftUI

// MARK: - 資料放在圖層的哪裡（2026-10 通用化）
//
// 文字裡的一段、進度的值與目標、圖示、圖表、條件、我的資料……都是「一個位置放一份資料」。
// 選擇資料面板與格式面板只認位置，讀寫都經過 EditorModel，一次修改是一步復原。

enum EditorBindingSlot: Hashable {
    /// 文字的第幾段。
    case segment(Int)
    /// 進度的 value、goal、minimum。
    case progress(String)
    case symbol
    case chartSeries
    case conditionSubject(UUID)
    case conditionOperand(UUID)
    case colorRuleSubject(Int)
    case colorRuleThreshold(Int)
    /// 色階依據的數字。
    case colorScale
    /// 月曆格依資料上色的清單。
    case calendarHeatmap
    case repeatCollection
    /// 點一下開的網址。
    case url
    /// 主要顏色取用資料。
    case color
    /// 我的資料取用的資料（設計層級）。
    case variable(UUID)
}

/// 選好的資料要做什麼。
enum EditorDataTarget: Hashable {
    /// 在文字的第幾段之前插入（nil 加在最後）。
    case insertSegment(Int?)
    /// 新增一條顯示條件。
    case newCondition
    case slot(EditorBindingSlot)
}

struct EditorDataPanelRequest: Identifiable, Equatable {
    let id = UUID()
    /// 設計層級的位置（我的資料）是 nil。
    let layerID: UUID?
    let target: EditorDataTarget
    /// 只列這些型別的資料；nil 不限。
    var kinds: Set<FormlessValueKind>? = nil
    /// 要整份清單（圖表、重複排列）。
    var wantsList = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct EditorFormatPanelRequest: Identifiable, Equatable {
    let id = UUID()
    let layerID: UUID?
    let slot: EditorBindingSlot

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    /// 打開選擇資料面板（由屬性面板提供）。
    @Entry var editorDataPanelOpener: ((EditorDataPanelRequest) -> Void)? = nil
    /// 打開格式面板。
    @Entry var editorFormatPanelOpener: ((EditorFormatPanelRequest) -> Void)? = nil
}

// MARK: - 讀寫

extension FormlessLayer {
    /// 文字的段落：還沒有段落的文字圖層，原本的文字就是唯一的一段。
    var editorSegments: [FormlessTextSegment] {
        if let segments, !segments.isEmpty { return segments }
        let text = value ?? ""
        return text.isEmpty ? [] : [.text(text)]
    }

    /// 寫入段落，同時把 value 換成目前的完整文字（舊版 App 打開時至少看得到當下的樣子）。
    /// 只剩固定字時回到單純的文字圖層（segments 清掉），和原本的文字圖層完全相同。
    mutating func editorSetSegments(_ segments: [FormlessTextSegment], live: FormlessLiveData) {
        var merged: [FormlessTextSegment] = []
        for segment in segments {
            if case .text(let next) = segment, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + next)
            } else if case .text(let text) = segment, text.isEmpty {
                continue
            } else {
                merged.append(segment)
            }
        }
        if merged.allSatisfy({ $0.binding == nil }) {
            self.segments = nil
            value = merged.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
        } else {
            self.segments = merged
            value = live.text(merged, at: Date())
        }
    }
}

extension EditorModel {

    /// 這個位置目前的資料。
    func dataBinding(at slot: EditorBindingSlot, layerID: UUID?) -> FormlessBinding? {
        if case .variable(let id) = slot { return document.variables?.first { $0.id == id }?.binding }
        guard let layerID, let layer = document.layers.first(where: { $0.id == layerID }) else { return nil }
        switch slot {
        case .segment(let index):
            let segments = layer.editorSegments
            return segments.indices.contains(index) ? segments[index].binding : nil
        case .progress(let key):
            guard let progress = layer.progress else { return nil }
            switch key {
            case "goal": return progress.goal.binding
            case "minimum": return progress.minimum?.binding
            default: return progress.value.binding
            }
        case .symbol: return layer.bindings?[FormlessBindableProperty.symbol.rawValue]
        case .chartSeries: return layer.chart?.series
        case .conditionSubject(let id): return layer.visibility?.conditions.first { $0.id == id }?.subject
        case .conditionOperand(let id): return layer.visibility?.conditions.first { $0.id == id }?.operand?.binding
        case .colorRuleSubject(let index):
            let rules = layer.colorRules ?? []
            return rules.indices.contains(index) ? rules[index].subject : nil
        case .colorRuleThreshold(let index):
            let rules = layer.colorRules ?? []
            return rules.indices.contains(index) ? rules[index].threshold?.binding : nil
        case .repeatCollection: return layer.repeatSpec?.collection
        case .url: return layer.bindings?[FormlessBindableProperty.url.rawValue]
        case .color: return layer.bindings?[FormlessBindableProperty.color.rawValue]
        case .colorScale: return layer.colorScale?.subject
        case .calendarHeatmap: return layer.calendarOptions?.heatmap
        case .variable: return nil
        }
    }

    /// 改這個位置的資料；nil 是拿掉（文字的那一段刪除、進度回到數字、圖示回到固定的圖示）。
    func setDataBinding(_ binding: FormlessBinding?, at slot: EditorBindingSlot, layerID: UUID?) {
        if case .variable(let id) = slot {
            var next = document
            guard let index = next.variables?.firstIndex(where: { $0.id == id }) else { return }
            next.variables?[index].binding = binding
            if let binding, let kind = live.fieldSpec(binding)?.kind { next.variables?[index].kind = kind }
            designBinding.wrappedValue = next
            return
        }
        guard let layerID else { return }
        let target = layerBinding(layerID)
        var layer = target.wrappedValue
        switch slot {
        case .segment(let index):
            var segments = layer.editorSegments
            guard segments.indices.contains(index) else { return }
            if let binding { segments[index] = .data(binding) } else { segments.remove(at: index) }
            layer.editorSetSegments(segments, live: live)
        case .progress(let key):
            var progress = layer.progress ?? FormlessProgressSpec()
            let constant = live.number(dataBinding(at: slot, layerID: layerID).map(FormlessOperand.binding), at: Date())
            let operand: FormlessOperand = binding.map(FormlessOperand.binding) ?? .number((constant ?? 0).rounded())
            switch key {
            case "goal": progress.goal = operand
            case "minimum": progress.minimum = binding == nil ? nil : operand
            default: progress.value = operand
            }
            layer.progress = progress
        case .symbol:
            var bindings = layer.bindings ?? [:]
            bindings[FormlessBindableProperty.symbol.rawValue] = binding
            layer.bindings = bindings.isEmpty ? nil : bindings
        case .url:
            var bindings = layer.bindings ?? [:]
            bindings[FormlessBindableProperty.url.rawValue] = binding
            layer.bindings = bindings.isEmpty ? nil : bindings
        case .color:
            var bindings = layer.bindings ?? [:]
            bindings[FormlessBindableProperty.color.rawValue] = binding
            layer.bindings = bindings.isEmpty ? nil : bindings
        case .chartSeries:
            var chart = layer.chart ?? FormlessChartSpec()
            chart.series = binding
            if let binding, let spec = live.fieldSpec(binding) {
                // 選了清單之後，數值欄位與標籤欄位先挑第一個合用的。
                chart.valueField = spec.itemFields.first { $0.kind == .number }?.id
                chart.labelField = spec.itemFields.first { $0.kind == .date }?.id ?? spec.itemFields.first { $0.kind == .text }?.id
            }
            layer.chart = chart
        case .conditionSubject(let id):
            guard var set = layer.visibility, let index = set.conditions.firstIndex(where: { $0.id == id }) else { return }
            if let binding {
                set.conditions[index].subject = binding
                let options = FormlessComparison.options(for: live.fieldSpec(binding)?.kind)
                if !options.contains(set.conditions[index].comparison) {
                    set.conditions[index].comparison = options.first ?? .isNotEmpty
                }
            } else {
                set.conditions.remove(at: index)
            }
            layer.visibility = set.conditions.isEmpty ? nil : set
        case .conditionOperand(let id):
            guard var set = layer.visibility, let index = set.conditions.firstIndex(where: { $0.id == id }) else { return }
            set.conditions[index].operand = binding.map(FormlessOperand.binding) ?? .value(.number(0, .none))
            layer.visibility = set
        case .colorRuleSubject(let index):
            guard var rules = layer.colorRules, rules.indices.contains(index), let binding else { return }
            rules[index].subject = binding
            layer.colorRules = rules
        case .colorRuleThreshold(let index):
            guard var rules = layer.colorRules, rules.indices.contains(index) else { return }
            rules[index].threshold = binding.map(FormlessOperand.binding)
            layer.colorRules = rules
        case .calendarHeatmap:
            var options = layer.calendarOptions ?? FormlessCalendarOptions()
            options.heatmap = binding
            if binding == nil { options.heatmapField = nil }
            layer.calendarOptions = options.isEmpty ? nil : options
        case .colorScale:
            if let binding {
                if var scale = layer.colorScale {
                    scale.subject = binding
                    layer.colorScale = scale
                } else {
                    layer.colorScale = Self.defaultScale(for: binding, base: layer.colorHex, live: live)
                }
            } else {
                layer.colorScale = nil
            }
        case .repeatCollection:
            if let binding {
                var spec = layer.repeatSpec ?? FormlessRepeatSpec(collection: binding)
                spec.collection = binding
                layer.repeatSpec = spec
            } else {
                layer.repeatSpec = nil
            }
        case .variable:
            return
        }
        target.wrappedValue = layer
    }

    /// 剛建立的色階：依資料的單位給合理的兩端（百分比 0～100、溫度 15～35°，其他從 0 到目前值的兩倍），
    /// 小的一端是平常的顏色、大的一端是橘紅色，之後再自己調。
    static func defaultScale(for binding: FormlessBinding, base: String?, live: FormlessLiveData) -> FormlessColorScale {
        let value = live.value(binding, at: Date())
        let range: (Double, Double)
        switch value.unit {
        case .percent: range = (0, 100)
        case .celsius: range = (15, 35)
        default:
            let current = abs(value.numberValue ?? 10)
            range = (0, max(10, (current * 2).rounded()))
        }
        let low = FormlessDualColor.light(base).flatMap { $0.lowercased() == "auto" ? nil : $0 } ?? "#007AFF"
        return FormlessColorScale(subject: binding, stops: [FormlessColorScaleStop(value: range.0, colorHex: low),
                                                            FormlessColorScaleStop(value: range.1, colorHex: "#FF3B30")])
    }

    /// 選擇資料面板選好之後。
    func applyData(_ binding: FormlessBinding, request: EditorDataPanelRequest) {
        switch request.target {
        case .slot(let slot):
            setDataBinding(binding, at: slot, layerID: request.layerID)
        case .insertSegment(let offset):
            guard let id = request.layerID else { return }
            let target = layerBinding(id)
            var layer = target.wrappedValue
            layer.editorSetSegments(Self.inserting(.data(binding), into: layer.editorSegments, at: offset), live: live)
            target.wrappedValue = layer
        case .newCondition:
            guard let id = request.layerID else { return }
            let target = layerBinding(id)
            var layer = target.wrappedValue
            var set = layer.visibility ?? FormlessConditionSet()
            let kind = live.fieldSpec(binding)?.kind
            let comparison = FormlessComparison.options(for: kind).first ?? .isNotEmpty
            let operand: FormlessOperand? = comparison.takesOperand
                ? (kind == .number || kind == .list ? .number(live.value(binding, at: Date()).numberValue?.rounded() ?? 0) : .value(.text("")))
                : nil
            set.conditions.append(FormlessCondition(subject: binding, comparison: comparison, operand: operand))
            layer.visibility = set
            target.wrappedValue = layer
        }
        // 用到新的來源時先抓一次，畫布馬上看得到值。
        Task { await refreshDataSnapshots() }
    }

    /// 在游標的位置插入一段：offset 以輸入框裡的字數計（UTF-16，膠囊算一個字）；nil 加在最後。
    /// 游標在一段文字中間時把那段切開。
    static func inserting(_ piece: FormlessTextSegment, into segments: [FormlessTextSegment], at offset: Int?) -> [FormlessTextSegment] {
        guard var remaining = offset else { return segments + [piece] }
        var result: [FormlessTextSegment] = []
        var inserted = false
        for segment in segments {
            guard !inserted else { result.append(segment); continue }
            switch segment {
            case .data:
                if remaining <= 0 { result.append(piece); inserted = true }
                remaining -= 1
                result.append(segment)
            case .text(let text):
                let units = Array(text.utf16)
                if remaining <= units.count {
                    let head = String(utf16CodeUnits: Array(units[0..<max(0, remaining)]), count: max(0, remaining))
                    let tail = String(utf16CodeUnits: Array(units[max(0, remaining)...]), count: units.count - max(0, remaining))
                    if !head.isEmpty { result.append(.text(head)) }
                    result.append(piece)
                    if !tail.isEmpty { result.append(.text(tail)) }
                    inserted = true
                } else {
                    remaining -= units.count
                    result.append(segment)
                }
            }
        }
        if !inserted { result.append(piece) }
        return result
    }

    /// 抓這份設計用到、還沒有或過期的資料，抓完更新畫布。
    func refreshDataSnapshots(force: Bool = false) async {
        let snapshot = document
        await FormlessDataCoordinator.warm([snapshot], force: force)
        let loaded = await Task.detached { FormlessDataCoordinator.snapshots(for: snapshot) }.value
        guard snapshot.id == document.id else { return }
        var next = live
        next.adopt(document)
        next.snapshots.merge(loaded) { _, new in new }
        if next != live { live = next }
    }
}

// MARK: - 名稱

enum EditorDataLabels {

    /// 來源在畫面上的名稱：自己取的名字，或「天氣・東京」；App 預設只寫資料的名字。
    static func name(of source: FormlessSource) -> String {
        if let name = source.name, !name.isEmpty { return name }
        guard let provider = FormlessProviders.provider(source.provider) else { return "找不到這份資料" }
        if source.isAppDefault { return provider.name }
        let summary = provider.summary(for: source)
        return summary.isEmpty ? provider.name : provider.name + "・" + summary
    }

    static func symbol(of source: FormlessSource) -> String {
        FormlessProviders.provider(source.provider)?.symbol ?? "questionmark.circle"
    }

    /// 文字裡的資料膠囊、條件列顯示的名稱與圖示。
    static func label(for binding: FormlessBinding, live: FormlessLiveData) -> (symbol: String, title: String) {
        switch binding.source {
        case FormlessBindingSource.variable:
            return ("pencil", live.variable(binding.field)?.name ?? "找不到這份資料")
        case FormlessBindingSource.item:
            return ("list.bullet", "這一筆・" + itemFieldName(binding.field))
        default:
            guard let source = live.source(binding.source), let provider = FormlessProviders.provider(source.provider) else {
                return ("exclamationmark.triangle", "找不到這份資料")
            }
            let fields = provider.fields(for: source, snapshot: live.snapshot(for: source))
            let field = fields.first { $0.id == binding.field }
            var title = field?.name ?? binding.field
            if let index = binding.index {
                title += " \(index)"
            }
            if let item = field?.itemField(binding.itemField) {
                title += "・" + item.name
            }
            if !source.isAppDefault {
                title = (source.name ?? provider.summary(for: source)) + "・" + title
            }
            return (provider.symbol, title)
        }
    }

    /// 「這一筆」的欄位名稱：從各資料清單的欄位說明找（標題、開始時間…）。
    static func itemFieldName(_ id: String) -> String {
        for provider in FormlessProviders.all {
            for field in provider.fields(for: .appDefault(provider.id), snapshot: nil) {
                if let item = field.itemFields.first(where: { $0.id == id }) { return item.name }
            }
        }
        return id
    }

    /// 狀態的說明（編輯器用語，規劃第 6.5 節）。
    static func status(_ status: FormlessDataStatus, provider: (any FormlessDataProvider)?) -> String? {
        switch status {
        case .ok, .empty: return nil
        case .loading: return "正在取得資料…"
        case .unauthorized:
            switch provider?.id {
            case "calendar": return "需要行事曆權限"
            case "reminders": return "需要提醒事項權限"
            case "activity": return "需要動作與健身權限"
            case "place": return "需要位置權限"
            default: return "需要權限"
            }
        case .unsupported: return "此安裝方式無法讀取這項資料"
        case .failed: return "暫時無法更新，顯示上次的資料"
        case .notConfigured: return "尚未設定"
        }
    }

    /// 「5 分鐘前更新」。
    static func updated(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "剛剛更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分鐘前更新" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小時前更新" }
        return "\(Int(seconds / 86_400)) 天前更新"
    }
}

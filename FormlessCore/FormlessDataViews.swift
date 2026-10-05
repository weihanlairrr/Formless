import SwiftUI
import Charts

// MARK: - 文字的其他樣式
//
// 沒有設定的項目完全不套用修飾，舊設計畫出來和原本逐像素相同。

struct FormlessTextDecoration: ViewModifier {
    let layer: FormlessLayer
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .modifier(Optional(layer.tracking.map { Tracking(value: $0 * scale) }))
            .modifier(Optional(layer.lineSpacing.map { LineSpacing(value: $0 * scale) }))
            .modifier(Optional(layer.italic == true ? Italic() : nil))
            .modifier(Optional(layer.underline == true ? Underline() : nil))
            .modifier(Optional(layer.strikethrough == true ? Strikethrough() : nil))
    }

    private struct Optional<M: ViewModifier>: ViewModifier {
        let wrapped: M?
        init(_ wrapped: M?) { self.wrapped = wrapped }
        func body(content: Content) -> some View {
            if let wrapped { content.modifier(wrapped) } else { content }
        }
    }
    private struct Tracking: ViewModifier {
        let value: CGFloat
        func body(content: Content) -> some View { content.tracking(value) }
    }
    private struct LineSpacing: ViewModifier {
        let value: CGFloat
        func body(content: Content) -> some View { content.lineSpacing(value) }
    }
    private struct Italic: ViewModifier { func body(content: Content) -> some View { content.italic() } }
    private struct Underline: ViewModifier { func body(content: Content) -> some View { content.underline() } }
    private struct Strikethrough: ViewModifier { func body(content: Content) -> some View { content.strikethrough() } }
}

extension FormlessLayer {
    /// 文字最多幾行：沒設定是 1 行（舊設計都是單行），0 是不限。
    var textLineLimit: Int { lineLimit ?? 1 }
}

// MARK: - 圖層效果
//
// 模糊、混合模式、翻轉。沒有設定的完全不套用。

enum FormlessBlendOption: String, CaseIterable, Identifiable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference, exclusion
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "正常"
        case .multiply: return "色彩增值"
        case .screen: return "濾色"
        case .overlay: return "覆蓋"
        case .darken: return "變暗"
        case .lighten: return "變亮"
        case .colorDodge: return "加亮顏色"
        case .colorBurn: return "加深顏色"
        case .softLight: return "柔光"
        case .hardLight: return "實光"
        case .difference: return "差異化"
        case .exclusion: return "排除"
        }
    }

    var mode: BlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        }
    }
}

struct FormlessLayerEffects: ViewModifier {
    let layer: FormlessLayer
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .modifier(Flip(horizontal: layer.flipHorizontal == true, vertical: layer.flipVertical == true))
            .modifier(Blur(radius: max(0, (layer.blur ?? 0)) * scale))
            .modifier(Blend(option: layer.blendMode.flatMap(FormlessBlendOption.init(rawValue:))))
    }

    private struct Flip: ViewModifier {
        let horizontal: Bool
        let vertical: Bool
        func body(content: Content) -> some View {
            if horizontal || vertical {
                content.scaleEffect(x: horizontal ? -1 : 1, y: vertical ? -1 : 1)
            } else {
                content
            }
        }
    }

    private struct Blur: ViewModifier {
        let radius: CGFloat
        func body(content: Content) -> some View {
            if radius > 0 { content.blur(radius: radius) } else { content }
        }
    }

    private struct Blend: ViewModifier {
        let option: FormlessBlendOption?
        func body(content: Content) -> some View {
            if let option, option != .normal { content.blendMode(option.mode) } else { content }
        }
    }
}

// MARK: - 進度

struct FormlessProgressView: View {
    let layer: FormlessLayer
    let size: CGSize
    let scale: CGFloat
    let date: Date
    let live: FormlessLiveData
    let colorHex: String?

    /// 0–1：(值 − 起點) ÷ (目標 − 起點)。拿不到值時是 0。
    static func fraction(_ spec: FormlessProgressSpec, live: FormlessLiveData, date: Date) -> Double {
        let minimum = live.number(spec.minimum, at: date) ?? 0
        let goal = live.number(spec.goal, at: date) ?? 100
        guard let value = live.number(spec.value, at: date), goal != minimum else { return 0 }
        return min(max((value - minimum) / (goal - minimum), 0), 1)
    }

    static let defaultTrackHex = "#78788033"

    var body: some View {
        let spec = layer.progress ?? FormlessProgressSpec()
        let fraction = Self.fraction(spec, live: live, date: date)
        let fill = Color(formlessHex: colorHex, fallback: "#007AFF")
        let track = Color(formlessHex: spec.trackColorHex, fallback: Self.defaultTrackHex)
        let round = spec.roundCaps ?? true

        switch spec.style {
        case .linear:
            let thickness = min(size.height, spec.thickness.map { max(1, $0 * scale) } ?? size.height)
            ZStack(alignment: .leading) {
                bar(track, round: round).frame(width: size.width, height: thickness)
                if fraction > 0 {
                    bar(fill, round: round).frame(width: max(round ? thickness : 1, size.width * fraction), height: thickness)
                }
            }
            .frame(width: size.width, height: size.height)

        case .ring, .arc:
            let side = min(size.width, size.height)
            let thickness = min(side / 2, spec.thickness.map { max(1, $0 * scale) } ?? side * 0.12)
            let span = spec.style == .ring ? 1.0 : 0.75
            let rotation = spec.style == .ring ? -90.0 : 135.0
            let stroke = StrokeStyle(lineWidth: thickness, lineCap: round ? .round : .butt)
            ZStack {
                Circle().trim(from: 0, to: span).stroke(track, style: stroke)
                if fraction > 0 {
                    Circle().trim(from: 0, to: span * fraction).stroke(fill, style: stroke)
                }
            }
            .rotationEffect(.degrees(rotation))
            .frame(width: side - thickness, height: side - thickness)
            .frame(width: size.width, height: size.height)

        case .segments:
            let count = max(1, min(spec.segmentCount ?? 10, 60))
            let gap = max(0, (spec.segmentGap ?? 3) * scale)
            let filled = Int((fraction * Double(count) + 1e-9).rounded(.down))
            let thickness = min(size.height, spec.thickness.map { max(1, $0 * scale) } ?? size.height)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    bar(index < filled ? fill : track, round: round).frame(height: thickness)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private func bar(_ color: Color, round: Bool) -> some View {
        if round { Capsule(style: .continuous).fill(color) } else { Rectangle().fill(color) }
    }
}

// MARK: - 圖表

struct FormlessChartView: View {
    let layer: FormlessLayer
    let size: CGSize
    let scale: CGFloat
    let date: Date
    let live: FormlessLiveData
    let colorHex: String?

    struct Point: Identifiable, Hashable {
        let id: Int
        let value: Double
        let label: String
    }

    /// 清單轉成圖上的點：每一筆取數值欄位，標籤用標籤欄位（日期顯示成星期或時間）。
    static func points(_ spec: FormlessChartSpec, live: FormlessLiveData, date: Date) -> [Point] {
        guard let series = spec.series else { return [] }
        let items = live.value(series, at: date).listValue ?? []
        let limit = max(1, min(spec.maxPoints ?? 12, 60))
        // 都是過去的日期（每日紀錄）取最後幾筆，其他（預報、行程）取最前面幾筆。
        let dated = items.compactMap { $0.recordValue?[spec.labelField ?? "date"].dateValue ?? $0.recordValue?["time"].dateValue }
        let past = !dated.isEmpty && dated.count == items.count && dated.allSatisfy { $0 <= date }
        let chosen = past ? Array(items.suffix(limit)) : Array(items.prefix(limit))
        return chosen.enumerated().compactMap { index, item in
            let raw: FormlessValue = spec.valueField.map { item.recordValue?[$0] ?? .empty } ?? item
            guard let number = raw.numberValue else { return nil }
            let value = raw.unit == .celsius ? FormlessWeatherStyle.temperature(number) : number
            return Point(id: index, value: value, label: label(item, field: spec.labelField))
        }
    }

    static func label(_ item: FormlessValue, field: String?) -> String {
        guard let record = item.recordValue else { return "" }
        let key = field ?? (record["date"].isEmpty ? (record["time"].isEmpty ? "label" : "time") : "date")
        switch record[key] {
        case .date(let day, let allDay):
            return FormlessValueFormatter.formatter(pattern: allDay ? "EEEEE" : "H", timeZone: nil, calendar: nil).string(from: day)
        case .empty: return ""
        case let other: return other.rawString ?? ""
        }
    }

    var body: some View {
        let spec = layer.chart ?? FormlessChartSpec()
        let points = Self.points(spec, live: live, date: date)
        let fill = Color(formlessHex: colorHex, fallback: "#007AFF")
        let secondary = Color(formlessHex: spec.secondaryColorHex, fallback: "#8E8E93")
        // 字級跟著畫布縮放（縮圖裡也一樣小），不設下限。
        let fontSize = max(1, (layer.fontSize ?? 10) * scale)
        let lineWidth = max(1, (spec.lineWidth ?? 2) * scale)

        Group {
            if points.isEmpty {
                // 沒有資料：一條淡淡的基準線，讓編輯器看得到、點得到這個圖層。
                Capsule().fill(secondary.opacity(0.35)).frame(height: max(1, scale))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                switch spec.kind {
                case .pie, .ring:
                    Chart(points) { point in
                        SectorMark(angle: .value("值", max(point.value, 0)),
                                   innerRadius: spec.kind == .ring ? .ratio(0.62) : .ratio(0),
                                   angularInset: 1)
                            .foregroundStyle(fill.opacity(1 - Double(point.id % 6) * 0.14))
                    }
                default:
                    cartesian(points, spec: spec, fill: fill, lineWidth: lineWidth)
                        .chartXAxis {
                            if spec.showsLabels == true {
                                AxisMarks(values: .automatic) { value in
                                    AxisValueLabel {
                                        if let index = value.as(Int.self), points.indices.contains(index) {
                                            Text(points[index].label).font(.system(size: fontSize)).foregroundStyle(secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .chartYAxis {
                            if spec.showsGrid == true {
                                AxisMarks { _ in AxisGridLine().foregroundStyle(secondary.opacity(0.4)) }
                            }
                        }
                        .chartYScale(domain: domain(points, spec: spec))
                        .chartXScale(domain: -0.5...(Double(points.count) - 0.5))
                        .chartLegend(.hidden)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 長條與面積從 0 開始；折線與點依資料的高低，上下各留一成，線才看得出起伏。
    private func domain(_ points: [Point], spec: FormlessChartSpec) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let minimum = values.min() ?? 0, maximum = values.max() ?? 1
        let fromZero = spec.kind == .bar || spec.kind == .area
        let padding = fromZero ? 0 : max((maximum - minimum) * 0.15, 0.5)
        let low = spec.minimum ?? (fromZero ? min(0, minimum) : minimum - padding)
        var high = spec.maximum ?? (maximum + padding)
        if high <= low { high = low + 1 }
        return low...high
    }

    @ChartContentBuilder
    private func marks(_ point: Point, spec: FormlessChartSpec, fill: Color, lineWidth: CGFloat) -> some ChartContent {
        switch spec.kind {
        case .line:
            LineMark(x: .value("項目", point.id), y: .value("值", point.value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(fill)
        case .area:
            AreaMark(x: .value("項目", point.id), y: .value("值", point.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [fill.opacity(0.55), fill.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("項目", point.id), y: .value("值", point.value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(fill)
        case .point:
            PointMark(x: .value("項目", point.id), y: .value("值", point.value))
                .symbolSize(lineWidth * lineWidth * 9)
                .foregroundStyle(fill)
        default:
            BarMark(x: .value("項目", point.id), y: .value("值", point.value),
                    width: .ratio(1 - min(max(spec.spacing ?? 0.3, 0), 0.9)))
                .cornerRadius(lineWidth)
                .foregroundStyle(fill)
        }
    }

    private func cartesian(_ points: [Point], spec: FormlessChartSpec, fill: Color, lineWidth: CGFloat) -> some View {
        Chart(points) { point in
            marks(point, spec: spec, fill: fill, lineWidth: lineWidth)
        }
    }
}

// MARK: - 按鈕改過的我的資料

/// 小工具按鈕（切換、加減）改的是這裡，不改設計檔：同一份設計放好幾個小工具時共用同一份狀態，
/// 編輯器裡改設計也不會被按鈕蓋掉。
enum FormlessVariableStore {
    static func fileName(_ document: UUID) -> String { "state-\(document.uuidString).json" }

    static func values(for document: UUID) -> [String: FormlessValue] {
        FormlessCache.load([String: FormlessValue].self, name: fileName(document)) ?? [:]
    }

    static func set(_ value: FormlessValue?, variable: UUID, document: UUID) {
        var all = values(for: document)
        all[variable.uuidString] = value
        FormlessCache.save(all, name: fileName(document))
    }

    static func reset(document: UUID) {
        FormlessCache.save([String: FormlessValue](), name: fileName(document))
    }
}

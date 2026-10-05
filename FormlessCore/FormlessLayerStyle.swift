import Foundation

// MARK: - 拷貝樣式、貼上樣式（2026-10，規劃 M7 重用與分享）
//
// 圖層「⋯」›「拷貝樣式」記下外觀，「貼上樣式」貼到另一個圖層。樣式是外觀分頁裡的那些值：顏色、字型、字級、粗細、
// 對齊、字距、行距、斜體底線刪除線、外框、陰影、透明度、效果（模糊、混合、翻轉）、圓角、填色與漸層；
// 不含內容、位置大小（旋轉也是位置）、資料（條件顏色、色階、取用資料的顏色都是資料）。
// 只貼到對方用得到的欄位：文字的字型不貼到圖片，色塊的漸層不貼到文字，元件各部位的顏色只貼到同一種元件。
// 放在 FormlessCore 是為了讓命令列測試驗證「只動對的欄位」；記在哪裡（App 內的記憶）由 App 決定。

/// 樣式的一組欄位，對應外觀分頁裡的一個設定。
enum FormlessStyleGroup: String, Codable, CaseIterable, Sendable {
    /// 主要顏色（文字色、色塊的單色、圖示色、進度色、時針、元件的強調色）。
    case color
    /// 各部位的顏色（時鐘的分針、刻度、錶盤；進度的軌道色；圖表的次要色；月曆格的週末；圖示的上色方式與第二顏色；
    /// 月曆、行程這類元件的次要色與底色）。
    case partColors
    /// 字型、字級、粗細、對齊、字距、行距、斜體、底線、刪除線。
    case text
    case stroke
    case shadow
    case opacity
    /// 模糊、混合模式、水平與垂直翻轉。
    case effects
    case corner
    /// 色塊的填色方式與漸層（顏色點、角度、半徑）。
    case fill
}

/// 拷貝下來的樣式。
struct FormlessLayerStyle: Codable, Hashable, Sendable {
    /// 拷貝來源的圖層種類：決定字型、各部位顏色、圓角能貼到哪些圖層。
    var sourceType: FormlessLayerType
    /// 來源圖層有用到、記下來的那幾組。
    var groups: [FormlessStyleGroup]
    /// 只有樣式欄位的圖層（其他欄位是預設值）：欄位名稱和設計檔相同，不必另外定一套格式。
    var values: FormlessLayer

    /// 記下 layer 的樣式：只記它用得到的那幾組。
    init(capturing layer: FormlessLayer) {
        sourceType = layer.type
        groups = FormlessStyleGroup.allCases.filter { $0.isCaptured(from: layer) }
        var values = FormlessLayer(id: layer.id, type: layer.type)
        for group in groups { group.copy(from: layer, to: &values, targetType: layer.type) }
        self.values = values
    }

    /// 會貼到 target 的那幾組。
    func groups(applicableTo target: FormlessLayer) -> [FormlessStyleGroup] {
        groups.filter { $0.applies(from: sourceType, values: values, to: target) }
    }

    /// 貼到 target：只改用得到的欄位，內容、位置大小、資料不動。
    func apply(to target: inout FormlessLayer) {
        for group in groups(applicableTo: target) { group.copy(from: values, to: &target, targetType: target.type) }
    }
}

extension FormlessStyleGroup {
    /// 文字類圖層（文字、日期、時間、即時文字）彼此之間字型設定全部互通。
    static let textTypes: Set<FormlessLayerType> = [.text, .date, .time, .liveText]
    /// 圓角以 pt 計、外觀分頁有「圓角」的圖層；月曆元件的圓角是百分比，只和月曆互貼。
    static let pointCornerTypes: Set<FormlessLayerType> = [.shape, .image, .remoteImage]

    /// 來源圖層有沒有用到這一組（沒用到就不記，也就不會貼過去）。
    func isCaptured(from layer: FormlessLayer) -> Bool {
        switch self {
        case .color:
            // 沒有設定顏色時不知道它實際畫成什麼顏色（各種圖層的預設色不同），不記。
            return layer.colorHex != nil && Self.hasMainColor(layer)
        case .partColors:
            // 「跟著天氣」的圖示畫的是天氣圖片，上色方式與第二顏色都沒有作用。
            return !Self.partColorFields(for: layer.type).isEmpty && Self.hasMainColor(layer)
        case .text:
            return !Self.textFields(for: layer.type).isEmpty
        case .stroke, .shadow, .opacity, .effects:
            return true
        case .corner:
            return Self.usesCorner(layer)
        case .fill:
            return layer.type == .shape
        }
    }

    /// 這一組（來源種類 sourceType）能不能貼到 target。
    func applies(from sourceType: FormlessLayerType, values: FormlessLayer, to target: FormlessLayer) -> Bool {
        switch self {
        case .color:
            guard Self.hasMainColor(target) else { return false }
            // 「跟隨資料顏色」只貼到也能跟隨的圖層（綁了第幾筆行程或提醒事項）；其他圖層貼了會變成預設色。
            if values.colorHex?.lowercased() == "auto" { return Self.supportsAutomaticColor(target) }
            return true
        case .partColors:
            // 各部位顏色的意思依元件而不同（月曆的底色是左側面板，行程的是事件卡），只貼到同一種。
            return sourceType == target.type && Self.hasMainColor(target)
        case .text:
            if Self.textTypes.contains(sourceType) && Self.textTypes.contains(target.type) { return true }
            return sourceType == target.type && !Self.textFields(for: target.type).isEmpty
        case .stroke, .shadow, .opacity, .effects:
            return true
        case .corner:
            guard Self.usesCorner(target) else { return false }
            return (sourceType == .calendar) == (target.type == .calendar)
        case .fill:
            return target.type == .shape
        }
    }

    /// 把這一組欄位從 source 抄到 target。沒設定（nil）也照抄：貼上後和來源一樣是預設值。
    /// 欄位依 targetType 決定（例如月曆格只有字級與粗細）。
    func copy(from source: FormlessLayer, to target: inout FormlessLayer, targetType: FormlessLayerType) {
        switch self {
        case .color:
            target.colorHex = source.colorHex
        case .partColors:
            for field in Self.partColorFields(for: targetType) {
                switch field {
                case .secondary: target.secondaryColorHex = source.secondaryColorHex
                case .panel: target.panelColorHex = source.panelColorHex
                case .text: target.textColorHex = source.textColorHex
                case .progressTrack:
                    if source.progress != nil || target.progress != nil {
                        var spec = target.progress ?? FormlessProgressSpec()
                        spec.trackColorHex = source.progress?.trackColorHex
                        target.progress = spec
                    }
                case .chartSecondary:
                    if source.chart != nil || target.chart != nil {
                        var spec = target.chart ?? FormlessChartSpec()
                        spec.secondaryColorHex = source.chart?.secondaryColorHex
                        target.chart = spec
                    }
                case .weekend:
                    // 月曆格的其他延伸設定（前後月份、農曆、依資料上色）不是樣式，不動。
                    var options = target.calendarOptions ?? FormlessCalendarOptions()
                    options.weekendColorHex = source.calendarOptions?.weekendColorHex
                    target.calendarOptions = options.isEmpty ? nil : options
                case .symbolMode:
                    target.symbolMode = source.symbolMode
                }
            }
        case .text:
            let fields = Self.textFields(for: targetType)
            if fields.contains(.size) { target.fontSize = source.fontSize }
            if fields.contains(.weight) { target.fontWeight = source.fontWeight }
            if fields.contains(.full) {
                target.fontFamily = source.fontFamily
                target.alignment = source.alignment
                target.tracking = source.tracking
                target.lineSpacing = source.lineSpacing
                target.italic = source.italic
                target.underline = source.underline
                target.strikethrough = source.strikethrough
            }
        case .stroke:
            target.strokeColorHex = source.strokeColorHex
            target.strokeWidth = source.strokeWidth
            target.strokeDash = source.strokeDash
        case .shadow:
            target.shadowColorHex = source.shadowColorHex
            target.shadowRadius = source.shadowRadius
            target.shadowOffsetX = source.shadowOffsetX
            target.shadowOffsetY = source.shadowOffsetY
        case .opacity:
            target.opacity = source.opacity
        case .effects:
            target.blur = source.blur
            target.blendMode = source.blendMode
            target.flipHorizontal = source.flipHorizontal
            target.flipVertical = source.flipVertical
        case .corner:
            target.cornerRadius = source.cornerRadius
            // 四個角分開的圓角只用在矩形色塊與圖片（月曆的圓角是百分比，沒有分開的設定）。
            if Self.pointCornerTypes.contains(targetType) { target.cornerRadii = source.cornerRadii }
        case .fill:
            target.fill = source.fill
            target.gradientStops = source.gradientStops
            target.gradientAngle = source.gradientAngle
            target.gradientRadius = source.gradientRadius
        }
    }

    // MARK: 各種圖層用到哪些欄位（和外觀分頁的方塊一致，見 EditorAppearanceTile）

    /// 有主要顏色：圖片沒有（畫的時候不用顏色）；「跟著天氣」的圖示畫的是天氣圖片，顏色沒有作用。
    static func hasMainColor(_ layer: FormlessLayer) -> Bool {
        switch layer.type {
        case .image, .remoteImage, .bundleImage, .yearGrid: return false
        case .symbol: return (layer.value ?? "") != "auto:weather"
        default: return true
        }
    }

    /// 能「跟隨資料顏色」：文字類與色塊綁了第幾筆行程或提醒事項，或本來就是跟隨。
    static func supportsAutomaticColor(_ layer: FormlessLayer) -> Bool {
        guard layer.type == .shape || textTypes.contains(layer.type) else { return false }
        if layer.colorHex?.lowercased() == "auto" { return true }
        guard let binding = FormlessDataBinding.parse(layer.dataIndex), binding.index > 0 else { return false }
        return binding.kind == "event" || binding.kind == "reminder"
    }

    /// 外觀分頁有「圓角」的圖層：矩形色塊、圖片、網路圖片、月曆（其他形狀的色塊圓角沒有作用）。
    static func usesCorner(_ layer: FormlessLayer) -> Bool {
        if layer.type == .shape { return layer.shapeKind == .rectangle }
        return pointCornerTypes.contains(layer.type) || layer.type == .calendar
    }

    enum PartColor { case secondary, panel, text, progressTrack, chartSecondary, weekend, symbolMode }

    /// 各種元件在外觀分頁有的部位顏色。
    static func partColorFields(for type: FormlessLayerType) -> [PartColor] {
        switch type {
        case .clock: return [.secondary, .text, .panel]
        case .progress: return [.progressTrack]
        case .chart: return [.chartSecondary]
        case .calendar, .events, .steps, .eventList: return [.secondary, .panel, .text]
        case .reminders, .reminderList, .yearProgress: return [.secondary, .text]
        case .calendarGrid: return [.secondary, .text, .weekend]
        // 圖示：上色方式（單色、階層、調色盤、多色）與調色盤的第二顏色。
        case .symbol: return [.symbolMode, .secondary]
        // 天氣元件與預報列：次要色與預報卡底色。
        case .weather, .weatherForecast: return [.secondary, .panel]
        case .ruler, .yearGrid: return [.secondary]
        default: return []
        }
    }

    enum TextSetting { case size, weight, full }

    /// 各種圖層的文字設定（和「文字」細項面板一致，見 EditorTextPanelSpec）：文字類全部都有；
    /// 月曆格有字級與粗細，提醒清單與天氣預報列只有字級，完整月曆只有粗細。
    static func textFields(for type: FormlessLayerType) -> Set<TextSetting> {
        if textTypes.contains(type) { return [.size, .weight, .full] }
        switch type {
        case .calendarGrid: return [.size, .weight]
        case .reminderList, .weatherForecast: return [.size]
        case .calendar: return [.weight]
        default: return []
        }
    }
}

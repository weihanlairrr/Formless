import Foundation

// MARK: - 資料、呈現、規則的設計檔模型
//
// 資料是素材，圖層是呈現，規則把兩者接起來。使用者看到的詞是「資料、第幾筆、格式、條件、重複排列、動作」；
// 來源實例、綁定、快照是內部實作，不出現在畫面上。

/// 選擇資料面板的分類，依這個順序列出。
enum FormlessDataCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case weather
    case calendar
    case reminders
    case dateTime
    case astronomy
    case activity
    case device
    case location
    case photos
    case web
    case mine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weather: return "天氣"
        case .calendar: return "行事曆"
        case .reminders: return "提醒事項"
        case .dateTime: return "日期與時間"
        case .astronomy: return "天文"
        case .activity: return "健康與活動"
        case .device: return "裝置"
        case .location: return "位置"
        case .photos: return "照片"
        case .web: return "網路資料"
        case .mine: return "我的資料"
        }
    }

    /// 單色圖示（10/03 決定：不用彩色方塊）。
    var symbol: String {
        switch self {
        case .weather: return "cloud.sun"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .dateTime: return "clock"
        case .astronomy: return "moon.stars"
        case .activity: return "figure.walk"
        case .device: return "iphone"
        case .location: return "location"
        case .photos: return "photo.on.rectangle"
        case .web: return "globe"
        case .mine: return "person.crop.circle"
        }
    }
}

// MARK: 來源實例

/// 一個資料來源的設定，例如「臺北天氣」「東京天氣」「工作行程」。
/// id 和供應者相同（例如 "weather"）的是 App 預設：舊設計與沒有另外設定的設計都用它，設定來自 App 的設定頁。
/// 這份設計自己的來源 id 是 UUID 字串，存在設計檔的 `sources`。
struct FormlessSource: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var provider: String
    var name: String?
    var settings: [String: FormlessValue]

    init(id: String = UUID().uuidString, provider: String, name: String? = nil, settings: [String: FormlessValue] = [:]) {
        self.id = id
        self.provider = provider
        self.name = name
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        name = try? c.decode(String.self, forKey: .name)
        settings = (try? c.decode([String: FormlessValue].self, forKey: .settings)) ?? [:]
    }

    /// App 預設的來源。
    static func appDefault(_ provider: String) -> FormlessSource {
        FormlessSource(id: provider, provider: provider)
    }

    var isAppDefault: Bool { id == provider }

    subscript(_ key: String) -> FormlessValue {
        get { settings[key] ?? .empty }
        set { settings[key] = newValue.isEmpty ? nil : newValue }
    }
}

// MARK: 綁定

/// 綁定的特殊來源。
enum FormlessBindingSource {
    /// 我的資料（設計內的變數），field 是變數的 id。
    static let variable = "var"
    /// 重複排列裡「這一筆」，field 是那一筆的欄位。
    static let item = "item"
}

/// 圖層的某個屬性取用哪一份資料：來源 › 欄位 › 第幾筆 › 那一筆的欄位，再經過格式。
struct FormlessBinding: Codable, Hashable, Sendable {
    /// 來源實例的 id、`var`（我的資料）或 `item`（重複排列的這一筆）。
    var source: String
    /// 欄位 id，例如 temperature、events。
    var field: String
    /// 清單的第幾筆，從 1 開始；nil 表示整個清單或不是清單。
    var index: Int?
    /// 那一筆的哪個欄位，例如行程的 title。
    var itemField: String?
    var format: FormlessFormat?

    init(source: String, field: String, index: Int? = nil, itemField: String? = nil, format: FormlessFormat? = nil) {
        self.source = source
        self.field = field
        self.index = index
        self.itemField = itemField
        self.format = format
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        field = (try? c.decode(String.self, forKey: .field)) ?? ""
        index = try? c.decode(Int.self, forKey: .index)
        itemField = try? c.decode(String.self, forKey: .itemField)
        format = try? c.decode(FormlessFormat.self, forKey: .format)
    }

    static func variable(_ id: UUID, format: FormlessFormat? = nil) -> FormlessBinding {
        FormlessBinding(source: FormlessBindingSource.variable, field: id.uuidString, format: format)
    }

    var isVariable: Bool { source == FormlessBindingSource.variable }
    var isItem: Bool { source == FormlessBindingSource.item }

    /// 不看格式的同一份資料（比較兩個綁定是不是指向同一個值）。
    var target: FormlessBinding {
        FormlessBinding(source: source, field: field, index: index, itemField: itemField)
    }
}

/// 一個數值或其他值：直接輸入，或取一份資料。
enum FormlessOperand: Hashable, Sendable {
    case value(FormlessValue)
    case binding(FormlessBinding)

    static func number(_ value: Double) -> FormlessOperand { .value(.number(value, .none)) }

    var binding: FormlessBinding? {
        if case .binding(let binding) = self { return binding }
        return nil
    }

    var constant: FormlessValue? {
        if case .value(let value) = self { return value }
        return nil
    }
}

extension FormlessOperand: Codable {
    private enum CodingKeys: String, CodingKey { case value, binding }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let binding = try? c.decode(FormlessBinding.self, forKey: .binding) {
            self = .binding(binding)
        } else {
            self = .value((try? c.decode(FormlessValue.self, forKey: .value)) ?? .empty)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let value): try c.encode(value, forKey: .value)
        case .binding(let binding): try c.encode(binding, forKey: .binding)
        }
    }
}

// MARK: 格式

/// 四則與比例運算，依序套用在數字上。
struct FormlessMathOperation: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case add, subtract, multiply, divide
        /// 佔多少百分比：值 ÷ 運算元 × 100。
        case percentOf
        /// 夾在 0 到運算元之間。
        case clampMax
        case clampMin
        case round
        case absolute

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .add: return "加"
            case .subtract: return "減"
            case .multiply: return "乘"
            case .divide: return "除以"
            case .percentOf: return "佔的百分比"
            case .clampMax: return "最多"
            case .clampMin: return "最少"
            case .round: return "四捨五入"
            case .absolute: return "絕對值"
            }
        }

        var takesOperand: Bool { ![.round, .absolute].contains(self) }
    }

    var id: UUID
    var kind: Kind
    var operand: FormlessOperand

    init(id: UUID = UUID(), kind: Kind, operand: FormlessOperand = .number(1)) {
        self.id = id
        self.kind = kind
        self.operand = operand
    }
}

/// 文字取代：partial（包含就換）、whole（整段相等才換）、regex。
struct FormlessReplacement: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var find: String
    var replace: String
    var mode: String

    init(id: UUID = UUID(), find: String, replace: String, mode: String = "partial") {
        self.id = id
        self.find = find
        self.replace = replace
        self.mode = mode
    }
}

/// 資料顯示成文字的方式與轉換。沒有設定的項目用欄位的預設（例如溫度不帶小數、步數有千分位）。
struct FormlessFormat: Codable, Hashable, Sendable {
    // 數字
    /// 小數位數；nil 依欄位預設。
    var decimals: Int?
    /// 千分位；nil 依欄位預設（4 位數以上的計數類有）。
    var grouping: Bool?
    /// 縮寫成 1.2 萬。
    var compact: Bool?
    /// 顯示單位（°、%、步）；nil 依欄位預設。
    var showsUnit: Bool?
    /// 溫度單位 c／f；nil 依 App 設定。
    var temperatureUnit: String?
    var operations: [FormlessMathOperation]?

    // 日期
    /// 日期樣式：範例格式 id、自訂格式字串，或特殊樣式 clock／timer／countdown／relative（系統即時走動）、
    /// countdownDays（還有幾天）。
    var dateStyle: String?
    /// 時區識別碼，例如 Asia/Tokyo；nil 為裝置時區。
    var timeZone: String?
    /// 曆法：chinese（農曆）、roc（民國）、buddhist、japanese；nil 為西曆。
    var calendar: String?
    /// 日期位移（天）。
    var dayOffset: Int?

    // 文字
    /// upper／lower／capitalized。
    var textCase: String?
    var replacements: [FormlessReplacement]?
    /// 最多幾個字，超過以「…」結尾。
    var maxLength: Int?

    /// 沒有值時顯示的文字；nil 為「－」，空字串為不顯示。
    var emptyText: String?

    init() {}

    var isEmpty: Bool { self == FormlessFormat() }
}

// MARK: 文字區段

/// 文字圖層的一段：固定字或資料。「今天走了 8,430 / 10,000 步」是五段。
enum FormlessTextSegment: Hashable, Sendable {
    case text(String)
    case data(FormlessBinding)

    var binding: FormlessBinding? {
        if case .data(let binding) = self { return binding }
        return nil
    }
}

extension FormlessTextSegment: Codable {
    private enum CodingKeys: String, CodingKey { case text, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let binding = try? c.decode(FormlessBinding.self, forKey: .data) {
            self = .data(binding)
        } else {
            self = .text((try? c.decode(String.self, forKey: .text)) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try c.encode(text, forKey: .text)
        case .data(let binding): try c.encode(binding, forKey: .data)
        }
    }
}

// MARK: 我的資料

/// 設計內的具名值：直接輸入，或取一份資料再轉換。可以被文字、條件、進度、圖表引用。
struct FormlessVariable: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: FormlessValueKind
    var value: FormlessValue
    /// 有設定時，值來自這份資料（加格式裡的運算）。
    var binding: FormlessBinding?

    init(id: UUID = UUID(), name: String, kind: FormlessValueKind, value: FormlessValue, binding: FormlessBinding? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.binding = binding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "未命名"
        kind = (try? c.decode(FormlessValueKind.self, forKey: .kind)) ?? .text
        value = (try? c.decode(FormlessValue.self, forKey: .value)) ?? .empty
        binding = try? c.decode(FormlessBinding.self, forKey: .binding)
    }

    static func defaultValue(for kind: FormlessValueKind) -> FormlessValue {
        switch kind {
        case .text: return .text("")
        case .number: return .number(0, .none)
        case .bool: return .bool(false)
        case .date: return .date(Calendar.current.startOfDay(for: Date()), allDay: true)
        case .duration: return .duration(3600)
        case .color: return .color("#007AFF")
        case .symbol: return .symbol("star.fill")
        case .image: return .image("")
        case .record: return .record(FormlessRecord(id: "0"))
        case .list: return .list([])
        }
    }
}

// MARK: 條件

/// 比較方式；條件列依資料的型別只列出合用的。
enum FormlessComparison: String, Codable, CaseIterable, Identifiable, Sendable {
    // 數字
    case greaterOrEqual = ">="
    case lessOrEqual = "<="
    case greater = ">"
    case less = "<"
    case equal = "="
    case notEqual = "!="
    case between
    // 文字
    case contains
    case notContains
    case textEquals
    case beginsWith
    // 日期
    case before
    case after
    case isToday
    case isTomorrow
    case isPast
    case isFuture
    /// 時段（2026-10）：時刻落在每天的某段時間（只看時與分，跨午夜也可以，例如 22:00～06:00）。
    /// operand 與 upper 是從午夜起的分鐘數。
    case timeOfDay
    // 是非
    case isTrue
    case isFalse
    // 共通
    case isEmpty
    case isNotEmpty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .greaterOrEqual: return "≥"
        case .lessOrEqual: return "≤"
        case .greater: return ">"
        case .less: return "<"
        case .equal: return "="
        case .notEqual: return "≠"
        case .between: return "介於"
        case .contains: return "包含"
        case .notContains: return "不包含"
        case .textEquals: return "是"
        case .beginsWith: return "開頭是"
        case .before: return "早於"
        case .after: return "晚於"
        case .isToday: return "是今天"
        case .isTomorrow: return "是明天"
        case .isPast: return "已經過了"
        case .isFuture: return "還沒到"
        case .timeOfDay: return "時段"
        case .isTrue: return "是"
        case .isFalse: return "否"
        case .isEmpty: return "沒有資料"
        case .isNotEmpty: return "有資料"
        }
    }

    /// 需要另外填一個值（≥ 多少、包含什麼）。
    var takesOperand: Bool {
        switch self {
        case .isToday, .isTomorrow, .isPast, .isFuture, .isTrue, .isFalse, .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }

    /// 某種型別的資料能用的比較。
    static func options(for kind: FormlessValueKind?) -> [FormlessComparison] {
        switch kind {
        case .number?, .duration?: return [.greaterOrEqual, .lessOrEqual, .greater, .less, .equal, .notEqual, .between, .isEmpty, .isNotEmpty]
        case .text?, .symbol?, .color?, .image?: return [.textEquals, .contains, .notContains, .beginsWith, .isEmpty, .isNotEmpty]
        case .date?: return [.isToday, .isTomorrow, .isPast, .isFuture, .before, .after, .timeOfDay, .isEmpty, .isNotEmpty]
        case .bool?: return [.isTrue, .isFalse]
        case .list?: return [.greaterOrEqual, .lessOrEqual, .equal, .isEmpty, .isNotEmpty]
        case .record?, nil: return [.isEmpty, .isNotEmpty]
        }
    }
}

/// 一條條件：資料 › 比較 › 值。
struct FormlessCondition: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var subject: FormlessBinding
    var comparison: FormlessComparison
    var operand: FormlessOperand?
    /// 「介於」的上限。
    var upper: FormlessOperand?

    init(id: UUID = UUID(), subject: FormlessBinding, comparison: FormlessComparison,
         operand: FormlessOperand? = nil, upper: FormlessOperand? = nil) {
        self.id = id
        self.subject = subject
        self.comparison = comparison
        self.operand = operand
        self.upper = upper
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        subject = try c.decode(FormlessBinding.self, forKey: .subject)
        comparison = (try? c.decode(FormlessComparison.self, forKey: .comparison)) ?? .isNotEmpty
        operand = try? c.decode(FormlessOperand.self, forKey: .operand)
        upper = try? c.decode(FormlessOperand.self, forKey: .upper)
    }
}

/// 一組條件：全部符合，或任一符合。
struct FormlessConditionSet: Codable, Hashable, Sendable {
    var matchAll: Bool
    var conditions: [FormlessCondition]

    init(matchAll: Bool = true, conditions: [FormlessCondition] = []) {
        self.matchAll = matchAll
        self.conditions = conditions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchAll = (try? c.decode(Bool.self, forKey: .matchAll)) ?? true
        conditions = (try? c.decode([FormlessCondition].self, forKey: .conditions)) ?? []
    }
}

// MARK: 進度

/// 進度圖層：值、目標、起點三個輸入，各自可以填數字或取資料。
struct FormlessProgressSpec: Codable, Hashable, Sendable {
    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case linear
        case ring
        case arc
        case segments

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .linear: return "線形"
            case .ring: return "環形"
            case .arc: return "弧形"
            case .segments: return "分段"
            }
        }

        var symbol: String {
            switch self {
            case .linear: return "minus"
            case .ring: return "circle.dashed"
            case .arc: return "gauge.with.dots.needle.50percent"
            case .segments: return "square.split.1x2"
            }
        }
    }

    var value: FormlessOperand
    var goal: FormlessOperand
    var minimum: FormlessOperand?
    var style: Style
    /// 粗細（以小工具的參考尺寸計，和字級同一套比例）。
    var thickness: Double?
    var trackColorHex: String?
    var roundCaps: Bool?
    var segmentCount: Int?
    /// 分段之間的間隔。
    var segmentGap: Double?

    init(value: FormlessOperand = .number(60), goal: FormlessOperand = .number(100), minimum: FormlessOperand? = nil,
         style: Style = .linear, thickness: Double? = nil, trackColorHex: String? = nil, roundCaps: Bool? = true,
         segmentCount: Int? = nil, segmentGap: Double? = nil) {
        self.value = value
        self.goal = goal
        self.minimum = minimum
        self.style = style
        self.thickness = thickness
        self.trackColorHex = trackColorHex
        self.roundCaps = roundCaps
        self.segmentCount = segmentCount
        self.segmentGap = segmentGap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? c.decode(FormlessOperand.self, forKey: .value)) ?? .number(0)
        goal = (try? c.decode(FormlessOperand.self, forKey: .goal)) ?? .number(100)
        minimum = try? c.decode(FormlessOperand.self, forKey: .minimum)
        style = (try? c.decode(Style.self, forKey: .style)) ?? .linear
        thickness = try? c.decode(Double.self, forKey: .thickness)
        trackColorHex = try? c.decode(String.self, forKey: .trackColorHex)
        roundCaps = try? c.decode(Bool.self, forKey: .roundCaps)
        segmentCount = try? c.decode(Int.self, forKey: .segmentCount)
        segmentGap = try? c.decode(Double.self, forKey: .segmentGap)
    }
}

// MARK: 圖表

/// 圖表圖層：一份清單（數字，或每筆資料的某個欄位）畫成長條、折線、面積、點、圓餅或環形。
struct FormlessChartSpec: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case bar, line, area, point, pie, ring

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bar: return "長條"
            case .line: return "折線"
            case .area: return "面積"
            case .point: return "點"
            case .pie: return "圓餅"
            case .ring: return "環形"
            }
        }

        var symbol: String {
            switch self {
            case .bar: return "chart.bar.fill"
            case .line: return "chart.xyaxis.line"
            case .area: return "chart.line.uptrend.xyaxis"
            case .point: return "chart.dots.scatter"
            case .pie: return "chart.pie.fill"
            case .ring: return "circle.circle"
            }
        }
    }

    /// 資料：清單。
    var series: FormlessBinding?
    /// 清單裡每一筆取哪個欄位當數值；清單本身是數字時為 nil。
    var valueField: String?
    /// 每一筆的標籤欄位。
    var labelField: String?
    var kind: Kind
    var maxPoints: Int?
    /// 數值範圍；nil 為自動。
    var minimum: Double?
    var maximum: Double?
    var showsLabels: Bool?
    var showsGrid: Bool?
    /// 次要顏色（格線、標籤、圓餅的其他區塊）。
    var secondaryColorHex: String?
    var lineWidth: Double?
    /// 長條或折線之間的間隔比例（0–0.9）。
    var spacing: Double?

    init(series: FormlessBinding? = nil, valueField: String? = nil, labelField: String? = nil, kind: Kind = .bar,
         maxPoints: Int? = nil, minimum: Double? = nil, maximum: Double? = nil, showsLabels: Bool? = nil,
         showsGrid: Bool? = nil, secondaryColorHex: String? = nil, lineWidth: Double? = nil, spacing: Double? = nil) {
        self.series = series
        self.valueField = valueField
        self.labelField = labelField
        self.kind = kind
        self.maxPoints = maxPoints
        self.minimum = minimum
        self.maximum = maximum
        self.showsLabels = showsLabels
        self.showsGrid = showsGrid
        self.secondaryColorHex = secondaryColorHex
        self.lineWidth = lineWidth
        self.spacing = spacing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        series = try? c.decode(FormlessBinding.self, forKey: .series)
        valueField = try? c.decode(String.self, forKey: .valueField)
        labelField = try? c.decode(String.self, forKey: .labelField)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .bar
        maxPoints = try? c.decode(Int.self, forKey: .maxPoints)
        minimum = try? c.decode(Double.self, forKey: .minimum)
        maximum = try? c.decode(Double.self, forKey: .maximum)
        showsLabels = try? c.decode(Bool.self, forKey: .showsLabels)
        showsGrid = try? c.decode(Bool.self, forKey: .showsGrid)
        secondaryColorHex = try? c.decode(String.self, forKey: .secondaryColorHex)
        lineWidth = try? c.decode(Double.self, forKey: .lineWidth)
        spacing = try? c.decode(Double.self, forKey: .spacing)
    }
}

// MARK: 重複排列

/// 群組的重複排列：一份清單的每一筆，各畫一份群組內容，往下、往右或排成格狀。
struct FormlessRepeatSpec: Codable, Hashable, Sendable {
    enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
        case down, right, grid

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .down: return "往下"
            case .right: return "往右"
            case .grid: return "格狀"
            }
        }
    }

    var collection: FormlessBinding
    var maxItems: Int
    var direction: Direction
    /// 每份之間的間距（以小工具參考尺寸計）。
    var spacing: Double
    /// 格狀的欄數。
    var columns: Int?

    init(collection: FormlessBinding, maxItems: Int = 5, direction: Direction = .down, spacing: Double = 4, columns: Int? = nil) {
        self.collection = collection
        self.maxItems = maxItems
        self.direction = direction
        self.spacing = spacing
        self.columns = columns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(FormlessBinding.self, forKey: .collection)
        maxItems = (try? c.decode(Int.self, forKey: .maxItems)) ?? 5
        direction = (try? c.decode(Direction.self, forKey: .direction)) ?? .down
        spacing = (try? c.decode(Double.self, forKey: .spacing)) ?? 4
        columns = try? c.decode(Int.self, forKey: .columns)
    }
}

/// 圖層可以綁資料的屬性（文字內容以外）。
enum FormlessBindableProperty: String, Codable, CaseIterable, Sendable {
    /// 圖示名稱。
    case symbol
    /// 圖片（網址或圖片庫檔名）。
    case image
    /// 點一下開的網址。
    case url
    /// 主要顏色（例如行程的行事曆顏色、條件之外的顏色來源）。
    case color
}

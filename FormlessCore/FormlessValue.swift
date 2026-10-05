import Foundation

// MARK: - 型別化的資料值
//
// 資料來源輸出的不是排好版的字串，而是帶型別、單位的值；文字、條件、進度、圖表都從同一個值取用，
// 要顯示時才依格式轉成文字（`FormlessFormat`）。數字不先轉字串，日期與時刻分開。

/// 資料的型別。選擇資料、條件比較、格式選項都依型別決定能用什麼。
enum FormlessValueKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case number
    case bool
    case date
    case duration
    case color
    case symbol
    case image
    case record
    case list

    var displayName: String {
        switch self {
        case .text: return "文字"
        case .number: return "數字"
        case .bool: return "是非"
        case .date: return "日期"
        case .duration: return "時間長度"
        case .color: return "顏色"
        case .symbol: return "圖示"
        case .image: return "圖片"
        case .record: return "一筆資料"
        case .list: return "清單"
        }
    }
}

/// 數字的單位。單位決定顯示時接什麼字（°、%、步），也決定能不能互相換算（溫度、距離）。
enum FormlessUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    /// 0–100 的百分比。
    case percent
    /// 攝氏溫度；顯示時依 App 的溫度單位換算。
    case celsius
    case steps
    case meters
    case kilometers
    case floors
    case hectopascals
    case millimeters
    case kilometersPerHour
    /// 角度（風向、方位）。
    case degrees
    case uvIndex
    case aqi
    case microgramsPerCubicMeter
    /// 幾筆、幾個。
    case count
    case bytes
    case days
    case hours
    case minutes
    case seconds
    /// 每分鐘幾步（步頻）。
    case stepsPerMinute
    /// 每公里幾秒（配速）。
    case secondsPerKilometer

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "none"
        self = FormlessUnit(rawValue: raw) ?? .none
    }

    /// 顯示在數字後面的單位字；空字串表示不接。
    var suffix: String {
        switch self {
        case .none, .uvIndex, .aqi, .count: return ""
        case .percent: return "%"
        case .celsius, .degrees: return "°"
        case .steps: return " 步"
        case .meters: return " 公尺"
        case .kilometers: return " 公里"
        case .floors: return " 層"
        case .hectopascals: return " hPa"
        case .millimeters: return " mm"
        case .kilometersPerHour: return " km/h"
        case .microgramsPerCubicMeter: return " µg/m³"
        case .bytes: return ""
        case .days: return " 天"
        case .hours: return " 小時"
        case .minutes: return " 分鐘"
        case .seconds: return " 秒"
        case .stepsPerMinute: return " 步/分"
        case .secondsPerKilometer: return ""
        }
    }
}

/// 一筆資料（行程、提醒事項、逐時預報的一個鐘點）：識別碼加上各欄位的值。
/// 識別碼讓重複排列的每一列有固定身分，資料順序改變時畫面不會錯位。
struct FormlessRecord: Codable, Hashable, Sendable {
    var id: String
    var fields: [String: FormlessValue]

    init(id: String, fields: [String: FormlessValue] = [:]) {
        self.id = id
        self.fields = fields
    }

    subscript(_ key: String) -> FormlessValue {
        get { fields[key] ?? .empty }
        set { fields[key] = newValue }
    }
}

/// 一個資料值。
enum FormlessValue: Hashable, Sendable {
    /// 沒有值（還沒抓到、這一筆不存在、欄位缺）。顯示時用空值替代文字。
    case empty
    case text(String)
    case number(Double, FormlessUnit)
    case bool(Bool)
    /// 時刻；allDay 為 true 時只有日期（全天行程、只有日期的提醒）。
    case date(Date, allDay: Bool)
    /// 時間長度（秒）。
    case duration(TimeInterval)
    /// 顏色 #RRGGBB 或 #RRGGBBAA。
    case color(String)
    /// SF Symbol 名稱。
    case symbol(String)
    /// 圖片：網址或圖片庫檔名。
    case image(String)
    case record(FormlessRecord)
    case list([FormlessValue])

    static func number(_ value: Double) -> FormlessValue { .number(value, .none) }
    static func number(_ value: Int, _ unit: FormlessUnit = .none) -> FormlessValue { .number(Double(value), unit) }
    static func date(_ value: Date) -> FormlessValue { .date(value, allDay: false) }
    static func optionalText(_ value: String?) -> FormlessValue {
        guard let value, !value.isEmpty else { return .empty }
        return .text(value)
    }
    static func optionalNumber(_ value: Double?, _ unit: FormlessUnit = .none) -> FormlessValue {
        guard let value, value.isFinite else { return .empty }
        return .number(value, unit)
    }
    static func optionalDate(_ value: Date?, allDay: Bool = false) -> FormlessValue {
        guard let value else { return .empty }
        return .date(value, allDay: allDay)
    }

    var kind: FormlessValueKind? {
        switch self {
        case .empty: return nil
        case .text: return .text
        case .number: return .number
        case .bool: return .bool
        case .date: return .date
        case .duration: return .duration
        case .color: return .color
        case .symbol: return .symbol
        case .image: return .image
        case .record: return .record
        case .list: return .list
        }
    }

    var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .text(let text): return text.isEmpty
        case .list(let items): return items.isEmpty
        default: return false
        }
    }

    /// 能當成數字比較或計算的值：數字、時間長度（秒）、是非（1／0）、可解析的文字。
    var numberValue: Double? {
        switch self {
        case .number(let value, _): return value.isFinite ? value : nil
        case .duration(let seconds): return seconds
        case .bool(let flag): return flag ? 1 : 0
        case .text(let text):
            let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(cleaned)
        case .list(let items): return Double(items.count)
        default: return nil
        }
    }

    var unit: FormlessUnit {
        if case .number(_, let unit) = self { return unit }
        return .none
    }

    var dateValue: Date? {
        switch self {
        case .date(let date, _): return date
        case .text(let text): return FormlessValue.parseDate(text)
        case .number(let value, _) where value > 100_000_000: return Date(timeIntervalSince1970: value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let flag): return flag
        case .number(let value, _): return value != 0
        case .text(let text):
            switch text.lowercased() {
            case "true", "yes", "1", "是", "開": return true
            case "false", "no", "0", "否", "關": return false
            default: return nil
            }
        default: return nil
        }
    }

    var listValue: [FormlessValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var recordValue: FormlessRecord? {
        if case .record(let record) = self { return record }
        return nil
    }

    /// 文字型別的原始字串（不套格式）；給比較、網址、圖示名稱用。
    var rawString: String? {
        switch self {
        case .empty: return nil
        case .text(let text), .color(let text), .symbol(let text), .image(let text): return text
        case .number(let value, _):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let flag): return flag ? "是" : "否"
        case .date(let date, _): return FormlessValue.isoParser.string(from: date)
        case .duration(let seconds): return String(seconds)
        case .record(let record): return record.id
        case .list(let items): return items.compactMap(\.rawString).joined(separator: "、")
        }
    }

    // 格式器讀取時是執行緒安全的（只在建立時設定一次）。
    nonisolated(unsafe) private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 帶毫秒的 ISO 日期（JavaScript 常見的 2026-10-04T07:08:09.123Z）。
    nonisolated(unsafe) private static let isoFractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let localParsers: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    /// 文字裡的日期：ISO 8601（含或不含毫秒）、沒有時區的「年-月-日 時:分:秒」（裝置時區）、只有日期。
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10, trimmed.first?.isNumber == true else { return nil }
        if let date = isoParser.date(from: trimmed) ?? isoFractionalParser.date(from: trimmed) { return date }
        for parser in localParsers { if let date = parser.date(from: trimmed) { return date } }
        return nil
    }
}

// MARK: - 編碼
//
// {"type":"number","value":3.5,"unit":"percent"}；日期存 1970 年起的秒數，不受編碼器的日期策略影響。

extension FormlessValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, unit, allDay, id, fields, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? "empty"
        switch type {
        case "text": self = .text((try? c.decode(String.self, forKey: .value)) ?? "")
        case "number":
            self = .number((try? c.decode(Double.self, forKey: .value)) ?? 0,
                           (try? c.decode(FormlessUnit.self, forKey: .unit)) ?? .none)
        case "bool": self = .bool((try? c.decode(Bool.self, forKey: .value)) ?? false)
        case "date":
            self = .date(Date(timeIntervalSince1970: FormlessValue.millisecond((try? c.decode(Double.self, forKey: .value)) ?? 0)),
                         allDay: (try? c.decode(Bool.self, forKey: .allDay)) ?? false)
        case "duration": self = .duration((try? c.decode(Double.self, forKey: .value)) ?? 0)
        case "color": self = .color((try? c.decode(String.self, forKey: .value)) ?? "#000000")
        case "symbol": self = .symbol((try? c.decode(String.self, forKey: .value)) ?? "")
        case "image": self = .image((try? c.decode(String.self, forKey: .value)) ?? "")
        case "record":
            self = .record(FormlessRecord(id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
                                          fields: (try? c.decode([String: FormlessValue].self, forKey: .fields)) ?? [:]))
        case "list": self = .list((try? c.decode([FormlessValue].self, forKey: .items)) ?? [])
        default: self = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try c.encode("empty", forKey: .type)
        case .text(let text):
            try c.encode("text", forKey: .type); try c.encode(text, forKey: .value)
        case .number(let value, let unit):
            try c.encode("number", forKey: .type)
            try c.encode(value.isFinite ? value : 0, forKey: .value)
            if unit != .none { try c.encode(unit, forKey: .unit) }
        case .bool(let flag):
            try c.encode("bool", forKey: .type); try c.encode(flag, forKey: .value)
        case .date(let date, let allDay):
            try c.encode("date", forKey: .type)
            try c.encode(FormlessValue.millisecond(date.timeIntervalSince1970), forKey: .value)
            if allDay { try c.encode(true, forKey: .allDay) }
        case .duration(let seconds):
            try c.encode("duration", forKey: .type); try c.encode(seconds, forKey: .value)
        case .color(let hex):
            try c.encode("color", forKey: .type); try c.encode(hex, forKey: .value)
        case .symbol(let name):
            try c.encode("symbol", forKey: .type); try c.encode(name, forKey: .value)
        case .image(let ref):
            try c.encode("image", forKey: .type); try c.encode(ref, forKey: .value)
        case .record(let record):
            try c.encode("record", forKey: .type); try c.encode(record.id, forKey: .id)
            try c.encode(record.fields, forKey: .fields)
        case .list(let items):
            try c.encode("list", forKey: .type); try c.encode(items, forKey: .items)
        }
    }
}

// MARK: - 任意 JSON
//
// 設計檔最上層與圖層最上層，這個版本不認得的欄位原樣保留（較新版本寫入的欄位，回到這個版本再存也不會遺失）。
// 巢狀物件（框、文字區段、綁定、格式、條件、進度、來源、我的資料）不保留：在巢狀物件加欄位時，
// 一定要把 `FormlessDocument.currentFormatVersion` 加一，舊版就會以唯讀開啟、不會存檔弄丟新欄位。
// JSON 資料來源也用它表示抓回來的內容。

enum FormlessJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FormlessJSON])
    case object([String: FormlessJSON])

    subscript(_ key: String) -> FormlessJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(_ index: Int) -> FormlessJSON? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    /// 轉成資料值：物件變成一筆資料、陣列變成清單、ISO 日期字串變成日期。
    func value(id: String = "") -> FormlessValue {
        switch self {
        case .null: return .empty
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number, .none)
        case .string(let text):
            if text.count >= 10, text.count <= 30, text.first?.isNumber == true,
               let date = FormlessValue.text(text).dateValue {
                return .date(date, allDay: text.count == 10)
            }
            return .text(text)
        case .array(let items):
            return .list(items.enumerated().map { $0.element.value(id: String($0.offset)) })
        case .object(let object):
            var fields: [String: FormlessValue] = [:]
            for (key, value) in object { fields[key] = value.value(id: key) }
            let identifier = object["id"].flatMap { json -> String? in
                switch json {
                case .string(let text): return text
                case .number(let number): return FormlessValue.number(number, .none).rawString
                default: return nil
                }
            } ?? id
            return .record(FormlessRecord(id: identifier, fields: fields))
        }
    }
}

extension FormlessJSON: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let flag = try? c.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? c.decode(Double.self) { self = .number(number) }
        else if let text = try? c.decode(String.self) { self = .string(text) }
        else if let array = try? c.decode([FormlessJSON].self) { self = .array(array) }
        else if let object = try? c.decode([String: FormlessJSON].self) { self = .object(object) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let flag): try c.encode(flag)
        case .number(let number): try c.encode(number)
        case .string(let text): try c.encode(text)
        case .array(let array): try c.encode(array)
        case .object(let object): try c.encode(object)
        }
    }
}

/// 解碼時讀出這個版本不認得的鍵。
struct FormlessAnyKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string; intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

extension Decoder {
    /// 這一層 JSON 物件裡、不在 known 裡的鍵與原始值。
    func formlessUnknownFields(known: Set<String>) -> [String: FormlessJSON]? {
        guard let container = try? container(keyedBy: FormlessAnyKey.self) else { return nil }
        var result: [String: FormlessJSON] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            if let value = try? container.decode(FormlessJSON.self, forKey: key) { result[key.stringValue] = value }
        }
        return result.isEmpty ? nil : result
    }
}

extension Encoder {
    /// 把保留下來的未知欄位寫回同一層 JSON 物件。
    func formlessWriteUnknownFields(_ fields: [String: FormlessJSON]?) throws {
        guard let fields, !fields.isEmpty else { return }
        var container = container(keyedBy: FormlessAnyKey.self)
        for (key, value) in fields { try container.encode(value, forKey: FormlessAnyKey(key)) }
    }
}

// MARK: - 預覽用的長文字

extension FormlessValue {
    /// 編輯器「很長的文字」預覽：文字換成長句（清單裡每一筆的文字欄位也換），檢查版面會不會被撐開或截斷。
    var lengthened: FormlessValue {
        switch self {
        case .text(let text):
            return .text(text.isEmpty ? text : FormlessValue.longSample)
        case .record(var record):
            for (key, value) in record.fields { record.fields[key] = value.lengthened }
            return .record(record)
        case .list(let items):
            return .list(items.map(\.lengthened))
        default:
            return self
        }
    }

    static let longSample = "這是一段特別長的文字，用來確認版面在內容很多時仍然好看"
}

extension FormlessValue {
    /// 時刻存到毫秒：1970 起的秒數換算有浮點誤差，帶小數秒的時刻讀回來會差一點點，
    /// 內容相同的資料被當成有變化、首頁多重畫一次縮圖（2026-10 測試發現）。存讀兩邊都取到毫秒，來回一次就穩定。
    static func millisecond(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return (seconds * 1000).rounded() / 1000
    }
}


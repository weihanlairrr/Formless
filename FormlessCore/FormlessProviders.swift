import Foundation

// MARK: - 資料供應者
//
// 每一種資料（天氣、行事曆、計步器、日期…）是一個供應者：宣告自己的欄位、設定、快取與時間變化點。
// 新增一種資料只要寫一個供應者檔，再把它加進 `FormlessProviders.all`；選擇資料面板、條件、格式自動可用。

/// 一個欄位的說明。
struct FormlessFieldSpec: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: FormlessValueKind
    var unit: FormlessUnit = .none
    /// 清單裡每一筆的欄位（kind 是 list 時）。
    var itemFields: [FormlessFieldSpec] = []
    /// 預設小數位數。
    var decimals: Int? = nil
    /// 預設有千分位（步數、距離這類計數）。
    var grouping: Bool = false
    /// 範例值：範例資料預覽、還沒有資料時面板的灰字。
    var sample: FormlessValue = .empty
    /// 可以用系統即時走動的時間顯示（倒數、計時、相對時間）。
    var live: Bool = false

    init(_ id: String, _ name: String, _ kind: FormlessValueKind, unit: FormlessUnit = .none,
         decimals: Int? = nil, grouping: Bool = false, sample: FormlessValue = .empty, live: Bool = false,
         items: [FormlessFieldSpec] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.unit = unit
        self.decimals = decimals
        self.grouping = grouping
        self.sample = sample
        self.live = live
        self.itemFields = items
    }

    func itemField(_ id: String?) -> FormlessFieldSpec? {
        guard let id else { return nil }
        return itemFields.first { $0.id == id }
    }
}

/// 資料目前的狀態，決定編輯器的說明文字與小工具的空值。
enum FormlessDataStatus: String, Codable, Hashable, Sendable {
    case ok
    /// 沒有內容（今天沒有行程）；不是錯誤。
    case empty
    /// 還沒抓到。
    case loading
    /// 需要權限。
    case unauthorized
    /// 這個安裝方式（SideStore）拿不到。
    case unsupported
    /// 這次沒抓到；有舊值時顯示舊值。
    case failed
    /// 還沒設定（例如 JSON 沒填網址）。
    case notConfigured

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "ok"
        self = FormlessDataStatus(rawValue: raw) ?? .ok
    }
}

/// 一個來源抓回來的資料與它的狀態。沿用 `FormlessCache` 的原子寫入與「內容相同不重寫」。
struct FormlessSnapshot: Codable, Hashable, Sendable {
    var values: [String: FormlessValue]
    /// 最後一次成功取得的時間。
    var fetchedAt: Date
    var status: FormlessDataStatus
    /// 狀態的補充說明（失敗原因）。
    var message: String?
    /// 資料出處（Open-Meteo、歐洲央行…）。
    var attribution: String?

    init(values: [String: FormlessValue], fetchedAt: Date = Date(), status: FormlessDataStatus = .ok,
         message: String? = nil, attribution: String? = nil) {
        self.values = values
        self.fetchedAt = fetchedAt
        self.status = status
        self.message = message
        self.attribution = attribution
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = (try? c.decode([String: FormlessValue].self, forKey: .values)) ?? [:]
        fetchedAt = (try? c.decode(Date.self, forKey: .fetchedAt)) ?? .distantPast
        status = (try? c.decode(FormlessDataStatus.self, forKey: .status)) ?? .ok
        message = try? c.decode(String.self, forKey: .message)
        attribution = try? c.decode(String.self, forKey: .attribution)
    }

    static func failure(_ status: FormlessDataStatus, _ message: String? = nil) -> FormlessSnapshot {
        FormlessSnapshot(values: [:], fetchedAt: .distantPast, status: status, message: message)
    }

    subscript(_ key: String) -> FormlessValue { values[key] ?? .empty }
}

/// 這份設計的來源設定項目（地點、行事曆、網址…），設定頁依它產生。
struct FormlessSettingSpec: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        /// 目前位置或指定地點（latitude、longitude、placeName、useCurrentLocation 四個設定鍵）。
        case location
        case text(placeholder: String)
        case url
        case number(min: Double, max: Double, step: Double)
        case toggle
        case choice([FormlessNamedValue])
        case calendars
        case reminderLists
        case date
        case dateTime
        /// 多行文字，一行一項（隨機挑一項的清單）。
        case lines
    }

    let id: String
    let name: String
    let kind: Kind
    var defaultValue: FormlessValue = .empty
    /// 補充說明（設定列下方）。
    var footer: String? = nil
}

struct FormlessNamedValue: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

protocol FormlessDataProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var symbol: String { get }
    var category: FormlessDataCategory { get }
    /// 要事先抓（網路、權限、感測器）。純計算的（日期、倒數、天文）是 false，用到時才算。
    var fetches: Bool { get }
    /// 快照多久內算新（秒）；超過才在 App 進前景或小工具更新時重抓。
    var lifetime: TimeInterval { get }
    /// 能不能另外設定一份（多地點天氣、多個行程查詢）。
    var allowsInstances: Bool { get }
    var settings: [FormlessSettingSpec] { get }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec]
    /// 同一個鍵的來源只抓一次、共用快取（十個圖層用同一份臺北天氣）。
    func cacheKey(for source: FormlessSource) -> String
    func fetch(_ source: FormlessSource) async -> FormlessSnapshot?
    /// date 那一刻的值；會隨時間變的欄位（倒數、行程結束與否）在這裡依 date 算。
    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue
    /// from 到 to 之間畫面會變的時間點，小工具時間線預先排好。
    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date]
    /// 來源的設定摘要，例如「目前位置」「臺北」。
    func summary(for source: FormlessSource) -> String
    /// 沒有快照時的狀態（純計算的永遠 ok）。
    func availability(for source: FormlessSource) -> FormlessDataStatus
}

extension FormlessDataProvider {
    var fetches: Bool { true }
    var lifetime: TimeInterval { 15 * 60 }
    var allowsInstances: Bool { false }
    var settings: [FormlessSettingSpec] { [] }
    func cacheKey(for source: FormlessSource) -> String { id }
    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? { nil }
    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] { [] }
    func summary(for source: FormlessSource) -> String { "" }
    func availability(for source: FormlessSource) -> FormlessDataStatus { fetches ? .loading : .ok }

    func field(_ id: String, source: FormlessSource, snapshot: FormlessSnapshot? = nil) -> FormlessFieldSpec? {
        fields(for: source, snapshot: snapshot).first { $0.id == id }
    }

    /// 快照裡的值；清單欄位依時間篩選由各供應者自己覆寫 value。
    func snapshotValue(_ field: String, _ snapshot: FormlessSnapshot?) -> FormlessValue {
        snapshot?.values[field] ?? .empty
    }
}

// MARK: - 登錄表

enum FormlessProviders {
    /// 所有內建供應者，依選擇資料面板的順序。
    static let all: [any FormlessDataProvider] = [
        FormlessWeatherDataProvider(),
        FormlessAirQualityProvider(),
        FormlessCalendarDataProvider(),
        FormlessReminderDataProvider(),
        FormlessDateTimeProvider(),
        FormlessCountdownProvider(),
        FormlessTimeProgressProvider(),
        FormlessAstronomyProvider(),
        FormlessActivityProvider(),
        FormlessDeviceProvider(),
        FormlessWidgetEnvironmentProvider(),
        FormlessPlaceProvider(),
        FormlessRandomProvider(),
        // 網路資料（2026-10，規劃第 5.3 節）：JSON、RSS、CSV；捷徑寫進來的資料放在「我的資料」類別。
        FormlessJSONDataProvider(),
        FormlessFeedDataProvider(),
        FormlessCSVDataProvider(),
        FormlessShortcutDataProvider()
    ]

    private static let table: [String: any FormlessDataProvider] = {
        var table: [String: any FormlessDataProvider] = [:]
        for provider in all { table[provider.id] = provider }
        return table
    }()

    static func provider(_ id: String) -> (any FormlessDataProvider)? { table[id] }

    static func providers(in category: FormlessDataCategory) -> [any FormlessDataProvider] {
        all.filter { $0.category == category }
    }
}

// MARK: - 快照快取

enum FormlessSnapshotStore {

    /// 快取檔名：src-<鍵>.json，鍵裡不能當檔名的字換成底線。
    static func fileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = safe.count > 120 ? String(safe.prefix(80)) + "-" + String(abs(key.hashValueStable)) : safe
        return "src-" + trimmed + ".json"
    }

    static func load(_ key: String) -> FormlessSnapshot? {
        FormlessCache.load(FormlessSnapshot.self, name: fileName(for: key))
    }

    /// 存一份新抓的資料。這次失敗但有舊值時保留舊值，狀態改成「暫時無法更新」，抓取時間仍是上次成功的時間。
    static func save(_ snapshot: FormlessSnapshot, key: String) {
        let old = load(key)
        var result = snapshot
        // 先照存檔的精度來回一次（時刻存到毫秒），和讀回來的舊值比較才不會每次都算成有變化。
        if let data = try? JSONEncoder().encode(result), let normalized = try? JSONDecoder().decode(FormlessSnapshot.self, from: data) {
            result = normalized
        }
        if [.failed, .unauthorized, .unsupported].contains(snapshot.status), snapshot.values.isEmpty,
           let old, !old.values.isEmpty {
            result = old
            result.status = .failed
            result.message = snapshot.message
        }
        // 內容沒變（只差抓取時間）時照樣存（抓取時間決定多久後重抓），但不通知首頁重畫縮圖。
        let changed = old?.values != result.values || old?.status != result.status || old?.message != result.message
        FormlessCache.save(result, name: fileName(for: key), notify: changed)
    }
}

extension String {
    /// 不隨執行次數改變的雜湊（Swift 的 hashValue 每次啟動不同，不能拿來當檔名）。
    var hashValueStable: Int {
        var hash: UInt64 = 5381
        for byte in utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(truncatingIfNeeded: hash & 0x7FFF_FFFF_FFFF)
    }
}

// MARK: - 共用設定讀取

extension FormlessSource {
    func number(_ key: String) -> Double? { settings[key]?.numberValue }
    func text(_ key: String) -> String? {
        guard let raw = settings[key]?.rawString, !raw.isEmpty else { return nil }
        return raw
    }
    func flag(_ key: String) -> Bool? { settings[key]?.boolValue }
    func date(_ key: String) -> Date? { settings[key]?.dateValue }
    func list(_ key: String) -> [String] { settings[key]?.listValue?.compactMap(\.rawString) ?? [] }
}

/// 地點設定（天氣、空氣品質、天文共用）：目前位置，或指定的地點。
struct FormlessPlace: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
    var isCurrent: Bool

    static let settingKeys = (latitude: "latitude", longitude: "longitude", name: "placeName", current: "useCurrentLocation")

    /// 來源設定的地點；使用目前位置時取 App 最近一次定位（沒有就臺北）。
    static func resolve(_ source: FormlessSource) -> FormlessPlace {
        let useCurrent = source.flag(settingKeys.current) ?? true
        if !useCurrent, let lat = source.number(settingKeys.latitude), let lon = source.number(settingKeys.longitude) {
            return FormlessPlace(latitude: lat, longitude: lon, name: source.text(settingKeys.name) ?? "", isCurrent: false)
        }
        let cached = FormlessCache.load(FormlessCoordinate.self, name: FormlessWeatherProvider.locationCacheName)
            ?? FormlessWeatherProvider.defaultCoordinate
        return FormlessPlace(latitude: cached.latitude, longitude: cached.longitude, name: cached.name, isCurrent: true)
    }

    /// 快取鍵：座標取到小數兩位（約 1 公里），目前位置也用解析後的座標，換地方就換一份。
    var cacheKey: String { String(format: "%.2f,%.2f", latitude, longitude) }

    static func summary(_ source: FormlessSource) -> String {
        let useCurrent = source.flag(settingKeys.current) ?? true
        if useCurrent { return "目前位置" }
        return source.text(settingKeys.name) ?? "指定地點"
    }

    static let setting = FormlessSettingSpec(id: "place", name: "地點", kind: .location)
}

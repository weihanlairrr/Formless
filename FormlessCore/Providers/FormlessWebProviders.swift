import Foundation

// MARK: - 網路資料：JSON、RSS 訂閱、CSV 表格
//
// 使用者填網址，每份設計可以有好幾個。抓回來先整理成快照：每個欄位的值事先算好，畫面取值時不再解析原始內容；
// 清單最多存 100 筆、文字最多 2,000 字，快照不會太大。快取由 `FormlessDataCoordinator` 依 cacheKey 管理，
// 多久重抓依來源設定的「更新頻率」（`lifetime(for:)`）。

// MARK: 更新頻率

/// 網路資料的更新頻率（來源設定「更新頻率」，值是秒數）。
enum FormlessWebRefresh {
    static let choices = [
        FormlessNamedValue(id: "900", name: "15 分鐘"),
        FormlessNamedValue(id: "1800", name: "30 分鐘"),
        FormlessNamedValue(id: "3600", name: "1 小時"),
        FormlessNamedValue(id: "21600", name: "6 小時"),
        FormlessNamedValue(id: "86400", name: "每天")
    ]
    static let defaultLifetime: TimeInterval = 3600
    static let setting = FormlessSettingSpec(id: "refresh", name: "更新頻率", kind: .choice(choices), defaultValue: .text("3600"))
    static let providerIDs: Set<String> = ["json", "rss", "csv"]

    /// 這份來源的快照多久內算新（秒）：依「更新頻率」，沒設定是 1 小時。
    static func lifetime(for source: FormlessSource) -> TimeInterval {
        guard let text = source.text("refresh"), let seconds = TimeInterval(text), seconds >= 60 else { return defaultLifetime }
        return seconds
    }

    /// 任何來源的有效期限：網路資料依來源設定，其他用供應者的 lifetime。
    static func lifetime(for source: FormlessSource, provider: any FormlessDataProvider) -> TimeInterval {
        providerIDs.contains(provider.id) ? lifetime(for: source) : provider.lifetime
    }
}

// MARK: 抓取

/// 網路資料的抓取：只用 GET、只接受 https（與 http），回應超過 2 MB 不收。
enum FormlessWebFetch {
    static let maxBytes = 2 * 1024 * 1024

    struct Response: Sendable {
        let data: Data
        /// 伺服器宣告的文字編碼（Content-Type 的 charset）。
        let encodingName: String?
    }

    enum Failure: Error, Hashable, Sendable {
        case invalidURL
        /// 系統不允許的不安全連線（http）。
        case insecure
        case certificate
        case http(Int)
        case tooLarge
        case timedOut
        case offline
        case cannotFindHost
        case other

        /// 快照的狀態說明。
        var message: String {
            switch self {
            case .invalidURL: return "網址格式不正確，要以 https:// 開頭"
            case .insecure: return "只支援 https 網址"
            case .certificate: return "安全連線失敗（憑證有問題）"
            case .http(let code):
                switch code {
                case 401, 403: return "需要授權才能讀取（HTTP \(code)）"
                case 404: return "找不到這個網址（HTTP 404）"
                case 429: return "要求太頻繁，請稍後再試（HTTP 429）"
                case 500...599: return "伺服器暫時無法回應（HTTP \(code)）"
                default: return "伺服器回應錯誤（HTTP \(code)）"
                }
            case .tooLarge: return "資料超過 2 MB"
            case .timedOut: return "連線逾時"
            case .offline: return "沒有網路連線"
            case .cannotFindHost: return "找不到伺服器"
            case .other: return "無法取得資料"
            }
        }
    }

    /// 使用者填的網址：去掉前後空白，沒寫 https:// 時補上；只接受 https 與 http。
    static func url(_ text: String?) -> URL? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// 快取鍵用的網址文字（和抓取時一樣補上 https://）。
    static func normalized(_ text: String?) -> String {
        url(text)?.absoluteString ?? (text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// 「名稱: 值」一行一個的標頭；格式不對的行略過。
    static func headers(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(where: \.isWhitespace) { result[name] = value }
        }
        return result
    }

    static func request(_ url: URL, headers: [String: String], accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// 讀取網址的內容；超過 2 MB 時一邊下載一邊就停，不會整份讀進記憶體。
    static func get(_ url: URL, headers: [String: String] = [:], accept: String) async -> Result<Response, Failure> {
        do {
            let (bytes, response) = try await FormlessNetwork.session.bytes(for: request(url, headers: headers, accept: accept))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                bytes.task.cancel()
                return .failure(.http(http.statusCode))
            }
            if response.expectedContentLength > Int64(maxBytes) {
                bytes.task.cancel()
                return .failure(.tooLarge)
            }
            var data = Data()
            data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(maxBytes))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes {
                    bytes.task.cancel()
                    return .failure(.tooLarge)
                }
            }
            return .success(Response(data: data, encodingName: response.textEncodingName))
        } catch let error as URLError {
            return .failure(failure(for: error.code))
        } catch {
            return .failure(.other)
        }
    }

    static func failure(for code: URLError.Code) -> Failure {
        switch code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return .cannotFindHost
        case .appTransportSecurityRequiresSecureConnection: return .insecure
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired: return .certificate
        default: return .other
        }
    }

    /// 設定摘要：網址的主機名稱。
    static func summary(_ source: FormlessSource) -> String {
        guard let text = source.text("url")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "尚未填寫網址" }
        return url(text)?.host() ?? text
    }

    /// 資料出處：來源設定的出處（範本建立的來源有，例如「中央氣象署」），沒有時是網址的主機名稱。
    static func attribution(_ source: FormlessSource, url: URL) -> String? {
        source.text("attribution") ?? url.host()
    }

    static func availability(_ source: FormlessSource) -> FormlessDataStatus {
        (source.text("url")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty ? .notConfigured : .loading
    }

    static let urlSetting = FormlessSettingSpec(id: "url", name: "網址", kind: .url)
}

/// 重建過的欄位說明（最多記 32 份，滿了全部清掉）。
final class FormlessWebSpecCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [FormlessFieldSpec]] = [:]

    func specs(for key: String, make: () -> [FormlessFieldSpec]) -> [FormlessFieldSpec] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[key] { return hit }
        if storage.count >= 32 { storage.removeAll() }
        let made = make()
        storage[key] = made
        return made
    }
}

extension FormlessValue {
    /// 存進快照前的大小限制：清單最多 items 筆、文字最多 text 個字（清單、一筆資料裡面的也算）。
    func formlessCapped(items limit: Int = 100, text textLimit: Int = 2000) -> FormlessValue {
        switch self {
        case .text(let text) where text.utf8.count > textLimit && text.count > textLimit:
            return .text(String(text.prefix(textLimit)))
        case .list(let items):
            return .list(items.prefix(limit).map { $0.formlessCapped(items: limit, text: textLimit) })
        case .record(var record):
            for (key, value) in record.fields { record.fields[key] = value.formlessCapped(items: limit, text: textLimit) }
            return .record(record)
        default:
            return self
        }
    }
}

// MARK: - JSON

/// 任何回傳 JSON 的網址。欄位依抓回來的內容產生：物件的每個鍵、陣列（清單，第幾筆的欄位是元素裡的鍵）。
struct FormlessJSONDataProvider: FormlessDataProvider {
    let id = "json"
    let name = "JSON"
    let symbol = "curlybraces"
    let category = FormlessDataCategory.web
    var lifetime: TimeInterval { FormlessWebRefresh.defaultLifetime }
    var allowsInstances: Bool { true }

    /// 快照裡的欄位說明（隱藏項目）。「[」後面不是引號或「]」的鍵不會是 JSON 路徑，不會和欄位撞名。
    static let fieldsKey = "[fields]"
    static let maxDepth = 6
    static let maxFields = 300
    static let maxItems = 100

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "url", name: "網址", kind: .url, footer: "回傳 JSON 的網址，用 GET 讀取。"),
            FormlessSettingSpec(id: "headers", name: "標頭", kind: .lines,
                                footer: "選填。一行一個「名稱: 值」，例如 Authorization: Bearer 金鑰。"),
            FormlessWebRefresh.setting
        ]
    }

    static func lifetime(for source: FormlessSource) -> TimeInterval { FormlessWebRefresh.lifetime(for: source) }

    func summary(for source: FormlessSource) -> String { FormlessWebFetch.summary(source) }

    /// 完整網址；有標頭時加上標頭的雜湊（金鑰不寫進檔名）。
    func cacheKey(for source: FormlessSource) -> String {
        let headers = source.list("headers").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let key = "json:" + FormlessWebFetch.normalized(source.text("url"))
        return headers.isEmpty ? key : key + "|" + String(headers.joined(separator: "\n").hashValueStable)
    }

    func availability(for source: FormlessSource) -> FormlessDataStatus { FormlessWebFetch.availability(source) }

    /// 還沒抓過時沒有欄位（面板顯示狀態）。欄位說明重建一次約 0.5 ms（300 個欄位），排版時每個綁定都會查，
    /// 所以同一份快照（同一個來源、同一次抓取）只重建一次。
    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        guard let snapshot, let descriptor = snapshot.values[Self.fieldsKey] else { return [] }
        let key = cacheKey(for: source) + "|" + String(snapshot.fetchedAt.timeIntervalSince1970) + "|" + String(descriptor.listValue?.count ?? 0)
        return Self.specCache.specs(for: key) { Self.specs(from: descriptor) }
    }

    private static let specCache = FormlessWebSpecCache()

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        field == Self.fieldsKey ? .empty : snapshotValue(field, snapshot)
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        guard let text = source.text("url"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.notConfigured, "還沒有填網址")
        }
        guard let url = FormlessWebFetch.url(text) else { return .failure(.failed, FormlessWebFetch.Failure.invalidURL.message) }
        let headers = FormlessWebFetch.headers(source.list("headers"))
        switch await FormlessWebFetch.get(url, headers: headers, accept: "application/json, text/json;q=0.9, */*;q=0.5") {
        case .failure(let failure): return .failure(.failed, failure.message)
        case .success(let response): return Self.snapshot(from: response.data, attribution: FormlessWebFetch.attribution(source, url: url))
        }
    }

    // MARK: 整理成快照

    /// 抓回來的 JSON 整理成快照：每個欄位的值先算好；清單的每一筆另外攤平成「author.name」這種鍵，
    /// 第幾筆的欄位直接查得到。另外存一份欄位說明，fields(for:snapshot:) 依它產生欄位。
    static func snapshot(from data: Data, fetchedAt: Date = Date(), attribution: String? = nil) -> FormlessSnapshot {
        guard let json = try? FormlessJSONPath.parse(data) else { return .failure(.failed, "回應不是 JSON 格式") }
        let all = FormlessJSONPath.fields(in: json, maxDepth: maxDepth, maxFields: maxFields)

        // 每個欄位的上一層（深度優先的清單裡，前面最近一個深度少一的欄位）、是不是在陣列元素裡面。
        var parent = [Int?](repeating: nil, count: all.count)
        var insideArray = [Bool](repeating: false, count: all.count)
        var lastAtDepth: [Int] = []
        for (index, field) in all.enumerated() {
            lastAtDepth.removeSubrange(min(field.depth, lastAtDepth.count)...)
            if field.depth > 0, field.depth <= lastAtDepth.count {
                let up = lastAtDepth[field.depth - 1]
                parent[index] = up
                insideArray[index] = all[up].isCollection || insideArray[up]
            }
            lastAtDepth.append(index)
        }
        /// 顯示名稱：路徑最後一段；上一層是物件時加上它的名稱（rates › TWD）。
        func displayName(_ index: Int) -> String {
            let field = all[index]
            if field.path == "[]" { return "清單" }
            if field.path.isEmpty { return "值" }
            guard let up = parent[index], all[up].kind == .record, !all[up].isCollection else { return field.name }
            return all[up].name + " › " + field.name
        }
        func descriptor(_ id: String, _ name: String, _ kind: FormlessValueKind, items: [FormlessValue] = []) -> FormlessValue {
            var fields: [String: FormlessValue] = ["name": .text(name), "kind": .text(kind.rawValue)]
            if !items.isEmpty { fields["items"] = .list(items) }
            return .record(FormlessRecord(id: id, fields: fields))
        }

        /// 最上層欄位（不在陣列裡）的 JSON 節點：從根沿著上層的鍵往下走。
        func node(_ index: Int) -> FormlessJSON? {
            var chain: [Int] = []
            var current: Int? = index
            while let step = current { chain.append(step); current = parent[step] }
            var result: FormlessJSON? = json
            for step in chain.reversed() where all[step].path != "[]" && !all[step].path.isEmpty { result = result?[all[step].name] }
            return result
        }

        var values: [String: FormlessValue] = [:]
        var descriptors: [FormlessValue] = []
        for (index, field) in all.enumerated() where !insideArray[index] {
            let id = field.path.isEmpty ? "value" : field.path
            let json = node(index)
            if field.isCollection {
                // 元素裡的欄位：子孫裡不在更深一層陣列裡的，id 是相對於元素的路徑（title、author.name）。
                let prefix = field.path == "[]" ? "[]" : field.path + "[]"
                var items: [(id: String, name: String, kind: FormlessValueKind)] = []
                var next = index + 1
                while next < all.count, all[next].depth > field.depth {
                    defer { next += 1 }
                    let child = all[next]
                    guard child.path.hasPrefix(prefix), let up = parent[next] else { continue }
                    // 中間隔著別的陣列（陣列裡的陣列）時取不到，略過
                    var ancestor: Int? = up
                    var blocked = false
                    while let current = ancestor, current != index {
                        if all[current].isCollection { blocked = true; break }
                        ancestor = parent[current]
                    }
                    let rest = child.path.dropFirst(prefix.count)
                    guard !blocked, !rest.hasPrefix("[]") else { continue }
                    let relative = rest.hasPrefix(".") ? String(rest.dropFirst()) : String(rest)
                    guard !relative.isEmpty else { continue }
                    items.append((relative, displayName(next), child.kind))
                }
                // 只轉換前 100 個元素；元素裡的巢狀欄位攤平成「author.name」這種鍵。
                guard case .array(let elements)? = json else { continue }
                values[id] = .list(elements.prefix(maxItems).enumerated().map { position, element in
                    guard case .record(var record) = element.value(id: String(position)) else {
                        return element.value(id: String(position)).formlessCapped()
                    }
                    for item in items where record.fields[item.id] == nil {
                        let value = FormlessJSONPath.value(at: item.id, in: element)
                        if !value.isEmpty { record.fields[item.id] = value }
                    }
                    return FormlessValue.record(record).formlessCapped()
                })
                descriptors.append(descriptor(id, displayName(index), .list,
                                              items: items.map { descriptor($0.id, $0.name, $0.kind) }))
            } else if field.kind == .record {
                // 物件：只存一層的文字、數字、日期（裡面的物件與清單本身也是欄位）。
                let children = all.indices.filter { parent[$0] == index && all[$0].kind != .record && all[$0].kind != .list }
                var record = json?.value(id: field.name).recordValue ?? FormlessRecord(id: field.name)
                record.fields = record.fields.filter { $0.value.kind != .record && $0.value.kind != .list }
                values[id] = FormlessValue.record(record).formlessCapped()
                descriptors.append(descriptor(id, displayName(index), .record,
                                              items: children.map { descriptor(all[$0].name, all[$0].name, all[$0].kind) }))
            } else {
                let value = (json?.value(id: field.name) ?? .empty).formlessCapped()
                if !value.isEmpty { values[id] = value }
                descriptors.append(descriptor(id, displayName(index), field.kind))
            }
        }
        values[fieldsKey] = .list(descriptors)
        return FormlessSnapshot(values: values, fetchedAt: fetchedAt, status: descriptors.isEmpty ? .empty : .ok,
                                attribution: attribution)
    }

    /// 快照裡的欄位說明轉回欄位。
    static func specs(from descriptor: FormlessValue?) -> [FormlessFieldSpec] {
        func spec(_ record: FormlessRecord, items: [FormlessFieldSpec]) -> FormlessFieldSpec {
            FormlessFieldSpec(record.id, record["name"].rawString ?? record.id,
                              FormlessValueKind(rawValue: record["kind"].rawString ?? "") ?? .text, items: items)
        }
        return (descriptor?.listValue ?? []).compactMap(\.recordValue).map { record in
            spec(record, items: (record["items"].listValue ?? []).compactMap(\.recordValue).map { spec($0, items: []) })
        }
    }
}

// MARK: - RSS 訂閱

/// RSS 2.0、RSS 1.0 與 Atom 訂閱。
struct FormlessFeedDataProvider: FormlessDataProvider {
    let id = "rss"
    let name = "RSS 訂閱"
    let symbol = "dot.radiowaves.up.forward"
    let category = FormlessDataCategory.web
    var lifetime: TimeInterval { FormlessWebRefresh.defaultLifetime }
    var allowsInstances: Bool { true }
    static let maxItems = 100

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "url", name: "網址", kind: .url, footer: "RSS 或 Atom 訂閱網址。"),
            FormlessWebRefresh.setting
        ]
    }

    static func lifetime(for source: FormlessSource) -> TimeInterval { FormlessWebRefresh.lifetime(for: source) }

    func summary(for source: FormlessSource) -> String { FormlessWebFetch.summary(source) }
    func cacheKey(for source: FormlessSource) -> String { "rss:" + FormlessWebFetch.normalized(source.text("url")) }
    func availability(for source: FormlessSource) -> FormlessDataStatus { FormlessWebFetch.availability(source) }

    /// 每一則的欄位，和 `FormlessFeed.value` 產生的一筆資料相同。
    static let itemFields: [FormlessFieldSpec] = {
        let now = Date()
        return [
            FormlessFieldSpec("title", "標題", .text, sample: .text("今天的頭條新聞")),
            FormlessFieldSpec("link", "網址", .text, sample: .text("https://example.com/news")),
            FormlessFieldSpec("date", "發布時間", .date, sample: .date(now.addingTimeInterval(-1800))),
            FormlessFieldSpec("summary", "摘要", .text, sample: .text("新聞的前幾句話。")),
            FormlessFieldSpec("author", "作者", .text, sample: .text("編輯部")),
            FormlessFieldSpec("image", "圖片", .image)
        ]
    }()

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let sample = FormlessValue.record(FormlessRecord(id: "sample", fields: Dictionary(uniqueKeysWithValues:
            Self.itemFields.filter { !$0.sample.isEmpty }.map { ($0.id, $0.sample) })))
        let now = Date()
        return [
            FormlessFieldSpec("title", "訂閱名稱", .text, sample: .text("新聞")),
            FormlessFieldSpec("items", "文章", .list, sample: .list([sample, sample, sample]), items: Self.itemFields),
            FormlessFieldSpec("latestTitle", "最新文章標題", .text, sample: .text("今天的頭條新聞")),
            FormlessFieldSpec("latestLink", "最新文章網址", .text, sample: .text("https://example.com/news")),
            FormlessFieldSpec("latestDate", "最新文章時間", .date, sample: .date(now.addingTimeInterval(-1800))),
            FormlessFieldSpec("latestImage", "最新文章圖片", .image),
            FormlessFieldSpec("count", "文章數", .number, unit: .count, sample: .number(20, .count))
        ]
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        snapshotValue(field, snapshot)
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        guard let text = source.text("url"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.notConfigured, "還沒有填網址")
        }
        guard let url = FormlessWebFetch.url(text) else { return .failure(.failed, FormlessWebFetch.Failure.invalidURL.message) }
        let accept = "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5"
        switch await FormlessWebFetch.get(url, accept: accept) {
        case .failure(let failure): return .failure(.failed, failure.message)
        case .success(let response):
            var snapshot = Self.snapshot(from: response.data, attribution: url.host())
            if let attribution = source.text("attribution") { snapshot.attribution = attribution }
            return snapshot
        }
    }

    /// 抓回來的訂閱整理成快照。最新一則是時間最晚的那一則（都沒有時間時是第一則）；文章數是訂閱裡的總數。
    static func snapshot(from data: Data, fetchedAt: Date = Date(), attribution: String? = nil) -> FormlessSnapshot {
        let feed: FormlessFeed
        do {
            feed = try FormlessFeedParser.parse(data)
        } catch {
            return .failure(.failed, (error as? LocalizedError)?.errorDescription ?? "不是 RSS 或 Atom 訂閱源")
        }
        let kept = FormlessFeed(title: feed.title, link: feed.link, items: Array(feed.items.prefix(maxItems)))
        var values: [String: FormlessValue] = [
            "items": (kept.value.recordValue?["items"] ?? .list([])).formlessCapped(items: maxItems),
            "count": .number(Double(feed.items.count), .count)
        ]
        values["title"] = .optionalText(feed.title)
        let latest = feed.items.enumerated().max { a, b in
            let left = a.element.date ?? .distantPast, right = b.element.date ?? .distantPast
            return left != right ? left < right : a.offset > b.offset
        }?.element
        if let latest {
            values["latestTitle"] = .optionalText(latest.title)
            values["latestLink"] = .optionalText(latest.link)
            values["latestDate"] = .optionalDate(latest.date)
            if let image = latest.imageURL, !image.isEmpty { values["latestImage"] = .image(image) }
        }
        return FormlessSnapshot(values: values.filter { !$0.value.isEmpty || $0.key == "items" }, fetchedAt: fetchedAt,
                                status: feed.items.isEmpty ? .empty : .ok,
                                attribution: feed.title.isEmpty ? attribution : feed.title)
    }
}

// MARK: - CSV 表格

/// CSV 檔（第一列是欄位名稱）。每一列是一筆資料；數字欄另外整理成 {數值, 標籤} 的清單給圖表用。
struct FormlessCSVDataProvider: FormlessDataProvider {
    let id = "csv"
    let name = "CSV 表格"
    let symbol = "tablecells"
    let category = FormlessDataCategory.web
    var lifetime: TimeInterval { FormlessWebRefresh.defaultLifetime }
    var allowsInstances: Bool { true }

    /// 快照裡的欄說明（隱藏項目）：依 CSV 的順序，每一欄的名稱、型別、是不是標籤欄。
    static let columnsKey = "[columns]"
    static let maxRows = 100

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "url", name: "網址", kind: .url, footer: "CSV 檔的網址，第一列是欄位名稱。"),
            FormlessWebRefresh.setting
        ]
    }

    static func lifetime(for source: FormlessSource) -> TimeInterval { FormlessWebRefresh.lifetime(for: source) }

    func summary(for source: FormlessSource) -> String { FormlessWebFetch.summary(source) }
    func cacheKey(for source: FormlessSource) -> String { "csv:" + FormlessWebFetch.normalized(source.text("url")) }
    func availability(for source: FormlessSource) -> FormlessDataStatus { FormlessWebFetch.availability(source) }

    /// 還沒抓過時沒有欄位（不知道有哪些欄）。
    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let columns = (snapshot?.values[Self.columnsKey]?.listValue ?? []).compactMap(\.recordValue)
        guard !columns.isEmpty else { return [] }
        func kind(_ column: FormlessRecord) -> FormlessValueKind { FormlessValueKind(rawValue: column["kind"].rawString ?? "") ?? .text }
        var specs = [
            FormlessFieldSpec("rows", "列", .list, items: columns.map { FormlessFieldSpec($0.id, $0.id, kind($0)) }),
            FormlessFieldSpec("count", "列數", .number, unit: .count)
        ]
        let label = columns.first { $0["label"].boolValue == true }
        for column in columns where kind(column) == .number {
            var items = [FormlessFieldSpec("value", "數值", .number)]
            if let label { items.append(FormlessFieldSpec("label", label.id, kind(label))) }
            specs.append(FormlessFieldSpec("column." + column.id, column.id + "（整欄）", .list, items: items))
        }
        return specs
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        field == Self.columnsKey ? .empty : snapshotValue(field, snapshot)
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        guard let text = source.text("url"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.notConfigured, "還沒有填網址")
        }
        guard let url = FormlessWebFetch.url(text) else { return .failure(.failed, FormlessWebFetch.Failure.invalidURL.message) }
        switch await FormlessWebFetch.get(url, accept: "text/csv, text/plain;q=0.9, */*;q=0.5") {
        case .failure(let failure): return .failure(.failed, failure.message)
        case .success(let response):
            return Self.snapshot(from: response.data, encodingName: response.encodingName,
                                 attribution: FormlessWebFetch.attribution(source, url: url))
        }
    }

    /// 抓回來的 CSV 整理成快照。每一欄的型別看第一個有值的格子；整欄都沒有值的欄（例如行尾多一個逗號）不列。
    /// 數字欄的標籤用第一個不是數字的欄（名稱、日期），沒有時用第一欄。列數是 CSV 裡的總列數，清單最多存 100 列。
    static func snapshot(from data: Data, encodingName: String? = nil, fetchedAt: Date = Date(),
                         attribution: String? = nil) -> FormlessSnapshot {
        let csv = FormlessCSVParser.parse(text(from: data, encodingName: encodingName))
        // 只轉換存下來的前 100 列；欄的型別只轉換那一欄第一個有值的格子（幾萬列的 CSV 也不必整份轉換）。
        let records = (FormlessCSV(headers: csv.headers, rows: Array(csv.rows.prefix(maxRows))).value.listValue ?? []).compactMap(\.recordValue)
        let columns: [(header: String, kind: FormlessValueKind)] = csv.headers.enumerated().compactMap { column, header in
            guard let cell = csv.rows.lazy.compactMap({ column < $0.count ? $0[column] : nil })
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            let value = FormlessCSV(headers: [header], rows: [[cell]]).value.listValue?.first?.recordValue?[header]
            return (header, value?.kind ?? .text)
        }
        guard !columns.isEmpty else {
            return FormlessSnapshot(values: ["count": .number(0, .count)], fetchedAt: fetchedAt, status: .empty,
                                    message: "CSV 裡沒有資料", attribution: attribution)
        }
        let label = columns.first { $0.kind != .number } ?? columns[0]
        var values: [String: FormlessValue] = [
            "rows": FormlessValue.list(records.map { .record($0) }).formlessCapped(items: maxRows),
            "count": .number(Double(csv.rows.count), .count)
        ]
        for column in columns where column.kind == .number {
            values["column." + column.header] = .list(records.map { row in
                var fields: [String: FormlessValue] = [:]
                if case .number = row[column.header] { fields["value"] = row[column.header] }
                if !row[label.header].isEmpty { fields["label"] = row[label.header].formlessCapped() }
                return .record(FormlessRecord(id: row.id, fields: fields))
            })
        }
        values[columnsKey] = .list(columns.map { column in
            var fields: [String: FormlessValue] = ["kind": .text(column.kind.rawValue)]
            if column.header == label.header { fields["label"] = .bool(true) }
            return .record(FormlessRecord(id: column.header, fields: fields))
        })
        return FormlessSnapshot(values: values, fetchedAt: fetchedAt, status: csv.rows.isEmpty ? .empty : .ok, attribution: attribution)
    }

    /// CSV 的文字：伺服器有宣告編碼就照它；沒有時 UTF-8，不是 UTF-8 時試 Big5（台灣的開放資料常見）。
    static func text(from data: Data, encodingName: String?) -> String {
        if let encodingName {
            let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        for big5 in [CFStringEncodings.dosChineseTrad, .big5_HKSCS_1999, .big5] {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(big5.rawValue)))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

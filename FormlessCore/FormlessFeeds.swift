import Foundation

// MARK: - 網路資料的解析：JSON 路徑、RSS／Atom、CSV
//
// 抓回來的內容在這裡轉成 FormlessJSON／FormlessFeed／FormlessCSV，再轉成資料值（FormlessValue）。
// 只用 Foundation，App 與小工具都會編進來；公開的型別都是值型別，可以跨執行緒傳遞。

// MARK: - JSON

/// 一個 JSON 欄位：路徑、型別、範例文字，給「選擇欄位」的樹狀清單用。
struct FormlessJSONField: Hashable, Sendable, Identifiable {
    var id: String { path }
    /// 例如 "data.items[].title"、"rates.TWD"、"[0].name"；"[]" 表示陣列裡的每一個。
    let path: String
    /// 路徑的最後一段，例如 "title"。
    let name: String
    /// 樹狀清單裡的層級，最上層是 0。
    let depth: Int
    /// 陣列是 .list、物件是 .record，其他依值判斷（文字、數字、是非、日期）。
    let kind: FormlessValueKind
    /// 範例值（最多 40 個字）；陣列是「N 筆」。
    let sample: String
    /// 是陣列（可以重複排列）。
    let isCollection: Bool
}

enum FormlessJSONPath {
    /// 解析 JSON；最外層可以是物件、陣列或單獨一個值。
    static func parse(_ data: Data) throws -> FormlessJSON {
        json(from: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// 路徑上的值。支援 "a.b"、"a[2].b"、"[0]"、含空白或中文的鍵，以及 "[]"（陣列裡的每一個，結果是清單）。
    /// "[n]" 從 0 起算，負數從最後面倒數；鍵裡有 . [ ] 時寫成 ["鍵"]。找不到時是 .empty。
    static func value(at path: String, in json: FormlessJSON) -> FormlessValue {
        resolve(steps(of: path)[...], in: json, id: "")
    }

    /// 給「選擇欄位」用的欄位清單，深度優先。解析後的物件不保留原本的鍵順序，所以依鍵名排序；
    /// 陣列用第一個元素描述一次（路徑加 "[]"），其他元素多出來的鍵也補進來。超過 maxDepth 層、maxFields 個就不再列。
    static func fields(in json: FormlessJSON, maxDepth: Int = 6, maxFields: Int = 300) -> [FormlessJSONField] {
        var fields: [FormlessJSONField] = []
        func add(_ node: FormlessJSON, path: String, name: String, depth: Int, childPrefix: String) {
            guard depth < maxDepth, fields.count < maxFields else { return }
            fields.append(FormlessJSONField(path: path, name: name, depth: depth, kind: kind(of: node),
                                            sample: sample(of: node), isCollection: node.isArray))
            addChildren(of: node, prefix: childPrefix, depth: depth + 1)
        }
        func addChildren(of node: FormlessJSON, prefix: String, depth: Int) {
            switch node {
            case .object(let object):
                for key in object.keys.sorted(by: keyOrder) {
                    let path = join(prefix, key)
                    add(object[key] ?? .null, path: path, name: key, depth: depth, childPrefix: path)
                }
            case .array(let items):
                if let element = representative(of: items) { addChildren(of: element, prefix: prefix + "[]", depth: depth) }
            default:
                break
            }
        }
        switch json {
        case .object: addChildren(of: json, prefix: "", depth: 0)
        // 最外層是陣列：清單本身是 "[]"，元素的欄位是 "[].name"
        case .array: add(json, path: "[]", name: "[]", depth: 0, childPrefix: "")
        default: add(json, path: "", name: "", depth: 0, childPrefix: "")
        }
        return fields
    }

    // MARK: 解析

    private static func json(from object: Any) -> FormlessJSON {
        switch object {
        case let number as NSNumber:
            // JSON 的 true／false 也是 NSNumber，要看是不是 CFBoolean 才分得出來
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String: return .string(text)
        case let array as [Any]: return .array(array.map(json(from:)))
        case let object as [String: Any]: return .object(object.mapValues(json(from:)))
        default: return .null
        }
    }

    // MARK: 路徑

    private enum Step: Hashable {
        case key(String)
        case index(Int)
        case each
    }

    /// 把路徑拆成步驟。開頭的 "$" 可有可無，"[*]" 等同 "[]"。
    private static func steps(of path: String) -> [Step] {
        var rest = Substring(path), steps: [Step] = [], key = ""
        if rest.first == "$", rest.count == 1 || [".", "["].contains(rest.dropFirst().first) { rest = rest.dropFirst() }
        func flush() {
            if !key.isEmpty { steps.append(.key(key)); key = "" }
        }
        while let character = rest.popFirst() {
            if character == "." { flush(); continue }
            guard character == "[" else { key.append(character); continue }
            if let quote = rest.first, quote == "\"" || quote == "'" {
                // ["鍵"]：引號裡的 \ 是跳脫
                flush()
                rest.removeFirst()
                var quoted = ""
                while let next = rest.popFirst(), next != quote {
                    quoted.append(next == "\\" ? (rest.popFirst() ?? next) : next)
                }
                if rest.first == "]" { rest.removeFirst() }
                steps.append(.key(quoted))
                continue
            }
            // 沒有對應的 ] 時，[ 當成鍵的一部分
            guard let close = rest.firstIndex(of: "]") else { key.append(character); continue }
            flush()
            let inner = rest[..<close].trimmingCharacters(in: .whitespaces)
            steps.append(inner.isEmpty || inner == "*" ? Step.each : Int(inner).map { Step.index($0) } ?? .key(inner))
            rest = rest[rest.index(after: close)...]
        }
        flush()
        return steps
    }

    private static func resolve(_ steps: ArraySlice<Step>, in json: FormlessJSON, id: String) -> FormlessValue {
        guard let step = steps.first else { return json.value(id: id) }
        let rest = steps.dropFirst()
        switch (step, json) {
        case (.each, .array(let items)):
            return .list(items.enumerated().map { resolve(rest, in: $0.element, id: String($0.offset)) })
        case (.index(let index), .array(let items)):
            let position = index < 0 ? items.count + index : index
            return items.indices.contains(position) ? resolve(rest, in: items[position], id: String(position)) : .empty
        case (.key(let key), .array(let items)):
            // "items.0.title" 的寫法：數字鍵在陣列上當索引
            guard let position = Int(key), items.indices.contains(position) else { return .empty }
            return resolve(rest, in: items[position], id: key)
        case (.key(let key), .object(let object)):
            return object[key].map { resolve(rest, in: $0, id: key) } ?? .empty
        case (.index(let index), .object(let object)):
            return object[String(index)].map { resolve(rest, in: $0, id: String(index)) } ?? .empty
        default:
            return .empty
        }
    }

    // MARK: 欄位清單

    /// 鍵的順序：數字部分依大小（item2 在 item10 前面）。
    private static func keyOrder(_ a: String, _ b: String) -> Bool {
        let order = a.compare(b, options: .numeric)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }

    /// 路徑接上一個鍵；鍵是空字串、"$"，或含 . [ ] " \ 時寫成 ["鍵"]。
    private static func join(_ prefix: String, _ key: String) -> String {
        guard key.isEmpty || key == "$" || key.contains(where: { ".[]\"\\".contains($0) }) else {
            return prefix.isEmpty ? key : prefix + "." + key
        }
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return prefix + "[\"" + escaped + "\"]"
    }

    private static func kind(of node: FormlessJSON) -> FormlessValueKind {
        switch node {
        case .array: return .list
        case .object: return .record
        default: return node.value().kind ?? .text
        }
    }

    private static func sample(of node: FormlessJSON) -> String {
        switch node {
        case .array(let items): return "\(items.count) 筆"
        case .object, .null: return ""
        case .string(let text): return FormlessText.shortened(text, to: 40)
        default: return FormlessText.shortened(node.value().rawString ?? "", to: 40)
        }
    }

    /// 陣列的代表元素：第一個不是 null 的元素；是物件時，其他元素（前 100 個）多出來的鍵、或第一個元素是 null 的鍵也補進來。
    private static func representative(of items: [FormlessJSON]) -> FormlessJSON? {
        guard let first = items.first(where: { $0 != .null }) else { return nil }
        guard case .object(var merged) = first else { return first }
        for case .object(let object) in items.prefix(100) {
            for (key, value) in object where merged[key] == nil || merged[key] == FormlessJSON.null { merged[key] = value }
        }
        return .object(merged)
    }
}

private extension FormlessJSON {
    var isArray: Bool {
        if case .array = self { return true }
        return false
    }
}

// MARK: - RSS／Atom

/// 訂閱源裡的一則（新聞、文章、發行版本）。
struct FormlessFeedItem: Hashable, Sendable {
    /// guid／id；沒有時用網址，再沒有用標題。
    var id: String
    var title: String
    var link: String?
    var date: Date?
    /// 拿掉 HTML、解開實體、縮空白，最多 300 個字。
    var summary: String?
    var author: String?
    /// 圖片網址：enclosure（圖片）、media:content、media:thumbnail、itunes:image，或內文的第一張 <img>。
    var imageURL: String?
}

/// 一個 RSS 或 Atom 訂閱源。
struct FormlessFeed: Hashable, Sendable {
    var title: String
    var link: String?
    var items: [FormlessFeedItem]

    /// 轉成資料值：一筆資料 {title, link, items: 清單，每一則是 {title, link, date, summary, author, image}}；沒有的欄位不放。
    var value: FormlessValue {
        var fields: [String: FormlessValue] = ["items": .list(items.map { .record($0.record) })]
        if !title.isEmpty { fields["title"] = .text(title) }
        if let link, !link.isEmpty { fields["link"] = .text(link) }
        return .record(FormlessRecord(id: link ?? title, fields: fields))
    }
}

private extension FormlessFeedItem {
    var record: FormlessRecord {
        var fields: [String: FormlessValue] = [:]
        if !title.isEmpty { fields["title"] = .text(title) }
        if let link, !link.isEmpty { fields["link"] = .text(link) }
        if let date { fields["date"] = .date(date, allDay: false) }
        if let summary, !summary.isEmpty { fields["summary"] = .text(summary) }
        if let author, !author.isEmpty { fields["author"] = .text(author) }
        if let imageURL, !imageURL.isEmpty { fields["image"] = .image(imageURL) }
        return FormlessRecord(id: id, fields: fields)
    }
}

/// 讀不出訂閱源的原因。
enum FormlessFeedError: LocalizedError, Sendable {
    /// 內容不是 XML（空的、JSON、純文字）。
    case notXML
    /// 是 XML 但不是 RSS 或 Atom（例如網頁）。
    case unknownFormat

    var errorDescription: String? {
        switch self {
        case .notXML: return "內容不是 XML 格式"
        case .unknownFormat: return "不是 RSS 或 Atom 訂閱源"
        }
    }
}

enum FormlessFeedParser {
    /// 讀 RSS 2.0、RSS 1.0（RDF）與 Atom；不是 XML 或根元素不認得時丟出 FormlessFeedError。
    /// XML 有錯（沒跳脫的 &、&nbsp; 這類 HTML 實體、控制字元、開頭的雜訊）時修過再讀一次；中途壞掉時留下壞掉之前讀到的。
    static func parse(_ data: Data) throws -> FormlessFeed {
        let first = FormlessFeedReader.read(data)
        if first.complete, let feed = first.feed { return feed }
        let second = FormlessFeedReader.read(repaired(data))
        if second.complete, let feed = second.feed { return feed }
        if let best = [second.feed, first.feed].compactMap({ $0 }).max(by: { $0.items.count < $1.items.count }) { return best }
        throw first.sawElement || second.sawElement ? FormlessFeedError.unknownFormat : FormlessFeedError.notXML
    }

    /// RFC 822／2822（星期、秒可省略，時區可以是 GMT、EST 這類名稱或 +0800；沒寫時區當成 UTC），
    /// 與 ISO 8601（小數秒、時區可省略；沒寫時區用裝置的時區）。
    static func parseDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return FormlessDateText.iso(text)?.date ?? FormlessDateText.rfc822(text)
    }

    /// 拿掉 HTML 標籤（script、style、註解連內容一起拿掉，換段的標籤換成空格），解開實體，縮空白。
    static func stripHTML(_ html: String) -> String {
        FormlessText.strip(html)
    }

    /// 修掉常見的 XML 錯誤再讀：開頭的雜訊、沒跳脫的 & 與 <、HTML 才有的實體、不合法的數字實體與控制字元。CDATA 裡不動。
    /// 以位元組處理，UTF-8、Big5、ISO-8859-1 這類與 ASCII 相容的編碼都適用。
    private static func repaired(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        func starts(_ pattern: String, at index: Int) -> Bool { bytes[index...].starts(with: pattern.utf8) }
        func find(_ pattern: String, before end: Int) -> Int? { (0..<end).first { starts(pattern, at: $0) } }
        func isNameStart(_ byte: UInt8) -> Bool {
            (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":") || byte >= 0x80
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 256)
        // 從 XML 宣告（根元素之前的才算，內文裡提到的不算）或根元素開始讀：前面可能有網站的錯誤訊息
        let root = ["<rss", "<feed", "<rdf:RDF", "<atom:feed"].compactMap { find($0, before: bytes.count) }.min()
        var index = find("<?xml", before: root ?? bytes.count) ?? root ?? bytes.firstIndex(of: UInt8(ascii: "<")) ?? bytes.count
        var inCDATA = false
        while index < bytes.count {
            let byte = bytes[index]
            if inCDATA {
                if byte == UInt8(ascii: "]"), starts("]]>", at: index) { inCDATA = false; out.append(contentsOf: "]]>".utf8); index += 3; continue }
            } else if byte == UInt8(ascii: "<") {
                if starts("<![CDATA[", at: index) { inCDATA = true; out.append(contentsOf: "<![CDATA[".utf8); index += 9; continue }
                let next = index + 1 < bytes.count ? bytes[index + 1] : 0
                if !(isNameStart(next) || [UInt8(ascii: "/"), UInt8(ascii: "!"), UInt8(ascii: "?")].contains(next)) {
                    out.append(contentsOf: "&lt;".utf8); index += 1; continue
                }
            } else if byte == UInt8(ascii: "&") {
                var end = index + 1
                while end < bytes.count, end - index <= 32, bytes[end] == UInt8(ascii: "#") || isNameStart(bytes[end]) && bytes[end] < 0x80 || (0x30...0x39).contains(bytes[end]) { end += 1 }
                if end < bytes.count, bytes[end] == UInt8(ascii: ";"), end > index + 1 {
                    let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    if name.hasPrefix("#") {
                        // 數字實體：XML 不允許的字元（&#0;、控制字元）直接拿掉
                        if FormlessText.isXMLCharacterReference(name) { out.append(contentsOf: bytes[index...end]) }
                        index = end + 1; continue
                    }
                    if ["amp", "lt", "gt", "quot", "apos"].contains(name) { out.append(contentsOf: bytes[index...end]); index = end + 1; continue }
                    if let scalar = FormlessText.namedEntities[name] { out.append(contentsOf: "&#\(scalar.value);".utf8); index = end + 1; continue }
                }
                out.append(contentsOf: "&amp;".utf8); index += 1; continue
            }
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { index += 1; continue }
            out.append(byte)
            index += 1
        }
        return Data(out)
    }
}

/// XMLParser 的委派：邊讀邊收集頻道與每一則的元素文字、屬性，讀完再整理成 FormlessFeed。
private final class FormlessFeedReader: NSObject, XMLParserDelegate {
    enum Format { case rss, rdf, atom }

    struct Tag {
        let name: String
        /// 相對於所在範圍（頻道或一則）的深度：一則本身是 0，直接子元素是 1。
        let depth: Int
        let attributes: [String: String]
    }

    /// 頻道或一則的原始內容。
    struct Entry {
        /// 直接子元素（與 author、media:group 裡面一層，鍵寫成 "author/name"）的文字。同名的取第一個不是空的。
        var texts: [String: String] = [:]
        /// 有屬性的元素（一則裡面任何深度；頻道只收直接子元素）。
        var tags: [Tag] = []

        func attribute(_ key: String, of name: String) -> String? {
            tags.first { $0.depth == 1 && $0.name == name }?.attributes[key]
        }

        func text(_ keys: String...) -> String? {
            keys.lazy.compactMap { FormlessText.nonEmpty(texts[$0]) }.first
        }

        mutating func store(_ text: String, for key: String) {
            if FormlessText.nonEmpty(texts[key]) == nil { texts[key] = text }
        }
    }

    /// 裡面一層的元素也要收的容器（Atom 的 <author><name>、Media RSS 的 <media:group>）。
    private static let atomContainers: Set<String> = ["author", "contributor", "source", "media:group"]
    private static let rssContainers: Set<String> = ["media:group"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp"]
    private static let mediaExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "mp4", "m4v",
                                                       "mov", "webm", "mkv", "avi", "pdf", "zip"]

    private var format: Format?
    private var sawElement = false
    private var stack: [String] = []
    private var channel = Entry()
    private var entries: [Entry] = []
    private var entry: Entry?
    private var entryDepth = 0
    private var capture: (key: String, depth: Int)?
    private var buffer = ""

    static func read(_ data: Data) -> (feed: FormlessFeed?, complete: Bool, sawElement: Bool) {
        let reader = FormlessFeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        let complete = parser.parse()
        return (reader.feed(), complete, reader.sawElement)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // Atom 的元素偶爾寫成 atom:entry，去掉字首一樣處理
        let name = format == .atom && elementName.hasPrefix("atom:") ? String(elementName.dropFirst(5)) : elementName
        let depth = stack.count
        stack.append(name)
        guard sawElement else {
            sawElement = true
            switch name {
            case "rss": format = .rss
            case "rdf:RDF", "RDF": format = .rdf
            case "feed", "atom:feed": format = .atom
            default: parser.abortParsing()
            }
            return
        }
        // 擷取中的元素裡面還有元素（Atom 的 xhtml、沒包 CDATA 的 HTML）：還原成標籤，之後一起當 HTML 處理
        if capture != nil {
            buffer += "<" + name + attributeDict.map { " \($0.key)=\"\(FormlessText.escapeAttribute($0.value))\"" }.joined() + ">"
            return
        }
        if entry == nil, name == (format == .atom ? "entry" : "item") {
            entry = Entry()
            entryDepth = depth
            if !attributeDict.isEmpty { entry?.tags.append(Tag(name: name, depth: 0, attributes: attributeDict)) }
            return
        }
        // 所在範圍：一則裡面，或頻道（RSS 是 channel，Atom 是根元素 feed）
        let base: Int
        if entry != nil { base = entryDepth }
        else if format == .atom { base = 0 }
        else if stack.count > 2, stack[1] == "channel" { base = 1 }
        else { return }
        let relative = depth - base
        if !attributeDict.isEmpty, entry != nil || relative == 1 {
            let tag = Tag(name: name, depth: relative, attributes: attributeDict)
            if entry != nil { entry?.tags.append(tag) } else { channel.tags.append(tag) }
        }
        let containers = format == .atom ? Self.atomContainers : Self.rssContainers
        let parent = stack[depth - 1]
        if relative == 1, !containers.contains(name) {
            capture = (name, depth); buffer = ""
        } else if relative == 2, containers.contains(parent) {
            capture = (parent + "/" + name, depth); buffer = ""
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let name = stack.popLast() else { return }
        let depth = stack.count
        if let capture {
            guard depth <= capture.depth else { buffer += "</" + name + ">"; return }
            self.capture = nil
            if entry != nil { entry?.store(buffer, for: capture.key) } else { channel.store(buffer, for: capture.key) }
        } else if let entry, depth == entryDepth {
            entries.append(entry)
            self.entry = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capture != nil { buffer += String(decoding: CDATABlock, as: UTF8.self) }
    }

    /// 有外部 DTD 的訂閱源（RSS 0.91）裡沒宣告的實體（&eacute;）會到這裡，不處理會直接消失：換成對應的字。
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        if capture != nil, let scalar = FormlessText.namedEntities[name] { buffer.unicodeScalars.append(scalar) }
        return nil
    }

    // MARK: 整理

    private func feed() -> FormlessFeed? {
        guard let format else { return nil }
        var raws = entries
        // 讀到一半壞掉時，最後一則有標題或網址才留下
        if let entry, entry.text("title", "link") != nil { raws.append(entry) }
        let channelLink = Self.link(of: channel, format: format)
        let channelAuthor = FormlessText.plainText(channel.texts["author/name"])
        var seen = Set<String>()
        let items = raws.enumerated().map { index, raw -> FormlessFeedItem in
            var item = Self.item(from: raw, format: format, base: channelLink)
            if item.author == nil { item.author = channelAuthor }
            if item.id.isEmpty { item.id = String(index) }
            if !seen.insert(item.id).inserted { item.id += "#\(index)" }
            return item
        }
        let title = FormlessText.plainText(channel.texts["title"], html: Self.isHTML(channel, "title", format)) ?? ""
        return FormlessFeed(title: title, link: channelLink, items: items)
    }

    private static func item(from raw: Entry, format: Format, base: String?) -> FormlessFeedItem {
        let link = resolve(self.link(of: raw, format: format), base: base)
        let title = FormlessText.plainText(raw.texts["title"], html: isHTML(raw, "title", format)) ?? ""
        let id = raw.text("guid", "id") ?? raw.tags.first { $0.depth == 0 }?.attributes["rdf:about"] ?? link ?? title
        let date = ["pubDate", "published", "dc:date", "updated", "dc:modified"].lazy
            .compactMap { raw.texts[$0].flatMap(FormlessFeedParser.parseDate) }.first
        // 摘要：description（Atom 是 summary）優先；只有圖片、拿掉 HTML 後沒有字時改用全文
        let summary = ["description", "summary", "content:encoded", "content", "media:group/media:description", "media:description"].lazy
            .compactMap { key in raw.texts[key].flatMap { FormlessText.plainText($0, html: isHTML(raw, key, format)) } }
            .first.map { FormlessText.shortened($0, to: 300) }
        return FormlessFeedItem(id: id, title: title, link: link, date: date, summary: summary,
                                author: authorName(raw.text("author/name", "dc:creator", "author", "itunes:author")),
                                imageURL: resolve(imageURL(of: raw, link: link), base: link ?? base))
    }

    /// 內容是不是 HTML：RSS 的 description、content:encoded 是；Atom 看 type 屬性（html、xhtml）。
    private static func isHTML(_ raw: Entry, _ key: String, _ format: Format) -> Bool {
        if format == .atom { return raw.attribute("type", of: key)?.lowercased().contains("html") ?? false }
        return key == "description" || key == "content:encoded"
    }

    /// 網址：rel="alternate"（或沒寫 rel）的 <link href>；RSS 是 <link> 的文字，沒有時用當作永久連結的 guid，RSS 1.0 用 rdf:about。
    private static func link(of raw: Entry, format: Format) -> String? {
        if let tag = raw.tags.first(where: { $0.depth == 1 && $0.name == "link" && $0.attributes["href"] != nil
                                             && ($0.attributes["rel"] ?? "alternate") == "alternate" }) {
            return tag.attributes["href"]
        }
        if let text = raw.text("link") { return text }
        if format == .rss, let guid = raw.text("guid"), guid.lowercased().hasPrefix("http"),
           raw.attribute("isPermaLink", of: "guid")?.lowercased() != "false" {
            return guid
        }
        return raw.tags.first { $0.depth == 0 }?.attributes["rdf:about"]
    }

    /// 圖片：enclosure（圖片）→ media:content（圖片，取最寬的）→ media:thumbnail → itunes:image → 內文的第一張圖。
    private static func imageURL(of raw: Entry, link: String?) -> String? {
        let tags = raw.tags
        if let tag = tags.first(where: { ($0.name == "enclosure" || $0.name == "link" && $0.attributes["rel"] == "enclosure") && isImage($0) }) {
            return tag.attributes["url"] ?? tag.attributes["href"]
        }
        if let tag = tags.filter({ $0.name == "media:content" && isImage($0) })
            .max(by: { Int($0.attributes["width"] ?? "") ?? 0 < Int($1.attributes["width"] ?? "") ?? 0 }) {
            return tag.attributes["url"]
        }
        if let url = tags.first(where: { $0.name == "media:thumbnail" && $0.attributes["url"] != nil })?.attributes["url"] { return url }
        if let url = tags.first(where: { $0.name == "itunes:image" && $0.attributes["href"] != nil })?.attributes["href"] { return url }
        return ["content:encoded", "content", "description", "summary"].lazy.compactMap { key in
            raw.texts[key].flatMap { firstImage(in: $0, acceptsBareURL: key == "content:encoded", link: link) }
        }.first
    }

    private static func isImage(_ tag: Tag) -> Bool {
        guard let url = FormlessText.nonEmpty(tag.attributes["url"] ?? tag.attributes["href"]) else { return false }
        if let medium = FormlessText.nonEmpty(tag.attributes["medium"]) { return medium.lowercased() == "image" }
        if let type = FormlessText.nonEmpty(tag.attributes["type"]) { return type.lowercased().hasPrefix("image/") }
        return !mediaExtensions.contains(pathExtension(url))
    }

    private static let imageTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
    private static let sourceAttribute = try! NSRegularExpression(
        pattern: #"(?<![\w-])src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, options: .caseInsensitive)
    private static let pixelSize = try! NSRegularExpression(
        pattern: #"(?<![\w-])(?:width|height)\s*=\s*["']?[01](?:px)?(?![\d.])"#, options: .caseInsensitive)

    /// 內文的第一張圖（略過 data: 與 1×1 的追蹤像素）。內容只有一個網址時：有圖片副檔名就是圖；
    /// content:encoded 裡沒有副檔名的也算（Yahoo 奇摩新聞這樣放圖），但和這則的網址相同時不算。
    private static func firstImage(in html: String, acceptsBareURL: Bool, link: String?) -> String? {
        let bare = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.lowercased().hasPrefix("http"), !bare.contains(where: { $0.isWhitespace || $0 == "<" }) {
            let fileExtension = pathExtension(bare)
            return imageExtensions.contains(fileExtension) || acceptsBareURL && fileExtension.isEmpty && bare != link ? bare : nil
        }
        guard html.contains("<") else { return nil }
        for match in imageTag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range]), whole = NSRange(tag.startIndex..., in: tag)
            guard pixelSize.firstMatch(in: tag, range: whole) == nil,
                  let source = sourceAttribute.firstMatch(in: tag, range: whole),
                  let value = (1...3).lazy.compactMap({ Range(source.range(at: $0), in: tag) }).first else { continue }
            let url = FormlessText.decodeEntities(String(tag[value])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, !url.lowercased().hasPrefix("data:") { return url }
        }
        return nil
    }

    /// RSS 的 <author> 常寫成「email (名字)」，取括號裡的名字。
    private static func authorName(_ text: String?) -> String? {
        guard let text = FormlessText.plainText(text) else { return nil }
        if text.hasSuffix(")"), let open = text.firstIndex(of: "("), text[..<open].contains("@") {
            let name = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return text
    }

    /// 相對網址（/a.jpg、../a.jpg）依 base 補成完整網址；//cdn 開頭的補 https:。
    private static func resolve(_ url: String?, base: String?) -> String? {
        guard let url = FormlessText.nonEmpty(url) else { return nil }
        if url.hasPrefix("//") { return "https:" + url }
        guard URL(string: url)?.scheme == nil, let base, let baseURL = URL(string: base), baseURL.scheme != nil else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }

    private static func pathExtension(_ url: String) -> String {
        URL(string: url)?.pathExtension.lowercased() ?? ""
    }
}

// MARK: - CSV

/// 一份 CSV：第一列是欄位名稱，其他列是資料。
struct FormlessCSV: Hashable, Sendable {
    var headers: [String]
    var rows: [[String]]

    /// 每一列一筆資料：欄位名是標題；看起來像數字的轉成 .number，像日期（yyyy-MM-dd 或 ISO 8601）的轉成 .date。
    var value: FormlessValue {
        .list(rows.enumerated().map { index, row -> FormlessValue in
            var fields: [String: FormlessValue] = [:]
            for (header, cell) in zip(headers, row) {
                let value = FormlessCSV.cellValue(cell)
                if value != .empty { fields[header] = value }
            }
            return .record(FormlessRecord(id: String(index), fields: fields))
        })
    }

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"^[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)?(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?%?$"#)

    /// 一格的值：1,234、-3.5、12%（單位是百分比）是數字；2026-10-04、2026/10/4（全天）與 ISO 8601 是日期；其他是文字。
    /// 前面補零的（0050、郵遞區號、電話）與超過 15 位數的（訂單編號）保持文字；空格是 .empty。
    private static func cellValue(_ cell: String) -> FormlessValue {
        let text = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if numberPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            let digits = text.filter(\.isNumber)
            let unsigned = text.drop { $0 == "+" || $0 == "-" }
            let paddedWithZero = unsigned.first == "0" && unsigned.dropFirst().first?.isNumber == true
            if !digits.isEmpty, digits.count <= 15, !paddedWithZero,
               let number = Double(text.filter { $0 != "," && $0 != "%" }), number.isFinite {
                return .number(number, text.hasSuffix("%") ? .percent : .none)
            }
        }
        if let parsed = FormlessDateText.iso(text) { return .date(parsed.date, allDay: !parsed.hasTime) }
        return .text(text)
    }
}

enum FormlessCSVParser {
    /// RFC 4180：引號裡可以有逗號、換行與 ""（一個引號）；行尾 CR、LF、CRLF 都可以；開頭的 UTF-8 BOM 與最後的換行略過。
    /// 第一行沒有逗號、但有分號或 Tab 時，用出現較多的那一個分隔。空白行略過；空的或重複的欄位名稱會補上編號。
    static func parse(_ text: String) -> FormlessCSV {
        let scalars = Array(text.unicodeScalars)
        var index = scalars.first == "\u{FEFF}" ? 1 : 0
        let firstLine = scalars[index...].prefix { $0 != "\n" && $0 != "\r" }
        var delimiter: Unicode.Scalar = ","
        if !firstLine.contains(",") {
            let tabs = firstLine.filter { $0 == "\t" }.count, semicolons = firstLine.filter { $0 == ";" }.count
            if tabs + semicolons > 0 { delimiter = tabs >= semicolons ? "\t" : ";" }
        }
        var rows: [[String]] = [], row: [String] = [], field = String.UnicodeScalarView(), quoted = false
        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            if row.count > 1 || !row[0].isEmpty { rows.append(row) }
            row = []
        }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if quoted {
                guard scalar == "\"" else { field.append(scalar); continue }
                if index < scalars.count, scalars[index] == "\"" { field.append("\""); index += 1 } else { quoted = false }
            } else if scalar == "\"", field.allSatisfy({ $0 == " " }) {
                // 引號開頭的欄位（逗號後面多打的空格也算）
                field = String.UnicodeScalarView()
                quoted = true
            } else if scalar == delimiter {
                endField()
            } else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
                endRow()
            } else {
                field.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        guard let first = rows.first else { return FormlessCSV(headers: [], rows: []) }
        let body = Array(rows.dropFirst())
        var headers: [String] = []
        for column in 0..<max(first.count, body.map(\.count).max() ?? 0) {
            var name = column < first.count ? first[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if name.isEmpty { name = "欄位\(column + 1)" }
            var unique = name, number = 2
            while headers.contains(unique) { unique = "\(name) \(number)"; number += 1 }
            headers.append(unique)
        }
        return FormlessCSV(headers: headers, rows: body)
    }
}

// MARK: - 文字工具

private enum FormlessText {
    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// 連續的空白（含換行、不換行空白）縮成一個空格，去掉頭尾。
    /// 只有全形空白的一段保留原樣：中文標題常用「　」當間隔（「活動曝　打卡送點心」）。
    static func collapse(_ text: String) -> String {
        var result = "", run = ""
        for character in text {
            if character.isWhitespace { run.append(character); continue }
            if !run.isEmpty, !result.isEmpty { result += run.allSatisfy { $0 == "\u{3000}" } ? run : " " }
            run = ""
            result.append(character)
        }
        return result
    }

    /// 縮空白；超過 limit 個字時截斷，最後一個字是「…」。
    static func shortened(_ text: String, to limit: Int) -> String {
        let text = collapse(text)
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// 標題、作者這類文字：解開實體、縮空白；是 HTML（或看起來像）時拿掉標籤。空的是 nil。
    static func plainText(_ text: String?, html: Bool = false) -> String? {
        guard let text else { return nil }
        let cleaned = html || looksLikeHTML(text) ? strip(text) : collapse(decodeEntities(text))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: HTML

    private static let hiddenBlocks = try! NSRegularExpression(
        pattern: #"<(script|style)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let blockTags = try! NSRegularExpression(
        pattern: #"<(?:br|hr|/?(?:p|div|li|ul|ol|tr|td|th|h[1-6]|blockquote|table|section|article|header|footer|figure|figcaption|pre|dd|dt|dl))\b[^>]*>"#,
        options: .caseInsensitive)
    private static let anyTag = try! NSRegularExpression(pattern: #"<[A-Za-z/!?][^>]*>"#)
    private static let htmlHint = try! NSRegularExpression(pattern: #"</[A-Za-z]|<(?:br|img|p)\b"#, options: .caseInsensitive)

    static func strip(_ html: String) -> String {
        var text = decodeEntities(removeTags(html))
        // 跳脫了兩次的 HTML（&amp;lt;p&amp;gt;）解開一次後還是標籤，再拿一次
        if looksLikeHTML(text) { text = decodeEntities(removeTags(text)) }
        return collapse(text)
    }

    /// 有成對的結束標籤或 <br>、<img>、<p>：Array<Int> 這種文字不算。
    static func looksLikeHTML(_ text: String) -> Bool {
        text.contains("<") && htmlHint.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func removeTags(_ html: String) -> String {
        guard html.contains("<") else { return html }
        return [(hiddenBlocks, ""), (blockTags, " "), (anyTag, "")].reduce(html) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }

    // MARK: 實體

    /// 解開 HTML 實體：&amp; &nbsp; &eacute; 這類名稱，與 &#39; &#x27; 這類數字。不認得的保持原樣。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = "", rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            if let semicolon = after.prefix(32).firstIndex(of: ";"), let character = entity(after[..<semicolon]) {
                result.append(character)
                rest = after[after.index(after: semicolon)...]
            } else {
                result.append("&")
                rest = after
            }
        }
        return result + rest
    }

    private static func entity(_ name: Substring) -> Character? {
        guard name.first == "#" else { return namedEntities[String(name)].map(Character.init) }
        let digits = name.dropFirst()
        let isHex = digits.first == "x" || digits.first == "X"
        guard let code = isHex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits) else { return nil }
        // 128–159 依瀏覽器的做法當成 Windows-1252（&#146; 是 ’）
        if (0x80...0x9F).contains(code) { return windows1252[Int(code - 0x80)] }
        guard code != 0, let scalar = Unicode.Scalar(code) else { return "\u{FFFD}" }
        return Character(scalar)
    }

    /// XML 允許的數字實體（&#9; &#10; &#13;、&#32; 以上，不含代理區與 FFFE、FFFF）。
    static func isXMLCharacterReference(_ name: String) -> Bool {
        let digits = name.dropFirst()
        let isHex = digits.first == "x" || digits.first == "X"
        guard let code = isHex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits) else { return false }
        return [0x9, 0xA, 0xD].contains(code) || (0x20...0xD7FF).contains(code) || (0xE000...0xFFFD).contains(code)
            || (0x10000...0x10FFFF).contains(code)
    }

    private static let windows1252 = Array("€\u{81}‚ƒ„…†‡ˆ‰Š‹Œ\u{8D}Ž\u{8F}\u{90}‘’“”•–—˜™š›œ\u{9D}žŸ")

    /// 常用的 HTML 實體名稱：U+00A0–U+00FF 依序，加上引號、破折號、符號。
    static let namedEntities: [String: Unicode.Scalar] = {
        var table: [String: Unicode.Scalar] = [:]
        let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro \
            para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil \
            Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave \
            Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml \
            igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute \
            thorn yuml
            """
        for (offset, name) in latin1.split(separator: " ").enumerated() { table[String(name)] = Unicode.Scalar(UInt32(0xA0 + offset)) }
        let others = """
            quot 34 amp 38 apos 39 lt 60 gt 62 OElig 338 oelig 339 Scaron 352 scaron 353 Yuml 376 fnof 402 circ 710 tilde 732 \
            ensp 8194 emsp 8195 thinsp 8201 zwnj 8204 zwj 8205 lrm 8206 rlm 8207 ndash 8211 mdash 8212 lsquo 8216 rsquo 8217 \
            sbquo 8218 ldquo 8220 rdquo 8221 bdquo 8222 dagger 8224 Dagger 8225 bull 8226 hellip 8230 permil 8240 prime 8242 \
            Prime 8243 lsaquo 8249 rsaquo 8250 frasl 8260 euro 8364 trade 8482 larr 8592 uarr 8593 rarr 8594 darr 8595 \
            harr 8596 minus 8722 infin 8734 ne 8800 le 8804 ge 8805 loz 9674 spades 9824 clubs 9827 hearts 9829 diams 9830
            """.split(separator: " ")
        for pair in stride(from: 0, to: others.count - 1, by: 2) {
            table[String(others[pair])] = UInt32(others[pair + 1]).flatMap(Unicode.Scalar.init)
        }
        return table
    }()
}

// MARK: - 日期文字

private enum FormlessDateText {
    private static let isoPattern = try! NSRegularExpression(
        pattern: #"^([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})(?:(?:T|\s+)([0-9]{1,2}):([0-9]{2})(?::([0-9]{2})(?:[.,]([0-9]+))?)?)?\s*(Z|UTC|GMT|[+-][0-9]{1,2}(?::?[0-9]{2})?)?$"#,
        options: .caseInsensitive)
    private static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    /// RFC 822 的時區名稱，加上幾個常見的（小時）。
    private static let zones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
        "CET": 1, "CEST": 2, "BST": 1, "JST": 9, "KST": 9, "HKT": 8, "SGT": 8, "AEST": 10, "AEDT": 11,
    ]

    /// ISO 8601：2026-10-04、2026/10/4、2026-10-04T15:08、2026-10-04 15:08:09.123+08:00。沒寫時區用裝置的時區。
    static func iso(_ text: String) -> (date: Date, hasTime: Bool)? {
        guard let match = isoPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1...8).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        let numbers = groups.prefix(6).map { $0.flatMap { Int($0) } }
        guard let year = numbers[0], let month = numbers[1], let day = numbers[2],
              let date = make(year, month, day, numbers[3] ?? 0, numbers[4] ?? 0, numbers[5] ?? 0,
                              offset: groups[7].map { offset($0) ?? 0 }) else { return nil }
        let fraction = groups[6].flatMap { Double("0." + $0) } ?? 0
        return (date.addingTimeInterval(fraction), groups[3] != nil)
    }

    /// RFC 822／2822：Sat, 04 Oct 2026 07:08:09 GMT、4 Oct 2026 15:08 +0800；也接受月份在前、GMT+0800、AM／PM、04-Oct-26。
    static func rfc822(_ text: String) -> Date? {
        var day: Int?, month: Int?, year: Int?, hour = 0, minute = 0, second = 0, offset = 0, afternoon: Bool?
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0.isNewline }).flatMap { token in
            token.first?.isNumber == true && token.contains("-") && !token.contains(":") ? token.split(separator: "-") : [token]
        }
        for token in tokens {
            if token.hasPrefix("(") { break }  // 後面的 (UTC)、(台北標準時間) 是註解
            let upper = token.uppercased()
            if token.first?.isNumber == true, token.contains(":") {
                // 時間後面直接接時區或上下午（07:08:09+0800、07:08:09Z、3:08PM）
                var time = Substring(token)
                if let suffixStart = time.firstIndex(where: { $0 == "+" || $0 == "-" || $0.isLetter }) {
                    let suffix = time[suffixStart...].uppercased()
                    if suffix == "AM" || suffix == "PM" { afternoon = suffix == "PM" } else { offset = self.offset(suffix) ?? 0 }
                    time = time[..<suffixStart]
                }
                let parts = time.split(separator: ":")
                guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
                hour = h; minute = m; second = parts.count > 2 ? Int(Double(parts[2]) ?? 0) : 0
            } else if token.first == "+" || token.first == "-" {
                offset = self.offset(String(token)) ?? 0
            } else if let number = Int(token) {
                if day == nil, token.count <= 2 { day = number } else { year = token.count <= 2 ? (number < 50 ? 2000 : 1900) + number : number }
            } else if upper == "AM" || upper == "PM" {
                afternoon = upper == "PM"
            } else if let hours = zones[upper] {
                offset = hours * 3600
            } else if upper.count >= 3, let index = months.firstIndex(of: String(upper.prefix(3))) {
                month = index + 1
            } else if upper.hasPrefix("GMT") || upper.hasPrefix("UTC") {
                offset = self.offset(String(token.dropFirst(3))) ?? 0
            }
            // 其他（星期、不認得的時區）略過
        }
        guard let day, let month, let year else { return nil }
        if let afternoon, hour <= 12 { hour = afternoon ? hour % 12 + 12 : hour % 12 }
        return make(year, month, day, hour, minute, second, offset: offset)
    }

    /// "+08:00"、"+0800"、"+8"、"-0530" 換成秒；Z、UTC、GMT 是 0。
    private static func offset(_ zone: String) -> Int? {
        if let hours = zones[zone.uppercased()] { return hours * 3600 }
        guard let sign = zone.first, sign == "+" || sign == "-" else { return nil }
        let digits = zone.dropFirst().filter { $0 != ":" }
        guard (1...4).contains(digits.count), let number = Int(digits) else { return nil }
        let seconds = digits.count <= 2 ? number * 3600 : number / 100 * 3600 + number % 100 * 60
        return sign == "-" ? -seconds : seconds
    }

    /// 年月日時分秒在指定時區（nil 是裝置的時區）的時刻。
    private static func make(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, offset: Int?) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...24).contains(hour), (0...59).contains(minute),
              (0...60).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if let offset {
            guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
            calendar.timeZone = zone
        } else {
            calendar.timeZone = .current
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}

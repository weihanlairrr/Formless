import Foundation
import CoreFoundation
import CoreGraphics
import CoreText

// MARK: - 匯入的字型
//
// 使用者從「檔案」匯入的字型檔（.ttf .otf .ttc）複製到 App 群組的 Fonts/，清單存在 Fonts/fonts.json，
// App 與小工具延伸都讀同一份。字型註冊只在呼叫的行程有效（`.process`）：App 與小工具延伸是兩個行程，
// 各自呼叫 `registerAll()`。跨行程的「持續」範圍要 Fonts 權限，SideStore 用的免費帳號沒有。
// 文字圖層的字型存成 fontFamily = "custom:<PostScript 名稱>"；字型被刪掉或還沒註冊時畫系統字型。
//
// 小工具的記憶體：CoreText 用記憶體對映讀字型檔，檔案本身是乾淨的頁面，不算進小工具的用量。
// iOS 27 模擬器實測（phys_footprint）：64 MB 的宋體註冊只多 0.03 MB，畫 300～3000 個不同的字多 1.5～1.7 MB；
// 22 MB 的 Arial Unicode、冬青黑體畫 3000 字多 1.1～2.1 MB。用量看畫了多少不同的字，和檔案大小關係不大
// （`FormlessMemoryEstimate` 依此估算）。

/// 一個匯入的字面。TTC 字型集一個檔案有好幾個字面，各是一筆，`fileName` 相同。
struct FormlessImportedFont: Codable, Hashable, Identifiable, Sendable {
    var postScriptName: String
    /// 字型裡的家族名稱（預設語言，多半是英文），同一家族的字面排在一起。
    var familyName: String
    /// 顯示用名稱：優先用字型裡的繁體中文名稱，其次簡體中文，最後是預設名稱；
    /// 常見的英文樣式名稱換成中文（Bold →「粗體」），一般粗細不寫，例如「宋體-繁」「宋體-繁 粗體」。
    var displayName: String
    /// 字型裡的樣式名稱（預設語言，例如 Bold）。
    var styleName: String
    /// Fonts/ 裡的檔名。
    var fileName: String
    /// 字型檔大小（bytes）。同一個檔案的字面記同一個數字。
    var fileSize: Int

    var id: String { postScriptName }

    /// 字型檔超過 15 MB：介面提醒「字型檔很大，小工具可能無法顯示」。
    var isLarge: Bool { fileSize > FormlessFontLibrary.largeFileBytes }
}

extension FormlessImportedFont {
    private enum CodingKeys: String, CodingKey {
        case postScriptName, familyName, displayName, styleName, fileName, fileSize
    }

    /// 清單是 App 寫、小工具讀：欄位缺了用預設值，不要因為一筆讀不懂整份清單就讀不到。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postScriptName = try c.decode(String.self, forKey: .postScriptName)
        fileName = try c.decode(String.self, forKey: .fileName)
        familyName = (try? c.decode(String.self, forKey: .familyName)) ?? postScriptName
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? postScriptName
        styleName = (try? c.decode(String.self, forKey: .styleName)) ?? ""
        fileSize = (try? c.decode(Int.self, forKey: .fileSize)) ?? 0
    }
}

enum FormlessFontLibraryError: LocalizedError, Equatable {
    case noSharedContainer
    case unreadable
    case notAFont
    case alreadyInstalled(String)
    case copyFailed
    case unusable

    var errorDescription: String? {
        switch self {
        case .noSharedContainer:
            return "暫時無法存取字型資料。請重新開啟 App 後再試。"
        case .unreadable:
            return "無法讀取這個檔案。請確認檔案已下載到裝置後再試。"
        case .notAFont:
            return "這個檔案不是字型。"
        case .alreadyInstalled(let name):
            return "「\(name)」已經安裝過了。"
        case .copyFailed:
            return "無法儲存字型。請確認裝置的儲存空間足夠後再試。"
        case .unusable:
            return "這個字型檔已損壞或格式不支援。"
        }
    }
}

enum FormlessFontLibrary {

    static let familyPrefix = "custom:"
    static let manifestName = "fonts.json"
    /// 介面提醒「字型檔很大」的門檻。
    static let largeFileBytes = 15 * 1024 * 1024

    // MARK: fontFamily 的值

    static func familyValue(for postScriptName: String) -> String {
        familyPrefix + postScriptName
    }

    /// "custom:<名稱>" 取出名稱；系統字型（system、rounded…）、空值與空名稱回 nil。
    static func postScriptName(fromFamily family: String?) -> String? {
        guard let family, family.hasPrefix(familyPrefix) else { return nil }
        let name = String(family.dropFirst(familyPrefix.count))
        return name.isEmpty ? nil : name
    }

    // MARK: App 群組的 Fonts/

    /// 讀的時候不建資料夾（小工具延伸只讀）；匯入時才建立。
    static var directoryURL: URL? {
        FormlessStorage.sharedContainerURL?.appendingPathComponent("Fonts", isDirectory: true)
    }

    /// 複製字型檔（.ttf .otf .ttc）到共用資料夾的 Fonts/，驗證、註冊，回傳檔內的所有字面。
    static func importFont(at url: URL) throws -> [FormlessImportedFont] {
        guard let directory = directoryURL else { throw FormlessFontLibraryError.noSharedContainer }
        return try importFont(at: url, into: directory)
    }

    /// 把 Fonts/ 裡的字型註冊到目前的行程（App 與小工具延伸各自要註冊）。可重複呼叫、執行緒安全、只做一次實際註冊。
    static func registerAll() {
        guard let directory = directoryURL else { return }
        registerAll(in: directory)
    }

    static func installed() -> [FormlessImportedFont] {
        guard let directory = directoryURL else { return [] }
        return installed(in: directory)
    }

    /// 同一個檔案的其他字面一起移除，並解除註冊。
    static func remove(_ font: FormlessImportedFont) {
        guard let directory = directoryURL else { return }
        remove(font, from: directory)
    }

    static func isAvailable(_ postScriptName: String) -> Bool {
        ctFont(postScriptName: postScriptName, size: 12) != nil
    }

    /// 量測用的字型；找不到時回 nil。會先確定 Fonts/ 已註冊，呼叫前不必另外註冊。
    static func ctFont(postScriptName: String, size: CGFloat) -> CTFont? {
        registerAll()
        return resolvedFont(postScriptName, size: size)
    }

    // MARK: 指定資料夾（App 用共用資料夾；測試用暫存資料夾，不碰使用者的資料）

    static func importFont(at url: URL, into directory: URL) throws -> [FormlessImportedFont] {
        // 從「檔案」選的檔案是安全範圍的網址，讀之前要先取得權限。
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FormlessFontLibraryError.unreadable
        }

        let faces = try readFaces(at: url)

        if let duplicate = duplicate(of: faces, in: directory) {
            throw FormlessFontLibraryError.alreadyInstalled(duplicate.displayName)
        }

        // 複製在鎖外做：中文字型檔常有 10～30 MB，複製期間不擋住畫面上讀清單、註冊的呼叫。
        let manager = FileManager.default
        let target: URL
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            target = uniqueFileURL(for: url.lastPathComponent, in: directory)
            try manager.copyItem(at: url, to: target)
        } catch {
            throw FormlessFontLibraryError.copyFailed
        }
        let size = (try? manager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0

        return try registry.lock.withLock {
            // 複製期間可能有另一個匯入裝了同一個字型：鎖內再檢查一次。
            var list = manifest(in: directory)
            if let duplicate = faces.first(where: { face in list.contains { $0.postScriptName == face.postScriptName } }) {
                try? manager.removeItem(at: target)
                throw FormlessFontLibraryError.alreadyInstalled(duplicate.displayName)
            }

            // 已經註冊過（105）、與系統字型同名（305）都不算失敗：同名時系統的那一份照樣可用。
            if !register([target]).isEmpty {
                try? manager.removeItem(at: target)
                throw FormlessFontLibraryError.unusable
            }
            registry.registered.insert(target.path)

            let added = faces.map { face -> FormlessImportedFont in
                var face = face
                face.fileName = target.lastPathComponent
                face.fileSize = size
                return face
            }
            list.append(contentsOf: added)

            do {
                try writeManifest(list, in: directory)
            } catch {
                unregister([target])
                registry.registered.remove(target.path)
                try? manager.removeItem(at: target)
                throw FormlessFontLibraryError.copyFailed
            }
            return added
        }
    }

    static func registerAll(in directory: URL) {
        registry.lock.withLock {
            // 清單沒變就什麼都不做：每畫一次文字都可能呼叫到這裡，平常只多一次查檔案時間。
            let stamp = fileStamp(directory.appendingPathComponent(manifestName))
            if let synced = registry.syncedStamps[directory.path], synced == stamp { return }

            let manager = FileManager.default
            var wanted = Set<String>()
            for name in Set(manifest(in: directory, stamp: stamp).map(\.fileName)) where isPlainFileName(name) {
                let path = directory.appendingPathComponent(name).path
                if manager.fileExists(atPath: path) { wanted.insert(path) }
            }

            // App 刪掉的字型：小工具延伸的行程可能還活著，這裡解除註冊。
            let prefix = directory.path + "/"
            let stale = registry.registered.filter { $0.hasPrefix(prefix) && !wanted.contains($0) }
            if !stale.isEmpty {
                unregister(stale.map { URL(fileURLWithPath: $0) })
                registry.registered.subtract(stale)
            }

            // 註冊失敗的檔案（檔案壞了）也記成已處理，不要每次畫文字都再試一次。
            let fresh = wanted.subtracting(registry.registered)
            if !fresh.isEmpty {
                _ = register(fresh.sorted().map { URL(fileURLWithPath: $0) })
                registry.registered.formUnion(fresh)
            }

            registry.syncedStamps.updateValue(stamp, forKey: directory.path)
        }
    }

    /// 同一家族排在一起（依第一次出現的順序），家族裡由細到粗、正體在斜體前。
    static func installed(in directory: URL) -> [FormlessImportedFont] {
        let list = registry.lock.withLock { manifest(in: directory) }
        let manager = FileManager.default
        var exists: [String: Bool] = [:]
        let present = list.filter { font in
            if let known = exists[font.fileName] { return known }
            let found = isPlainFileName(font.fileName)
                && manager.fileExists(atPath: directory.appendingPathComponent(font.fileName).path)
            exists[font.fileName] = found
            return found
        }

        var familyOrder: [String: Int] = [:]
        for font in present where familyOrder[font.familyName] == nil {
            familyOrder[font.familyName] = familyOrder.count
        }
        return present.enumerated().sorted { a, b in
            let familyA = familyOrder[a.element.familyName] ?? 0, familyB = familyOrder[b.element.familyName] ?? 0
            if familyA != familyB { return familyA < familyB }
            let rankA = FormlessFontStyle(a.element.styleName).rank, rankB = FormlessFontStyle(b.element.styleName).rank
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func remove(_ font: FormlessImportedFont, from directory: URL) {
        // 檔名只能是 Fonts/ 裡的一個檔案：清單被改壞時也不會刪到資料夾外面。
        guard isPlainFileName(font.fileName) else { return }
        registry.lock.withLock {
            var list = manifest(in: directory)
            list.removeAll { $0.fileName == font.fileName }
            try? writeManifest(list, in: directory)

            let url = directory.appendingPathComponent(font.fileName)
            if registry.registered.remove(url.path) != nil {
                unregister([url])
            }
            try? FileManager.default.removeItem(at: url)
            registry.syncedStamps.updateValue(fileStamp(directory.appendingPathComponent(manifestName)),
                                              forKey: directory.path)
        }
    }

    // MARK: 讀字型檔

    /// 檔案裡的所有字面。依家族、粗細排好（TTC 的原始順序常是粗細交錯）。
    private static func readFaces(at url: URL) throws -> [FormlessImportedFont] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            throw FormlessFontLibraryError.notAFont
        }

        var faces: [FormlessImportedFont] = []
        for descriptor in descriptors {
            // 還沒註冊的檔案也能從描述建字型（描述裡帶著檔案位置），名稱、字形表都讀得到。
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let postScriptName = CTFontCopyPostScriptName(font) as String
            guard !postScriptName.isEmpty, !faces.contains(where: { $0.postScriptName == postScriptName }) else { continue }
            let familyName = CTFontCopyFamilyName(font) as String
            let styleName = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? ""
            faces.append(FormlessImportedFont(
                postScriptName: postScriptName,
                familyName: familyName.isEmpty ? postScriptName : familyName,
                displayName: displayName(for: font, familyName: familyName, styleName: styleName),
                styleName: styleName,
                fileName: url.lastPathComponent,
                fileSize: 0
            ))
        }
        guard !faces.isEmpty else { throw FormlessFontLibraryError.notAFont }

        return faces.enumerated().sorted { a, b in
            if a.element.familyName != b.element.familyName {
                return a.element.familyName.localizedStandardCompare(b.element.familyName) == .orderedAscending
            }
            let rankA = FormlessFontStyle(a.element.styleName).rank, rankB = FormlessFontStyle(b.element.styleName).rank
            return rankA != rankB ? rankA < rankB : a.offset < b.offset
        }.map(\.element)
    }

    /// 家族：字型裡的繁體中文 → 簡體中文 → 系統依使用者語言挑的 → 預設名稱。
    /// 樣式：字型裡的中文樣式名稱照用；英文的常見樣式換成中文，一般粗細不寫。
    private static func displayName(for font: CTFont, familyName: String, styleName: String) -> String {
        let table = FormlessFontNameTable(font: font)
        let family = table?.familyName(.traditional)
            ?? table?.familyName(.simplified)
            ?? (CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil) as String?)
            ?? familyName
        let rawStyle = table?.styleName(.traditional) ?? table?.styleName(.simplified) ?? styleName
        let style = FormlessFontStyle(rawStyle).chineseName
        let base = family.isEmpty ? (CTFontCopyPostScriptName(font) as String) : family
        return style.isEmpty ? base : base + " " + style
    }

    // MARK: 清單（Fonts/fonts.json）

    private static func duplicate(of faces: [FormlessImportedFont], in directory: URL) -> FormlessImportedFont? {
        let existing = Set(registry.lock.withLock { manifest(in: directory) }.map(\.postScriptName))
        return faces.first { existing.contains($0.postScriptName) }
    }

    /// 呼叫時要拿著 `registry.lock`。依檔案時間與大小快取，畫面每次重畫讀清單不必每次解 JSON。
    private static func manifest(in directory: URL) -> [FormlessImportedFont] {
        manifest(in: directory, stamp: fileStamp(directory.appendingPathComponent(manifestName)))
    }

    private static func manifest(in directory: URL, stamp: FormlessFileStamp?) -> [FormlessImportedFont] {
        if let cached = registry.manifests[directory.path], cached.stamp == stamp { return cached.fonts }
        var fonts: [FormlessImportedFont] = []
        if stamp != nil, let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)) {
            fonts = (try? JSONDecoder().decode([FormlessImportedFont].self, from: data)) ?? []
        }
        registry.manifests[directory.path] = (stamp, fonts)
        return fonts
    }

    /// 呼叫時要拿著 `registry.lock`。整份寫完再換上（atomic），小工具延伸讀不到寫一半的檔案。
    private static func writeManifest(_ fonts: [FormlessImportedFont], in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(manifestName)
        try encoder.encode(fonts).write(to: url, options: .atomic)
        registry.manifests[directory.path] = (fileStamp(url), fonts)
    }

    private static func fileStamp(_ url: URL) -> FormlessFileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FormlessFileStamp(modified: modified, size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name != manifestName
    }

    /// 檔名已被別的字型用掉時加上編號（「思源宋體 2.otf」），不覆蓋別的字型。
    private static func uniqueFileURL(for name: String, in directory: URL) -> URL {
        let clean = isPlainFileName(name) ? name : "字型.ttf"
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var candidate = directory.appendingPathComponent(clean)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    // MARK: 註冊

    /// 這個行程已註冊的字型檔與上次看過的清單版本（App 與小工具延伸各有一份）。
    private static let registry = FormlessFontRegistry()

    /// 回傳註冊失敗的檔案與錯誤碼。已經註冊過（105）、與已有字型同名（305）不算失敗。
    /// iOS 27 實測 `.process` 範圍在函式返回前就呼叫完處理區塊；保險起見沒完成時最多等 5 秒。
    @discardableResult
    private static func register(_ urls: [URL]) -> [String: Int] {
        guard !urls.isEmpty else { return [:] }
        let result = FormlessFontManagerResult()
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, done in
            result.collect(errors, done: done, ignoring: [105, 305])
            return true
        }
        return result.wait()
    }

    private static func unregister(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let result = FormlessFontManagerResult()
        CTFontManagerUnregisterFontURLs(urls as CFArray, .process) { errors, done in
            result.collect(errors, done: done, ignoring: [])
            return true
        }
        _ = result.wait()
    }

    /// 只回傳名稱完全相同的字型：名稱找不到時 CoreText 會給一個替代字型，不能當成找到。
    private static func resolvedFont(_ postScriptName: String, size: CGFloat) -> CTFont? {
        guard !postScriptName.isEmpty else { return nil }
        let font = CTFontCreateWithName(postScriptName as CFString, size, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName ? font : nil
    }
}


// MARK: - 內部

private struct FormlessFileStamp: Equatable {
    let modified: Date
    let size: Int
}

private final class FormlessFontRegistry: @unchecked Sendable {
    /// 可重入：註冊字型時 CoreText 會同步送出字型變更的通知，萬一有人在通知裡又讀字型，同一條執行緒不會卡死。
    let lock = NSRecursiveLock()
    /// 已註冊的字型檔完整路徑。
    var registered: Set<String> = []
    /// 資料夾路徑 → 上次同步註冊時清單檔的時間與大小（沒有清單時是 nil）。
    var syncedStamps: [String: FormlessFileStamp?] = [:]
    var manifests: [String: (stamp: FormlessFileStamp?, fonts: [FormlessImportedFont])] = [:]
}

/// CoreText 的註冊結果：處理區塊可能被叫好幾次，`done` 為 true 才算完成。
private final class FormlessFontManagerResult: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var isDone = false
    private var failures: [String: Int] = [:]

    func collect(_ errors: CFArray, done: Bool, ignoring ignored: Set<Int>) {
        lock.withLock {
            for error in (errors as? [CFError]) ?? [] {
                let code = CFErrorGetCode(error)
                guard !ignored.contains(code) else { continue }
                let info = CFErrorCopyUserInfo(error) as? [String: Any]
                let urls = info?[kCTFontManagerErrorFontURLsKey as String] as? [URL] ?? []
                for url in urls { failures[url.path] = code }
                if urls.isEmpty { failures[""] = code }
            }
            if done, !isDone {
                isDone = true
                finished.signal()
            }
        }
    }

    func wait() -> [String: Int] {
        if !lock.withLock({ isDone }) {
            _ = finished.wait(timeout: .now() + 5)
        }
        return lock.withLock { failures }
    }
}

/// 字型的 name 表（OpenType 'name'）。CoreText 的在地化名稱跟著使用者的語言走，
/// 這裡直接讀表，固定先找繁體中文、再找簡體中文，結果不因裝置語言而變。
private struct FormlessFontNameTable {

    enum Script { case traditional, simplified }

    private struct Record {
        let platform: UInt16
        let language: UInt16
        let nameID: UInt16
        let value: String
    }

    private let records: [Record]

    init?(font: CTFont) {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) else { return nil }
        let bytes = [UInt8](table as Data)
        func uint16(_ offset: Int) -> UInt16? {
            offset >= 0 && offset + 1 < bytes.count ? UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) : nil
        }
        guard let count = uint16(2), let storage = uint16(4) else { return nil }

        var records: [Record] = []
        for index in 0..<Int(count) {
            let base = 6 + index * 12
            guard let platform = uint16(base), let encoding = uint16(base + 2), let language = uint16(base + 4),
                  let nameID = uint16(base + 6), let length = uint16(base + 8), let offset = uint16(base + 10) else { break }
            let start = Int(storage) + Int(offset), end = start + Int(length)
            guard [1, 2, 4, 16, 17].contains(nameID), end <= bytes.count, start < end else { continue }
            let slice = Array(bytes[start..<end])
            let text: String?
            switch platform {
            case 0, 3:
                // Unicode 與 Windows 平台：UTF-16（大端）。
                text = String(bytes: slice, encoding: .utf16BigEndian)
            case 1:
                // Mac 平台：編碼代號就是 Mac 的文字編碼（0 羅馬、2 繁體中文、25 簡體中文）。
                let encodingValue = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding))
                text = String(bytes: slice, encoding: String.Encoding(rawValue: encodingValue))
            default:
                text = nil
            }
            let clean = text?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let clean, !clean.isEmpty {
                records.append(Record(platform: platform, language: language, nameID: nameID, value: clean))
            }
        }
        self.records = records
    }

    /// 家族：先看「排版用家族」（16），沒有才看舊式家族（1）。舊式家族在字面多的字型裡常帶著粗細。
    func familyName(_ script: Script) -> String? {
        name(ids: [16, 1], script: script)
    }

    func styleName(_ script: Script) -> String? {
        name(ids: [17, 2], script: script)
    }

    private func name(ids: [UInt16], script: Script) -> String? {
        for id in ids {
            if let record = records.first(where: { $0.nameID == id && matches($0, script) }) { return record.value }
        }
        return nil
    }

    /// Windows 語言代號：0x0404 台灣、0x0C04 香港、0x1404 澳門；0x0804 中國、0x1004 新加坡。Mac：19 繁體、33 簡體。
    private func matches(_ record: Record, _ script: Script) -> Bool {
        switch (script, record.platform) {
        case (.traditional, 3): return [0x0404, 0x0C04, 0x1404].contains(record.language)
        case (.traditional, 1): return record.language == 19
        case (.simplified, 3): return [0x0804, 0x1004].contains(record.language)
        case (.simplified, 1): return record.language == 33
        default: return false
        }
    }
}

/// 樣式名稱：換成中文的顯示名稱，並給排序用的粗細等級。
/// 中文用語照蘋果繁中介面（蘋方：極細、纖細、細、標準、中黑、中粗、粗）；更粗的兩級另取「特粗」「極粗」。
struct FormlessFontStyle {
    /// 顯示用；一般粗細的正體是空字串（名稱只寫家族）。
    let chineseName: String
    /// 100（最細）～ 900（最粗），斜體加 1；看不懂的樣式排在一般粗細。
    let rank: Int

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 字型自己就有中文樣式名稱：照用，只有「一般」的幾種寫法不寫。
        if trimmed.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            let regular = ["標準體", "標準", "常規體", "常規", "一般", "正常", "正體", "标准体", "标准", "常规体", "常规"]
            chineseName = regular.contains(trimmed) ? "" : trimmed
            rank = 400
            return
        }

        var key = trimmed.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        let italic = key.contains("italic") || key.contains("oblique")
        key = key.replacingOccurrences(of: "italic", with: "").replacingOccurrences(of: "oblique", with: "")

        let weights: [(keys: [String], stem: String, rank: Int)] = [
            (["", "regular", "normal", "book", "roman", "plain", "standard"], "", 400),
            (["thin", "hairline"], "纖細", 100),
            (["extralight", "ultralight"], "極細", 200),
            (["light"], "細", 300),
            (["medium"], "中黑", 500),
            (["semibold", "demibold", "demi"], "中粗", 600),
            (["bold"], "粗", 700),
            (["extrabold", "ultrabold", "heavy"], "特粗", 800),
            (["black", "extrablack", "ultrablack", "ultra"], "極粗", 900)
        ]
        guard let weight = weights.first(where: { $0.keys.contains(key) }) else {
            // 看不懂的樣式（例如 Condensed Bold）保留原文，不亂翻。
            chineseName = trimmed
            rank = 400 + (italic ? 1 : 0)
            return
        }
        if weight.stem.isEmpty {
            chineseName = italic ? "斜體" : ""
        } else {
            chineseName = weight.stem + (italic ? "斜體" : "體")
        }
        rank = weight.rank + (italic ? 1 : 0)
    }
}

extension FormlessFontLibrary {
    /// fontFamily 的值（custom:PostScript 名稱）對應的顯示名稱；不是匯入的字型回 nil。字型被刪掉時顯示原本的名稱。
    static func displayName(forFamily family: String?) -> String? {
        guard let name = postScriptName(fromFamily: family) else { return nil }
        return installed().first { $0.postScriptName == name }?.displayName ?? name
    }
}

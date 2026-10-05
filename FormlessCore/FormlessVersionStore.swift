import Foundation

// MARK: - 版本紀錄（2026-10，規劃 M7 重用與分享）
//
// 每份設計保留最近 10 個版本。存檔（`FormlessStorage.save`）把舊檔蓋掉之前，距離上一個版本超過 10 分鐘，
// 就把舊檔複製一份到 Versions/<設計 id>/<時間>.formless；超過 10 個刪最舊的。編輯中每停一下就自動存檔，
// 一律留版本的話 10 個很快就只剩最近一兩分鐘，所以至少隔 10 分鐘才留一個。
// 檔名的時間是記下版本的那一刻（1970 年起的毫秒）：設計在那個時間點就是檔案裡的樣子。
// 只在 App 裡用（小工具設定 › 版本紀錄）；不進匯出包，小工具也不讀。

/// 一個版本。
struct FormlessVersion: Identifiable, Hashable, Sendable {
    let documentID: UUID
    /// 記下這個版本的時間：設計在這一刻的樣子。
    let date: Date
    let url: URL

    var id: String { documentID.uuidString + "/" + url.lastPathComponent }
}

enum FormlessVersionStore {
    /// 每份設計最多留幾個版本。
    static let maxCount = 10
    /// 和上一個版本至少隔多久才再留一個。
    static let minimumInterval: TimeInterval = 10 * 60

    /// 同一份設計可能同時從兩個地方存檔（編輯器的自動存檔、首頁改名）：記版本的檢查與寫入一次只做一個。
    private static let lock = NSLock()

    /// 共用資料夾裡的 Versions/。
    static var rootURL: URL? {
        FormlessStorage.sharedContainerURL?.appendingPathComponent("Versions", isDirectory: true)
    }

    // MARK: 共用資料夾（App 用）

    /// 存檔前呼叫（`FormlessStorage.save`）：舊檔要被 newData 蓋掉、而且距離上一個版本超過 10 分鐘，就把舊檔留成一個版本。
    /// 大部分存檔只看一次資料夾裡的檔名就結束，不讀舊檔。任何錯誤都不影響存檔本身。
    static func recordPrevious(fileAt url: URL, for id: UUID, before newData: Data? = nil, at date: Date = Date()) {
        guard let root = rootURL else { return }
        recordPrevious(fileAt: url, for: id, before: newData, at: date, in: root)
    }

    /// 把 previousData 留成一個版本：距離上一個版本不到 10 分鐘、或和上一個版本完全相同時不留（force 時不看間隔）。
    /// 回傳新留的版本；沒有留是 nil。
    @discardableResult
    static func record(previousData: Data, for id: UUID, at date: Date = Date(), force: Bool = false) -> FormlessVersion? {
        guard let root = rootURL else { return nil }
        return record(previousData: previousData, for: id, at: date, force: force, in: root)
    }

    /// 新的在前。
    static func versions(of id: UUID) -> [FormlessVersion] {
        guard let root = rootURL else { return [] }
        return versions(of: id, in: root)
    }

    static func deleteAll(of id: UUID) {
        guard let root = rootURL else { return }
        deleteAll(of: id, in: root)
    }

    // MARK: 不分資料夾

    /// 讀出一個版本的設計（id 一律是原本那份設計的 id）。
    static func document(of version: FormlessVersion) -> FormlessDocument? {
        guard let data = try? Data(contentsOf: version.url),
              var document = try? JSONDecoder().decode(FormlessDocument.self, from: data) else { return nil }
        document.id = version.documentID
        return document
    }

    /// 回復到 version：先把目前的設計（current，可能還有沒存的修改）也留成一個版本（不看 10 分鐘的間隔），
    /// 再回傳版本裡的設計。不寫入設計檔：編輯器裡由編輯器的自動存檔寫入（回復也算一步復原）。
    /// 版本讀不出來時丟出錯誤，目前的設計不受影響。
    static func restore(_ version: FormlessVersion, replacing current: FormlessDocument?, at date: Date = Date()) throws -> FormlessDocument {
        let data = try Data(contentsOf: version.url)
        var document = try JSONDecoder().decode(FormlessDocument.self, from: data)
        document.id = version.documentID
        if let current, let currentData = try? FormlessStorage.encode(current) {
            record(currentData, inFolder: version.url.deletingLastPathComponent(), documentID: version.documentID,
                   at: date, force: true)
        }
        return document
    }

    static func delete(_ version: FormlessVersion) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: version.url)
    }

    // MARK: 指定資料夾（命令列測試用暫存資料夾，不碰 App 群組）

    static func folder(for id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func recordPrevious(fileAt url: URL, for id: UUID, before newData: Data?, at date: Date, in root: URL) {
        let folder = folder(for: id, in: root)
        // 先看間隔：還不到 10 分鐘就連舊檔都不必讀（編輯中的自動存檔幾乎都在這裡結束）。
        if let newest = newestDate(inFolder: folder), isTooSoon(date, after: newest) { return }
        guard let previous = try? Data(contentsOf: url), previous != newData else { return }
        record(previous, inFolder: folder, documentID: id, at: date, force: false)
    }

    @discardableResult
    static func record(previousData: Data, for id: UUID, at date: Date, force: Bool, in root: URL) -> FormlessVersion? {
        record(previousData, inFolder: folder(for: id, in: root), documentID: id, at: date, force: force)
    }

    static func versions(of id: UUID, in root: URL) -> [FormlessVersion] {
        versions(inFolder: folder(for: id, in: root), documentID: id)
    }

    static func deleteAll(of id: UUID, in root: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder(for: id, in: root))
    }

    // MARK: 內部

    @discardableResult
    private static func record(_ data: Data, inFolder folder: URL, documentID: UUID, at date: Date, force: Bool) -> FormlessVersion? {
        lock.lock()
        defer { lock.unlock() }
        let existing = versions(inFolder: folder, documentID: documentID)
        if !force, let newest = existing.first, isTooSoon(date, after: newest.date) { return nil }
        // 和上一個版本一模一樣就不再留（例如連續回復兩次、只改名又改回來）。
        if let newest = existing.first, (try? Data(contentsOf: newest.url)) == data { return nil }
        let url = folder.appendingPathComponent(fileName(for: date))
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        // 超過 10 個刪最舊的。
        for old in versions(inFolder: folder, documentID: documentID).dropFirst(maxCount) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return FormlessVersion(documentID: documentID, date: date, url: url)
    }

    /// 距離上一個版本還不到 10 分鐘。上一個版本的時間比現在還晚（裝置時間被往回調過）時不算，照常留版本，
    /// 不然要等到時間追上那個版本才會再留。
    private static func isTooSoon(_ date: Date, after newest: Date) -> Bool {
        date >= newest && date.timeIntervalSince(newest) < minimumInterval
    }

    private static func versions(inFolder folder: URL, documentID: UUID) -> [FormlessVersion] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url in
            guard url.pathExtension == FormlessConstants.fileExtension,
                  let date = date(fromFileName: url.lastPathComponent) else { return nil }
            return FormlessVersion(documentID: documentID, date: date, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    private static func newestDate(inFolder folder: URL) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.compactMap { date(fromFileName: $0) }.max()
    }

    /// 1970 年起的毫秒：排序、比較都直接，和時區、語系無關。
    static func fileName(for date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded())) + "." + FormlessConstants.fileExtension
    }

    static func date(fromFileName name: String) -> Date? {
        let suffix = "." + FormlessConstants.fileExtension
        guard name.hasSuffix(suffix), let milliseconds = Int64(name.dropLast(suffix.count)) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

// MARK: - 顯示的時間

extension FormlessVersion {
    /// 版本紀錄列的時間：「今天 下午 3:20」「昨天 上午 9:05」「10月1日 下午 3:20」，不是今年的加上年份。
    func displayTime(relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        FormlessVersionTimeText.text(for: date, relativeTo: now, calendar: calendar)
    }
}

enum FormlessVersionTimeText {
    static func text(for date: Date, relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "今天"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "昨天"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            day = formatted(date, "M月d日", calendar: calendar)
        } else {
            day = formatted(date, "y年M月d日", calendar: calendar)
        }
        return day + " " + formatted(date, "a h:mm", calendar: calendar)
    }

    /// 每次叫都新建 DateFormatter：版本紀錄最多 10 列，不值得為它另外做快取（共用的格式快取在主執行緒上不建新格式）。
    private static func formatted(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

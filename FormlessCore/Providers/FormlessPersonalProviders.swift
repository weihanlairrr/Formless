import Foundation
@preconcurrency import EventKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreMotion)
import CoreMotion
#endif

// MARK: - 行事曆

/// 行程查詢：每份設計可以有好幾個（「工作行程」只讀公司行事曆、「這週」讀七天）。
/// App 預設的那一份照設定頁「行事曆」選的行事曆，讀今天起七天。
struct FormlessCalendarDataProvider: FormlessDataProvider {
    let id = "calendar"
    let name = "行事曆"
    let symbol = "calendar"
    let category = FormlessDataCategory.calendar
    var lifetime: TimeInterval { 10 * 60 }
    var allowsInstances: Bool { true }

    static let ranges = [
        FormlessNamedValue(id: "1", name: "今天"),
        FormlessNamedValue(id: "2", name: "今天和明天"),
        FormlessNamedValue(id: "7", name: "七天內"),
        FormlessNamedValue(id: "14", name: "兩週內"),
        FormlessNamedValue(id: "30", name: "一個月內")
    ]

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "calendars", name: "行事曆", kind: .calendars,
                                footer: "沒有選擇時，用設定頁「行事曆」選的行事曆。"),
            FormlessSettingSpec(id: "days", name: "範圍", kind: .choice(Self.ranges), defaultValue: .text("7")),
            FormlessSettingSpec(id: "allDay", name: "包含整天行程", kind: .toggle, defaultValue: .bool(true)),
            FormlessSettingSpec(id: "keyword", name: "標題包含", kind: .text(placeholder: "不限")),
            FormlessSettingSpec(id: "keepEnded", name: "保留今天已結束的行程", kind: .toggle, defaultValue: .bool(false))
        ]
    }

    func summary(for source: FormlessSource) -> String {
        let days = source.text("days") ?? "7"
        let range = Self.ranges.first { $0.id == days }?.name ?? ""
        let count = source.list("calendars").count
        return count == 0 ? range : "\(count) 本行事曆・\(range)"
    }

    func cacheKey(for source: FormlessSource) -> String {
        "calendar-" + [source.list("calendars").sorted().joined(separator: ","), source.text("days") ?? "7",
                       String(source.flag("allDay") ?? true), source.text("keyword") ?? ""].joined(separator: "|").hashValueStable.description
    }

    func availability(for source: FormlessSource) -> FormlessDataStatus {
        FormlessEventsProvider.isAuthorized ? .loading : .unauthorized
    }

    static let itemFields: [FormlessFieldSpec] = {
        let now = Date()
        return [
            FormlessFieldSpec("title", "標題", .text, sample: .text("設計討論")),
            FormlessFieldSpec("start", "開始時間", .date, sample: .date(now.addingTimeInterval(3600)), live: true),
            FormlessFieldSpec("end", "結束時間", .date, sample: .date(now.addingTimeInterval(7200)), live: true),
            FormlessFieldSpec("allDay", "整天", .bool, sample: .bool(false)),
            FormlessFieldSpec("location", "地點", .text, sample: .text("會議室 A")),
            FormlessFieldSpec("notes", "備註", .text, sample: .text("帶筆電")),
            FormlessFieldSpec("calendar", "行事曆", .text, sample: .text("工作")),
            FormlessFieldSpec("color", "行事曆顏色", .color, sample: .color("#4C8BF6")),
            FormlessFieldSpec("duration", "時長", .duration, sample: .duration(3600)),
            FormlessFieldSpec("startsIn", "多久後開始", .duration, sample: .duration(3600), live: true),
            FormlessFieldSpec("ongoing", "進行中", .bool, sample: .bool(false)),
            FormlessFieldSpec("url", "網址", .text, sample: .empty)
        ]
    }()

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let sampleItem = FormlessValue.record(FormlessRecord(id: "sample", fields: Dictionary(uniqueKeysWithValues: Self.itemFields.map { ($0.id, $0.sample) })))
        return [
            FormlessFieldSpec("events", "行程", .list, sample: .list([sampleItem, sampleItem, sampleItem]), items: Self.itemFields),
            FormlessFieldSpec("next", "下一個行程", .record, sample: sampleItem, items: Self.itemFields),
            FormlessFieldSpec("count", "行程數", .number, unit: .count, sample: .number(3, .count)),
            FormlessFieldSpec("todayCount", "今天的行程數", .number, unit: .count, sample: .number(2, .count)),
            FormlessFieldSpec("tomorrowCount", "明天的行程數", .number, unit: .count, sample: .number(1, .count))
        ]
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        guard FormlessEventsProvider.isAuthorized else { return .failure(.unauthorized, "需要行事曆權限") }
        let store = EKEventStore()
        let calendar = FormlessLiveTime.calendar
        let start = calendar.startOfDay(for: Date())
        let days = Int(source.text("days") ?? "7") ?? 7
        guard let end = calendar.date(byAdding: .day, value: max(1, days), to: start) else { return nil }

        let chosen = Set(source.list("calendars"))
        let excluded = FormlessCalendarSettings.current().excluded
        let calendars = store.calendars(for: .event).filter {
            chosen.isEmpty ? !excluded.contains($0.calendarIdentifier) : chosen.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return FormlessSnapshot(values: ["events": .list([])], status: .empty) }

        let includeAllDay = source.flag("allDay") ?? true
        let keyword = (source.text("keyword") ?? "").lowercased()
        let names = FormlessCalendarNameSettings.current()
        let locations = FormlessEventLocationSettings.load()

        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { includeAllDay || !$0.isAllDay }
            .filter { keyword.isEmpty || ($0.title ?? "").lowercased().contains(keyword) }
            .sorted { ($0.startDate ?? start) < ($1.startDate ?? start) }
            .prefix(60)

        let records: [FormlessValue] = events.map { event in
            let begin = event.startDate ?? start
            let finish = event.endDate ?? begin
            let item = FormlessEventItem(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "（無標題）",
                                         calendarName: names.name(for: event.calendar?.calendarIdentifier) ?? event.calendar?.title ?? "",
                                         calendarColorHex: Self.hex(event.calendar), startDate: begin, isAllDay: event.isAllDay,
                                         location: event.location, calendarIdentifier: event.calendar?.calendarIdentifier,
                                         endDate: finish)
            var fields: [String: FormlessValue] = [
                "title": .text(item.title),
                "start": .date(begin, allDay: event.isAllDay),
                "end": .date(finish, allDay: event.isAllDay),
                "allDay": .bool(event.isAllDay),
                "calendar": .text(item.calendarName),
                "color": .color(item.calendarColorHex),
                "duration": .duration(finish.timeIntervalSince(begin))
            ]
            let place = locations.showsLocation(for: item) ? locations.extract(event.location ?? "") : ""
            if !place.isEmpty { fields["location"] = .text(place) }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { fields["notes"] = .text(notes) }
            if let url = event.url?.absoluteString { fields["url"] = .text(url) }
            return .record(FormlessRecord(id: item.id + "@" + String(Int(begin.timeIntervalSince1970)), fields: fields))
        }
        return FormlessSnapshot(values: ["events": .list(records)], status: records.isEmpty ? .empty : .ok)
    }

    /// date 那一刻還在畫面上的行程（已結束的拿掉，除非設定保留），附上「多久後開始」「進行中」。
    func events(_ source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> [FormlessRecord] {
        let keepEnded = source.flag("keepEnded") ?? false
        let calendar = FormlessLiveTime.calendar
        let today = calendar.startOfDay(for: date)
        return (snapshot?["events"].listValue ?? []).compactMap { value -> FormlessRecord? in
            guard var record = value.recordValue, let begin = record["start"].dateValue else { return nil }
            let allDay = record["allDay"].boolValue ?? false
            let until = FormlessLiveTime.visibleUntil(start: begin, end: record["end"].dateValue, allDay: allDay)
            if keepEnded {
                if until <= today { return nil }
            } else if until <= date {
                return nil
            }
            record["startsIn"] = .duration(max(0, begin.timeIntervalSince(date)))
            record["ongoing"] = .bool(begin <= date && until > date)
            return record
        }
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        let items = events(source, snapshot: snapshot, at: date)
        let calendar = FormlessLiveTime.calendar
        switch field {
        case "events": return snapshot == nil ? .empty : .list(items.map(FormlessValue.record))
        // 下一個行程：正在進行或還沒開始的第一個。開了「保留已結束的行程」時清單裡會有結束的，不能直接取第一筆。
        case "next":
            return items.first { ($0["ongoing"].boolValue ?? false) || ($0["start"].dateValue ?? .distantPast) > date }
                .map(FormlessValue.record) ?? .empty
        case "count": return snapshot == nil ? .empty : .number(Double(items.count), .count)
        case "todayCount":
            guard snapshot != nil else { return .empty }
            return .number(Double(items.filter { calendar.isDate($0["start"].dateValue ?? .distantPast, inSameDayAs: date) }.count), .count)
        case "tomorrowCount":
            guard snapshot != nil, let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return .empty }
            return .number(Double(items.filter { calendar.isDate($0["start"].dateValue ?? .distantPast, inSameDayAs: tomorrow) }.count), .count)
        default: return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        for value in snapshot?["events"].listValue ?? [] {
            guard let record = value.recordValue, let begin = record["start"].dateValue else { continue }
            let until = FormlessLiveTime.visibleUntil(start: begin, end: record["end"].dateValue, allDay: record["allDay"].boolValue ?? false)
            for moment in [begin, until] where moment > from && moment < to { result.append(moment) }
        }
        let midnight = FormlessLiveTime.endOfDay(from)
        if midnight < to { result.append(midnight) }
        return result
    }

    static func hex(_ calendar: EKCalendar?) -> String {
        #if canImport(UIKit)
        guard let cgColor = calendar?.cgColor else { return "#4C8BF6" }
        return Color(uiColor: UIColor(cgColor: cgColor)).formlessHex
        #else
        return "#4C8BF6"
        #endif
    }
}

// MARK: - 提醒事項

struct FormlessReminderDataProvider: FormlessDataProvider {
    let id = "reminders"
    let name = "提醒事項"
    let symbol = "checklist"
    let category = FormlessDataCategory.reminders
    var lifetime: TimeInterval { 10 * 60 }
    var allowsInstances: Bool { true }

    static let ranges = [
        FormlessNamedValue(id: "today", name: "今天與逾期"),
        FormlessNamedValue(id: "threeDays", name: "三天內"),
        FormlessNamedValue(id: "week", name: "一週內"),
        FormlessNamedValue(id: "scheduled", name: "有到期日的"),
        FormlessNamedValue(id: "all", name: "全部未完成")
    ]

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "lists", name: "清單", kind: .reminderLists, footer: "沒有選擇時讀全部的清單。"),
            FormlessSettingSpec(id: "range", name: "範圍", kind: .choice(Self.ranges), defaultValue: .text("today"))
        ]
    }

    func summary(for source: FormlessSource) -> String {
        let range = source.text("range") ?? "today"
        let name = Self.ranges.first { $0.id == range }?.name ?? ""
        let count = source.list("lists").count
        return count == 0 ? name : "\(count) 個清單・\(name)"
    }

    func cacheKey(for source: FormlessSource) -> String {
        "reminders-" + (source.list("lists").sorted().joined(separator: ",") + "|" + (source.text("range") ?? "today")).hashValueStable.description
    }

    func availability(for source: FormlessSource) -> FormlessDataStatus {
        FormlessRemindersProvider.isAuthorized ? .loading : .unauthorized
    }

    static let itemFields: [FormlessFieldSpec] = [
        FormlessFieldSpec("title", "標題", .text, sample: .text("繳電話費")),
        FormlessFieldSpec("due", "到期時間", .date, sample: .date(Date().addingTimeInterval(5400)), live: true),
        FormlessFieldSpec("list", "清單", .text, sample: .text("提醒事項")),
        FormlessFieldSpec("color", "清單顏色", .color, sample: .color("#EB5545")),
        FormlessFieldSpec("priority", "優先順序", .text, sample: .text("高")),
        FormlessFieldSpec("notes", "備註", .text, sample: .empty),
        FormlessFieldSpec("overdue", "已逾期", .bool, sample: .bool(false))
    ]

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let sampleItem = FormlessValue.record(FormlessRecord(id: "sample", fields: Dictionary(uniqueKeysWithValues: Self.itemFields.map { ($0.id, $0.sample) })))
        return [
            FormlessFieldSpec("reminders", "提醒事項", .list, sample: .list([sampleItem, sampleItem]), items: Self.itemFields),
            FormlessFieldSpec("count", "未完成數", .number, unit: .count, sample: .number(4, .count)),
            FormlessFieldSpec("todayCount", "今天到期", .number, unit: .count, sample: .number(2, .count)),
            FormlessFieldSpec("overdueCount", "已逾期", .number, unit: .count, sample: .number(1, .count)),
            FormlessFieldSpec("completedToday", "今天完成", .number, unit: .count, sample: .number(3, .count))
        ]
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        guard FormlessRemindersProvider.isAuthorized else { return .failure(.unauthorized, "需要提醒事項權限") }
        let store = EKEventStore()
        let calendar = FormlessLiveTime.calendar
        let startOfToday = calendar.startOfDay(for: Date())
        let chosen = Set(source.list("lists"))
        let lists = store.calendars(for: .reminder).filter { chosen.isEmpty || chosen.contains($0.calendarIdentifier) }
        guard !lists.isEmpty else { return FormlessSnapshot(values: ["reminders": .list([])], status: .empty) }

        func query(_ predicate: NSPredicate) async -> [EKReminder]? {
            await withCheckedContinuation { continuation in
                let completion = FormlessOneShot<[EKReminder]?> { continuation.resume(returning: $0) }
                let token = store.fetchReminders(matching: predicate) { completion.resolve($0) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                    if completion.resolve(nil) { store.cancelFetchRequest(token) }
                }
            }
        }

        guard let open = await query(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)) else {
            return .failure(.failed, "讀取逾時")
        }
        let done = await query(store.predicateForCompletedReminders(withCompletionDateStarting: startOfToday, ending: Date(), calendars: lists)) ?? []

        let range = source.text("range") ?? "today"
        let days: Int? = ["today": 1, "threeDays": 3, "week": 7][range]
        let ending = days.flatMap { calendar.date(byAdding: .day, value: $0, to: startOfToday) }

        let records: [FormlessValue] = open.compactMap { reminder -> (Date?, FormlessValue)? in
            let due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
            let hasTime = reminder.dueDateComponents?.hour != nil
            switch range {
            case "all": break
            case "scheduled": if due == nil { return nil }
            default:
                guard let due, let ending, due < ending else { return nil }
            }
            var fields: [String: FormlessValue] = [
                "title": .text(reminder.title ?? "（無標題）"),
                "list": .text(reminder.calendar?.title ?? ""),
                "color": .color(FormlessCalendarDataProvider.hex(reminder.calendar))
            ]
            if let due { fields["due"] = .date(due, allDay: !hasTime) }
            switch reminder.priority {
            case 1...4: fields["priority"] = .text("高")
            case 5: fields["priority"] = .text("中")
            case 6...9: fields["priority"] = .text("低")
            default: break
            }
            if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { fields["notes"] = .text(notes) }
            return (due, .record(FormlessRecord(id: reminder.calendarItemIdentifier, fields: fields)))
        }
        .sorted { ($0.0 ?? .distantFuture) < ($1.0 ?? .distantFuture) }
        .prefix(60)
        .map(\.1)

        return FormlessSnapshot(values: ["reminders": .list(Array(records)), "completedToday": .number(Double(done.count), .count)],
                                status: records.isEmpty ? .empty : .ok)
    }

    /// date 那一刻的提醒：到期的不拿掉，標成已逾期（`overdue`），只有日期的到當天結束才算逾期。
    func reminders(_ snapshot: FormlessSnapshot?, at date: Date) -> [FormlessRecord] {
        (snapshot?["reminders"].listValue ?? []).compactMap { value -> FormlessRecord? in
            guard var record = value.recordValue else { return nil }
            if case .date(let due, let allDay) = record["due"] {
                let until = allDay ? FormlessLiveTime.endOfDay(due) : due
                record["overdue"] = .bool(until <= date)
            } else {
                record["overdue"] = .bool(false)
            }
            return record
        }
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        guard snapshot != nil else { return .empty }
        let items = reminders(snapshot, at: date)
        let calendar = FormlessLiveTime.calendar
        switch field {
        case "reminders": return .list(items.map(FormlessValue.record))
        case "count": return .number(Double(items.count), .count)
        case "todayCount":
            return .number(Double(items.filter { calendar.isDate($0["due"].dateValue ?? .distantPast, inSameDayAs: date) }.count), .count)
        case "overdueCount": return .number(Double(items.filter { $0["overdue"].boolValue == true }.count), .count)
        case "completedToday":
            guard let fetched = snapshot?.fetchedAt, calendar.isDate(fetched, inSameDayAs: date) else { return .number(0, .count) }
            return snapshot?["completedToday"] ?? .empty
        default: return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        for value in snapshot?["reminders"].listValue ?? [] {
            guard case .date(let due, let allDay)? = value.recordValue?["due"] else { continue }
            let moment = allDay ? FormlessLiveTime.endOfDay(due) : due
            if moment > from, moment < to { result.append(moment) }
        }
        let midnight = FormlessLiveTime.endOfDay(from)
        if midnight < to { result.append(midnight) }
        return result
    }
}

// MARK: - 健康與活動（計步器）

/// 計步器：步數、距離、樓層、配速、步頻，與每日紀錄。SideStore 安裝沒有 HealthKit，全部來自動作感測器；
/// 系統只保留 7 天，更早的每日數字從啟用後自己存（activity-history.json）。
struct FormlessActivityProvider: FormlessDataProvider {
    let id = "activity"
    let name = "計步器"
    let symbol = "figure.walk"
    let category = FormlessDataCategory.activity
    var lifetime: TimeInterval { 5 * 60 }

    static let historyCacheName = "activity-history.json"

    struct Day: Codable, Hashable, Sendable {
        var date: Date
        var steps: Int
        var distance: Double?
        var floors: Int?
    }

    func availability(for source: FormlessSource) -> FormlessDataStatus {
        #if canImport(CoreMotion)
        guard CMPedometer.isStepCountingAvailable() else { return .unsupported }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted: return .unauthorized
        default: return .loading
        }
        #else
        return .unsupported
        #endif
    }

    static let historyFields: [FormlessFieldSpec] = [
        FormlessFieldSpec("date", "日期", .date, sample: .date(Date(), allDay: true)),
        FormlessFieldSpec("steps", "步數", .number, unit: .steps, grouping: true, sample: .number(8430, .steps)),
        FormlessFieldSpec("distance", "距離", .number, unit: .kilometers, decimals: 1, sample: .number(6.1, .kilometers))
    ]

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let samples: [FormlessValue] = (0..<7).map { offset in
            .record(FormlessRecord(id: String(offset), fields: [
                "date": .date(Date().addingTimeInterval(Double(offset - 6) * 86_400), allDay: true),
                "steps": .number(Double([6200, 9100, 4300, 11_800, 7600, 10_200, 8430][offset]), .steps),
                "distance": .number([4.5, 6.6, 3.1, 8.5, 5.5, 7.3, 6.1][offset], .kilometers)
            ]))
        }
        return [
            FormlessFieldSpec("steps", "今天步數", .number, unit: .steps, grouping: true, sample: .number(8430, .steps)),
            FormlessFieldSpec("distance", "今天距離", .number, unit: .kilometers, decimals: 1, sample: .number(6.1, .kilometers)),
            FormlessFieldSpec("floorsUp", "爬升樓層", .number, unit: .floors, sample: .number(12, .floors)),
            FormlessFieldSpec("floorsDown", "下降樓層", .number, unit: .floors, sample: .number(9, .floors)),
            FormlessFieldSpec("pace", "目前配速", .number, unit: .secondsPerKilometer, sample: .number(540, .secondsPerKilometer)),
            FormlessFieldSpec("cadence", "目前步頻", .number, unit: .stepsPerMinute, sample: .number(108, .stepsPerMinute)),
            FormlessFieldSpec("weekSteps", "七天步數", .number, unit: .steps, grouping: true, sample: .number(57_630, .steps)),
            FormlessFieldSpec("averageSteps", "七天平均步數", .number, unit: .steps, grouping: true, sample: .number(8233, .steps)),
            FormlessFieldSpec("history", "每日紀錄", .list, sample: .list(samples), items: Self.historyFields)
        ]
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        #if canImport(CoreMotion)
        guard CMPedometer.isStepCountingAvailable() else { return .failure(.unsupported, "這台裝置沒有計步器") }
        if [.denied, .restricted].contains(CMPedometer.authorizationStatus()) { return .failure(.unauthorized, "需要動作與健身權限") }
        let calendar = FormlessLiveTime.calendar
        let today = calendar.startOfDay(for: Date())
        let pedometer = CMPedometer()

        func query(_ start: Date, _ end: Date) async -> CMPedometerData? {
            await withCheckedContinuation { continuation in
                let completion = FormlessOneShot<CMPedometerData?> { continuation.resume(returning: $0) }
                pedometer.queryPedometerData(from: start, to: end) { [pedometer] data, _ in
                    _ = pedometer
                    completion.resolve(data)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { completion.resolve(nil) }
            }
        }

        guard let now = await query(today, Date()) else { return .failure(.failed, "計步器沒有回應") }

        var history = FormlessCache.load([Day].self, name: Self.historyCacheName) ?? []
        func record(_ day: Day) {
            history.removeAll { calendar.isDate($0.date, inSameDayAs: day.date) }
            history.append(day)
        }
        record(Day(date: today, steps: now.numberOfSteps.intValue, distance: now.distance.map { $0.doubleValue / 1000 },
                   floors: now.floorsAscended?.intValue))
        // 前六天（系統保留 7 天）：每次補齊，之後就從自己的紀錄讀。
        for offset in 1...6 {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            if history.contains(where: { calendar.isDate($0.date, inSameDayAs: start) }) && offset > 1 { continue }
            if let data = await query(start, end) {
                record(Day(date: start, steps: data.numberOfSteps.intValue, distance: data.distance.map { $0.doubleValue / 1000 },
                           floors: data.floorsAscended?.intValue))
            }
        }
        history = Array(history.sorted { $0.date < $1.date }.suffix(60))
        FormlessCache.save(history, name: Self.historyCacheName, notify: false)

        var values: [String: FormlessValue] = [
            "steps": .number(now.numberOfSteps.doubleValue, .steps),
            "history": .list(history.map { day in
                var fields: [String: FormlessValue] = ["date": .date(day.date, allDay: true), "steps": .number(Double(day.steps), .steps)]
                if let distance = day.distance { fields["distance"] = .number(distance, .kilometers) }
                return .record(FormlessRecord(id: String(Int(day.date.timeIntervalSince1970)), fields: fields))
            })
        ]
        if let distance = now.distance { values["distance"] = .number(distance.doubleValue / 1000, .kilometers) }
        if let up = now.floorsAscended { values["floorsUp"] = .number(up.doubleValue, .floors) }
        if let down = now.floorsDescended { values["floorsDown"] = .number(down.doubleValue, .floors) }
        if let pace = now.currentPace, pace.doubleValue > 0 { values["pace"] = .number(pace.doubleValue * 1000, .secondsPerKilometer) }
        if let cadence = now.currentCadence, cadence.doubleValue > 0 { values["cadence"] = .number(cadence.doubleValue * 60, .stepsPerMinute) }
        // 舊的步數圖層也讀得到同一份（和 FormlessStepsProvider 存的同一個快取）。
        FormlessStepsCache.record(now.numberOfSteps.intValue)
        return FormlessSnapshot(values: values)
        #else
        return .failure(.unsupported, "這台裝置沒有計步器")
        #endif
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        guard let snapshot else { return .empty }
        let calendar = FormlessLiveTime.calendar
        // 過了午夜，今天的數字從 0 開始。
        let sameDay = calendar.isDate(snapshot.fetchedAt, inSameDayAs: date)
        let history = (snapshot["history"].listValue ?? []).compactMap(\.recordValue)
        let lastWeek = history.filter {
            guard let day = $0["date"].dateValue else { return false }
            let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: date)).day ?? 99
            return age >= 0 && age < 7
        }
        switch field {
        case "steps": return sameDay ? snapshot["steps"] : .number(0, .steps)
        case "distance": return sameDay ? snapshot["distance"] : .number(0, .kilometers)
        case "floorsUp", "floorsDown": return sameDay ? snapshot[field] : .number(0, .floors)
        case "pace", "cadence": return sameDay ? snapshot[field] : .empty
        case "weekSteps": return .number(lastWeek.compactMap { $0["steps"].numberValue }.reduce(0, +), .steps)
        case "averageSteps":
            let steps = lastWeek.compactMap { $0["steps"].numberValue }
            return steps.isEmpty ? .empty : .number((steps.reduce(0, +) / Double(steps.count)).rounded(), .steps)
        case "history": return .list(history.suffix(30).map(FormlessValue.record))
        default: return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        let midnight = FormlessLiveTime.endOfDay(from)
        return midnight < to ? [midnight] : []
    }
}

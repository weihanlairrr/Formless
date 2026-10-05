import SwiftUI
import WidgetKit
import EventKit

struct EventLocationSettingsView: View {
    @State private var pattern = ""
    @State private var locations: [String] = []
    @State private var loaded = false
    @State private var status = "讀取中…"
    @State private var savedPattern = ""
    @State private var preview: [String: String] = [:]
    @State private var invalidRule = false
    @State private var calendars: [EKCalendar] = []
    @State private var excludedCalendars: Set<String> = []
    private struct PreviewInput: Hashable { let pattern: String; let locations: [String] }
    private var groupedCalendars: [(String, [EKCalendar])] {
        Dictionary(grouping: calendars) { $0.source?.title ?? "其他" }
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        // 卡片不放標題（使用者規則：全 App 的卡片上方都不放標題），說明留在卡片下方。
        Form {
            Section {
                // 說明、規則是否有效、儲存狀態都是在講這條規則：同一列（`EditorFunctionRow`）。
                EditorFunctionRow {
                    TextField("正規表達式", text: $pattern, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .editorLine(.text)
                    Text("取第一個捕捉群組。留空、未符合或規則無效時保留原文。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .editorLine(.text)
                    if invalidRule {
                        Text("規則無效，將顯示原文。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .editorLine(.text)
                    }
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                        .editorLine(.text)
                    if status.hasPrefix("儲存失敗") {
                        Button("重試儲存") { Task { await persist(pattern) } }
                            .buttonStyle(.borderless)
                            .editorLine(.text)
                    }
                }
            }
            Section {
                if calendars.isEmpty {
                    Text("尚未取得行事曆權限，或沒有可用的行事曆。").foregroundStyle(.secondary)
                }
                ForEach(groupedCalendars, id: \.0) { source, items in
                    ForEach(items, id: \.calendarIdentifier) { item in
                        Toggle(isOn: calendarBinding(for: item)) {
                            HStack(spacing: 10) {
                                Circle().fill(color(of: item)).frame(width: 10, height: 10)
                                Text(item.title)
                                if groupedCalendars.count > 1 {
                                    Text(source).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } footer: { Text("關閉的行事曆，其行程地點在小工具上留白。只列出「行事曆來源」有選取的行事曆。") }
            Section {
                if locations.isEmpty {
                    Text(loaded ? "目前沒有可預覽的行程地點。" : "讀取行程中…")
                        .foregroundStyle(.secondary)
                }
                ForEach(locations, id: \.self) { original in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原文").font(.caption).foregroundStyle(.secondary)
                        Text(original).textSelection(.enabled)
                        Text("結果").font(.caption).foregroundStyle(.secondary)
                        Text(preview[original] ?? original)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                Button("重新讀取行程") { Task { await loadLocations() } }
                    .frame(minHeight: 44)
            } footer: { Text("使用目前選取的行事曆與既有行程查詢範圍。") }
        }
        // 設定的每一頁：標題列到第一張卡片的距離和設定首頁相同（卡片上方沒有標題）。
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("行程地點")
        .scrollDismissesKeyboard(.interactively)
        .task {
            guard !loaded else { return }
            let settings = await Task.detached { FormlessEventLocationSettings.load() }.value
            pattern = settings.pattern
            savedPattern = pattern
            excludedCalendars = settings.excludedCalendars
            let sourceExcluded = FormlessCalendarSettings.current().excluded
            calendars = FormlessEventsProvider.allCalendars().filter { !sourceExcluded.contains($0.calendarIdentifier) }
            loaded = true
            status = "已儲存"
            await loadLocations()
        }
        .task(id: pattern) {
            guard loaded, pattern != savedPattern else { return }
            status = "儲存中…"
            let snapshot = pattern
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await persist(snapshot)
        }
        .task(id: PreviewInput(pattern: pattern, locations: locations)) {
            let input = PreviewInput(pattern: pattern, locations: locations)
            let results = await Task.detached {
                let settings = FormlessEventLocationSettings(pattern: input.pattern)
                let invalid = !input.pattern.isEmpty && (try? NSRegularExpression(pattern: input.pattern)) == nil
                return (Dictionary(uniqueKeysWithValues: input.locations.map { ($0, settings.extract($0)) }), invalid)
            }.value
            guard !Task.isCancelled else { return }
            preview = results.0
            invalidRule = results.1
        }
        .onDisappear {
            let snapshot = pattern
            guard loaded, snapshot != savedPattern else { FormlessWidgetReload.flush(); return }
            Task { await persist(snapshot); FormlessWidgetReload.flush() }
        }
    }

    private func calendarBinding(for item: EKCalendar) -> Binding<Bool> {
        Binding {
            !excludedCalendars.contains(item.calendarIdentifier)
        } set: { isOn in
            if isOn { excludedCalendars.remove(item.calendarIdentifier) } else { excludedCalendars.insert(item.calendarIdentifier) }
            Task { await persist(pattern) }
        }
    }

    private func color(of item: EKCalendar) -> Color {
        guard let cgColor = item.cgColor else { return .accentColor }
        return Color(uiColor: UIColor(cgColor: cgColor))
    }

    private func persist(_ snapshot: String) async {
        let revision = ProcessInfo.processInfo.systemUptime
        do {
            let settings = FormlessEventLocationSettings(pattern: snapshot, excludedCalendars: excludedCalendars)
            let didSave = try await EventLocationWriter.shared.save(settings, revision: revision)
            guard didSave, snapshot == pattern else { return }
            savedPattern = snapshot
            status = "已儲存"
            // 打字停頓、切換行事曆都會存一次；小工具等離開這一頁再一起重新整理。
            FormlessWidgetReload.request()
        } catch {
            status = "儲存失敗，請重試。"
        }
    }

    private func loadLocations() async {
        let values = await Task.detached {
            let events = FormlessEventsProvider.fetch(limit: Int.max) ?? []
            return Array(Set(events.compactMap(\.location).filter { !$0.isEmpty })).sorted()
        }.value
        locations = values
    }
}

private actor EventLocationWriter {
    static let shared = EventLocationWriter()
    private var latestRevision = 0.0
    func save(_ settings: FormlessEventLocationSettings, revision: Double) throws -> Bool {
        guard revision >= latestRevision else { return false }
        latestRevision = revision
        guard let directory = FormlessStorage.cacheDirectoryURL else { throw FormlessError.noSharedContainer }
        let data = try JSONEncoder().encode(settings)
        try data.write(to: directory.appendingPathComponent(FormlessEventLocationSettings.cacheName), options: .atomic)
        NotificationCenter.default.post(name: FormlessCache.didUpdate, object: nil)
        return true
    }
}

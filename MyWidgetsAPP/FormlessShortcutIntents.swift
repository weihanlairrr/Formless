import Foundation
import AppIntents
import WidgetKit

// MARK: - 捷徑動作：把值存進 Formless、讀出來
//
// 「設定 Formless 資料」把捷徑裡的值存成「我的資料 › 捷徑」裡的一個欄位，存完重新整理小工具，不打開 App。
// 讀懂文字的規則在 `FormlessShortcutStore.value(from:as:)`（FormlessCore，測試也用它）。

/// 捷徑裡「種類」的選項。
enum FormlessShortcutKindOption: String, AppEnum {
    case text, number, date, bool, lines, json

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "資料種類"
    nonisolated static let caseDisplayRepresentations: [FormlessShortcutKindOption: DisplayRepresentation] = [
        .text: "文字",
        .number: "數字",
        .date: "日期",
        .bool: "是非",
        .lines: "清單（每行一項）",
        .json: "JSON"
    ]

    var kind: FormlessShortcutValueKind { FormlessShortcutValueKind(rawValue: rawValue) ?? .text }
}

struct FormlessSetDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "設定 Formless 資料"
    nonisolated static let description = IntentDescription(
        "把值存進 Formless 的「捷徑」資料，小工具會跟著更新。數字可以有千分位（8,430），日期可以寫 2026/10/04 15:08，清單一行一項。")
    nonisolated static let openAppWhenRun: Bool = false
    nonisolated static let isDiscoverable: Bool = true

    @Parameter(title: "名稱") var name: String
    @Parameter(title: "值") var value: String
    @Parameter(title: "種類", default: .text) var kind: FormlessShortcutKindOption

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$name) 設成 \(\.$value)") {
            \.$kind
        }
    }

    init() {
        name = ""
        value = ""
        kind = .text
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FormlessShortcutValueError(message: "名稱不能是空的") }
        let parsed = try FormlessShortcutStore.value(from: value, as: kind.kind)
        FormlessShortcutStore.set(parsed, for: key)
        WidgetCenter.shared.reloadAllTimelines()
        let shown = FormlessShortcutStore.text(parsed)
        return .result(value: shown, dialog: "已把「\(key)」設成 \(shown.isEmpty ? "空白" : shown)")
    }
}

struct FormlessGetDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "讀取 Formless 資料"
    nonisolated static let description = IntentDescription("讀出「設定 Formless 資料」存的值（文字）。清單一行一項，一筆資料是 JSON。")
    nonisolated static let openAppWhenRun: Bool = false
    nonisolated static let isDiscoverable: Bool = true

    @Parameter(title: "名稱", optionsProvider: FormlessShortcutNameOptions()) var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("讀取 \(\.$name)")
    }

    init() {
        name = ""
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = FormlessShortcutStore.all()[key] else {
            return .result(value: "", dialog: "還沒有「\(key)」這筆資料")
        }
        let text = FormlessShortcutStore.text(entry.value)
        return .result(value: text, dialog: "\(text.isEmpty ? "空白" : text)")
    }
}

/// 「讀取」的名稱選項：捷徑存過的名稱。
struct FormlessShortcutNameOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        FormlessShortcutStore.all().keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct FormlessShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FormlessSetDataIntent(),
                    phrases: ["用 \(.applicationName) 設定資料", "在 \(.applicationName) 記下資料"],
                    shortTitle: "設定資料",
                    systemImageName: "square.on.square.dashed")
        AppShortcut(intent: FormlessGetDataIntent(),
                    phrases: ["用 \(.applicationName) 讀取資料"],
                    shortTitle: "讀取資料",
                    systemImageName: "square.on.square.dashed")
    }
}

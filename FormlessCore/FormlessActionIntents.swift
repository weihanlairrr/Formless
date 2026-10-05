import Foundation
import AppIntents
import WidgetKit
@preconcurrency import EventKit

// MARK: - 小工具上直接執行的動作（2026-10 通用化，規劃第 4.3 節）
//
// 切換、加減我的資料與完成提醒事項在小工具上按了就做，不打開 App；系統執行後會重新整理小工具。
// 改的是 `FormlessVariableStore`（不是設計檔）：同一份設計放好幾個小工具時共用同一份狀態。

struct FormlessVariableActionIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "改變我的資料"
    nonisolated static let description = IntentDescription("切換或加減小工具裡的「我的資料」。")
    nonisolated static let isDiscoverable: Bool = false
    nonisolated static let openAppWhenRun: Bool = false

    @Parameter(title: "設計") var documentID: String
    @Parameter(title: "我的資料") var variableID: String
    /// toggle 或 add。
    @Parameter(title: "動作") var action: String
    @Parameter(title: "數值") var amount: Double

    init() {
        documentID = ""
        variableID = ""
        action = "toggle"
        amount = 1
    }

    init(documentID: UUID, variableID: String, action: String, amount: Double) {
        self.documentID = documentID.uuidString
        self.variableID = variableID
        self.action = action
        self.amount = amount
    }

    func perform() async throws -> some IntentResult {
        guard let document = FormlessStorage.load(idString: documentID),
              let variable = document.variables?.first(where: { $0.id.uuidString == variableID }) else { return .result() }
        let current = FormlessVariableStore.values(for: document.id)[variableID] ?? variable.value
        let next: FormlessValue
        if action == "toggle" {
            next = .bool(!(current.boolValue ?? false))
        } else {
            next = .number((current.numberValue ?? 0) + amount, current.unit)
        }
        FormlessVariableStore.set(next, variable: variable.id, document: document.id)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct FormlessCompleteReminderIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "完成提醒事項"
    nonisolated static let description = IntentDescription("把小工具上的這一筆提醒事項標成完成。")
    nonisolated static let isDiscoverable: Bool = false
    nonisolated static let openAppWhenRun: Bool = false

    @Parameter(title: "提醒事項") var reminderID: String

    init() { reminderID = "" }
    init(reminderID: String) { self.reminderID = reminderID }

    func perform() async throws -> some IntentResult {
        guard FormlessRemindersProvider.isAuthorized else { return .result() }
        let store = EKEventStore()
        if let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder, !reminder.isCompleted {
            reminder.isCompleted = true
            try? store.save(reminder, commit: true)
        }
        // 讀新的提醒事項清單，小工具重新整理時就看不到剛完成的這一筆。
        await FormlessLiveData.bounded(8) {
            if let reminders = await FormlessRemindersProvider.fetch() {
                FormlessCache.save(reminders, name: FormlessRemindersProvider.cacheName)
            }
            for document in FormlessStorage.loadAll() {
                await FormlessDataCoordinator.warm([document], force: true)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

extension FormlessLayer {
    /// 小工具上這個圖層的按鈕動作；nil 是不在小工具上直接執行（開網址這類由 Link 處理）。
    func widgetIntent(document: FormlessDocument, live: FormlessLiveData) -> (any AppIntent)? {
        switch effectiveTapAction {
        case .refresh?:
            return FormlessRefreshIntent(kind: "", documentID: document.id.uuidString)
        case .toggleVariable?:
            guard let target = tapTarget, document.variables?.contains(where: { $0.id.uuidString == target }) == true else { return nil }
            return FormlessVariableActionIntent(documentID: document.id, variableID: target, action: "toggle", amount: 0)
        case .adjustVariable?:
            guard let target = tapTarget, document.variables?.contains(where: { $0.id.uuidString == target }) == true else { return nil }
            return FormlessVariableActionIntent(documentID: document.id, variableID: target, action: "add", amount: tapAmount ?? 1)
        case .completeReminder?:
            guard let id = live.item?.id, !id.isEmpty, id != "sample" else { return nil }
            return FormlessCompleteReminderIntent(reminderID: id)
        default:
            return nil
        }
    }
}

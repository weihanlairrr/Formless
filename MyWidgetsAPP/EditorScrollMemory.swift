import SwiftUI
import UIKit

/// 記住原生表單的捲動位置；不讀寫檔案，也不取代原生鍵盤避讓。
struct EditorScrollMemory: UIViewRepresentable {
    let session: EditorSession
    let key: String
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak uiView] in
            guard let uiView else { return }
            coordinator.attach(from: uiView, key: key)
        }
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator {
        let session: EditorSession
        weak var scroll: UIScrollView?
        var observation: NSKeyValueObservation?
        var key: String?
        var restoring = false
        var appliedHistoryRevision: UInt64?
        init(session: EditorSession) { self.session = session }
        func findScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.bounds.height > 80 { return scroll }
            for child in view.subviews { if let found = findScroll(child) { return found } }
            return nil
        }
        func attach(from view: UIView, key newKey: String) {
            var ancestor = view.superview
            var found: UIScrollView?
            while let candidate = ancestor, found == nil {
                found = findScroll(candidate)
                ancestor = candidate.superview
            }
            guard let found else { return }
            if scroll === found && key == newKey {
                guard appliedHistoryRevision != session.historyNavigationRevision else { return }
                appliedHistoryRevision = session.historyNavigationRevision
                restoreOffset(in: found, key: newKey)
                return
            }
            detach()
            scroll = found; key = newKey
            appliedHistoryRevision = session.historyNavigationRevision
            restoreOffset(in: found, key: newKey)
            observation = found.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    guard let self, let key = self.key else { return }
                    // 屬性面板（key 是「圖層:分類」）的頂端淡化和圖層清單同一個算法、同一個來源：
                    // 直接讀底下 UIScrollView 的位移（位移 + 頂端內距，停在初始位置為 0）。
                    if key.contains(":") {
                        self.session.inspectorFade.update(scrollOffset: scroll.contentOffset.y + scroll.adjustedContentInset.top)
                    }
                    guard !self.restoring else { return }
                    self.session.scrollOffsets[key] = scroll.contentOffset
                }
            }
        }
        private func restoreOffset(in scroll: UIScrollView, key: String) {
            guard let saved = session.scrollOffsets[key] else { return }
            restoring = true
            scroll.layoutIfNeeded()
            scroll.setContentOffset(saved, animated: false)
            restoring = false
        }
        func detach() {
            if let scroll, let key, !restoring { session.scrollOffsets[key] = scroll.contentOffset }
            observation = nil; scroll = nil; key = nil; appliedHistoryRevision = nil
        }
    }
}

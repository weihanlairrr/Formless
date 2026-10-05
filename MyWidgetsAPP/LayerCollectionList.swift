import SwiftUI
import UIKit

/// 圖層清單的 UIKit 版本。每一列仍由 SwiftUI 的 `EditorListRow` 繪製（`UIHostingConfiguration`），
/// 但排序拖曳改由自己的長按手勢驅動 `UICollectionView` 的互動式移動，而不是 SwiftUI `List.onMove`：
/// - 拿得到手指的水平位置，才能判定「往左下離開群組」「往右進入群組」，並讓被拖的卡片即時內縮／變長；
/// - 放下時只更新有變動的列，不重建整份清單，不會閃爍；
/// - 不走系統的 drag and drop，模擬器的合成觸控也能完整測試。
struct LayerCollectionList: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    let onSelect: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, session: session, onSelect: onSelect) }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeCollectionView() }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.picking = session.picking
        // 內距固定：選取模式較小的頂端間距由外層版面往上靠來做，和畫布、工具列同一個 SwiftUI 動畫。
        coordinator.setTopInset(EditorPanelUnderlap.height, animated: false)
        coordinator.apply(rows: model.displayRows, animated: !context.transaction.disablesAnimations)
        coordinator.reveal(session.listAnchor)
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: EditorModel
        let session: EditorSession
        var onSelect: (UUID) -> Void
        var picking = false

        private(set) weak var collectionView: UICollectionView?
        private var offsetObservation: NSKeyValueObservation?
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private var rowsByID: [UUID: FormlessLayerRow] = [:]
        private var order: [UUID] = []
        private var pendingRows: [FormlessLayerRow]?

        /// 一次拖曳的狀態。`others` 是不含被拖列的順序；`target` 是被拖列在 `others` 中的插入位置，
        /// 也就是移動後它在整份清單裡的索引。
        private struct Drag {
            let id: UUID
            let row: FormlessLayerRow
            let startLocation: CGPoint
            let centerX: CGFloat
            let grabOffsetY: CGFloat
            let originalIndex: Int
            let others: [UUID]
            let collapsedForLift: Bool
            var target: Int
            var intentParent: UUID?
            var lastLocation: CGPoint
            weak var cell: UICollectionViewCell?
        }
        private var drag: Drag?
        /// 這次拖曳的放下收尾是否已執行；didReorder 與 endDrag 的下一輪補呼叫都會進來，只做一次。
        private var dropFinalized = false
        private weak var press: UILongPressGestureRecognizer?
        /// 手指相對於按下位置的水平位移超過這個值，才算「往左」或「往右」的意圖（約半個內縮寬度）。
        private let intentThreshold: CGFloat = 28

        init(model: EditorModel, session: EditorSession, onSelect: @escaping (UUID) -> Void) {
            self.model = model
            self.session = session
            self.onSelect = onSelect
        }

        // MARK: 建立

        func makeCollectionView() -> UICollectionView {
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            let layout = LayerCollectionLayout(configuration: configuration)
            layout.constrainTarget = { [weak self] previous, proposed in
                self?.constrainedTarget(previous: previous, proposed: proposed) ?? proposed
            }
            let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
            // 頂端淡化只在內容捲進留白時出現：把捲動位移（扣掉頂端內距）回報給 session。
            offsetObservation = view.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.session.listFade.update(scrollOffset: view.contentOffset.y + view.contentInset.top)
                }
            }
            view.backgroundColor = .clear
            view.allowsSelection = false
            view.alwaysBounceVertical = true
            view.contentInsetAdjustmentBehavior = .never
            view.contentInset = UIEdgeInsets(top: EditorPanelUnderlap.height, left: 0,
                                             bottom: 64 + FormlessSafeArea.bottom, right: 0)
            view.verticalScrollIndicatorInsets = UIEdgeInsets(top: EditorPanelUnderlap.height, left: 0,
                                                              bottom: FormlessSafeArea.bottom, right: 0)
            view.keyboardDismissMode = .interactive
            view.semanticContentAttribute = .forceLeftToRight
            if #available(iOS 26.0, *) {
                view.topEdgeEffect.isHidden = true
                view.bottomEdgeEffect.isHidden = true
            }

            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: view) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in self?.drag != nil }
            dataSource.reorderingHandlers.didReorder = { [weak self] transaction in self?.finishReorder(transaction) }

            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
            press.minimumPressDuration = 0.3
            press.allowableMovement = 10
            press.delegate = self
            view.addGestureRecognizer(press)
            self.press = press

            collectionView = view
            return view
        }

        /// 選取模式與一般模式的頂端內距不同；切換時連著位移一起動畫，停在頂端的清單不會跳。
        func setTopInset(_ inset: CGFloat, animated: Bool) {
            guard let view = collectionView, abs(view.contentInset.top - inset) > 0.5 else { return }
            let atTop = view.contentOffset.y <= -view.contentInset.top + 1
            let apply = {
                view.contentInset.top = inset
                view.verticalScrollIndicatorInsets.top = inset
                if atTop { view.contentOffset.y = -inset }
            }
            if animated { UIView.animate(withDuration: FormlessMotion.pushDuration, delay: 0, options: [.curveEaseOut], animations: apply) } else { apply() }
        }

        /// 拖曳中會被放進的收合群組：標題列亮起。
        private var dropTargetGroupID: UUID?
        private func setDropTarget(_ id: UUID?) {
            guard id != dropTargetGroupID else { return }
            let previous = dropTargetGroupID
            dropTargetGroupID = id
            for groupID in [previous, id].compactMap({ $0 }) {
                if let indexPath = dataSource.indexPath(for: groupID),
                   let cell = collectionView?.cellForItem(at: indexPath) as? UICollectionViewListCell {
                    configure(cell, id: groupID)
                }
            }
        }

        private func configure(_ cell: UICollectionViewListCell, id: UUID, indentOverride: Int? = nil) {
            guard let row = rowsByID[id] else { return }
            let override: Int? = indentOverride ?? (drag?.id == id ? (drag?.intentParent != nil ? 1 : 0) : nil)
            let model = model, session = session
            let dropTarget = dropTargetGroupID == id
            cell.contentConfiguration = UIHostingConfiguration {
                EditorListRow(model: model, session: session, row: row,
                              onSelect: { [weak self] in self?.onSelect(id) },
                              indentOverride: override, dropTarget: dropTarget)
            }
            .margins(.horizontal, 0)
            .margins(.vertical, 3)
            .background(Color.clear)
            cell.backgroundConfiguration = .clear()
            // 淡出移除過的格子會被重複使用，拿來顯示別的列時要恢復不透明；剛加回來、還在等其他列讓位的列內容先藏著。
            // 要在設定內容之後：換內容時會換上新的 contentView，先設的透明度會被蓋掉。
            cell.alpha = 1
            cell.contentView.alpha = heldIDs.contains(id) ? 0 : 1
        }

        // MARK: 資料

        /// 要移除的列正在淡出：這段期間的更新先記著，淡出完一起套用。
        private var fading = false
        private var rowsAfterFade: [FormlessLayerRow]?

        /// 依模型更新列。順序沒變時只重設內容有變（名稱、內縮、狀態）的列；拖曳中先擱著，放下後再套用。
        func apply(rows: [FormlessLayerRow], animated: Bool, fadesRemoved: Bool = true) {
            recoverStaleDragIfNeeded()
            guard drag == nil else { pendingRows = rows; return }
            if fading { rowsAfterFade = rows; return }
            if animated, fadesRemoved, fadeOutRemovedRows(before: rows) { return }
            let previous = rowsByID
            rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let ids = rows.map(\.id)
            let changed = rows.filter { row in
                previous[row.id].map { Self.rowChanged($0, row) } ?? false
            }.map(\.id)
            let orderChanged = ids != order
            guard orderChanged || !changed.isEmpty else { return }
            let previousOrder = Set(order)
            order = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            if !changed.isEmpty { snapshot.reconfigureItems(changed) }
            // 加回來的列（例如上一步讓消失的群組回來）先保持透明，等其他列滑開讓出位置才原地淡入；
            // 原本加入和讓位同時進行，新的列淡入時和往下滑的列疊在一起，看起來閃一下（使用者回報）。
            // 系統版面會自己動列本身的透明度，所以藏的是列的內容（contentView），版面管不到。
            let inserted = Set(ids.filter { !previousOrder.contains($0) })
            let animate = animated && orderChanged
            guard animate, !inserted.isEmpty, !previousOrder.isEmpty else {
                dataSource.apply(snapshot, animatingDifferences: animate)
                return
            }
            heldIDs.formUnion(inserted)
            let reveal: () -> Void = { [weak self] in
                guard let self, !self.heldIDs.isDisjoint(with: inserted) else { return }
                self.heldIDs.subtract(inserted)
                let cells = inserted.compactMap { id in
                    self.dataSource.indexPath(for: id).flatMap { self.collectionView?.cellForItem(at: $0) }
                }
                UIView.animate(withDuration: FormlessDesign.Motion.fadeDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    cells.forEach { $0.contentView.alpha = 1 }
                }
            }
            // 系統的完成回呼在這裡會在動畫一開始就叫，不能拿來等。讀出這次讓位動畫的實際長度（實機與模擬器不同），
            // 跑到約三分之二、其他列已經讓開時就開始淡入：等到完全結束，動畫尾巴那段幾乎不動，看起來像空了一拍。
            // 讀不到長度時，以整個動畫交易結束為準。
            let start = CACurrentMediaTime()
            CATransaction.begin()
            CATransaction.setCompletionBlock(reveal)
            dataSource.apply(snapshot, animatingDifferences: true)
            CATransaction.commit()
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.collectionView else { return }
                let duration = view.visibleCells
                    .compactMap { cell in ["position", "bounds.origin", "bounds"].compactMap { cell.layer.animation(forKey: $0)?.duration }.max() }
                    .max()
                guard let duration, duration > 0 else { return }
                let remaining = max(0, start + duration * 0.65 - CACurrentMediaTime())
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: reveal)
            }
        }
        private var heldIDs = Set<UUID>()

        /// 捲到指定的列（新增圖層後）：屬性面板滑進來蓋住清單之後才捲，看不到捲動；回到清單時就停在那一列。
        /// 整列已經看得到就不動。捲完清掉 `listAnchor`。
        private var pendingReveal: UUID?
        func reveal(_ id: UUID?) {
            guard let id, id != pendingReveal else { return }
            pendingReveal = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.pendingReveal == id else { return }
                self.pendingReveal = nil
                defer { if self.session.listAnchor == id { self.session.listAnchor = nil } }
                guard let view = self.collectionView, let indexPath = self.dataSource.indexPath(for: id) else { return }
                view.layoutIfNeeded()
                let visible = view.bounds.inset(by: view.contentInset)
                if let frame = view.layoutAttributesForItem(at: indexPath)?.frame, visible.contains(frame) { return }
                view.scrollToItem(at: indexPath, at: .top, animated: false)
            }
        }

        /// 列上看得到的東西有沒有變：名稱、顯示、鎖定、群組與收合、所屬群組、內縮。其他欄位（顏色、大小、位置……）
        /// 在清單上看不到，不必重設這一列（原本任何欄位一變就重設，拖一下滑桿被蓋住的清單也跟著重排版）。
        private static func rowChanged(_ old: FormlessLayerRow, _ new: FormlessLayerRow) -> Bool {
            let a = old.layer, b = new.layer
            return old.indent != new.indent || a.name != b.name || a.visible != b.visible || a.locked != b.locked
                || a.group != b.group || a.collapsed != b.collapsed || a.parentID != b.parentID
        }

        /// 要從清單拿掉的列先原地淡出，淡出完才移除、下面的列再往上補位。原本移除和補位同時開始，
        /// 下面的列滑上來時壓在還沒淡完的列上，看起來閃一下（使用者回報：群組消失時）。
        /// 淡出期間留下來的列照常更新（例如結束選取模式時換回一般外觀）。畫面上看不到要移除的列就直接套用。
        private func fadeOutRemovedRows(before rows: [FormlessLayerRow]) -> Bool {
            guard let view = collectionView else { return false }
            let incoming = Set(rows.map(\.id))
            let removed = order.filter { !incoming.contains($0) }
            let cells = removed.compactMap { id in dataSource.indexPath(for: id).flatMap { view.cellForItem(at: $0) } }
            guard !cells.isEmpty else { return false }
            // 先更新留下來的列；要移除的列保留原本的資料，淡出時維持原樣。
            let previous = rowsByID
            var interim = previous
            for row in rows { interim[row.id] = row }
            rowsByID = interim
            let changed = rows.filter { row in
                previous[row.id].map { Self.rowChanged($0, row) } ?? false
            }.map(\.id)
            var snapshot = dataSource.snapshot()
            let present = changed.filter { snapshot.indexOfItem($0) != nil }
            if !present.isEmpty {
                snapshot.reconfigureItems(present)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            fading = true
            rowsAfterFade = rows
            UIView.animate(withDuration: FormlessDesign.Motion.fadeDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                cells.forEach { $0.alpha = 0 }
            } completion: { [weak self] _ in
                guard let self else { return }
                self.fading = false
                let latest = self.rowsAfterFade ?? rows
                self.rowsAfterFade = nil
                self.apply(rows: latest, animated: true, fadesRemoved: false)
                // 淡出期間又被加回來的列（例如馬上復原）要重新顯示。
                let kept = Set(latest.map(\.id))
                for id in removed where kept.contains(id) {
                    if let indexPath = self.dataSource.indexPath(for: id) { self.collectionView?.cellForItem(at: indexPath)?.alpha = 1 }
                }
            }
            return true
        }

        private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard !picking, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "刪除") { [weak self] _, _, completion in
                self?.model.deleteLayers([id])
                completion(true)
            }
            delete.image = UIImage(systemName: "trash")
            let configuration = UISwipeActionsConfiguration(actions: [delete])
            configuration.performsFirstActionWithFullSwipe = false
            return configuration
        }

        // MARK: 拖曳

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            recoverStaleDragIfNeeded()
            guard picking, drag == nil, let collectionView else { return false }
            return collectionView.indexPathForItem(at: gestureRecognizer.location(in: collectionView)) != nil
        }

        /// 與列內的 SwiftUI 手勢並存（按住時它們不會成立）；捲動的 pan 不並存，長按成立後就不再捲動。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other is UIPanGestureRecognizer)
        }

        @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            let location = recognizer.location(in: collectionView)
            switch recognizer.state {
            case .began: beginDrag(at: location)
            case .changed: updateDrag(to: location)
            case .ended: endDrag()
            case .cancelled, .failed: cancelDrag()
            default: break
            }
        }

        private func beginDrag(at location: CGPoint) {
            guard let collectionView,
                  let indexPath = collectionView.indexPathForItem(at: location),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let row = rowsByID[id] else { return }
            var collapsed = false
            if row.layer.group && !row.layer.collapsed {
                // 拖群組前先收合，整個群組以一列移動；放下後維持收合。
                model.setCollapsed(id, true)
                collapsed = true
                apply(rows: model.displayRows, animated: false)
                collectionView.layoutIfNeeded()
            }
            guard let index = order.firstIndex(of: id),
                  let currentPath = dataSource.indexPath(for: id),
                  let cell = collectionView.cellForItem(at: currentPath),
                  let current = rowsByID[id] else {
                if collapsed { model.setCollapsed(id, false) }
                return
            }
            var others = order
            others.remove(at: index)
            drag = Drag(id: id, row: current, startLocation: location, centerX: cell.center.x,
                        grabOffsetY: cell.center.y - location.y, originalIndex: index, others: others,
                        collapsedForLift: collapsed, target: index, intentParent: current.layer.parentID,
                        lastLocation: location, cell: cell)
            guard collectionView.beginInteractiveMovementForItem(at: currentPath) else {
                drag = nil
                if collapsed { model.setCollapsed(id, false) }
                return
            }
            setLifted(cell, true)
            FormlessHaptics.light()
        }

        private func updateDrag(to location: CGPoint) {
            guard drag != nil, let collectionView else { return }
            drag?.lastLocation = location
            // 卡片只跟著手指上下移動；左右的意圖用內縮表達，不讓卡片左右漂。
            let target = CGPoint(x: drag!.centerX, y: location.y + drag!.grabOffsetY)
            collectionView.updateInteractiveMovementTargetPosition(target)
            refreshIntent()
        }

        private func endDrag() {
            guard let collectionView, drag != nil else { return }
            collectionView.endInteractiveMovement()
            // 落點與原位置相同時，UIKit 不會回報搬動、didReorder 也不會來；下一輪自行收尾。
            // 若 didReorder 已先收尾，這裡是空操作。
            DispatchQueue.main.async { [weak self] in self?.completeDrop(finalOrder: nil) }
        }

        /// 手指已經不在螢幕上，拖曳狀態卻還留著（放下時沒有任何回呼進來）：清掉並還原外觀，清單才會繼續更新。
        private func recoverStaleDragIfNeeded() {
            guard let current = drag, !dropFinalized, let press, press.state == .possible else { return }
            collectionView?.cancelInteractiveMovement()
            if let cell = current.cell { setLifted(cell, false) }
            setDropTarget(nil)
            drag = nil
            let rows = pendingRows ?? model.displayRows
            pendingRows = nil
            apply(rows: rows, animated: false)
        }

        private func cancelDrag() {
            guard let collectionView, let current = drag else { return }
            guard !dropFinalized else { return }
            collectionView.cancelInteractiveMovement()
            if let cell = current.cell { setLifted(cell, false) }
            setDropTarget(nil)
            drag = nil
            if current.collapsedForLift { model.setCollapsed(current.id, false) }
            apply(rows: pendingRows ?? model.displayRows, animated: false)
            pendingRows = nil
        }

        /// didReorder：資料源已依落點換好順序。
        private func finishReorder(_ transaction: NSDiffableDataSourceTransaction<Int, UUID>) {
            completeDrop(finalOrder: transaction.finalSnapshot.itemIdentifiers)
        }

        /// 放下：先把搬動（含進出群組）寫進模型，再依模型結果更新清單。清單順序已經一致，只會重設有變動的列（內縮）。
        /// `finalOrder` 為 nil 表示 UIKit 沒有換位置（落點同原位）；此時仍依水平意圖決定進出群組。
        private func completeDrop(finalOrder: [UUID]?) {
            guard let current = drag, !dropFinalized else { return }
            dropFinalized = true
            if let finalOrder { order = finalOrder }
            // 以拖曳中最後一次回報給版面的落點為準（那就是使用者看到的縫隙位置），
            // 不用資料源回報的最終索引：兩者偶爾差一格，會讓預告的內縮和實際結果不符。
            let target = current.target
            let dx = current.lastLocation.x - current.startLocation.x
            let parent = resolvedParent(target: target, dx: dx, for: current)
            setDropTarget(nil)
            var anchor: UUID? = target < current.others.count ? current.others[target] : nil
            if let parent, anchor == parent || rowsByID[parent]?.layer.collapsed == true {
                // 放進收合中的群組（停在標題上，不管落點算在標題之前還是之後）：放在群組最上面，
                // 也就是標題之後的第一個子圖層之前；原本落點在標題之後時會掉到群組最底下。
                anchor = model.document.children(of: parent).last?.id
            }
            if let cell = current.cell { setLifted(cell, false) }
            FormlessHaptics.light()

            // didReorder 是在資料源套用快照的過程中呼叫的，這裡不能再套用快照（會重入而崩潰）。
            // 等這一輪結束再改模型、更新清單；期間 drag 仍非 nil，模型變動觸發的更新會先擱著。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.moveLayers([current.id], before: anchor, parent: parent)
                if let parent, self.rowsByID[parent]?.layer.collapsed == true {
                    // 進到收合中的群組：展開它，讓使用者看到圖層落在哪。
                    self.model.setCollapsed(parent, false)
                }
                self.drag = nil
                self.dropFinalized = false
                self.pendingRows = nil
                self.apply(rows: self.model.displayRows, animated: true)
            }
        }

        /// 版面詢問落點時同步更新 `drag.target`；群組不能停在別的群組區塊裡，依拖曳方向貼到區塊邊界。
        private func constrainedTarget(previous: IndexPath, proposed: IndexPath) -> IndexPath {
            guard let current = drag else { return proposed }
            var target = max(0, min(proposed.item, current.others.count))
            if current.row.layer.group, let block = block(containingSlot: target, in: current.others) {
                target = target > current.originalIndex ? block.end : block.start
            }
            drag?.target = target
            return IndexPath(item: target, section: 0)
        }

        /// 插入位置 `slot` 若在某群組的區塊裡（下一列是它的子圖層），回傳該區塊在 `others` 中的起訖：
        /// `start` 是群組標題的索引，`end` 是最後一個子圖層之後的位置。
        private func block(containingSlot slot: Int, in others: [UUID]) -> (start: Int, end: Int)? {
            guard slot < others.count, let next = rowsByID[others[slot]], let group = next.layer.parentID,
                  let start = others.firstIndex(of: group) else { return nil }
            var end = start + 1
            while end < others.count, rowsByID[others[end]]?.layer.parentID == group { end += 1 }
            return (start, end)
        }

        /// 依落點與水平意圖決定放下後所屬的群組（nil 為根層）。
        /// - 落在某群組的子圖層之間（含緊接標題之後）：進入該群組。
        /// - 群組區塊末端（最後一個子圖層之後）：原本就在這個群組 → 往左才離開；來自外面 → 往右才進入。
        /// - 緊接收合群組的標題之後：往右才算進入。
        /// - 群組標題之前、根層之間：根層。群組本身永遠在根層。
        private func resolvedParent(target: Int, dx: CGFloat, for current: Drag) -> UUID? {
            guard !current.row.layer.group else { return nil }
            let others = current.others
            let previous = target > 0 ? rowsByID[others[target - 1]] : nil
            let next = target < others.count ? rowsByID[others[target]] : nil
            if let parent = next?.layer.parentID { return parent }
            if let previous, previous.layer.group {
                return (!previous.layer.collapsed || dx > intentThreshold) ? previous.id : nil
            }
            // 停在收合群組的標題上（落點在標題之前）並往右：直接放進這個群組，不必先展開它。
            if let next, next.layer.group, next.layer.collapsed, dx > intentThreshold { return next.id }
            if let previous, let parent = previous.layer.parentID {
                let inside = current.row.layer.parentID == parent ? dx > -intentThreshold : dx > intentThreshold
                return inside ? parent : nil
            }
            return nil
        }

        private func refreshIntent() {
            guard let current = drag else { return }
            let dx = current.lastLocation.x - current.startLocation.x
            let intent = resolvedParent(target: current.target, dx: dx, for: current)
            guard intent != current.intentParent else { return }
            drag?.intentParent = intent
            if let cell = current.cell as? UICollectionViewListCell {
                configure(cell, id: current.id, indentOverride: intent != nil ? 1 : 0)
            }
            // 放手會落入的群組，標題亮起（不管展開或收合）；卡片內縮只說「會在某個群組裡」，亮起才說是哪一個。
            setDropTarget(intent)
            FormlessHaptics.light()
        }

        /// 抬起的視覺：內容稍微放大、加陰影。動的是 contentView，版面屬性不會覆蓋它。
        private func setLifted(_ cell: UICollectionViewCell, _ lifted: Bool) {
            UIView.animate(withDuration: FormlessDesign.Motion.fadeDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                cell.contentView.transform = lifted ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
                cell.contentView.layer.shadowOpacity = lifted ? 0.16 : 0
            }
            cell.contentView.layer.shadowColor = UIColor.black.cgColor
            cell.contentView.layer.shadowRadius = 10
            cell.contentView.layer.shadowOffset = CGSize(width: 0, height: 6)
        }
    }
}

/// 讓外部決定互動式移動的落點（群組不進群組）。
final class LayerCollectionLayout: UICollectionViewCompositionalLayout {
    var constrainTarget: ((IndexPath, IndexPath) -> IndexPath)?

    init(configuration: UICollectionLayoutListConfiguration) {
        super.init(sectionProvider: { _, environment in
            NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        })
    }

    required init?(coder: NSCoder) { nil }

    /// 只有寬度變了才重排；畫布拖曳時清單只是高度逐格改變，預設每一格都整份重排（每個 UIHostingConfiguration 列都重量），
    /// 拖起來一格一格卡。
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return super.shouldInvalidateLayout(forBoundsChange: newBounds) }
        return abs(collectionView.bounds.width - newBounds.width) > 0.5
    }

    override func targetIndexPath(forInteractivelyMovingItem previousIndexPath: IndexPath,
                                  withPosition position: CGPoint) -> IndexPath {
        let proposed = super.targetIndexPath(forInteractivelyMovingItem: previousIndexPath, withPosition: position)
        return constrainTarget?(previousIndexPath, proposed) ?? proposed
    }
}

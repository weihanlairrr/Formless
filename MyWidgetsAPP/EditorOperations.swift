import SwiftUI
import Combine

/// 僅供編輯器使用；編輯範圍固定在 1600 × 1600 畫布內。
enum EditorNumbers {
    /// 只取整數，不限制範圍：位置可以是負的、尺寸可以超過面板，超出的部分本來就允許。
    static func integer(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(-Double(Int.max / 2), min(value.rounded(), Double(Int.max / 2)))
    }
    static func frame(_ source: FormlessFrame) -> FormlessFrame {
        let width = max(1, integer(source.width * 1600))
        let height = max(1, integer(source.height * 1600))
        return FormlessFrame(x: integer(source.x * 1600) / 1600, y: integer(source.y * 1600) / 1600,
                             width: width / 1600, height: height / 1600)
    }

    static func moved(_ source: FormlessFrame, dx: Double, dy: Double) -> FormlessFrame {
        var result = source
        if dx != 0 { result.x = integer(source.x * 1600 + dx) / 1600 }
        if dy != 0 { result.y = integer(source.y * 1600 + dy) / 1600 }
        return result
    }
}

@MainActor
extension EditorModel {
    func expandedIDs(_ ids: Set<UUID>) -> Set<UUID> {
        ids.union(document.layers.filter { $0.parentID.map(ids.contains) ?? false }.map(\.id))
    }

    func bounds(of ids: Set<UUID>) -> FormlessFrame? {
        let expanded = expandedIDs(ids)
        let frames = document.layers.filter { expanded.contains($0.id) && !$0.group }.map(\.frame)
        guard let first = frames.first else { return nil }
        let left = frames.reduce(first.x) { min($0, $1.x) }
        let top = frames.reduce(first.y) { min($0, $1.y) }
        let right = frames.reduce(first.x + first.width) { max($0, $1.x + $1.width) }
        let bottom = frames.reduce(first.y + first.height) { max($0, $1.y + $1.height) }
        return FormlessFrame(x: left, y: top, width: right - left, height: bottom - top)
    }

    func setGeometry(_ ids: Set<UUID>, frame: FormlessFrame) {
        guard let updated = geometryDocument(ids, frame: frame),
              let editID = ids.sorted(by: { $0.uuidString < $1.uuidString }).first else { return }
        noteEdit(editID)
        document = updated
    }

    private func geometryDocument(_ ids: Set<UUID>, frame: FormlessFrame) -> FormlessDocument? {
        let members = expandedIDs(ids)
        guard let old = bounds(of: ids),
              !document.layers.contains(where: { members.contains($0.id) && document.effectivelyLocked($0) }) else { return nil }
        let target = EditorNumbers.frame(frame)
        var updated = document
        for i in updated.layers.indices where members.contains(updated.layers[i].id) && !updated.layers[i].group {
            let original = updated.layers[i].frame
            var next = original
            next.x = target.x + (old.width > 0 ? (original.x - old.x) * target.width / old.width : 0)
            next.y = target.y + (old.height > 0 ? (original.y - old.y) * target.height / old.height : 0)
            next.width = old.width > 0 ? original.width * target.width / old.width : target.width
            next.height = old.height > 0 ? original.height * target.height / old.height : target.height
            updated.layers[i].frame = EditorNumbers.frame(next)
        }
        return updated == document ? nil : updated
    }

    func visibleBounds(of ids: Set<UUID>) -> FormlessFrame? {
        if let cached = visibleBoundsCache[ids], cached.document == documentRevision, cached.live == liveRevision,
           Date().timeIntervalSince(cached.at) < 1 {
            return cached.frame
        }
        let frame = EditorVisibleGeometry.bounds(document: document, ids: ids, live: live)
        visibleBoundsCache[ids] = (documentRevision, liveRevision, Date(), frame)
        return frame
    }

    enum VisibleEdge {
        case left, right, top, bottom
    }

    /// 四個絕對位置欄位都平移整個圖層，不改變尺寸。
    func moveVisibleEdge(_ ids: Set<UUID>, edge: VisibleEdge, to value: Double) {
        guard let visible = visibleBounds(of: ids) ?? bounds(of: ids) else { return }
        let current: Double
        switch edge {
        case .left: current = visible.x * 1600
        case .right: current = (visible.x + visible.width) * 1600
        case .top: current = visible.y * 1600
        case .bottom: current = (visible.y + visible.height) * 1600
        }
        let offset = EditorNumbers.integer(value) - current
        guard abs(offset) >= 0.01 else { return }
        switch edge {
        case .left, .right: translate(ids, dx: offset, dy: 0)
        case .top, .bottom: translate(ids, dx: 0, dy: offset)
        }
    }

    /// 只能等比縮放的圖層：文字類的可見大小由字級決定，圖片與圖示是等比放進框內，寬高都無法單獨改。
    static let proportionalTypes: Set<FormlessLayerType> = [.text, .date, .time, .liveText,
                                                            .image, .remoteImage, .bundleImage, .symbol]
    /// 選取（含群組成員）裡只要有一個只能等比縮放的圖層（含圓形色塊），整個選取就等比縮放，相對位置與比例才不會亂。
    func resizesProportionally(_ ids: Set<UUID>) -> Bool {
        let members = expandedIDs(ids)
        return document.layers.contains {
            members.contains($0.id) && !$0.group && (Self.proportionalTypes.contains($0.type) || Self.isCircle($0))
        }
    }
    static func isCircle(_ layer: FormlessLayer) -> Bool { layer.type == .shape && layer.shapeKind == .circle }
    /// 只選了一個圓形色塊：大小方塊只顯示「直徑」。
    func singleCircle(_ ids: Set<UUID>) -> Bool {
        ids.count == 1 && document.layers.contains { ids.contains($0.id) && Self.isCircle($0) }
    }

    /// 圓形色塊的框：直徑就是框寬（畫布寬的格數），框高 = 框寬 × 尺寸的寬高比，畫出來才是正圓
    /// （大型小工具的格子橫向 0.5 px、縱向 0.52 px，格子不是正方形）。使用者只看到「直徑」一個數字，高由這裡算。
    func circleFrame(_ frame: FormlessFrame, diameter: Double? = nil) -> FormlessFrame {
        let aspect = Double(document.family.aspectRatio)
        // 沒指定直徑時（剛切成圓形）以物理上的短邊為直徑，框不會突然變大。
        let width = diameter.map { max(1, EditorNumbers.integer($0)) }
            ?? max(1, EditorNumbers.integer(min(frame.width, frame.height / aspect) * 1600))
        return FormlessFrame(x: frame.x, y: frame.y, width: width / 1600,
                             height: max(1, EditorNumbers.integer(width * aspect)) / 1600)
    }
    /// 把選取裡所有圓形色塊的框修正成正圓（大小改變之後呼叫）。
    private func enforceCircles(_ document: inout FormlessDocument, members: Set<UUID>) {
        for i in document.layers.indices where members.contains(document.layers[i].id) && Self.isCircle(document.layers[i]) {
            document.layers[i].frame = circleFrame(document.layers[i].frame, diameter: document.layers[i].frame.width * 1600)
        }
    }

    /// 尺寸欄位縮放圖層，然後補償位置，讓可見內容的左／上邊維持原位。
    /// 可見邊界是點陣量測，與圖層框不成正比：先依比例猜，再用割線法修正一次，取最接近目標的結果。
    /// 位置補償以「顯示出來的整數」為準：x 軸一格不到一個像素，只比對實際差值會讓上／左每按一次跳 1。
    func resizeVisible(_ ids: Set<UUID>, horizontal: Bool, to value: Double) {
        let members = expandedIDs(ids)
        guard let base = bounds(of: ids),
              !document.layers.contains(where: { members.contains($0.id) && document.effectivelyLocked($0) }),
              let editID = ids.sorted(by: { $0.uuidString < $1.uuidString }).first else { return }
        let visible = visibleBounds(of: ids) ?? base
        let currentVisible = horizontal ? visible.width : visible.height
        let current = currentVisible * 1600
        guard current > 0, abs(value - current) >= 0.01 else { return }
        let desired = max(1, EditorNumbers.integer(value)) / 1600
        let selected = ids.count == 1 ? document.layers.first { ids.contains($0.id) && !$0.group } : nil
        let angle = selected.map { abs($0.rotation * .pi / 180) } ?? 0
        let changeWidth = (horizontal && abs(cos(angle)) >= abs(sin(angle))) ||
            (!horizontal && abs(cos(angle)) < abs(sin(angle)))
        let originalDimension = changeWidth ? base.width : base.height
        // 等比：框的寬高同一個比例，文字類的字級也乘上同一個比例（字級是「字級 × 畫布比例」，與框無關，
        // 只改框的話可見大小完全不動；多選時以前就是這樣，文字按了沒反應）。
        let proportional = resizesProportionally(ids)
        let fontMembers = proportional
            ? document.layers.filter { members.contains($0.id) && [.text, .date, .time, .liveText].contains($0.type) }
            : []

        func attempt(_ dimension: Double) -> (document: FormlessDocument, bounds: FormlessFrame, actual: Double)? {
            guard dimension.isFinite, dimension > 0 else { return nil }
            var target = base
            let ratio = dimension / originalDimension
            if proportional {
                target.width = base.width * ratio
                target.height = base.height * ratio
            } else if changeWidth {
                target.width = dimension
            } else {
                target.height = dimension
            }
            guard var resolved = geometryDocument(ids, frame: target) ?? (fontMembers.isEmpty ? nil : document) else { return nil }
            for member in fontMembers {
                guard let index = resolved.layers.firstIndex(where: { $0.id == member.id }) else { continue }
                // 與外觀分頁「字級」滑桿同一個範圍（6～120）；超出就到頂，可見尺寸只能盡量接近目標。
                resolved.layers[index].fontSize = min(120, max(6, (member.fontSize ?? 22) * ratio))
            }
            guard let bounds = EditorVisibleGeometry.bounds(document: resolved, ids: ids, live: live) else { return nil }
            return (resolved, bounds, horizontal ? bounds.width : bounds.height)
        }

        let firstGuess = originalDimension * desired / currentVisible
        guard var best = attempt(firstGuess) else { return }
        if abs(best.actual - desired) >= 0.5 / 1600 {
            let slope = (best.actual - currentVisible) / (firstGuess - originalDimension)
            if slope.isFinite, abs(slope) > 0.00001 {
                let next = firstGuess + (desired - best.actual) / slope
                if abs(next - firstGuess) * 1600 >= 0.5, let candidate = attempt(next),
                   abs(candidate.actual - desired) < abs(best.actual - desired) {
                    best = candidate
                }
            }
        }
        var updated = best.document
        enforceCircles(&updated, members: members)

        // 位置補償：先平移量到的差值，再對照顯示整數，最多修兩次。
        func shift(_ dx: Double, _ dy: Double) {
            for i in updated.layers.indices where members.contains(updated.layers[i].id) && !updated.layers[i].group {
                var shifted = updated.layers[i].frame
                shifted.x += dx; shifted.y += dy
                updated.layers[i].frame = EditorNumbers.frame(shifted)
            }
        }
        let shownX = EditorNumbers.integer(visible.x * 1600), shownY = EditorNumbers.integer(visible.y * 1600)
        shift(visible.x - best.bounds.x, visible.y - best.bounds.y)
        for _ in 0..<2 {
            guard let settled = EditorVisibleGeometry.bounds(document: updated, ids: ids, live: live) else { break }
            let dx = shownX - EditorNumbers.integer(settled.x * 1600)
            let dy = shownY - EditorNumbers.integer(settled.y * 1600)
            guard dx != 0 || dy != 0 else { break }
            shift(dx / 1600, dy / 1600)
        }
        guard updated != document else { return }
        noteEdit(editID)
        document = updated
    }

    func translate(_ ids: Set<UUID>, dx: Double, dy: Double) {
        let members = expandedIDs(ids)
        guard (dx != 0 || dy != 0),
              !document.layers.contains(where: { members.contains($0.id) && document.effectivelyLocked($0) }),
              let editID = ids.sorted(by: { $0.uuidString < $1.uuidString }).first else { return }
        var updated = document
        for i in updated.layers.indices where members.contains(updated.layers[i].id) && !updated.layers[i].group {
            updated.layers[i].frame = EditorNumbers.moved(updated.layers[i].frame, dx: dx, dy: dy)
        }
        guard updated != document else { return }
        noteEdit(editID)
        document = updated
    }

    // MARK: 畫布直接拖曳（10/03 決定）

    /// 只限已選取的圖層、從圖層本身開始拖；拖曳 1:1 跟手，放手算一步復原（開始時記一步，拖曳中直接改框）。
    /// 群組拖的是整組。鎖定的圖層不能拖。
    func beginCanvasDrag(_ id: UUID) -> Bool {
        let members = expandedIDs([id])
        guard !document.layers.contains(where: { members.contains($0.id) && document.effectivelyLocked($0) }) else { return false }
        let frames = document.layers.filter { members.contains($0.id) && !$0.group }.map { ($0.id, $0.frame) }
        guard !frames.isEmpty else { return false }
        pushUndo("位置" + layerTitle(id))
        canvasDragFrames = Dictionary(uniqueKeysWithValues: frames)
        return true
    }

    /// 拖曳中的範圍（畫布比例座標）：貼齊用。
    var canvasDragBounds: FormlessFrame? {
        guard let frames = canvasDragFrames?.values, let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for frame in frames {
            minX = min(minX, frame.x); minY = min(minY, frame.y)
            maxX = max(maxX, frame.x + frame.width); maxY = max(maxY, frame.y + frame.height)
        }
        return FormlessFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// dx、dy 是從開始拖的位置算起的位移（畫布比例）；存的時候和位置欄位一樣對齊到 1600 格的整數。
    func moveCanvasDrag(dx: Double, dy: Double) {
        guard let frames = canvasDragFrames else { return }
        var updated = document
        for i in updated.layers.indices {
            if let start = frames[updated.layers[i].id] {
                updated.layers[i].frame = EditorNumbers.moved(start, dx: dx * 1600, dy: dy * 1600)
            }
        }
        guard updated != document else { return }
        document = updated
    }

    func endCanvasDrag() { canvasDragFrames = nil }

    func deleteLayers(_ ids: Set<UUID>) {
        let targets = expandedIDs(ids)
        guard document.layers.contains(where: { targets.contains($0.id) }) else { return }
        pushUndo("刪除" + layersTitle(ids), detail: namesDetail(ids))
        let formerParents = Set(document.layers.filter { targets.contains($0.id) }.compactMap(\.parentID))
        document.layers.removeAll { targets.contains($0.id) }
        removeEmptiedGroups(formerParents)
        renumber()
        repairSelection()
    }

    /// 群組裡的圖層被刪光或搬空，群組就等於不存在，一併移除（使用者規則）。
    /// 只看這次被刪掉的圖層原本所屬的群組：剛新增、本來就是空的群組不受影響。
    func removeEmptiedGroups(_ formerParents: Set<UUID>) {
        // 選取模式中先保留，結束選取模式時才移除（見 finishPicking）。
        guard !defersEmptyGroupRemoval else { return }
        let occupied = Set(document.layers.compactMap(\.parentID))
        let emptied = formerParents.subtracting(occupied)
        guard !emptied.isEmpty else { return }
        document.layers.removeAll { $0.group && emptied.contains($0.id) }
    }

    func setVisibility(_ ids: Set<UUID>, hidden: Bool) {
        let targets = expandedIDs(ids)
        guard document.layers.contains(where: { targets.contains($0.id) && $0.visible == hidden }) else { return }
        var updated = document
        for i in updated.layers.indices where targets.contains(updated.layers[i].id) {
            updated.layers[i].isHidden = hidden ? true : nil
        }
        pushUndo((hidden ? "隱藏" : "顯示") + layersTitle(ids), detail: namesDetail(ids))
        document = updated
    }

    /// 依清單的前到後順序插入；放到根列之前即移出群組。
    func moveLayers(_ ids: Set<UUID>, before anchor: UUID?, parent: UUID?) {
        guard let next = Self.movedLayers(document.layers, ids: ids, before: anchor, parent: parent,
                                          removeEmptied: !defersEmptyGroupRemoval),
              next != document.layers else { return }
        let destination = parent.map { "至" + layerTitle($0) }
            ?? (document.layers.contains { ids.contains($0.id) && $0.parentID != nil } ? "移出群組" : nil)
        pushUndo("調整順序", detail: ([layerNames(ids)] + [destination].compactMap { $0 }).joined(separator: "、"))
        document.layers = next
        renumber()
        repairSelection()
    }

    /// moveLayers 的純函式版本：回傳搬動後的圖層陣列，不動文件、不記復原。
    /// 群組會連同子圖層整塊移動；被搬空的群組一併移除。
    static func movedLayers(_ layers: [FormlessLayer], ids: Set<UUID>, before anchor: UUID?, parent: UUID?,
                            removeEmptied: Bool = true) -> [FormlessLayer]? {
        func expanded(_ ids: Set<UUID>) -> Set<UUID> {
            ids.union(layers.filter { $0.parentID.map(ids.contains) ?? false }.map(\.id))
        }
        guard anchor.map({ !expanded(ids).contains($0) }) ?? true else { return nil }
        let hasGroup = layers.contains { ids.contains($0.id) && $0.group }
        guard !hasGroup || parent == nil else { return nil }
        if let parent, !layers.contains(where: { $0.id == parent && $0.group }) { return nil }
        let moving = expanded(ids)
        let oldParents = Set(layers.filter { ids.contains($0.id) }.compactMap(\.parentID))
        var front = Array(layers.reversed())
        var block = front.filter { moving.contains($0.id) }
        guard !block.isEmpty else { return nil }
        for i in block.indices where ids.contains(block[i].id) && !(block[i].parentID.map(ids.contains) ?? false) {
            block[i].parentID = parent
        }
        front.removeAll { moving.contains($0.id) }
        let anchorIDs = anchor.map { expanded([$0]) } ?? []
        let index = front.firstIndex { anchorIDs.contains($0.id) } ?? front.count
        front.insert(contentsOf: block, at: index)
        var next = Array(front.reversed())
        guard removeEmptied else { return next }
        let occupiedParents = Set(next.compactMap(\.parentID))
        let emptiedGroups = oldParents.subtracting(occupiedParents)
        next.removeAll { $0.group && emptiedGroups.contains($0.id) }
        return next
    }

    /// 清單前到後的列（含展開群組的子圖層），可套用在任何圖層陣列上。
    static func rows(for layers: [FormlessLayer]) -> [FormlessLayerRow] {
        var rows: [FormlessLayerRow] = []
        let ids = Set(layers.map(\.id))
        let roots = layers.filter { layer in layer.parentID == nil || !ids.contains(layer.parentID!) }
        let childrenByParent = Dictionary(grouping: layers.filter { $0.parentID != nil }, by: { $0.parentID! })
        for layer in roots.reversed() {
            rows.append(FormlessLayerRow(id: layer.id, layer: layer, indent: 0))
            if layer.group && !layer.collapsed {
                for child in (childrenByParent[layer.id] ?? []).reversed() {
                    rows.append(FormlessLayerRow(id: child.id, layer: child, indent: 1))
                }
            }
        }
        return rows
    }

    /// 某群組整塊之後的第一個根層項目（前到後順序）；沒有就回 nil，表示清單最後。
    private static func rootFollowing(group: UUID, in layers: [FormlessLayer], excluding: Set<UUID> = []) -> UUID? {
        let front = Array(layers.reversed())
        guard let header = front.firstIndex(where: { $0.id == group }) else { return nil }
        return front[(header + 1)...].first { $0.parentID == nil && !excluding.contains($0.id) && $0.id != group }?.id
    }

    /// 清單拖曳的落點：放在某一列之前，或整份清單最後。
    enum LayerDropPosition: Equatable {
        case before(UUID)
        case end
    }

    /// 依規則解析後要執行的搬動。
    struct ResolvedReorder {
        let ids: Set<UUID>
        let anchor: UUID?
        let parent: UUID?
        /// 結果與系統回報的落點完全一致。false 表示落點被規則修正過，
        /// 畫面上要先讓系統把列彈回，再動畫到修正後的位置。
        let matchesRequest: Bool
    }

    /// 圖層清單的拖曳排序規則（單一階層、不巢狀）：
    /// - 根層項目（一般圖層或群組）只在根層之間移動。落在某群組的子圖層之間時，
    ///   依拖曳方向停在那一整塊群組的上方或下方；群組因此永遠不會進到另一個群組裡。
    /// - 群組內的圖層只在原群組內移動。落到群組外時貼回群組的最前或最後一個位置；
    ///   要離開群組請用「移出群組」。
    /// 群組被拖曳時子圖層會跟著整塊移動（由 moveLayers 處理）。
    func reorderRows(_ sources: [UUID], to position: LayerDropPosition) {
        guard let resolved = resolveReorder(sources, to: position) else { return }
        applyReorder(resolved)
    }

    func applyReorder(_ resolved: ResolvedReorder) {
        moveLayers(resolved.ids, before: resolved.anchor, parent: resolved.parent)
    }

    func resolveReorder(_ sources: [UUID], to position: LayerDropPosition) -> ResolvedReorder? {
        let rows = displayRows
        let ids = Set(sources)
        let sourceRows = rows.filter { ids.contains($0.id) }
        guard let first = sourceRows.first,
              let sourceIndex = rows.firstIndex(where: { $0.id == first.id }) else { return nil }
        let sourceParent = first.layer.parentID
        // 同一批只處理同一層、同一個群組的項目。
        guard sourceRows.allSatisfy({ $0.layer.parentID == sourceParent }) else { return nil }

        let anchorRow: FormlessLayerRow?
        let anchorIndex: Int
        switch position {
        case .before(let id):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
            if ids.contains(id) { return nil }
            anchorRow = rows[index]
            anchorIndex = index
        case .end:
            anchorRow = nil
            anchorIndex = rows.count
        }
        // 落在自己（被拖曳群組）的子圖層上視為沒有移動。
        if let anchorRow, let parent = anchorRow.layer.parentID, ids.contains(parent) { return nil }

        func nextRoot(after headerIndex: Int) -> UUID? {
            rows.indices.contains(headerIndex + 1)
                ? rows[(headerIndex + 1)...].first { $0.indent == 0 }?.id
                : nil
        }

        var anchor: UUID?
        var parent: UUID?
        if let group = sourceParent {
            parent = group
            if let anchorRow, anchorRow.layer.parentID == group {
                anchor = anchorRow.id
            } else {
                guard let headerIndex = rows.firstIndex(where: { $0.id == group }) else { return nil }
                if anchorIndex <= headerIndex {
                    // 落在群組上方：貼回群組最前面。
                    guard let firstChild = rows.first(where: { $0.layer.parentID == group && !ids.contains($0.id) }) else { return nil }
                    anchor = firstChild.id
                } else {
                    // 落在群組下方（含緊接在最後一個子圖層之後）：貼到群組最後。
                    anchor = nextRoot(after: headerIndex)
                }
            }
        } else if let anchorRow, let host = anchorRow.layer.parentID {
            // 根層項目落在某群組的子圖層之間：往下拖停在整塊之後，往上拖停在整塊之前。
            guard let hostIndex = rows.firstIndex(where: { $0.id == host }) else { return nil }
            anchor = sourceIndex < hostIndex ? nextRoot(after: hostIndex) : host
        } else {
            anchor = anchorRow?.id
        }

        guard let moved = Self.movedLayers(document.layers, ids: ids, before: anchor, parent: parent,
                                           removeEmptied: !defersEmptyGroupRemoval),
              moved != document.layers else { return nil }

        // 拖曳中被拖群組的子圖層是收起的；比對時一併排除，只看畫面上真正存在的列。
        func visible(_ rows: [FormlessLayerRow]) -> [UUID] {
            rows.filter { !($0.layer.parentID.map(ids.contains) ?? false) }.map(\.id)
        }
        var expected = visible(rows).filter { !ids.contains($0) }
        let insertAt: Int
        switch position {
        case .before(let id): insertAt = expected.firstIndex(of: id) ?? expected.count
        case .end: insertAt = expected.count
        }
        expected.insert(contentsOf: visible(rows).filter { ids.contains($0) }, at: insertAt)
        let matches = expected == visible(Self.rows(for: moved))
        return ResolvedReorder(ids: ids, anchor: anchor, parent: parent, matchesRequest: matches)
    }

    /// 群組只能停在根層；即使落在另一個群組的子圖層上，也跨過整個群組區塊。
    func moveGroup(_ groupID: UUID, past targetID: UUID) {
        guard document.layers.contains(where: { $0.id == groupID && $0.group }),
              let target = document.layers.first(where: { $0.id == targetID }) else { return }
        let targetRootID = target.parentID ?? target.id
        let roots = displayRows.filter { $0.indent == 0 }
        guard let sourceIndex = roots.firstIndex(where: { $0.id == groupID }),
              let targetIndex = roots.firstIndex(where: { $0.id == targetRootID }),
              sourceIndex != targetIndex else { return }

        // 往下拖就放在目標群組之後；往上拖就放在它之前。anchor 一定是根層。
        let anchor: UUID? = sourceIndex < targetIndex
            ? (targetIndex + 1 < roots.count ? roots[targetIndex + 1].id : nil)
            : targetRootID
        moveLayers([groupID], before: anchor, parent: nil)
    }

    /// 移入群組：放在群組最前面（清單中緊接在群組標題之下）。parent 為 nil 即移出群組。
    func moveToGroup(_ ids: Set<UUID>, parent: UUID?) {
        guard let parent else { moveOutOfGroup(ids); return }
        let members = Set(document.layers.filter { ids.contains($0.id) && !$0.group && $0.parentID != parent }.map(\.id))
        guard !members.isEmpty, document.layers.contains(where: { $0.id == parent && $0.group }) else { return }
        let frontChild = document.layers.reversed().first { $0.parentID == parent && !members.contains($0.id) }?.id
        let anchor = frontChild ?? Self.rootFollowing(group: parent, in: document.layers, excluding: members)
        moveLayers(members, before: anchor, parent: parent)
    }

    /// 移出群組：一律放到原群組整塊的下一層，也就是清單中緊接在該群組之後的位置。
    /// 多個圖層可來自不同群組；全部合成一筆復原。群組因此變空時一併移除（選取模式中等結束才移除）。
    func moveOutOfGroup(_ ids: Set<UUID>) {
        var working = document.layers
        let members = working.filter { ids.contains($0.id) && !$0.group && $0.parentID != nil }
        guard !members.isEmpty else { return }
        var seen = Set<UUID>()
        let parents = Array(working.reversed()).compactMap(\.parentID).filter { parent in
            members.contains { $0.parentID == parent } && seen.insert(parent).inserted
        }
        for parent in parents {
            let moving = Set(members.filter { $0.parentID == parent }.map(\.id))
            let anchor = Self.rootFollowing(group: parent, in: working, excluding: moving)
            if let next = Self.movedLayers(working, ids: moving, before: anchor, parent: nil,
                                           removeEmptied: !defersEmptyGroupRemoval) { working = next }
        }
        guard working != document.layers else { return }
        pushUndo("移出群組" + layersTitle(ids), detail: namesDetail(ids))
        document.layers = working
        renumber()
        repairSelection()
    }

    enum Alignment: String, CaseIterable, Identifiable {
        case left = "靠左", centerX = "水平置中", right = "靠右"
        case top = "靠上", centerY = "垂直置中", bottom = "靠下"
        var id: String { rawValue }
    }

    /// 位移以畫面上顯示的整數（1600 格）計算：可見邊界帶小數時直接四捨五入位移，對齊後顯示的數字會差 1。
    /// 圖層框都是整數格，平移整數格後可見邊界的小數部分不變，顯示的數字就正好等於基準的數字。
    private func alignmentOffset(from frame: FormlessFrame, to reference: FormlessFrame,
                                 alignment: Alignment) -> (dx: Double, dy: Double) {
        func shown(_ value: Double) -> Double { EditorNumbers.integer(value * 1600) }
        switch alignment {
        case .left: return (shown(reference.x) - shown(frame.x), 0)
        case .centerX: return (shown(reference.x + reference.width / 2) - shown(frame.x + frame.width / 2), 0)
        case .right: return (shown(reference.x + reference.width) - shown(frame.x + frame.width), 0)
        case .top: return (0, shown(reference.y) - shown(frame.y))
        case .centerY: return (0, shown(reference.y + reference.height / 2) - shown(frame.y + frame.height / 2))
        case .bottom: return (0, shown(reference.y + reference.height) - shown(frame.y + frame.height))
        }
    }

    /// 對齊：選取的圖層（多選、群組的成員）視為一個整體（以可見聯集計算），全部平移同一距離，彼此的相對位置不變；
    /// 不分基準是畫布還是某個圖層（使用者規則：多選或群組要當成單一圖層對齊，每個圖層的移動幅度相同）。
    func alignTogether(_ ids: Set<UUID>, to reference: FormlessFrame, alignment: Alignment, referenceName: String) {
        let roots = ids.filter { id in
            !document.layers.contains { $0.id == id && $0.parentID.map(ids.contains) == true }
        }
        let members = expandedIDs(ids)
        guard let frame = visibleBounds(of: ids),
              !document.layers.contains(where: { members.contains($0.id) && document.effectivelyLocked($0) }) else { return }
        let offset = alignmentOffset(from: frame, to: reference, alignment: alignment)
        var updated = document
        for i in updated.layers.indices where members.contains(updated.layers[i].id) && !updated.layers[i].group {
            updated.layers[i].frame = EditorNumbers.moved(updated.layers[i].frame, dx: offset.dx, dy: offset.dy)
        }
        guard updated != document else { return }
        func signed(_ value: Double) -> String { (value < 0 ? "−" : "+") + String(Int(abs(value))) }
        var detail = ["\(roots.count) 個圖層", "基準 " + referenceName]
        if offset.dy != 0 { detail.append("上 " + signed(offset.dy)) }
        if offset.dx != 0 { detail.append("左 " + signed(offset.dx)) }
        pushUndo("對齊 " + alignment.rawValue, detail: detail.joined(separator: "、"))
        document = updated
    }

    func distribute(_ ids: Set<UUID>, horizontal: Bool) {
        let roots = ids.filter { id in
            !document.layers.contains { $0.id == id && $0.parentID.map(ids.contains) == true }
        }
        let entries = roots.compactMap { id in visibleBounds(of: [id]).map { (id, $0) } }
            .sorted { horizontal ? $0.1.x < $1.1.x : $0.1.y < $1.1.y }
        guard entries.count >= 3, let first = entries.first, let last = entries.last else { return }
        let start = horizontal ? first.1.x : first.1.y
        let end = horizontal ? last.1.x + last.1.width : last.1.y + last.1.height
        let total = entries.reduce(0.0) { $0 + (horizontal ? $1.1.width : $1.1.height) }
        let gap = (end - start - total) / Double(entries.count - 1)
        var updated = document
        var position = start
        for (id, frame) in entries {
            let shift = position - (horizontal ? frame.x : frame.y)
            let moving = expandedIDs([id])
            for i in updated.layers.indices where moving.contains(updated.layers[i].id) && !updated.layers[i].group {
                updated.layers[i].frame = EditorNumbers.moved(updated.layers[i].frame,
                                                               dx: horizontal ? shift * 1600 : 0,
                                                               dy: horizontal ? 0 : shift * 1600)
            }
            position += (horizontal ? frame.width : frame.height) + gap
        }
        guard updated != document else { return }
        pushUndo(horizontal ? "水平等距" : "垂直等距", detail: "\(entries.count) 個圖層")
        document = updated
    }
}

struct EditorHistoryLocation {
    enum Surface: String { case layers, inspector, design, batch, layerPicker }
    let surface: Surface
    let selectedLayerID: UUID?
    let category: String
    let propertyAnchor: String?
    let scrollOffset: CGPoint?
    let picking: Bool
    let picked: Set<UUID>
}

@MainActor
final class EditorSession: ObservableObject {
    var scrollOffsets: [String: CGPoint] = [:]
    @Published var selectedID: UUID?
    /// 圖層清單要捲到這一列（新增圖層後：屬性面板蓋住清單時先捲好，回到清單時就停在新圖層）。
    @Published var listAnchor: UUID?
    /// 剛新增、要馬上選圖的圖片圖層：它的屬性面板一出現就打開圖片庫（不發布變更，只在面板出現時讀一次）。
    var pendingImagePick: UUID?
    /// 剛新增、要直接打字的圖層（文字、網路圖片）：它的「內容」一出現就把輸入欄位叫出鍵盤。
    var pendingInputFocus: UUID?
    /// 剛新增的圖示圖層：它的「內容」一出現就打開圖示面板。
    var pendingSymbolPick: UUID?
    /// 剛新增的即時文字：它的「內容」一出現就打開選擇資料面板。
    var pendingDataPick: UUID?
    @Published var search = ""
    @Published var searchVisible = false
    @Published var filter = "全部"
    @Published var inspecting = false {
        didSet { if !inspecting { categoryBar.set(false) } }
    }
    /// 屬性面板底部分類列的縮放狀態（仿 iOS 26 分頁列的 minimize）。獨立的物件、只有分類列自己觀察：
    /// 捲動中反覆縮放時不必重繪整個編輯器，也不會在捲動時卡頓。離開面板時還原。
    let categoryBar = FormlessMinimizeState()
    /// 圖層清單／屬性面板頂端淡化的強度：只在內容真的往上捲進留白時出現，停在初始位置完全不淡。
    let listFade = EditorEdgeFade()
    let inspectorFade = EditorEdgeFade()
    /// 切換分類一律從頂端開始：清掉各分類表單記住的捲動位置（key 是「圖層:分類」）。
    /// 在 didSet 裡同步清，新分類的表單建立時就讀不到舊位置；舊分類表單拆掉時存下的位置，下次切換時再清一次。
    @Published var category = "版面" {
        didSet {
            if category != oldValue {
                scrollOffsets = scrollOffsets.filter { !$0.key.contains(":") }
                // 使用者自己換了分頁（或恢復原本的分頁）：引導的那一次進入就結束了，之後照使用者選的走。
                guidedEntry = nil
            }
        }
    }
    /// 引導的一次進入（使用者規則）：剛新增的圖層第一次進去先開在該做的事的分頁（文字開在內容、色塊開在外觀），
    /// 空的圖片圖層每次進去都開在內容。只算那一次，之後進任何圖層（包括再進同一個）都回到使用者原本停的分頁；
    /// 原本直接改掉目前分頁，之後點每個圖層都停在內容，「版面」放在第一個就沒有意義了。
    private var guidedEntry: (layer: UUID, previous: String, shown: Bool)?

    func beginGuidedEntry(_ category: String, layer: UUID, shown: Bool = false) {
        let previous = guidedEntry?.previous ?? self.category
        self.category = category
        guidedEntry = (layer, previous, shown)
    }

    /// 進入圖層前呼叫：剛新增圖層的第一次進入保留引導的分頁；其他情況恢復使用者原本停的分頁。
    func resolveGuidedEntry(for id: UUID) {
        guard let entry = guidedEntry else { return }
        if entry.layer == id && !entry.shown {
            guidedEntry?.shown = true
            return
        }
        category = entry.previous
        guidedEntry = nil
    }
    @Published var propertyAnchor: String?
    @Published var historyNavigationRevision: UInt64 = 0
    @Published var designOpen = false
    @Published var layerPickerOpen = false
    /// 下半部工具面板（位置與大小、顏色）的開關放在獨立的物件，session 本身不發布變更。
    let toolPanels = EditorToolPanelState()
    var batchPositionOpen: Bool {
        get { toolPanels.positionOpen }
        set { if toolPanels.positionOpen != newValue { toolPanels.positionOpen = newValue } }
    }
    /// 離開選取模式時一併關掉「位置與對齊」的旗標：sheet 掛在選取工具列上，工具列消失時 sheet 跟著消失，
    /// 但旗標不會自己變回 false，下次進選取模式就會自己彈出。
    @Published var picking = false {
        didSet {
            if !picking { batchPositionOpen = false }
            if picking {
                // 進入：清單列先換成選取外觀（整份清單重畫約 0.1 秒，最花時間的一步）並送出一格，
                // 下一次畫面更新才切版面（工具列、畫布縮放、清單位移）並啟動動畫，重畫不會落在動畫裡。
                FormlessNextFrame.run { [layout] in layout.picking = true }
            } else if layout.picking {
                layout.picking = false
            }
        }
    }
    /// 退出選取模式：先只切版面啟動往回推的動畫（只有編輯器根視圖重畫），選取狀態的清除（勾選圈、畫布藍框、
    /// 取消時的還原）等動畫結束後才做。原本一按下去 session 和 model 同時發布變更，整份清單和畫布在同一格重畫，
    /// 動畫要等重畫完（約 0.1 秒）才開始，實機看起來是按了停一下才推回去（使用者回報）。
    func exitPicking(then completion: @escaping () -> Void = {}) {
        layout.picking = false
        exitGeneration &+= 1
        let generation = exitGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessMotion.pushDuration + 0.05) { [weak self] in
            guard let self, self.exitGeneration == generation, !self.layout.picking else { return }
            completion()
            self.picking = false
            self.picked = []
        }
    }
    private var exitGeneration: UInt = 0
    /// 版面用的選取狀態；獨立的物件，變動時只有編輯器根視圖重畫，清單列不受影響。
    let layout = EditorLayoutState()
    @Published var picked: Set<UUID> = []
    @Published var renamingLayerID: UUID?
    /// 拖曳中的群組：按住群組列時先把子圖層收起，整個群組以一列移動，放下後再展開。
    @Published var foldedGroupID: UUID?
    private static var sessions: [UUID: EditorSession] = [:]
    static func session(for id: UUID) -> EditorSession {
        if let existing = sessions[id] { return existing }
        let value = EditorSession()
        sessions[id] = value
        return value
    }

    func historyLocation(selectedLayerID: UUID?) -> EditorHistoryLocation {
        let surface: EditorHistoryLocation.Surface = designOpen ? .design :
            (batchPositionOpen ? .batch : (layerPickerOpen ? .layerPicker : (inspecting ? .inspector : .layers)))
        let scrollKey: String?
        switch surface {
        case .inspector:
            scrollKey = selectedLayerID.map { $0.uuidString + ":" + category }
        case .batch: scrollKey = "批次調整"
        case .layers: scrollKey = "圖層清單"
        case .design, .layerPicker: scrollKey = nil
        }
        let editedProperty = (surface == .batch || (surface == .inspector && category == "版面")) ? propertyAnchor : nil
        return EditorHistoryLocation(surface: surface, selectedLayerID: selectedLayerID,
                                     category: category, propertyAnchor: editedProperty,
                                     scrollOffset: scrollKey.flatMap { scrollOffsets[$0] },
                                     picking: picking, picked: picked)
    }

    func resetForExit() {
        selectedID = nil
        listAnchor = nil
        search = ""
        searchVisible = false
        filter = "全部"
        inspecting = false
        categoryBar.set(false)
        category = "版面"
        guidedEntry = nil
        propertyAnchor = nil
        historyNavigationRevision = 0
        designOpen = false
        layerPickerOpen = false
        batchPositionOpen = false
        picking = false
        picked = []
        renamingLayerID = nil
        foldedGroupID = nil
        scrollOffsets = [:]
    }
}

extension FormlessLiveSource {
    var editorCategory: String {
        switch need {
        case "events": return "行事曆"
        case "reminders": return "提醒事項"
        case "steps": return "健康"
        case "weather": return "天氣服務"
        default: return "系統日期"
        }
    }
}

extension FormlessLiveSource {
    var editorIndexKind: String? {
        switch self {
        case .eventTitle, .eventSource, .eventDate, .eventTime, .eventLocation: return "event"
        case .reminderTitle: return "reminder"
        case .forecastName, .forecastTemp: return "forecast"
        default: return nil
        }
    }
}

/// 編輯紀錄每一步的參數說明（例如「上 +7」「字級 +2」「字重 粗體」）：比對這一步前後的文件算出來，名稱與屬性面板的欄位一致。
/// 位置與大小以畫面上顯示的數字（可見範圍，1600 格）為準：純移動直接用框的位移（和可見範圍的位移相同），
/// 大小有變才實際量可見範圍，因為文字、圖片的可見大小和框不成正比。新增、刪除圖層的步驟不另外說明（名稱已經說了）。
@MainActor
enum EditorHistoryDetail {
    static func describe(from before: FormlessDocument, to after: FormlessDocument, live: FormlessLiveData) -> String? {
        var items = documentItems(before, after)
        let beforeLayers = Dictionary(uniqueKeysWithValues: before.layers.map { ($0.id, $0) })
        let afterIDs = Set(after.layers.map(\.id))
        guard Set(beforeLayers.keys) == afterIDs else { return items.isEmpty ? nil : joined(items) }
        let changed = after.layers.compactMap { layer -> (FormlessLayer, FormlessLayer)? in
            guard let old = beforeLayers[layer.id], old != layer else { return nil }
            return (old, layer)
        }
        items += geometryItems(changed, before: before, after: after, live: live)
        // 屬性只列一個圖層的（多個圖層一起改同一個屬性時內容相同，列一次就好）。
        var seen = Set<String>()
        let resized = changed.contains { !$0.1.group && ($0.0.frame.width != $0.1.frame.width || $0.0.frame.height != $0.1.frame.height) }
        for (old, new) in changed {
            for item in propertyItems(old, new, resized: resized) where seen.insert(item).inserted { items.append(item) }
        }
        return items.isEmpty ? nil : joined(items)
    }

    private static func joined(_ items: [String]) -> String { items.joined(separator: "、") }

    private static func signed(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + String(Int(abs(value)))
    }

    /// 小數位數跟著變化量：整數就不顯示小數，否則最多兩位（去掉尾端的 0）。
    private static func signedAuto(_ value: Double) -> String {
        var text = String(format: "%.2f", abs(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return (value < 0 ? "−" : "+") + text
    }

    private static func geometryItems(_ changed: [(FormlessLayer, FormlessLayer)], before: FormlessDocument,
                                      after: FormlessDocument, live: FormlessLiveData) -> [String] {
        // 只改可用寬度的文字不算移動或縮放：畫面上的字沒動，由屬性那邊列「可用寬度」。
        let moved = changed.filter { !$0.1.group && $0.0.frame != $0.1.frame && !availableWidthChanged($0.0, $0.1) }
        guard !moved.isEmpty else { return [] }
        let sameSize = moved.allSatisfy { $0.0.frame.width == $0.1.frame.width && $0.0.frame.height == $0.1.frame.height }
        var items: [String] = []
        func add(_ label: String, _ delta: Double) {
            let rounded = EditorNumbers.integer(delta)
            if rounded != 0 { items.append(label + " " + signed(rounded)) }
        }
        if sameSize {
            // 純移動：每個圖層位移相同才說得出一個數字；各自移動不同距離（例如多個圖層互相對齊）就不列。
            let first = moved[0]
            let dx = (first.1.frame.x - first.0.frame.x) * 1600, dy = (first.1.frame.y - first.0.frame.y) * 1600
            let uniform = moved.allSatisfy {
                abs(($0.1.frame.x - $0.0.frame.x) * 1600 - dx) < 0.5 && abs(($0.1.frame.y - $0.0.frame.y) * 1600 - dy) < 0.5
            }
            guard uniform else { return [] }
            add("上", dy)
            add("左", dx)
            return items
        }
        let ids = Set(moved.map { $0.1.id })
        guard let old = EditorVisibleGeometry.bounds(document: before, ids: ids, live: live),
              let new = EditorVisibleGeometry.bounds(document: after, ids: ids, live: live) else { return [] }
        // 以顯示出來的整數相減，和使用者在方塊裡看到的數字變化一致。
        func shown(_ value: Double) -> Double { EditorNumbers.integer(value * 1600) }
        add("上", shown(new.y) - shown(old.y))
        add("左", shown(new.x) - shown(old.x))
        if moved.count == 1, EditorModel.isCircle(moved[0].1) {
            add("直徑", shown(new.width) - shown(old.width))
        } else {
            add("高", shown(new.height) - shown(old.height))
            add("寬", shown(new.width) - shown(old.width))
        }
        return items
    }

    private static func propertyItems(_ old: FormlessLayer, _ new: FormlessLayer, resized: Bool) -> [String] {
        var items: [String] = []
        let type = new.type
        /// 以欄位上顯示出來的數字相減（小數位數和屬性面板的欄位相同：步進 1 顯示整數、0.5 與 0.1 一位、0.05 兩位），
        /// 存的值帶著看不到的小數時才不會出現「字級 +1.87」這種和畫面對不上的差。
        func number(_ label: String, _ a: Double?, _ b: Double?, fallback: Double, decimals: Int = 0) {
            let scale = pow(10, Double(decimals))
            let delta = ((b ?? fallback) * scale).rounded() / scale - ((a ?? fallback) * scale).rounded() / scale
            if abs(delta) >= 0.5 / scale { items.append(label + " " + signedAuto(delta)) }
        }
        func changed<T: Equatable>(_ a: T, _ b: T) -> Bool { a != b }

        if changed(old.name, new.name) { items.append("名稱「\(clip(new.name))」") }
        // 用「大小」等比縮放文字時字級是跟著變的，寬高已經說明了，不再重複列字級。
        if !resized {
            // 元件拆開後的清單、月曆格、天氣預報字級步進 0.5，其他文字步進 1。
            let halfStep = [.calendarGrid, .reminderList, .weatherForecast].contains(type)
            number("字級", old.fontSize, new.fontSize, fallback: halfStep ? 12 : 22, decimals: halfStep ? 1 : 0)
        }
        number("透明度 %", old.opacity * 100, new.opacity * 100, fallback: 100)
        number("旋轉", old.rotation, new.rotation, fallback: 0)
        number(type == .calendar ? "面板圓角 %" : "圓角", old.cornerRadius, new.cornerRadius, fallback: 0)
        number("外框寬度", old.strokeWidth, new.strokeWidth, fallback: 0, decimals: 1)
        number("陰影半徑", old.shadowRadius, new.shadowRadius, fallback: 0, decimals: 1)
        number("陰影垂直位移", old.shadowOffsetY, new.shadowOffsetY, fallback: 0, decimals: 1)

        if changed(old.shapeKind, new.shapeKind) { items.append("形狀 " + new.shapeKind.displayName) }
        if changed(old.fillStyle, new.fillStyle) { items.append("填色 " + new.fillStyle.displayName) }
        if changed(old.gradientStops, new.gradientStops) {
            let before = old.gradientStops?.count ?? 0, after = new.gradientStops?.count ?? 0
            items.append(after > before ? "新增顏色點" : (after < before ? "刪除顏色點" : "漸層顏色點"))
        }
        number("漸層角度", old.gradientAngle, new.gradientAngle, fallback: 180)
        number("漸層半徑 %", old.gradientRadius.map { $0 * 100 }, new.gradientRadius.map { $0 * 100 }, fallback: 100)
        if changed(old.colorHex, new.colorHex) {
            items.append(new.colorHex?.lowercased() == "auto" ? "跟隨資料顏色" : (type.isComponent ? "強調色" : "顏色"))
        }
        if changed(old.colorRules, new.colorRules) {
            let before = old.colorRules?.count ?? 0, after = new.colorRules?.count ?? 0
            items.append(after > before ? "新增條件" : (after < before ? "刪除條件" : "條件顏色"))
        }
        if changed(old.secondaryColorHex, new.secondaryColorHex) { items.append("次要色") }
        if changed(old.panelColorHex, new.panelColorHex) { items.append(panelColorTitle(type)) }
        if changed(old.textColorHex, new.textColorHex) { items.append(textColorTitle(type)) }
        if changed(old.strokeColorHex, new.strokeColorHex), (new.strokeWidth ?? 0) > 0, old.strokeWidth == new.strokeWidth {
            items.append("外框顏色")
        }
        if changed(old.shadowColorHex, new.shadowColorHex), (new.shadowRadius ?? 0) > 0, old.shadowRadius == new.shadowRadius {
            items.append("陰影顏色")
        }

        if changed(old.fontWeight, new.fontWeight) {
            let name = formlessFontWeightOptions.first { $0.id == new.fontWeight }?.displayName ?? ""
            items.append(([.calendar, .calendarGrid].contains(type) ? "日期字重" : "字重") + " " + name)
        }
        if changed(old.fontFamily, new.fontFamily) {
            items.append("字型 " + (formlessFontFamilyOptions.first { $0.id == new.fontFamily }?.displayName
                                     ?? FormlessFontLibrary.displayName(forFamily: new.fontFamily) ?? ""))
        }
        if changed(old.alignment, new.alignment) {
            let name = ["center": "置中", "trailing": "靠右"][new.alignment ?? ""] ?? "靠左"
            items.append("對齊 " + name)
        }
        if changed(old.autoShrink, new.autoShrink) {
            items.append("文字過長時 " + (new.autoShrink == false ? "以省略號截斷" : "縮小文字"))
        }
        if availableWidthChanged(old, new) {
            number("可用寬度", old.frame.width * 1600, new.frame.width * 1600, fallback: 0)
        }
        if changed(old.value, new.value) { items.append(valueItem(new)) }
        if changed(old.tapAction, new.tapAction) { items.append("點一下圖層") }
        if changed(old.actionURL, new.actionURL) { items.append("網址") }
        if changed(old.showsPanel, new.showsPanel) {
            let title = type == .calendar ? "顯示左側大日期" : (type == .reminders ? "顯示外框背景" : "顯示背景")
            items.append(title + " " + ((new.showsPanel ?? true) ? "開" : "關"))
        }
        if changed(old.weekStartsOnMonday, new.weekStartsOnMonday) {
            items.append("週一開始 " + ((new.weekStartsOnMonday ?? false) ? "開" : "關"))
        }
        if changed(old.useCurrentLocation, new.useCurrentLocation) {
            items.append("使用目前位置 " + ((new.useCurrentLocation ?? true) ? "開" : "關"))
        } else if changed(old.locationName, new.locationName) || changed(old.latitude, new.latitude)
                    || changed(old.longitude, new.longitude) {
            items.append("地點")
        }
        if changed(old.dataIndex, new.dataIndex) || changed(old.visibility, new.visibility) { items.append("何時顯示") }
        if changed(old.segments, new.segments) && !changed(old.value, new.value) { items.append("資料格式") }
        if changed(old.progress, new.progress) { items.append("進度") }
        if changed(old.chart, new.chart) { items.append("圖表") }
        if changed(old.bindings, new.bindings) { items.append("取用資料") }
        if changed(old.lineLimit, new.lineLimit) || changed(old.lineSpacing, new.lineSpacing) || changed(old.tracking, new.tracking)
            || changed(old.italic, new.italic) || changed(old.underline, new.underline) || changed(old.strikethrough, new.strikethrough) {
            items.append("文字樣式")
        }
        if changed(old.partOffsets, new.partOffsets) { items.append("微調部位") }
        if changed(old.visible, new.visible) { items.append(new.visible ? "顯示" : "隱藏") }
        if changed(old.locked, new.locked) { items.append(new.locked ? "鎖定" : "解除鎖定") }
        return items
    }

    /// 外觀面板的「可用寬度」：文字類圖層只有框寬變了（旋轉時位置跟著調），高與字級都沒變。
    /// 「大小」縮放文字時字級與框高一定跟著變，不會被當成這一項。
    private static func availableWidthChanged(_ old: FormlessLayer, _ new: FormlessLayer) -> Bool {
        [.text, .date, .time, .liveText].contains(new.type) && old.type == new.type
            && old.frame.width != new.frame.width && old.frame.height == new.frame.height && old.fontSize == new.fontSize
    }

    private static func documentItems(_ old: FormlessDocument, _ new: FormlessDocument) -> [String] {
        var items: [String] = []
        if old.name != new.name { items.append("名稱「\(clip(new.name))」") }
        if old.family != new.family { items.append("尺寸 " + new.family.displayName) }
        if old.backgroundColorHex != new.backgroundColorHex { items.append("背景顏色") }
        if old.backgroundImageName != new.backgroundImageName { items.append("背景圖片") }
        if old.tapAction != new.tapAction { items.append("點一下小工具") }
        if old.tapURL != new.tapURL { items.append("網址") }
        if old.refreshMinutes != new.refreshMinutes { items.append("自動更新") }
        if old.showsPastItems != new.showsPastItems {
            items.append("保留今天已過的行程與提醒 " + ((new.showsPastItems ?? false) ? "開" : "關"))
        }
        if old.sources != new.sources { items.append("資料") }
        if old.variables != new.variables { items.append("我的資料") }
        return items
    }

    private static func valueItem(_ layer: FormlessLayer) -> String {
        let value = layer.value ?? ""
        switch layer.type {
        case .text: return "文字「\(clip(value))」"
        case .events: return "標題文字「\(clip(value))」"
        case .reminders: return "標題「\(clip(value))」"
        case .steps: return "下方文字「\(clip(value))」"
        case .date: return "日期格式"
        case .time: return "時間樣式"
        case .remoteImage: return "圖片網址"
        case .symbol: return "符號名稱"
        default: return "內容"
        }
    }

    private static func panelColorTitle(_ type: FormlessLayerType) -> String {
        switch type {
        case .calendar: return "左側面板底色"
        case .events: return "事件卡底色"
        case .steps: return "圓形底色"
        case .eventList, .weatherForecast: return "卡片底色"
        case .weather, .symbol: return "預報卡底色"
        default: return "底色"
        }
    }

    private static func textColorTitle(_ type: FormlessLayerType) -> String {
        switch type {
        case .calendar, .calendarGrid: return "日期文字色"
        case .events, .eventList: return "日期時間顏色"
        case .reminders, .reminderList: return "項目文字色"
        case .steps: return "數字顏色"
        case .yearProgress: return "未完成顏色"
        default: return "文字顏色"
        }
    }

    private static func clip(_ text: String) -> String {
        text.count > 10 ? String(text.prefix(10)) + "…" : text
    }
}


/// 下半部工具面板（位置與大小、顏色）的開關狀態。獨立的物件、只有面板、畫布與選取工具列觀察：
/// 原本放在 EditorSession 與編輯器根視圖，打開面板那一格整個編輯器、圖層清單每一列、面板裡的按鈕全部重算，
/// 實機上面板剛彈出時頓一下（使用者回報）。
@MainActor final class EditorToolPanelState: ObservableObject {
    /// 使用者要求打開「位置與大小」（選取工具列的按鈕）。
    @Published var positionOpen = false
    /// 「位置與大小」已在螢幕外建好（進入選取模式、畫面穩定後就先建）。
    @Published var positionMounted = false
    /// 「位置與大小」實際滑上來的狀態。
    @Published var positionShown = false
    /// 屬性面板裡正在調的顏色（開著顏色工具面板時非 nil）。
    @Published var color: EditorColorPanelRequest?
    /// 顏色面板實際滑上來的狀態：先在螢幕外建好，下一格才滑上來。
    @Published var colorShown = false
    /// 外觀的細項面板（填色、形狀、文字、圓角、外框、陰影）：開著時非 nil。
    @Published var style: EditorStylePanelRequest?
    /// 細項面板實際滑上來的狀態：先在螢幕外建好，下一格才滑上來。
    @Published var styleShown = false
    /// 顏色面板或細項面板的滴管取色中：面板暫時滑下去，整個畫面露出來讓使用者取色。
    @Published var eyedropping = false
    /// 畫布要讓到面板上方：跟著面板實際滑上來的狀態走，兩者同一格開始動。
    /// 圖示面板：正在挑圖示的圖層（開著時非 nil）。
    @Published var symbol: UUID?
    /// 圖示面板實際滑上來的狀態：先在螢幕外建好，下一格才滑上來。
    @Published var symbolShown = false
    /// 小工具的底色面板（顏色或圖片二擇一，下面是調色盤）：右上角選單或點畫布空白處打開。
    @Published var background = false
    @Published var backgroundShown = false
    /// 選擇資料面板（開著時非 nil）。
    @Published var data: EditorDataPanelRequest?
    @Published var dataShown = false
    /// 資料的格式面板（點文字裡的資料膠囊）。
    @Published var format: EditorFormatPanelRequest?
    @Published var formatShown = false
    /// 底色面板滴管取色時用來辨認的固定代號。
    static let backgroundPanelID = UUID()
    var open: Bool {
        positionShown || ((colorShown || styleShown || backgroundShown) && !eyedropping) || symbolShown || dataShown || formatShown
    }
    /// 有任何工具面板開著（含正在滑出、滴管取色中）：這段期間畫面不接受左右滑動的返回手勢
    /// （使用者：所有彈出的面板都不應該能左右滑動；從面板左緣往右滑曾把屬性面板連同面板一起滑走）。
    var anyPresented: Bool {
        positionOpen || positionShown || color != nil || style != nil || symbol != nil || background || eyedropping
            || data != nil || format != nil
    }

    /// 一次只開一個面板：開新的之前把屬性面板開的其他面板收起來。
    func closeInspectorPanels() {
        color = nil
        style = nil
        symbol = nil
        data = nil
        format = nil
    }
}

/// 編輯器版面的選取狀態（見 `EditorSession.picking`）。
@MainActor final class EditorLayoutState: ObservableObject {
    @Published var picking = false
}

/// 在下一次畫面更新（CADisplayLink 的下一個 tick，也就是目前這一格送出之後）執行一次。
@MainActor enum FormlessNextFrame {
    private final class Runner: NSObject {
        let action: () -> Void
        let created = CACurrentMediaTime()
        var link: CADisplayLink?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tick() {
            // 剛加入時常會立刻收到一次 tick（還在同一格裡），略過它，等目前這一格送出後的下一格。
            guard CACurrentMediaTime() - created > 0.006 else { return }
            link?.invalidate()
            link = nil
            action()
        }
    }
    static func run(_ action: @escaping () -> Void) {
        let runner = Runner(action: action)
        let link = CADisplayLink(target: runner, selector: #selector(Runner.tick))
        runner.link = link
        link.add(to: .main, forMode: .common)
    }
}


/// 顏色工具面板要調的欄位：標題、是否可調透明度、讀寫的綁定。
struct EditorColorPanelRequest {
    let id = UUID()
    let title: String
    let supportsOpacity: Bool
    /// 調的是哪個圖層的哪個顏色欄位：面板自己從 model 建綁定。原本傳進來的是屬性面板裡 `$layer` 做的綁定，
    /// 它讀到的是那個畫面上次更新時的值，面板開著時上一步、下一步或改了顏色，讀回來還是舊值（使用者回報滑桿沒跟著變）。
    let layerID: UUID
    let keyPath: WritableKeyPath<FormlessLayer, String?>
    let fallback: String
    /// 可以「跟隨資料顏色」的顏色：面板最上面多一個開關。
    var automatic = false
    /// 可以設條件顏色的主要顏色（文字類與圖示）：調色盤上方多平常的顏色條與條件列，調的是這個圖層。
    var rulesLayerID: UUID? = nil
    /// 新增條件時，平常的顏色沒設定就用這個。
    var rulesFallback = "#000000"
    /// 調的是小工具本身的底色（不是圖層）：面板從 `model.designBinding` 建綁定。
    var backgroundOfDocument = false

    /// 小工具底色：可調透明度。
    @MainActor static func documentBackground(_ model: EditorModel) -> EditorColorPanelRequest {
        EditorColorPanelRequest(title: "底色", supportsOpacity: true, layerID: model.document.id, keyPath: \.colorHex,
                                fallback: "#F4F4F4", backgroundOfDocument: true)
    }
}

extension EnvironmentValues {
    /// 屬性面板的顏色欄位用來打開顏色工具面板（由屬性面板提供）。
    @Entry var editorColorPanelOpener: ((EditorColorPanelRequest) -> Void)? = nil
}

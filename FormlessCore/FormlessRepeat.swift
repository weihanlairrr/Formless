import Foundation

// MARK: - 重複排列（2026-10 通用化，規劃第 4.2 節）
//
// 群組選一份清單（行程、逐時預報、RSS 文章…），清單的每一筆各畫一份群組內容；第一份在原位（編輯器裡改的就是它），
// 之後往下、往右或排成格狀，間距固定。群組裡的圖層可以取「這一筆」的欄位。渲染時展開成一般圖層，
// App 畫布、首頁縮圖、小工具都用同一套展開，看到的一定相同。

/// 實際要畫的一個圖層：重複排列展開後的每一份都有自己的位置與「這一筆」。
struct FormlessRenderedLayer: Identifiable {
    let id: String
    let layer: FormlessLayer
    let live: FormlessLiveData
}

extension FormlessDocument {

    func layer(_ id: UUID?) -> FormlessLayer? {
        guard let id else { return nil }
        return layers.first { $0.id == id }
    }

    /// 群組的重複排列要畫哪幾筆（最多 maxItems）。不是重複排列的群組回空陣列。
    func repeatItems(of group: FormlessLayer, live: FormlessLiveData, date: Date) -> [FormlessRecord] {
        guard let spec = group.repeatSpec else { return [] }
        let items = live.value(spec.collection, at: date).listValue ?? []
        return Array(items.compactMap(\.recordValue).prefix(max(1, min(spec.maxItems, 30))))
    }

    /// 群組內容的範圍（畫布比例座標，未旋轉的框）。
    func childBounds(of groupID: UUID) -> FormlessFrame? {
        let members = children(of: groupID).filter { !$0.group }
        guard let first = members.first else { return nil }
        var minX = first.frame.x, minY = first.frame.y
        var maxX = first.frame.x + first.frame.width, maxY = first.frame.y + first.frame.height
        for member in members.dropFirst() {
            minX = min(minX, member.frame.x); minY = min(minY, member.frame.y)
            maxX = max(maxX, member.frame.x + member.frame.width); maxY = max(maxY, member.frame.y + member.frame.height)
        }
        return FormlessFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 第 index 份相對於原位的位移（畫布比例）。
    func repeatOffset(_ spec: FormlessRepeatSpec, bounds: FormlessFrame, index: Int) -> (dx: Double, dy: Double) {
        let gapX = spec.spacing / Double(family.referenceWidth)
        let gapY = spec.spacing / Double(family.referenceHeight)
        let stepX = bounds.width + gapX, stepY = bounds.height + gapY
        switch spec.direction {
        case .down: return (0, Double(index) * stepY)
        case .right: return (Double(index) * stepX, 0)
        case .grid:
            let columns = max(1, spec.columns ?? 2)
            return (Double(index % columns) * stepX, Double(index / columns) * stepY)
        }
    }

    /// 這個圖層畫的時候用的資料：在重複排列的群組裡時帶上第一筆（編輯器的原位那一份）。
    func itemContext(for layer: FormlessLayer, live: FormlessLiveData, date: Date) -> FormlessLiveData {
        guard let group = self.layer(layer.parentID), group.repeatSpec != nil,
              let first = repeatItems(of: group, live: live, date: date).first else { return live }
        var context = live
        context.item = first
        return context
    }

    /// 要畫的圖層（已排除隱藏與群組）：重複排列的群組展開成每一筆一份，群組的「何時顯示」套用到每一份。
    func renderedLayers(_ visible: [FormlessLayer], live: FormlessLiveData, date: Date) -> [FormlessRenderedLayer] {
        var itemsCache: [UUID: [FormlessRecord]] = [:]
        var boundsCache: [UUID: FormlessFrame] = [:]
        var result: [FormlessRenderedLayer] = []
        result.reserveCapacity(visible.count)
        for layer in visible {
            guard let group = self.layer(layer.parentID), let spec = group.repeatSpec else {
                // 一般圖層；在一般群組裡時，群組的「何時顯示」也要成立，透明度也乘上群組的（整組一起變淡，2026-10）。
                var shown = layer
                if let group = self.layer(layer.parentID) {
                    if !live.matches(group.visibility, at: date) { continue }
                    if group.opacity < 1 { shown.opacity *= max(0, group.opacity) }
                }
                result.append(FormlessRenderedLayer(id: layer.id.uuidString, layer: shown, live: live))
                continue
            }
            let items = itemsCache[group.id] ?? repeatItems(of: group, live: live, date: date)
            itemsCache[group.id] = items
            guard let bounds = boundsCache[group.id] ?? childBounds(of: group.id) else { continue }
            boundsCache[group.id] = bounds
            for (index, item) in items.enumerated() {
                var context = live
                context.item = item
                guard context.matches(group.visibility, at: date) else { continue }
                var copy = layer
                if group.opacity < 1 { copy.opacity *= max(0, group.opacity) }
                let offset = repeatOffset(spec, bounds: bounds, index: index)
                copy.frame.x += offset.dx
                copy.frame.y += offset.dy
                result.append(FormlessRenderedLayer(id: layer.id.uuidString + "#" + String(index), layer: copy, live: context))
            }
        }
        return result
    }
}

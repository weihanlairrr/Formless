import Foundation

// MARK: - 我的組合（2026-10，規劃 M7 重用與分享）
//
// 群組的「⋯」›「儲存為我的組合」把一個群組連同子圖層、它們用到的這份設計自己的資料來源與我的資料存起來；
// 之後在任何設計的「新增圖層」最下面那張卡片選它，整組放進目前的設計。
// 存在共用資料夾的 Components/<id>.json。只有 App 用（小工具不畫組合），放在 FormlessCore 是為了讓命令列測試
// 驗證得到存讀、相依資料與尺寸換算。

/// 一個「我的組合」。
struct FormlessComponent: Codable, Identifiable, Hashable, Sendable {
    /// 存的時候的設計檔格式版本：圖層裡的巢狀欄位跟著設計檔的版本走（見 `FormlessDocument.currentFormatVersion`）。
    var formatVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    /// 存的時候那份設計的尺寸。圖層的框是這個尺寸畫布的比例座標：縮圖照它的比例畫，放進其他尺寸時照它換算。
    var family: FormlessWidgetFamily
    /// 存的時候那份設計的底色，只給縮圖用（白字畫在透明底上看不見）；放進設計時不帶。
    var backgroundColorHex: String?
    /// 群組在最前面，後面是子圖層（由後到前，和設計檔裡的順序相同）。
    var layers: [FormlessLayer]
    /// 圖層用到的這份設計自己的資料來源（例如「東京天氣」）。App 預設的來源每份設計都有，不必存。
    var sources: [FormlessSource]
    /// 圖層用到的我的資料，連同它們再取用的我的資料。
    var variables: [FormlessVariable]

    init(formatVersion: Int = FormlessDocument.currentFormatVersion, id: UUID = UUID(), name: String,
         createdAt: Date = Date(), family: FormlessWidgetFamily, backgroundColorHex: String? = nil,
         layers: [FormlessLayer], sources: [FormlessSource] = [], variables: [FormlessVariable] = []) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        // 取到整秒：存檔用 ISO 8601（沒有小數秒），讀回來才和記憶中的一樣。
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.family = family
        self.backgroundColorHex = backgroundColorHex
        self.layers = layers
        self.sources = sources
        self.variables = variables
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, createdAt, family, backgroundColorHex, layers, sources, variables
    }

    /// 和設計檔一樣寬鬆：缺欄位就用預設值，只有圖層是必要的（沒有圖層就不是組合）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? FormlessDocument.currentFormatVersion
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "我的組合"
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        family = (try? c.decode(FormlessWidgetFamily.self, forKey: .family)) ?? .medium
        backgroundColorHex = try? c.decode(String.self, forKey: .backgroundColorHex)
        layers = try c.decode([FormlessLayer].self, forKey: .layers)
        sources = (try? c.decode([FormlessSource].self, forKey: .sources)) ?? []
        variables = (try? c.decode([FormlessVariable].self, forKey: .variables)) ?? []
    }

    var group: FormlessLayer? { layers.first(where: \.group) }
    var members: [FormlessLayer] { layers.filter { !$0.group } }

    /// 子圖層合起來的範圍（存的時候那個尺寸畫布的比例座標，未旋轉的框）。
    var bounds: FormlessFrame? {
        let frames = members.map(\.frame)
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for frame in frames.dropFirst() {
            minX = min(minX, frame.x); minY = min(minY, frame.y)
            maxX = max(maxX, frame.x + frame.width); maxY = max(maxY, frame.y + frame.height)
        }
        return FormlessFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 縮圖用：只有這組圖層的一份設計，尺寸、底色、資料來源與我的資料都照存的時候。
    var previewDocument: FormlessDocument {
        var document = FormlessDocument(id: id, name: name, family: family,
                                        backgroundColorHex: backgroundColorHex ?? "#F4F4F4", layers: layers)
        document.sources = sources.isEmpty ? nil : sources
        document.variables = variables.isEmpty ? nil : variables
        return document
    }
}

// MARK: - 從設計做成組合

extension FormlessComponent {
    /// 把設計裡的一個群組做成組合：群組與子圖層、這些圖層用到的這份設計自己的資料來源與我的資料。
    /// 名稱留空就用群組的名稱。群組不存在、或裡面沒有圖層時是 nil（空群組放進設計什麼也看不到）。
    init?(group groupID: UUID, in document: FormlessDocument, name: String, id: UUID = UUID(), createdAt: Date = Date()) {
        guard let group = document.layers.first(where: { $0.id == groupID && $0.group }) else { return nil }
        let members = document.children(of: groupID).filter { !$0.group }
        guard !members.isEmpty else { return nil }
        var stored = [group] + members
        // 收合是清單的檢視狀態，不是組合的內容：放進設計時一律展開。
        for index in stored.indices { stored[index].isCollapsed = nil }
        let needs = Self.dependencies(of: stored, in: document)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: id, name: trimmed.isEmpty ? group.name : trimmed, createdAt: createdAt,
                  family: document.family, backgroundColorHex: document.backgroundColorHex,
                  layers: stored, sources: needs.sources, variables: needs.variables)
    }

    /// 這些圖層用到的這份設計自己的資料來源與我的資料，依設計裡原本的順序。
    /// 我的資料往下追它取用的資料（我的資料取用另一份我的資料或某個來源）；「切換／加減我的資料」的點擊動作
    /// 指向的我的資料也算。重複排列的「這一筆」不是來源；App 預設的來源每份設計都有，不列。
    static func dependencies(of layers: [FormlessLayer], in document: FormlessDocument)
        -> (sources: [FormlessSource], variables: [FormlessVariable]) {
        let variables = document.variables ?? []
        var pending = layers.flatMap(\.dataBindings)
        for layer in layers where layer.tapAction == .toggleVariable || layer.tapAction == .adjustVariable {
            if let id = layer.tapTarget.flatMap(UUID.init(uuidString:)) { pending.append(.variable(id)) }
        }
        var variableIDs = Set<UUID>()
        var sourceIDs = Set<String>()
        while let binding = pending.popLast() {
            if binding.isItem { continue }
            if binding.isVariable {
                guard let id = UUID(uuidString: binding.field), variableIDs.insert(id).inserted else { continue }
                if let variable = variables.first(where: { $0.id == id }) {
                    pending += variable.binding?.allBindings ?? []
                }
            } else {
                sourceIDs.insert(binding.source)
            }
        }
        return ((document.sources ?? []).filter { sourceIDs.contains($0.id) },
                variables.filter { variableIDs.contains($0.id) })
    }
}

// MARK: - 放進設計

extension FormlessComponent {
    /// 放進 target 尺寸的設計時的圖層（id 不變，呼叫的一方再換新的）。
    /// 同一個尺寸原樣放回原位。不同尺寸時照實際大小換算：字級、圓角這些數值以小工具參考尺寸計，在每個尺寸看起來
    /// 一樣大，所以框也換成同樣的實際大小（只用比例座標的話，小型存的組合放進中型會被拉寬一倍）；整組的中心放在
    /// 畫布上同樣比例的位置。整組比畫布大時等比縮小到剛好放得下，以參考尺寸計的數值一起縮。原本整組都在畫布內的，
    /// 換算後也保持在畫布內；原本就刻意超出畫布的（出血的裝飾）不拉回來。框對齊編輯器的 1600 格。
    func layers(for target: FormlessWidgetFamily) -> [FormlessLayer] {
        guard target != family, let bounds else { return layers }
        let sourceWidth = Double(family.referenceWidth), sourceHeight = Double(family.referenceHeight)
        let targetWidth = Double(target.referenceWidth), targetHeight = Double(target.referenceHeight)
        let width = max(bounds.width * sourceWidth, .ulpOfOne), height = max(bounds.height * sourceHeight, .ulpOfOne)
        let scale = min(1, targetWidth / width, targetHeight / height)
        let newWidth = width * scale, newHeight = height * scale
        var left = (bounds.x + bounds.width / 2) * targetWidth - newWidth / 2
        var top = (bounds.y + bounds.height / 2) * targetHeight - newHeight / 2
        let tolerance = 1.0 / Self.grid
        let inside = bounds.x >= -tolerance && bounds.y >= -tolerance
            && bounds.x + bounds.width <= 1 + tolerance && bounds.y + bounds.height <= 1 + tolerance
        if inside {
            left = min(max(left, 0), max(targetWidth - newWidth, 0))
            top = min(max(top, 0), max(targetHeight - newHeight, 0))
        }
        return layers.map { layer in
            var copy = layer
            if !layer.group {
                let x = left + (layer.frame.x - bounds.x) * sourceWidth * scale
                let y = top + (layer.frame.y - bounds.y) * sourceHeight * scale
                copy.frame = FormlessFrame(
                    x: Self.snapped(x / targetWidth),
                    y: Self.snapped(y / targetHeight),
                    width: max(Self.snapped(layer.frame.width * sourceWidth * scale / targetWidth), 1 / Self.grid),
                    height: max(Self.snapped(layer.frame.height * sourceHeight * scale / targetHeight), 1 / Self.grid))
            }
            if scale < 1 { copy.scaleReferenceValues(by: scale) }
            return copy
        }
    }

    /// 編輯器的座標格數（畫布 1600 × 1600，和 Widgy 相同）。
    static let grid: Double = 1600

    private static func snapped(_ value: Double) -> Double { (value * grid).rounded() / grid }
}

extension FormlessLayer {
    /// 以小工具參考尺寸計的數值一起乘上 factor（組合等比縮小時）：字級、圓角（含四個角分開的）、外框、陰影、字距、
    /// 行距、模糊、進度的粗細與分段間隔、圖表線寬、重複排列的間距。月曆元件的圓角是百分比，不換算；沒設定的維持沒設定。
    mutating func scaleReferenceValues(by factor: Double) {
        func scaled(_ value: Double?) -> Double? { value.map { $0 * factor } }
        fontSize = scaled(fontSize)
        if type != .calendar {
            cornerRadius = scaled(cornerRadius)
            cornerRadii = cornerRadii.map { $0.map { $0 * factor } }
        }
        strokeWidth = scaled(strokeWidth)
        shadowRadius = scaled(shadowRadius)
        shadowOffsetX = scaled(shadowOffsetX)
        shadowOffsetY = scaled(shadowOffsetY)
        tracking = scaled(tracking)
        lineSpacing = scaled(lineSpacing)
        blur = scaled(blur)
        if var spec = progress {
            spec.thickness = scaled(spec.thickness)
            spec.segmentGap = scaled(spec.segmentGap)
            progress = spec
        }
        if var spec = chart {
            spec.lineWidth = scaled(spec.lineWidth)
            chart = spec
        }
        if var spec = repeatSpec {
            spec.spacing *= factor
            repeatSpec = spec
        }
    }
}

extension FormlessDocument {
    /// 把組合放進這份設計：群組與子圖層換新的 id（群組關係照舊）、加在最上層（子圖層在前、群組在後，和「建立群組」
    /// 相同，清單裡群組在最上面、子圖層緊接在下面）；尺寸不同時照 `FormlessComponent.layers(for:)` 換算。
    /// 組合用到的資料來源與我的資料一起帶進來；這份設計已經有同一個 id 的，沿用這份設計的那一份（使用者可能已經
    /// 改過地點或數值）。回傳群組的新 id；組合裡沒有群組時是 nil、設計不變。
    @discardableResult
    mutating func insert(_ component: FormlessComponent) -> UUID? {
        let converted = component.layers(for: family)
        guard let group = converted.first(where: \.group) else { return nil }
        var mapping: [UUID: UUID] = [:]
        for layer in converted { mapping[layer.id] = UUID() }
        let renamed = converted.compactMap { layer -> FormlessLayer? in
            guard let id = mapping[layer.id] else { return nil }
            var copy = layer
            copy.id = id
            copy.parentID = layer.parentID.flatMap { mapping[$0] }
            return copy
        }
        var next = (layers.map(\.zIndex).max() ?? -1) + 1
        for var layer in renamed.filter({ !$0.group }) + renamed.filter(\.group) {
            layer.zIndex = next
            next += 1
            layers.append(layer)
        }

        let newSources = component.sources.filter { source in !(sources ?? []).contains { $0.id == source.id } }
        if !newSources.isEmpty { sources = (sources ?? []) + newSources }
        let newVariables = component.variables.filter { variable in !(variables ?? []).contains { $0.id == variable.id } }
        if !newVariables.isEmpty { variables = (variables ?? []) + newVariables }
        return mapping[group.id]
    }
}

// MARK: - 存讀

enum FormlessComponentStore {
    /// 共用資料夾裡的 Components/。
    static var directoryURL: URL? {
        FormlessStorage.sharedContainerURL?.appendingPathComponent("Components", isDirectory: true)
    }

    static func all() -> [FormlessComponent] {
        directoryURL.map { all(in: $0) } ?? []
    }

    static func load(id: UUID) -> FormlessComponent? {
        directoryURL.flatMap { load(id: id, in: $0) }
    }

    static func save(_ component: FormlessComponent) throws {
        guard let directory = directoryURL else { throw FormlessError.noSharedContainer }
        try save(component, in: directory)
    }

    static func delete(id: UUID) {
        guard let directory = directoryURL else { return }
        delete(id: id, in: directory)
    }

    // MARK: 指定資料夾（命令列測試用暫存資料夾，不碰 App 群組）

    static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// 新存的在前；同一時間存的依名稱。讀不出來的檔案略過（不影響其他組合）。
    static func all(in directory: URL) -> [FormlessComponent] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decode($0) } }
            .sorted {
                $0.createdAt != $1.createdAt
                    ? $0.createdAt > $1.createdAt
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func load(id: UUID, in directory: URL) -> FormlessComponent? {
        (try? Data(contentsOf: fileURL(for: id, in: directory))).flatMap { try? decode($0) }
    }

    static func save(_ component: FormlessComponent, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(component).write(to: fileURL(for: component.id, in: directory), options: .atomic)
    }

    static func delete(id: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: id, in: directory))
    }

    static func encode(_ component: FormlessComponent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(component)
    }

    static func decode(_ data: Data) throws -> FormlessComponent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FormlessComponent.self, from: data)
    }
}

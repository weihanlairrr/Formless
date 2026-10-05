import SwiftUI

struct EditorGeometryControls: View, Equatable {
    @ObservedObject var model: EditorModel
    let ids: Set<UUID>
    let session: EditorSession?
    /// 量實際畫出來的範圍（圖片、圖示、元件要把圖層畫一次再掃像素）。選取模式預先建在螢幕外的「位置與大小」面板
    /// 看不到，先用圖層框，打開時才量：原本每勾一個圖層就在背後量一次，勾選會頓一下。
    var measures = true
    /// 外層重畫（例如工具面板滑上來）時，同一組圖層不重算整組方塊與對齊鈕；圖層內容改變由 model 通知。
    static func == (lhs: EditorGeometryControls, rhs: EditorGeometryControls) -> Bool {
        lhs.model === rhs.model && lhs.session === rhs.session && lhs.ids == rhs.ids && lhs.measures == rhs.measures
    }
    init(model: EditorModel, ids: Set<UUID>, session: EditorSession? = nil, measures: Bool = true) {
        self.model = model
        self.ids = ids
        self.session = session
        self.measures = measures
    }
    @AppStorage("formless.nudgeStep") private var step: Double = 10
    typealias AlignmentReference = EditorAlignmentReference
    /// 對齊基準的記憶範圍：群組本身與其所有子圖層共用同一份設定，在同一群組內切換圖層不必重設；
    /// 根層圖層（或跨群組的多選）共用另一份。
    private var referenceScope: EditorAlignmentScope {
        if let selectedGroupID { return .group(selectedGroupID) }
        let parents = Set(model.document.layers.filter { ids.contains($0.id) }.map(\.parentID))
        if parents.count == 1, let parent = parents.first ?? nil { return .group(parent) }
        return .root
    }
    /// 預設基準：群組（含其子圖層）以清單最下方、也就是最底層的成員為準，通常就是卡片底色；
    /// 選的正好是那個成員、或不在任何群組裡時，以畫布為準。
    private var defaultReference: AlignmentReference {
        switch referenceScope {
        case .root:
            return .canvas
        case .group(let group):
            if let bottom = model.document.children(of: group).first, isOffered(.layer(bottom.id)) {
                return .layer(bottom.id)
            }
            return selectedGroupID != nil ? .groupBounds : .canvas
        }
    }
    /// 記住的基準在目前的選單裡是否還選得到（圖層可能已刪除、移出群組，或正是被對齊的對象）。
    private func isOffered(_ reference: AlignmentReference) -> Bool {
        switch reference {
        case .canvas: return selectedGroupID == nil
        case .groupBounds: return selectedGroupID != nil
        case .layer(let id): return referenceChoices.contains { $0.id == id }
        }
    }
    private var selectedReference: AlignmentReference {
        if let remembered = model.alignmentReferences[referenceScope], isOffered(remembered) { return remembered }
        return defaultReference
    }
    private var referenceBinding: Binding<AlignmentReference> {
        Binding(get: { selectedReference }, set: { model.alignmentReferences[referenceScope] = $0 })
    }
    private var selectedGroupID: UUID? {
        guard ids.count == 1, let id = ids.first,
              model.document.layers.contains(where: { $0.id == id && $0.group }) else { return nil }
        return id
    }
    private var alignmentTargets: Set<UUID> {
        guard let selectedGroupID else { return ids }
        return Set(model.document.children(of: selectedGroupID).map(\.id))
    }
    private var referenceChoices: [FormlessLayer] {
        if let selectedGroupID { return model.document.children(of: selectedGroupID) }
        let members = model.expandedIDs(ids)
        return model.document.layers.filter { !members.contains($0.id) }
    }
    private var referenceOptions: [FormlessMenuOption] {
        let first = selectedGroupID != nil
            ? FormlessMenuOption(id: AnyHashable(AlignmentReference.groupBounds), title: "群組範圍")
            : FormlessMenuOption(id: AnyHashable(AlignmentReference.canvas), title: "畫布")
        return [first] + referenceChoices.map { FormlessMenuOption(id: AnyHashable(AlignmentReference.layer($0.id)), title: $0.name) }
    }
    private var referenceName: String {
        switch selectedReference {
        case .canvas: return "畫布"
        case .groupBounds: return "群組範圍"
        case .layer(let id): return model.document.layers.first { $0.id == id }?.name ?? "畫布"
        }
    }
    private var alignmentReference: FormlessFrame? {
        switch selectedReference {
        case .canvas: return FormlessFrame(x: 0, y: 0, width: 1, height: 1)
        case .groupBounds:
            guard let selectedGroupID else { return nil }
            return model.visibleBounds(of: [selectedGroupID])
        case .layer(let id): return model.visibleBounds(of: [id])
        }
    }
    private func alignmentRow(_ items: [EditorModel.Alignment]) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { alignment in
                alignmentButton(alignment.rawValue) {
                    guard let reference = alignmentReference else { return }
                    // 多選或群組一律當成一個圖層對齊：所有成員平移同一距離、相對位置不變，不分基準是畫布還是圖層（使用者規則）。
                    model.alignTogether(alignmentTargets, to: reference, alignment: alignment, referenceName: referenceName)
                }
            }
        }
    }
    private func alignmentButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    private var locked: Bool {
        let members = model.expandedIDs(ids)
        return model.document.layers.contains { members.contains($0.id) && model.document.effectivelyLocked($0) }
    }
    /// 造成鎖定的圖層：成員自己鎖定的，以及成員所屬、本身鎖定的群組。解除時一起解。
    private var lockedIDs: Set<UUID> {
        let members = model.expandedIDs(ids)
        var result = Set<UUID>()
        for layer in model.document.layers where members.contains(layer.id) {
            if layer.locked { result.insert(layer.id) }
            if let parent = layer.parentID,
               model.document.layers.first(where: { $0.id == parent })?.locked == true { result.insert(parent) }
        }
        return result
    }
    private var lockedTitle: String {
        let causes = lockedIDs
        if causes.contains(where: { id in !ids.contains(id) && model.document.layers.contains { $0.id == id && $0.group } }) {
            return "所屬群組已鎖定"
        }
        return causes.count > 1 ? "\(causes.count) 個圖層已鎖定" : "圖層已鎖定"
    }
    /// 鎖定時整區變灰並停用；用 opacity 與去色，玻璃按鈕光靠 disabled 看不出差別。
    private func lockedDimmed<Content: View>(_ content: Content, locked: Bool) -> some View {
        content
            .disabled(locked)
            .opacity(locked ? 0.35 : 1)
            .grayscale(locked ? 1 : 0)
            .animation(FormlessDesign.Motion.fade, value: locked)
    }
    private var lockedNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(lockedTitle).font(.subheadline.weight(.medium))
                Text("位置、大小與對齊已停用；外觀與內容仍可編輯。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("解除鎖定") { model.setLocked(lockedIDs, false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
    private func edit(_ property: String, action: () -> Void) {
        session?.propertyAnchor = property
        action()
    }
    private var alignmentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 只有群組需要標明「對齊的是群組內的圖層」；其他情況按鈕本身已足夠說明。
                if selectedGroupID != nil {
                    Text("群組內圖層對齊")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // 自己畫的彈出清單，不用系統 Menu：系統選單關閉後約一秒內捲動表單，這個標籤會晚一秒才跟上（使用者回報）。
                FormlessOptionMenu(options: referenceOptions, selection: AnyHashable(referenceBinding.wrappedValue),
                                   onSelect: { id in if let reference = id.base as? AlignmentReference { referenceBinding.wrappedValue = reference } }) {
                    // 選值的選單：文字用一般文字色、箭頭灰色（不用主色）。
                    HStack(spacing: 4) {
                        Text("對齊基準：" + referenceName)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    // 文字本身只有 20 pt 高，點擊範圍太小；上下各補 6 pt 讓可點區接近按鈕高度，位置不變。
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
            // 基準列與第一排對齊鈕原本只隔 8 pt，容易誤點到「靠右」；多留一段距離。
            .padding(.bottom, 6)
            alignmentRow([.left, .centerX, .right])
            alignmentRow([.top, .centerY, .bottom])
        }
        .padding(.vertical, 4)
    }
    /// 移動步進：方向鍵每按一下加減多少，是方向鍵的設定，和方向鍵放在同一列、中間不加分隔線（使用者：屬於移動、不屬於對齊）。
    /// 放在方塊右上方（10/05 試過右下方，使用者決定改回右上方），和對齊區的「對齊基準」同一種選單：點了才列出選項，不會按方向鍵時誤改
    /// （10/05 先做成方塊下方的分段控制，緊貼「向下」鍵，使用者回報容易誤點）。原本在屬性面板分類列右邊的「…」選單。
    private static let stepChoices: [Double] = [1, 10, 50]
    private var stepMenu: some View {
        HStack {
            Spacer(minLength: 0)
            FormlessOptionMenu(options: Self.stepChoices.map { FormlessMenuOption(id: AnyHashable($0), title: "\(Int($0))") },
                               selection: AnyHashable(step),
                               onSelect: { id in if let value = id.base as? Double { step = value } }) {
                HStack(spacing: 4) {
                    Text("步進：\(Int(step))")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                // 和「對齊基準」相同：上下各補 6 pt 讓可點區接近按鈕高度。
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        }
    }
    enum GeometryEntryKind { case position, size }
    private func nudge(dx: Double, dy: Double) {
        edit(dx != 0 ? "visibleLeft" : "visibleTop") { model.translate(ids, dx: dx, dy: dy) }
    }
    /// 等比縮放鍵：以較長的一邊加減一個步進，另一邊跟著等比變（細長的圖層以短邊算，一步會變太多）。
    private func scale(by delta: Double) {
        guard let frame = model.visibleBounds(of: ids) ?? model.bounds(of: ids) else { return }
        // 圓形：直徑就是框寬，一律改寬（高由模型算）；其他以較長的一邊為準。
        resize(horizontal: model.singleCircle(ids) || frame.width >= frame.height, by: delta)
    }
    /// 每次都重新讀取目前尺寸，長按連續調整時才會逐步累加。
    private func resize(horizontal: Bool, by delta: Double) {
        guard let frame = model.visibleBounds(of: ids) ?? model.bounds(of: ids) else { return }
        let current = EditorNumbers.integer((horizontal ? frame.width : frame.height) * 1600)
        edit(horizontal ? "visibleWidth" : "visibleHeight") {
            model.resizeVisible(ids, horizontal: horizontal, to: max(1, current + delta))
        }
    }
    /// 只套用使用者真的改過的欄位：文字類圖層長寬連動，兩個都重套會讓後者蓋掉前者。
    private func applyEntry(_ kind: GeometryEntryKind, first: Double?, second: Double?) {
        switch kind {
        case .position:
            if let first { edit("visibleTop") { model.moveVisibleEdge(ids, edge: .top, to: first) } }
            if let second { edit("visibleLeft") { model.moveVisibleEdge(ids, edge: .left, to: second) } }
        case .size:
            if let first { edit("visibleWidth") { model.resizeVisible(ids, horizontal: true, to: max(1, first)) } }
            if let second { edit("visibleHeight") { model.resizeVisible(ids, horizontal: false, to: max(1, second)) } }
        }
    }
    /// 方向鍵列四邊一律留 20 pt，和表單其他列（對齊區、預設列內距）一致；原本上下 16、左右 12 加上置中剩下的空隙，
    /// 看起來上下擠、左右鬆。
    private static let padRowInset: CGFloat = 20
    /// 方向鍵盤的邊長由實際列寬算出：兩顆盤加中間 12 pt 剛好填滿列寬，左右留白就等於列內距，不再有置中後的多餘空隙。
    /// 量到列寬之前先用視窗寬度估計（iPhone 上兩者相同，不會先小後大跳一下）。
    private var padSize: CGFloat {
        let formMargin: CGFloat = 20
        let width = padRowWidth ?? (FormlessSafeArea.windowWidth - 2 * formMargin - 2 * Self.padRowInset)
        return min(176, max(132, ((width - 12) / 2).rounded(.down)))
    }
    @State private var padRowWidth: CGFloat?
    private func pads(_ frame: FormlessFrame) -> some View {
        VStack(spacing: 8) {
            stepMenu
            padRow(frame, size: padSize)
        }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { padRowWidth = $0 }
            .listRowInsets(EdgeInsets(top: Self.padRowInset, leading: Self.padRowInset,
                                      bottom: Self.padRowInset, trailing: Self.padRowInset))
            // List 預設把分隔線對齊列內第一段文字的左緣，這裡的文字在圓圈中央，會讓分隔線偏到一半；改成貼齊列的左緣。
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
    private func padRow(_ frame: FormlessFrame, size: CGFloat) -> some View {
        let proportional = model.resizesProportionally(ids)
        // 只選一個圓形色塊：中央只有「直徑」（框寬），高由模型算成正圓，沒有第二個可以改的數字。
        let circle = model.singleCircle(ids)
        return HStack(spacing: 12) {
            GeometryPad(
                title: "位置", size: size,
                center: [("上", frame.y * 1600), ("左", frame.x * 1600)],
                symbols: ("arrow.up", "arrow.down", "arrow.left", "arrow.right"),
                up: { nudge(dx: 0, dy: -step) },
                down: { nudge(dx: 0, dy: step) },
                left: { nudge(dx: -step, dy: 0) },
                right: { nudge(dx: step, dy: 0) },
                allowsNegative: true,
                onEdit: { index, value in applyEntry(.position, first: index == 0 ? value : nil, second: index == 1 ? value : nil) }
            )
            GeometryPad(
                title: "大小", size: size,
                // 高在上、寬在下，和左邊方塊的「上」（直向）、「左」（橫向）同一行對應；圓形只有直徑。
                center: circle ? [("直徑", frame.width * 1600)] : [("高", frame.height * 1600), ("寬", frame.width * 1600)],
                // 箭頭指向中線是縮小、背離中線是放大；直的一對管高、橫的一對管寬，不必看文字就分得出來。
                // 只能等比縮放的圖層（文字、圖片、圖示）只有兩顆斜向鍵：往內是等比縮小、往外是等比放大。
                symbols: proportional
                    ? ("arrow.down.right.and.arrow.up.left", "arrow.up.left.and.arrow.down.right", "", "")
                    : ("arrow.down.and.line.horizontal.and.arrow.up", "arrow.up.and.line.horizontal.and.arrow.down",
                       "arrow.right.and.line.vertical.and.arrow.left", "arrow.left.and.line.vertical.and.arrow.right"),
                proportional: proportional,
                up: { proportional ? scale(by: -step) : resize(horizontal: false, by: -step) },
                down: { proportional ? scale(by: step) : resize(horizontal: false, by: step) },
                left: { resize(horizontal: true, by: -step) },
                right: { resize(horizontal: true, by: step) },
                allowsNegative: false,
                onEdit: { index, value in
                    if circle { applyEntry(.size, first: value, second: nil) }
                    else { applyEntry(.size, first: index == 1 ? value : nil, second: index == 0 ? value : nil) }
                }
            )
        }
    }
    var body: some View {
        if let frame = (measures ? model.visibleBounds(of: ids) : nil) ?? model.bounds(of: ids) {
            let locked = self.locked
            // 位置與大小、對齊各一張卡片（2026-10-05 使用者要求，原本同一張卡片用分隔線隔開）。
            // 對齊一律在方塊下方，多選的「位置與對齊」面板和屬性面板同一個順序。
            Section {
                if locked { lockedNotice }
                lockedDimmed(pads(frame), locked: locked)
            }
            Section {
                lockedDimmed(alignmentControls, locked: locked)
            }
        } else {
            Text("目前沒有可量測的可見內容。")
        }
    }
}

/// 對齊基準的選項：畫布、群組範圍，或某一個圖層。
enum EditorAlignmentReference: Hashable {
    case canvas, groupBounds, layer(UUID)
}

/// 對齊基準的記憶單位：同一群組（群組本身與其所有子圖層）共用一份；根層圖層共用另一份。
enum EditorAlignmentScope: Hashable {
    case root
    case group(UUID)
}

/// 十字方向鍵：中央一顆較大的數值圓，四周四顆較小的方向鈕；長按可連續調整。
/// 中央的數字本身就是輸入欄：點數字直接編輯、鍵盤立刻出現，不另外插入輸入列，
/// 所以不會有「輸入區先出現、鍵盤才出現」或「鍵盤收了輸入區還留著」的問題。
struct GeometryPad: View {
    let title: String
    /// 整組的邊長；中央與四周按鈕的大小都由此推算。
    let size: CGFloat
    let center: [(String, Double)]
    let symbols: (up: String, down: String, left: String, right: String)
    var highlighted = false
    /// 只有兩顆斜向鍵（等比縮小在左上、等比放大在右下），用 `up`／`down` 與其符號。
    var proportional = false
    let up: () -> Void
    let down: () -> Void
    let left: () -> Void
    let right: () -> Void
    let allowsNegative: Bool
    /// 使用者在中央改完第 index 個數字（0 上／高、1 左／寬）。
    let onEdit: (Int, Double) -> Void

    /// 正在編輯中央第幾個數字；點整顆圓的上半／下半即可開始編輯，不必精準點到小數字。
    @FocusState private var focusedField: Int?
    private var gap: CGFloat { 4 }
    private var satellite: CGFloat { (size * 0.26).rounded() }
    private var hub: CGFloat { size - 2 * satellite - 2 * gap }
    private var reach: CGFloat { hub / 2 + gap + satellite / 2 }
    private var hubShape: RoundedRectangle { RoundedRectangle(cornerRadius: (hub * 0.24).rounded(), style: .continuous) }
    /// 方向鍵的點擊範圍往中央延伸：跨過 4 pt 的間隙再進中央 8 pt。中央整塊都能點來輸入數字，手指稍微偏向中央
    /// 就會變成開始輸入（使用者回報：按方向鍵常常點到中間）；外觀不變，中央靠內的範圍照樣點了就輸入。
    private var reachIn: CGFloat { gap + 8 }

    var body: some View {
        ZStack {
            centerFields
                .frame(width: hub, height: hub)
            if proportional {
                // 放在對角：像拖曳圖片角落那樣等比縮放，斜向箭頭的方向也和位置一致。
                padButton(symbols.up, label: title + "等比縮小", toward: EdgeInsets(top: 0, leading: 0, bottom: reachIn, trailing: reachIn),
                          action: up).offset(x: -reach, y: -reach)
                padButton(symbols.down, label: title + "等比放大", toward: EdgeInsets(top: reachIn, leading: reachIn, bottom: 0, trailing: 0),
                          action: down).offset(x: reach, y: reach)
            } else {
                padButton(symbols.up, label: title + "向上", toward: EdgeInsets(top: 0, leading: 0, bottom: reachIn, trailing: 0),
                          action: up).offset(y: -reach)
                padButton(symbols.down, label: title + "向下", toward: EdgeInsets(top: reachIn, leading: 0, bottom: 0, trailing: 0),
                          action: down).offset(y: reach)
                padButton(symbols.left, label: title + "向左", toward: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: reachIn),
                          action: left).offset(x: -reach)
                padButton(symbols.right, label: title + "向右", toward: EdgeInsets(top: 0, leading: reachIn, bottom: 0, trailing: 0),
                          action: right).offset(x: reach)
            }
        }
        .frame(width: size, height: size)
    }

    private var centerFields: some View {
        VStack(spacing: 3) {
            ForEach(Array(center.enumerated()), id: \.offset) { index, item in
                GeometryNumberField(index: index, label: item.0, value: item.1, allowsNegative: allowsNegative,
                                    accessibilityTitle: title + item.0, focus: $focusedField) { onEdit(index, $0) }
            }
        }
        .frame(width: hub, height: hub)
        .contentShape(hubShape)
        // 只用系統玻璃，不另外描邊：自訂的灰色細框會和玻璃本身的邊緣亮線疊成兩層，在白色卡片上顯得髒。
        // 圓角矩形而不是圓形：整組放在圓角矩形的卡片裡，圓形和外框的形狀不和諧（使用者要求）。
        .formlessGlass(.regular, in: hubShape)
        .overlay {
            if highlighted {
                hubShape.strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        // 整顆圓都是點擊目標：上半編第一個數字、下半編第二個。整顆圓也算輸入框，鍵盤開著時點它只切換欄位、不收鍵盤。
        .background(FormlessInputArea())
        .onTapGesture { point in focusedField = center.count > 1 && point.y >= hub / 2 ? 1 : 0 }
        .accessibilityElement(children: .contain)
    }

    private func padButton(_ symbol: String, label: String, toward hub: EdgeInsets,
                           action: @escaping () -> Void) -> some View {
        RepeatingPadButton(symbol: symbol, diameter: satellite, hitOutset: hub, action: action)
            .accessibilityLabel(label)
    }
}

/// 中央圓裡的一行「中文字＋數字」，數字是就地編輯的欄位。
/// 開始編輯時欄位清空、舊值以灰色佈景字提示，只出現游標：系統的全選把手會超出這麼小的欄位而被裁掉，且無法控制其繪製範圍，乾脆不用全選。
/// 只在按鍵盤「完成」、欄位失焦或鍵盤收起時套用；不逐鍵套用，避免輸入到一半的數字把圖層縮到 1。留空表示不改。
private struct GeometryNumberField: View {
    let index: Int
    let label: String
    let value: Double
    let allowsNegative: Bool
    let accessibilityTitle: String
    var focus: FocusState<Int?>.Binding
    let onCommit: (Double) -> Void
    @State private var text = ""
    @State private var editing = false
    private var focused: Bool { focus.wrappedValue == index }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // 欄位四邊比文字多留一點空間：編輯時的選取高亮與游標會超出字形，欄位邊界會把它們裁掉。
            // 尺寸由同一字串的隱藏 Text 決定，欄位寬度仍跟著位數走，中文字與數字的距離維持固定。
            ZStack {
                Text(text.isEmpty ? format(value) : text)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .hidden()
                TextField(format(value), text: $text)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .keyboardType(.numberPad)
                    .focused(focus, equals: index)
                    .accessibilityLabel(accessibilityTitle)
            }
            .fixedSize()
            .frame(minWidth: 28, alignment: .trailing)
        }
        .frame(minHeight: 22)
        .onAppear { text = format(value) }
        // 用 editing 而不是 focused 判斷：按方向鍵時先收鍵盤、再改模型，FocusState 要到下一輪才變回 nil；
        // 若只看 focused，這一次的變動不會顯示，要等下一次變動才一起補上（使用者回報「點了沒反應、再點一下算兩次」）。
        .onChange(of: value) { _, next in
            if !editing { text = format(next) }
        }
        .onChange(of: focus.wrappedValue) { _, current in
            if current == index {
                editing = true
                text = ""
            } else if editing {
                commit()
            }
        }
        // 鍵盤被收掉（點欄位外、互動捲動）時 FocusState 不一定即時更新；以鍵盤通知補上，確保套用並結束編輯。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            guard editing else { return }
            commit()
            if focus.wrappedValue == index { focus.wrappedValue = nil }
        }
    }

    private func format(_ number: Double) -> String { String(Int(EditorNumbers.integer(number))) }

    private func commit() {
        guard editing else { return }
        editing = false
        if let entered = FormlessNumberKeyboard.parse(text) {
            let rounded = EditorNumbers.integer(entered)
            if rounded != EditorNumbers.integer(value) { onCommit(rounded) }
        }
        text = format(value)
    }
}

/// 點一下觸發一次，按住約 0.4 秒後每 0.1 秒重複一次。
/// 按住／放開直接由 UIKit 觸控事件回報（不用手勢辨識器）：長按辨識器即使最短時間設 0，
/// 快速輕點時「放開」可能比「開始」先處理而被判定失敗，也會被「點外面收鍵盤」的手勢要求先失敗，點了沒反應。
/// 方向鍵與加減鍵。為了和捲動分得清楚：
/// - 放開手指才算一次點擊；按住 0.4 秒且手指沒動，才開始每 0.1 秒連續加減。
/// - 手指移動超過 8 pt、或表單開始捲動（系統取消觸控），整個取消，不執行也不留下按下的樣子。
/// - 按下的樣子等手指停住 0.08 秒才出現，快速滑過不會亮；點一下放開時補一下短暫的按下樣子當回饋。
/// 不用系統的可互動玻璃：它一碰到就亮，捲動時會「沒觸發卻發亮」。
struct RepeatingPadButton: View {
    let symbol: String
    let diameter: CGFloat
    /// 點擊範圍比按鈕外觀多出的部分（只在指定的邊）。
    var hitOutset = EdgeInsets()
    let action: () -> Void
    @State private var pressing = false
    @State private var holdTask: Task<Void, Never>?
    @State private var repeating = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: (diameter * 0.3).rounded(), style: .continuous) }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (diameter * 0.4).rounded(), weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .contentShape(shape)
            .formlessGlass(.regular, in: shape)
            .overlay {
                shape.fill(Color.primary.opacity(pressing ? FormlessDesign.Press.overlay : 0)).allowsHitTesting(false)
            }
            .overlay {
                FormlessHoldObserver(onBegan: began, onEnded: ended,
                                     outset: UIEdgeInsets(top: hitOutset.top, left: hitOutset.leading,
                                                          bottom: hitOutset.bottom, right: hitOutset.trailing))
                    .padding(EdgeInsets(top: -hitOutset.top, leading: -hitOutset.leading,
                                        bottom: -hitOutset.bottom, trailing: -hitOutset.trailing))
            }
            .scaleEffect(pressing ? FormlessDesign.Press.scale : 1)
            .animation(FormlessDesign.Motion.press, value: pressing)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func began() {
        holdTask?.cancel()
        repeating = false
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            pressing = true
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            repeating = true
            while !Task.isCancelled {
                fire()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// `tapped`：手指在按鈕上放開、途中沒有移動也沒有被捲動取消。
    private func ended(_ tapped: Bool) {
        holdTask?.cancel()
        holdTask = nil
        let wasRepeating = repeating
        repeating = false
        guard tapped, !wasRepeating else { pressing = false; return }
        fire()
        pressing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            pressing = false
        }
    }

    private func fire() {
        // 鍵盤開著（正在輸入中央數字）時先收鍵盤：輸入值會先套用，這一下加減才是接在新值之後。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        action()
    }
}

/// 透明的觸控層：手指落下時回報開始；放開時回報「是否算點擊」（途中移動超過 8 pt 或被取消就不算）。
/// 只接受按鈕圓角矩形範圍內的觸控。
struct FormlessHoldObserver: UIViewRepresentable {
    var onBegan: () -> Void
    var onEnded: (Bool) -> Void
    /// 視圖比按鈕外觀大出的部分（延伸的點擊範圍）；按鈕本身仍只收圓角矩形以內。
    var outset: UIEdgeInsets = .zero

    final class HoldView: FormlessKeyboardPassThroughView {
        var onBegan: () -> Void = {}
        var onEnded: (Bool) -> Void = { _ in }
        var outset: UIEdgeInsets = .zero
        private var tracking = false
        private var start: CGPoint = .zero
        private static let slop: CGFloat = 8

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let button = bounds.inset(by: outset)
            let radius = (min(button.width, button.height) * 0.3).rounded()
            if UIBezierPath(roundedRect: button, cornerRadius: radius).contains(point) { return true }
            // 延伸出去的長條：和按鈕同寬（或同高），往指定的邊延伸。
            if outset.top > 0, CGRect(x: button.minX, y: bounds.minY, width: button.width, height: outset.top).contains(point) { return true }
            if outset.bottom > 0, CGRect(x: button.minX, y: button.maxY, width: button.width, height: outset.bottom).contains(point) { return true }
            if outset.left > 0, CGRect(x: bounds.minX, y: button.minY, width: outset.left, height: button.height).contains(point) { return true }
            if outset.right > 0, CGRect(x: button.maxX, y: button.minY, width: outset.right, height: button.height).contains(point) { return true }
            return false
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !tracking, let touch = touches.first else { return }
            tracking = true
            start = touch.location(in: self)
            onBegan()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracking, let touch = touches.first else { return }
            let point = touch.location(in: self)
            // 手指移動超過容許範圍就當成在捲動，取消這次按壓。
            if hypot(point.x - start.x, point.y - start.y) > Self.slop { finish(false) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let inside = touches.first.map { self.point(inside: $0.location(in: self), with: event) } ?? false
            finish(inside)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(false) }
        private func finish(_ tapped: Bool) {
            guard tracking else { return }
            tracking = false
            onEnded(tapped)
        }
    }

    func makeUIView(context: Context) -> HoldView {
        let view = HoldView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.onBegan = onBegan
        view.onEnded = onEnded
        view.outset = outset
        return view
    }
    func updateUIView(_ view: HoldView, context: Context) {
        view.onBegan = onBegan
        view.onEnded = onEnded
        view.outset = outset
    }
}

struct EditorGroupInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    let id: UUID
    let category: String
    private var group: FormlessLayer? { model.document.layers.first { $0.id == id } }
    var body: some View {
        Form {
            if category == "其他" {
                // 和一般圖層的「其他」同一個樣子：一張卡片（左名稱、右輸入）。
                Section {
                    EditorTextRow(title: "名稱", text: model.layerBinding(id).name)
                    LabeledContent("種類", value: "群組")
                    Toggle("顯示", isOn: Binding(
                        get: { group?.visible ?? true },
                        set: { visible in
                            if group?.visible != visible { model.toggleHidden(id) }
                        }
                    ))
                    Toggle("鎖定圖層", isOn: Binding(
                        get: { group?.locked ?? false },
                        set: { locked in
                            if group?.locked != locked { model.toggleLocked(id) }
                        }
                    ))
                }
                // 整組透明度（2026-10）：群組裡每個圖層再乘上這個透明度，整組一起變淡。
                Section {
                    EditorNumberRow(title: "透明度", value: Binding(get: { ((group?.opacity ?? 1) * 100).rounded() },
                                                                 set: { model.layerBinding(id).wrappedValue.opacity = min(max($0, 0), 100) / 100 }),
                                    range: 0...100, step: 1, suffix: "%")
                }
                EditorRepeatSection(model: model, session: session, groupID: id)
                if group != nil {
                    EditorVisibilitySection(layer: model.layerBinding(id), live: model.live)
                }
            } else {
                EditorGeometryControls(model: model, ids: [id], session: session)
                    .id(id)
            }
        }
        .background(EditorScrollMemory(session: session, key: id.uuidString + ":" + category))
        .scrollDismissesKeyboard(.interactively)
        // 屬性面板所有區塊都不放標題，頂端統一補上標題原本自帶的留白。
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: EditorPanelUnderlap.formHeadlessHeight) }
        .scrollEdgeEffectHidden(true, for: .top)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .contentMargins(.bottom, EditorPanelUnderlap.formBottom + FormlessSafeArea.bottom, for: .scrollContent)
        .formlessTapToDismissKeyboard()
        // 群組的「何時顯示」也用選擇資料面板（一次只開一個面板）。
        .environment(\.editorDataPanelOpener) { request in
            session.toolPanels.closeInspectorPanels()
            session.toolPanels.data = request
        }
        .environment(\.editorFormatPanelOpener) { request in
            session.toolPanels.closeInspectorPanels()
            session.toolPanels.format = request
        }
    }
}

/// 群組的重複排列（規劃第 6.2 節）：選一份清單，每一筆畫一份群組內容；最多幾筆、方向、間距、欄數。
struct EditorRepeatSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var session: EditorSession
    let groupID: UUID

    private var group: FormlessLayer? { model.document.layer(groupID) }

    private func change(_ edit: (inout FormlessRepeatSpec) -> Void) {
        guard var spec = group?.repeatSpec else { return }
        edit(&spec)
        model.layerBinding(groupID).wrappedValue.repeatSpec = spec
    }

    var body: some View {
        let spec = group?.repeatSpec
        Section {
            HStack(spacing: 8) {
                Text("重複排列")
                Spacer(minLength: FormlessDesign.Space.tight)
                Button {
                    session.toolPanels.closeInspectorPanels()
                    if spec != nil {
                        session.toolPanels.format = EditorFormatPanelRequest(layerID: groupID, slot: .repeatCollection)
                    } else {
                        session.toolPanels.data = EditorDataPanelRequest(layerID: groupID, target: .slot(.repeatCollection), wantsList: true)
                    }
                } label: {
                    if let spec {
                        let label = EditorDataLabels.label(for: spec.collection, live: model.live)
                        EditorDataCapsule(symbol: label.symbol, title: label.title, menu: true)
                    } else {
                        EditorDataCapsule(symbol: "plus", title: "選擇清單")
                    }
                }
                .buttonStyle(.plain)
            }
            if let spec {
                EditorIntegerField(title: "最多幾筆", value: Binding(get: { spec.maxItems }, set: { value in change { $0.maxItems = value } }),
                                   range: 1...30)
                HStack(spacing: 8) {
                    ForEach(FormlessRepeatSpec.Direction.allCases) { direction in
                        EditorChoiceButton(direction.displayName, selected: spec.direction == direction) {
                            change { $0.direction = direction }
                        }
                    }
                }
                .padding(.vertical, 4)
                EditorStepperRow(title: "間距", value: Binding(get: { spec.spacing }, set: { value in change { $0.spacing = value } }),
                                 range: 0...80, step: 1)
                if spec.direction == .grid {
                    EditorIntegerField(title: "欄數", value: Binding(get: { spec.columns ?? 2 }, set: { value in change { $0.columns = value } }),
                                       range: 1...8)
                }
            }
        } footer: {
            Text(spec == nil
                 ? "選一份清單（行程、逐時預報、RSS 文章…），清單的每一筆各畫一份這個群組。"
                 : "第一份就是正在編輯的這一份；群組裡的圖層選資料時，最上面會出現「這一筆」。")
        }
    }
}

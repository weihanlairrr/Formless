import SwiftUI
import UIKit

// MARK: - 文字與資料膠囊（2026-10 通用化，規劃第 6.2 節「資料晶片」）
//
// 參考捷徑的變數膠囊：文字中的資料以膠囊顯示（來源圖示＋欄位名），點膠囊開「格式」。
// 打字照常；膠囊在文字裡就像一個字，可以刪除、移動游標經過。

/// 文字裡的一顆資料膠囊。
final class FormlessChipAttachment: NSTextAttachment {
    let binding: FormlessBinding
    let title: String
    let symbol: String

    init(binding: FormlessBinding, title: String, symbol: String, font: UIFont, traits: UITraitCollection) {
        self.binding = binding
        self.title = title
        self.symbol = symbol
        super.init(data: nil, ofType: nil)
        render(font: font, traits: traits)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 膠囊：淡灰底、單色圖示、欄位名；高度是字的行高，垂直置中在文字上。
    func render(font: UIFont, traits: UITraitCollection) {
        let chipFont = UIFont.systemFont(ofSize: font.pointSize * 0.88, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [
            .font: chipFont, .foregroundColor: UIColor.label.resolvedColor(with: traits)
        ])
        let configuration = UIImage.SymbolConfiguration(pointSize: chipFont.pointSize * 0.9, weight: .medium)
        let icon = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(UIColor.label.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
        let height = ceil(font.lineHeight + 4)
        let iconWidth = icon.map { $0.size.width + 4 } ?? 0
        let textSize = text.size()
        let width = ceil(10 + iconWidth + textSize.width + 10)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width + 2, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = traits.displayScale > 0 ? traits.displayScale : 3
            return format
        }())
        image = renderer.image { _ in
            let rect = CGRect(x: 1, y: 0, width: width, height: height)
            UIColor.tertiarySystemFill.resolvedColor(with: traits).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: height / 2).fill()
            var x = rect.minX + 10
            if let icon {
                icon.draw(at: CGPoint(x: x, y: (height - icon.size.height) / 2))
                x += iconWidth
            }
            text.draw(at: CGPoint(x: x, y: (height - textSize.height) / 2))
        }
        // 膠囊的中線對齊文字的中線（x 高的一半），看起來和字在同一行。
        bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: width + 2, height: height)
    }
}

/// 游標位置（膠囊算一個字），給「插入資料」用。不發布變更。
final class EditorSegmentCursor {
    var offset: Int?
}

final class FormlessSegmentTextView: UITextView, UIGestureRecognizerDelegate {
    var onChipTap: ((Int) -> Void)?
    private lazy var chipTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        return tap
    }()

    func installChipTap() {
        guard !(gestureRecognizers ?? []).contains(chipTap) else { return }
        addGestureRecognizer(chipTap)
        // 點到膠囊時不放游標、不叫出鍵盤：系統的單擊要等膠囊判斷完才動作（點在字上時立刻失敗，沒有延遲感）。
        for recognizer in gestureRecognizers ?? [] where recognizer !== chipTap {
            if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1 {
                tap.require(toFail: chipTap)
            }
        }
    }

    /// 點的位置是第幾段的膠囊。
    func chipIndex(at point: CGPoint) -> Int? {
        var segment = 0
        var hit: Int?
        let storage = attributedText ?? NSAttributedString()
        var lastWasText = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let chip = value as? FormlessChipAttachment {
                for offset in 0..<range.length {
                    if let start = position(from: beginningOfDocument, offset: range.location + offset),
                       let end = position(from: start, offset: 1), let textRange = textRange(from: start, to: end) {
                        let rect = firstRect(for: textRange).insetBy(dx: -4, dy: -6)
                        if rect.contains(point) { hit = segment; stop.pointee = true; return }
                    }
                    segment += 1
                }
                _ = chip
                lastWasText = false
            } else {
                if !lastWasText { segment += 1 }
                lastWasText = true
            }
        }
        return hit
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === chipTap else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return chipIndex(at: gestureRecognizer.location(in: self)) != nil
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let index = chipIndex(at: recognizer.location(in: self)) else { return }
        onChipTap?(index)
    }
}

/// 文字與資料膠囊的輸入框。
struct EditorSegmentTextEditor: UIViewRepresentable {
    let segments: [FormlessTextSegment]
    let live: FormlessLiveData
    let cursor: EditorSegmentCursor
    /// 剛新增的文字圖層：叫出鍵盤並全選預設文字（一打字就取代）。
    @Binding var focusRequest: Bool
    let onChange: ([FormlessTextSegment]) -> Void
    let onChipTap: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FormlessSegmentTextView {
        let view = FormlessSegmentTextView()
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .done
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onChipTap = { index in context.coordinator.parent.onChipTap(index) }
        view.installChipTap()
        context.coordinator.apply(segments, to: view)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (view: FormlessSegmentTextView, _: UITraitCollection) in
            context.coordinator.apply(context.coordinator.parent.segments, to: view, force: true)
        }
        return view
    }

    func updateUIView(_ view: FormlessSegmentTextView, context: Context) {
        context.coordinator.parent = self
        view.onChipTap = { index in context.coordinator.parent.onChipTap(index) }
        if !context.coordinator.editing || Coordinator.parse(view.attributedText) != segments {
            context.coordinator.apply(segments, to: view)
        }
        if focusRequest {
            DispatchQueue.main.async {
                view.becomeFirstResponder()
                view.selectAll(nil)
                focusRequest = false
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FormlessSegmentTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(size.height, uiView.font?.lineHeight ?? 22))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditorSegmentTextEditor
        var editing = false
        private var applied: [FormlessTextSegment]?

        init(_ parent: EditorSegmentTextEditor) { self.parent = parent }

        func apply(_ segments: [FormlessTextSegment], to view: UITextView, force: Bool = false) {
            guard force || applied != segments else { return }
            applied = segments
            let font = view.font ?? UIFont.preferredFont(forTextStyle: .body)
            let result = NSMutableAttributedString()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            for segment in segments {
                switch segment {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .data(let binding):
                    let label = EditorDataLabels.label(for: binding, live: parent.live)
                    let chip = FormlessChipAttachment(binding: binding, title: label.title, symbol: label.symbol,
                                                      font: font, traits: view.traitCollection)
                    let piece = NSMutableAttributedString(attachment: chip)
                    piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
                    result.append(piece)
                }
            }
            let selection = view.selectedRange
            view.attributedText = result
            view.typingAttributes = attributes
            if view.isFirstResponder {
                view.selectedRange = NSRange(location: min(selection.location, result.length), length: 0)
            }
            view.invalidateIntrinsicContentSize()
        }

        static func parse(_ text: NSAttributedString?) -> [FormlessTextSegment] {
            guard let text else { return [] }
            var result: [FormlessTextSegment] = []
            let string = text.string as NSString
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let chip = value as? FormlessChipAttachment {
                    for _ in 0..<range.length { result.append(.data(chip.binding)) }
                } else {
                    let piece = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                    guard !piece.isEmpty else { return }
                    if case .text(let previous)? = result.last {
                        result[result.count - 1] = .text(previous + piece)
                    } else {
                        result.append(.text(piece))
                    }
                }
            }
            return result
        }

        func textViewDidBeginEditing(_ textView: UITextView) { editing = true }

        func textViewDidEndEditing(_ textView: UITextView) {
            editing = false
            parent.cursor.offset = textView.selectedRange.location
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.cursor.offset = textView.selectedRange.location
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // 換行鍵是「完成」（和其他文字欄位相同）。
            if text == "\n" { textView.resignFirstResponder(); return false }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            let segments = Self.parse(textView.attributedText)
            applied = segments
            parent.onChange(segments)
            textView.invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - 內容分頁：文字

/// 文字圖層的「內容」：上面是文字（可以夾資料膠囊），下面一列「插入資料」。
struct EditorTextContentSection: View {
    @Binding var layer: FormlessLayer
    let live: FormlessLiveData
    @Binding var focusRequest: Bool
    @Environment(\.editorDataPanelOpener) private var openData
    @Environment(\.editorFormatPanelOpener) private var openFormat
    @State private var cursor = EditorSegmentCursor()

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("文字")
                EditorSegmentTextEditor(segments: layer.editorSegments, live: live, cursor: cursor, focusRequest: $focusRequest,
                                        onChange: { segments in layer.editorSetSegments(segments, live: live) },
                                        onChipTap: { index in
                                            dismissKeyboard()
                                            openFormat?(EditorFormatPanelRequest(layerID: layer.id, slot: .segment(index)))
                                        })
            }
            .padding(.vertical, FormlessDesign.Space.rowExtra)
            Button {
                dismissKeyboard()
                openData?(EditorDataPanelRequest(layerID: layer.id, target: .insertSegment(cursor.offset)))
            } label: {
                Label("插入資料", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        } footer: {
            Text("點文字裡的資料可以設定格式：數字、單位、第幾筆、沒有資料時顯示的文字。")
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - 格式面板

/// 點資料膠囊（或進度、條件裡的資料）後滑出的面板：換資料、第幾筆、數字與日期的格式、計算、沒有資料時的文字。
/// 和其他工具面板一樣：螢幕 60% 高、畫布不擋、點外面關閉；改了畫布立刻變。
struct EditorFormatPanel: View {
    @ObservedObject var model: EditorModel
    let request: EditorFormatPanelRequest
    let height: CGFloat
    var shown = true
    let onReplace: () -> Void
    let onClose: () -> Void

    private var binding: FormlessBinding? { model.dataBinding(at: request.slot, layerID: request.layerID) }

    private func update(_ change: (inout FormlessBinding) -> Void) {
        guard var next = binding else { return }
        change(&next)
        if next.format?.isEmpty == true { next.format = nil }
        model.setDataBinding(next, at: request.slot, layerID: request.layerID)
    }

    private func format<T>(_ keyPath: WritableKeyPath<FormlessFormat, T>) -> Binding<T> {
        Binding(
            get: { (binding?.format ?? FormlessFormat())[keyPath: keyPath] },
            set: { value in update { $0.format = { var f = $0.format ?? FormlessFormat(); f[keyPath: keyPath] = value; return f }($0) } }
        )
    }

    var body: some View {
        Form {
            if let binding {
                let live = model.live
                let spec = live.fieldSpec(binding)
                let value = live.value(binding, at: Date())
                let kind = spec?.kind ?? value.kind
                Section {
                    Button(action: onReplace) {
                        HStack(spacing: 14) {
                            let label = EditorDataLabels.label(for: binding, live: live)
                            Image(systemName: label.symbol).frame(width: 26)
                            Text(label.title).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: FormlessDesign.Space.valueGap)
                            Text("更換").foregroundStyle(FormlessDesign.Palette.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if binding.index != nil {
                        EditorStepperRow(title: "第幾筆", value: Binding(
                            get: { Double(binding.index ?? 1) },
                            set: { index in update { $0.index = max(1, Int(index)) } }), range: 1...60, step: 1)
                    }
                    HStack {
                        Text("目前的值")
                        Spacer(minLength: FormlessDesign.Space.valueGap)
                        Text(live.text(binding, at: Date())).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                switch kind {
                case .number?, .list?: numberSection(spec: spec, unit: value.unit)
                case .date?: dateSection
                case .duration?: durationSection
                case .text?: textSection
                default: EmptyView()
                }
                if kind == .number || kind == .duration { mathSection }
                Section {
                    EditorTextRow(title: "沒有資料時", placeholder: "－", text: Binding(
                        get: { binding.format?.emptyText ?? "" },
                        set: { text in update { $0.format = { var f = $0.format ?? FormlessFormat(); f.emptyText = text.isEmpty ? nil : text; return f }($0) } }))
                }
                Section {
                    Button(role: .destructive) {
                        model.setDataBinding(nil, at: request.slot, layerID: request.layerID)
                        onClose()
                    } label: {
                        Text(removeTitle).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(FormlessDesign.Space.panel)
        .contentMargins(.horizontal, BatchPositionPanel.margin, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, BatchPositionPanel.margin + FormlessSafeArea.bottom, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(FormlessFixedPanelScroll())
        .safeAreaBar(edge: .top, spacing: 0) {
            Text("格式").font(.headline).frame(maxWidth: .infinity).frame(height: BatchPositionPanel.titleBar)
        }
        .editorToolPanel(height: height, active: shown, onClose: onClose)
    }

    private var removeTitle: String {
        switch request.slot {
        case .segment: return "從文字移除這份資料"
        case .progress: return "改回固定的數字"
        default: return "不使用這份資料"
        }
    }

    @ViewBuilder private func numberSection(spec: FormlessFieldSpec?, unit: FormlessUnit) -> some View {
        let effective = binding?.format?.decimals ?? spec?.decimals ?? FormlessValueFormatter.defaultDecimals(0, unit: unit)
        Section {
            EditorStepperRow(title: "小數位數", value: Binding(
                get: { Double(effective) },
                set: { decimals in update { $0.format = { var f = $0.format ?? FormlessFormat(); f.decimals = Int(decimals); return f }($0) } }),
                             range: 0...4, step: 1)
            Toggle("千分位", isOn: Binding(
                get: { binding?.format?.grouping ?? (spec?.grouping ?? false) },
                set: { flag in update { $0.format = { var f = $0.format ?? FormlessFormat(); f.grouping = flag; return f }($0) } }))
            Toggle("縮寫成「萬」", isOn: Binding(
                get: { binding?.format?.compact ?? false },
                set: { flag in update { $0.format = { var f = $0.format ?? FormlessFormat(); f.compact = flag ? true : nil; return f }($0) } }))
            if !unit.suffix.isEmpty || unit == .bytes {
                Toggle("顯示單位（\(unit == .celsius ? "°" : unit.suffix.trimmingCharacters(in: .whitespaces))）", isOn: Binding(
                    get: { binding?.format?.showsUnit ?? FormlessValueFormatter.showsUnitByDefault(unit) },
                    set: { flag in update { $0.format = { var f = $0.format ?? FormlessFormat(); f.showsUnit = flag; return f }($0) } }))
            }
            if unit == .celsius {
                Picker("溫度單位", selection: Binding(
                    get: { binding?.format?.temperatureUnit ?? "" },
                    set: { unit in update { $0.format = { var f = $0.format ?? FormlessFormat(); f.temperatureUnit = unit.isEmpty ? nil : unit; return f }($0) } })) {
                    Text("依 App 設定").tag("")
                    Text("攝氏").tag("c")
                    Text("華氏").tag("f")
                }
            }
        }
    }

    private static let calendars: [(id: String, name: String)] = [
        ("", "西曆"), ("roc", "民國"), ("chinese", "農曆"), ("buddhist", "佛曆"), ("japanese", "日本曆")
    ]

    @ViewBuilder private var dateSection: some View {
        let style = binding?.format?.dateStyle ?? ""
        let known = FormlessDateStylePreset.options.contains { $0.id == style } || style.isEmpty
        Section {
            Picker("樣式", selection: Binding(
                get: { known ? style : "custom" },
                set: { next in update { b in
                    var f = b.format ?? FormlessFormat()
                    f.dateStyle = next == "custom" ? "yyyy/MM/dd HH:mm" : (next.isEmpty ? nil : next)
                    b.format = f
                } })) {
                Text("自動").tag("")
                ForEach(FormlessDateStylePreset.options, id: \.id) { option in
                    Text(option.name + "（" + sample(option.id) + "）").tag(option.id)
                }
                Text("自訂格式").tag("custom")
            }
            if !known {
                EditorTextRow(title: "格式", placeholder: "yyyy/MM/dd", text: Binding(
                    get: { style },
                    set: { text in update { b in var f = b.format ?? FormlessFormat(); f.dateStyle = text.isEmpty ? nil : text; b.format = f } }),
                              plain: true)
            }
            Picker("曆法", selection: Binding(
                get: { binding?.format?.calendar ?? "" },
                set: { next in update { b in var f = b.format ?? FormlessFormat(); f.calendar = next.isEmpty ? nil : next; b.format = f } })) {
                ForEach(Self.calendars, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("時區", selection: Binding(
                get: { binding?.format?.timeZone ?? "" },
                set: { next in update { b in var f = b.format ?? FormlessFormat(); f.timeZone = next.isEmpty ? nil : next; b.format = f } })) {
                ForEach(FormlessDateTimeProvider.timeZones) { Text($0.name).tag($0.id) }
            }
        } footer: {
            Text("「即時」的樣式由系統自己走動，不受小工具更新頻率限制。")
        }
    }

    private func sample(_ style: String) -> String {
        var format = FormlessFormat()
        format.dateStyle = style
        let target = Date().addingTimeInterval(3 * 86_400 + 3600)
        return FormlessValueFormatter.text(.date(style == FormlessDateStylePreset.countdownDays || style == FormlessLiveDateStyle.timer.rawValue
                                                 || style == FormlessLiveDateStyle.relative.rawValue ? target : Date()),
                                           format: format, spec: nil, at: Date())
    }

    @ViewBuilder private var durationSection: some View {
        Section {
            Picker("樣式", selection: Binding(
                get: { binding?.format?.dateStyle ?? "" },
                set: { next in update { b in var f = b.format ?? FormlessFormat(); f.dateStyle = next.isEmpty ? nil : next; b.format = f } })) {
                Text("幾小時幾分").tag("")
                Text("倒數計時（即時）").tag(FormlessLiveDateStyle.timer.rawValue)
            }
        }
    }

    @ViewBuilder private var textSection: some View {
        Section {
            Picker("大小寫", selection: Binding(
                get: { binding?.format?.textCase ?? "" },
                set: { next in update { b in var f = b.format ?? FormlessFormat(); f.textCase = next.isEmpty ? nil : next; b.format = f } })) {
                Text("不變").tag("")
                Text("全部大寫").tag("upper")
                Text("全部小寫").tag("lower")
                Text("字首大寫").tag("capitalized")
            }
            EditorStepperRow(title: "最多幾個字", value: Binding(
                get: { Double(binding?.format?.maxLength ?? 0) },
                set: { count in update { b in var f = b.format ?? FormlessFormat(); f.maxLength = count > 0 ? Int(count) : nil; b.format = f } }),
                             range: 0...200, step: 1)
        } footer: {
            Text("最多幾個字是 0 時不限。")
        }
    }

    /// 計算：依序加減乘除、算佔目標的百分比。值可以是數字或我的資料。
    @ViewBuilder private var mathSection: some View {
        let operations = binding?.format?.operations ?? []
        Section {
            ForEach(Array(operations.enumerated()), id: \.element.id) { index, operation in
                HStack(spacing: 8) {
                    FormlessOptionMenu(options: FormlessMathOperation.Kind.allCases.map { FormlessMenuOption(id: AnyHashable($0.rawValue), title: $0.displayName) },
                                       selection: AnyHashable(operation.kind.rawValue),
                                       onSelect: { id in
                                           guard let raw = id.base as? String, let kind = FormlessMathOperation.Kind(rawValue: raw) else { return }
                                           setOperation(index) { $0.kind = kind }
                                       }) {
                        menuLabel(operation.kind.displayName)
                    }
                    if operation.kind.takesOperand { operandControl(index, operation: operation) }
                    Spacer(minLength: 0)
                    Button { removeOperation(index) } label: {
                        Image(systemName: "minus")
                            .font(FormlessDesign.Symbol.smallCircle)
                            .frame(width: FormlessDesign.Size.compactControl, height: FormlessDesign.Size.compactControl)
                            .background(FormlessDesign.Palette.tintFill, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除計算")
                }
            }
            Button {
                update { b in
                    var f = b.format ?? FormlessFormat()
                    f.operations = (f.operations ?? []) + [FormlessMathOperation(kind: .subtract, operand: .number(0))]
                    b.format = f
                }
            } label: {
                Label("加入計算", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        } footer: {
            Text("例如「目標 減 步數」得到還差幾步；「佔的百分比」算出佔目標多少。")
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .frame(minHeight: FormlessDesign.Size.compactControl)
        .formlessGrayBox()
    }

    /// 運算的另一個值：數字，或從選單挑我的資料。
    @ViewBuilder private func operandControl(_ index: Int, operation: FormlessMathOperation) -> some View {
        let variables = model.document.variables ?? []
        if let bound = operation.operand.binding, bound.isVariable {
            FormlessOptionMenu(options: [FormlessMenuOption(id: AnyHashable(""), title: "數字")]
                               + variables.map { FormlessMenuOption(id: AnyHashable($0.id.uuidString), title: $0.name) },
                               selection: AnyHashable(bound.field),
                               onSelect: { id in selectOperand(index, id.base as? String ?? "") }) {
                menuLabel(model.live.variable(bound.field)?.name ?? "我的資料")
            }
        } else {
            HStack(spacing: 4) {
                FormlessNumberField(value: operation.operand.constant?.numberValue ?? 0,
                                    format: { FormlessValueFormatter.fixed($0, decimals: $0.rounded() == $0 ? 0 : 2, grouping: false) }) { number in
                    setOperation(index) { $0.operand = .number(number) }
                }
                .font(.body.monospacedDigit())
                .padding(.horizontal, 8)
                .frame(width: FormlessDesign.Size.fieldShort + 10)
                .frame(minHeight: FormlessDesign.Size.compactControl)
                .formlessGrayBox()
                if !variables.isEmpty {
                    FormlessOptionMenu(options: variables.map { FormlessMenuOption(id: AnyHashable($0.id.uuidString), title: $0.name) },
                                       selection: nil, onSelect: { id in selectOperand(index, id.base as? String ?? "") }) {
                        Image(systemName: "pencil")
                            .frame(width: FormlessDesign.Size.compactControl, height: FormlessDesign.Size.compactControl)
                            .formlessGrayBox()
                    }
                    .accessibilityLabel("使用我的資料")
                }
            }
        }
    }

    private func selectOperand(_ index: Int, _ id: String) {
        setOperation(index) { operation in
            if let uuid = UUID(uuidString: id) {
                operation.operand = .binding(.variable(uuid))
            } else {
                operation.operand = .number(0)
            }
        }
    }

    private func setOperation(_ index: Int, _ change: (inout FormlessMathOperation) -> Void) {
        update { b in
            var f = b.format ?? FormlessFormat()
            var operations = f.operations ?? []
            guard operations.indices.contains(index) else { return }
            change(&operations[index])
            f.operations = operations
            b.format = f
        }
    }

    private func removeOperation(_ index: Int) {
        update { b in
            var f = b.format ?? FormlessFormat()
            var operations = f.operations ?? []
            guard operations.indices.contains(index) else { return }
            operations.remove(at: index)
            f.operations = operations.isEmpty ? nil : operations
            b.format = f
        }
    }
}

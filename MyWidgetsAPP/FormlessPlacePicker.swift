import Combine
import MapKit
import SwiftUI

/// 地點的即時建議（打字時列出符合的地點），新增行程的地點欄和地圖選點的搜尋共用。
@MainActor
final class FormlessPlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// 輸入的文字；空白就清掉建議。
    func update(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = text
        }
    }

    /// 選了一筆建議：查出它的座標與地址。
    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = Array(completer.results.prefix(5)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }
}

extension MKMapItem {
    /// 地點名稱底下那行地址（沒有就是空字串）。
    var formlessAddressLine: String {
        address?.shortAddress ?? address?.fullAddress ?? ""
    }
}

/// 一筆地點建議：左邊名稱、右邊地址（和其他列一樣左名稱右內容），整列都點得到。
/// 建議只在打字時出現、鍵盤一定開著；「點外面收鍵盤」的擋板只放行輸入框（或輸入範圍）的 UIView，
/// SwiftUI 的按鈕沒有自己的 UIView、放在背景的標記也碰不到，點下去只會收鍵盤（實測）。
/// 所以整列最上層蓋一塊 UIKit 的點擊區（內含輸入範圍標記），點擊由它直接接收。
struct FormlessPlaceSuggestionRow: View {
    let completion: MKLocalSearchCompletion
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(completion.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(completion.subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .overlay(FormlessInputTapArea(action: action))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// 鍵盤開著時也點得到的點擊區：擋板看到輸入範圍標記就放行，觸控交給這塊的點擊手勢。
/// 用手勢而不是 touchesEnded：在清單裡捲動時手勢會被取消，不會誤選。
struct FormlessInputTapArea: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let marker = FormlessInputAreaView()
        marker.backgroundColor = .clear
        marker.frame = view.bounds
        marker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(marker)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

/// 在地圖上選地點：拖動地圖讓中間的圖釘對到位置，或上方搜尋；下方卡片顯示目前選到的地點，按「完成」帶回。
/// 往下滑關閉就是不改。
struct FormlessMapPicker: View {
    let initial: MKMapItem?
    let onPick: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var resolved: MKMapItem?
    /// 從搜尋選的地點：地圖移過去後保留它的店名，不用反查出來的地址蓋掉。
    @State private var pendingPick: MKMapItem?
    @State private var query = ""
    @StateObject private var search = FormlessPlaceSearch()

    init(initial: MKMapItem?, onPick: @escaping (MKMapItem) -> Void) {
        self.initial = initial
        self.onPick = onPick
        if let initial {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: initial.location.coordinate, latitudinalMeters: 600, longitudinalMeters: 600)))
            _resolved = State(initialValue: initial)
            _pendingPick = State(initialValue: initial)
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        NavigationStack {
            FormlessMapPickerContent(
                position: $position,
                resolved: $resolved,
                pendingPick: $pendingPick,
                query: $query,
                search: search
            )
            .navigationTitle("選擇地點")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋地點")
            .onChange(of: query) { _, text in search.update(text) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("選擇") {
                        if let resolved { onPick(resolved) }
                        dismiss()
                    }
                    .disabled(resolved == nil)
                }
            }
        }
        .presentationDetents([.large])
        .formlessSheetBackground()
    }
}

private struct FormlessMapPickerContent: View {
    @Binding var position: MapCameraPosition
    @Binding var resolved: MKMapItem?
    @Binding var pendingPick: MKMapItem?
    @Binding var query: String
    @ObservedObject var search: FormlessPlaceSearch

    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var geocodeTask: Task<Void, Never>?
    /// 地圖中心在畫面上的位置：圖釘畫在這一點，選到的就是地圖中心的座標，兩者永遠是同一點。
    /// 不把圖釘固定在畫面正中間：地圖的中心會隨搜尋列、卡片等可見範圍變化而不在畫面正中（實測差約 290 m）。
    @State private var pinPoint: CGPoint?

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                pinPoint = proxy.convert(context.camera.centerCoordinate, to: .local)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                pinPoint = proxy.convert(context.camera.centerCoordinate, to: .local)
                locate(context.camera.centerCoordinate)
            }
            // 圖釘的尖端（圖示底邊）對準地圖中心。
            .overlay(alignment: .topLeading) {
                if let pinPoint {
                    Image(systemName: "mappin")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44, alignment: .bottom)
                        .position(x: pinPoint.x, y: pinPoint.y - 22)
                        .allowsHitTesting(false)
                }
            }
            // 卡片疊在地圖上，不佔地圖的範圍（用 safeAreaInset 會讓地圖的中心跟著移動）。
            .overlay(alignment: .bottom) {
                if let resolved {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resolved.name ?? "")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !resolved.formlessAddressLine.isEmpty {
                            Text(resolved.formlessAddressLine)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(20)
                }
            }
            .overlay {
                if isSearching && !search.results.isEmpty {
                    List(search.results, id: \.self) { completion in
                        FormlessPlaceSuggestionRow(completion: completion) { pick(completion) }
                    }
                }
            }
        }
    }

    /// 地圖停下來：中心還在已選地點附近（30 m 內）就保留它的店名；其他情況反查中心的地址。
    /// 已選地點不因為地圖移動而清掉：地圖剛打開時會先回報一次預設位置，清掉的話店名會被反查出的地址蓋掉（實測）。
    private func locate(_ center: CLLocationCoordinate2D) {
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        geocodeTask?.cancel()
        if let pendingPick, pendingPick.location.distance(from: here) < 30 {
            resolved = pendingPick
            return
        }
        geocodeTask = Task {
            guard let request = MKReverseGeocodingRequest(location: here),
                  let item = try? await request.mapItems.first,
                  !Task.isCancelled else { return }
            resolved = item
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        dismissSearch()
        query = ""
        Task {
            guard let item = await search.resolve(completion) else { return }
            pendingPick = item
            resolved = item
            withAnimation {
                position = .region(MKCoordinateRegion(
                    center: item.location.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
            }
        }
    }
}

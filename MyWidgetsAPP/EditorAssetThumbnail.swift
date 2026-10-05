import SwiftUI

struct EditorAssetThumbnail<Content: View>: View {
    let item: FormlessAssetItem
    @ViewBuilder var content: (UIImage?) -> Content
    @State private var image: UIImage?
    var body: some View {
        content(image)
            .task(id: item.id) {
                let source = item
                image = await Task.detached {
                    FormlessAssetCache.shared.image(named: FormlessAssetLibrary.thumbName(for: source))
                }.value
            }
    }
}

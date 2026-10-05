import WidgetKit
import SwiftUI

@main
struct FormlessWidgetsBundle: WidgetBundle {

    var body: some Widget {

        FormlessSmallWidget()

        FormlessMediumWidget()

        FormlessLargeWidget()

        FormlessExtraLargeWidget()
    }
}

import BuildThisPlease
import SwiftUI

@main
struct BuildThisPleaseExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ExampleRootView()
                .modifier(ExampleSoftScrollEdges())
        }
    }
}

struct ExampleSoftScrollEdges: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
        }
    }
}

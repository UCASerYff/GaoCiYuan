import SwiftUI

struct WidgetSetup: ViewModifier {
    @ObservedObject var store: MonitorStore
    func body(content: Content) -> some View {
        content.onAppear {
            MemberDiscovery.shared.configure(store)
            Task { await store.exportWidgetSnapshot() }
        }
    }
}

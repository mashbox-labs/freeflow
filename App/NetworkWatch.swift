import Foundation
import FreeFlowKit
import Network

/// Whether the current connection is expensive (cellular or a phone's hotspot), so a large download can ask first.
@MainActor
final class NetworkWatch: ObservableObject {
    static let shared = NetworkWatch()
    @Published private(set) var expensive = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let e = path.isExpensive
            Task { @MainActor in NetworkWatch.shared.expensive = e }
        }
        monitor.start(queue: DispatchQueue(label: FF.subsystem + ".network"))
    }
}

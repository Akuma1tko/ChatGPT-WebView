import Combine
import Foundation

@MainActor
final class LocalMemoryWriteActivity: ObservableObject {
    static let shared = LocalMemoryWriteActivity()

    @Published private(set) var activeWriteCount = 0

    var isWriting: Bool {
        activeWriteCount > 0
    }

    private init() {}

    func begin() {
        activeWriteCount += 1
    }

    func end() {
        activeWriteCount = max(0, activeWriteCount - 1)
    }
}

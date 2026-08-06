import Foundation

actor DeveloperSourceResponseMetadataRegistry {
    static let shared = DeveloperSourceResponseMetadataRegistry()

    private var sourceMapReferencesBySourceID: [String: [String]] = [:]

    func clear() {
        sourceMapReferencesBySourceID.removeAll(keepingCapacity: false)
    }

    func recordSourceMapReferences(_ references: [String], for sourceID: String) {
        let normalized = references
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if normalized.isEmpty {
            sourceMapReferencesBySourceID[sourceID] = nil
        } else {
            sourceMapReferencesBySourceID[sourceID] = Array(Set(normalized)).sorted()
        }
    }

    func sourceMapReferences(for sourceIDs: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for sourceID in sourceIDs {
            if let references = sourceMapReferencesBySourceID[sourceID] {
                result[sourceID] = references
            }
        }
        return result
    }
}

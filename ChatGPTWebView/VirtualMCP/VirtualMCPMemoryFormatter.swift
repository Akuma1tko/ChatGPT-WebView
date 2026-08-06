import Foundation

enum VirtualMCPMemoryFormatter {
    static func memoryContent(from proposal: VirtualMCPSaveContextProposal) -> String {
        var sections: [String] = []
        sections.append(proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines))

        appendSection(title: "Decisions", values: proposal.decisions, into: &sections)
        appendSection(title: "Open tasks", values: proposal.openTasks, into: &sections)
        appendSection(title: "Files discussed", values: proposal.filesDiscussed, into: &sections)
        appendSection(title: "Next steps", values: proposal.nextSteps, into: &sections)

        sections.append("Importance: \(proposal.importance)/5")
        sections.append("Source: virtual_mcp.save_context_after_approval")

        return sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func normalizedTags(from proposal: VirtualMCPSaveContextProposal) -> [String] {
        var tags = proposal.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for required in ["virtual-mcp", "approved-save"] where !tags.contains(required) {
            tags.append(required)
        }

        return Array(tags.prefix(12))
    }

    private static func appendSection(title: String, values: [String], into sections: inout [String]) {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else {
            return
        }

        let body = cleaned.map { "- \($0)" }.joined(separator: "\n")
        sections.append("\(title):\n\(body)")
    }
}

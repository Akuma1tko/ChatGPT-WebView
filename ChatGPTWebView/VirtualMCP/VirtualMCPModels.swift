import Foundation

struct VirtualMCPToolDescriptor: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let title: String
    let description: String
    let requiresApproval: Bool
    let inputContract: String
    let outputContract: String

    init(
        name: String,
        title: String,
        description: String,
        requiresApproval: Bool,
        inputContract: String,
        outputContract: String
    ) {
        self.id = name
        self.name = name
        self.title = title
        self.description = description
        self.requiresApproval = requiresApproval
        self.inputContract = inputContract
        self.outputContract = outputContract
    }
}

struct VirtualMCPToolRegistry: Sendable {
    let tools: [VirtualMCPToolDescriptor]

    static let memoryPrototype = VirtualMCPToolRegistry(tools: [
        VirtualMCPToolDescriptor(
            name: "save_context_after_approval",
            title: "Save Context After Approval",
            description: "Real backend MCP-style write tool. Saves an approved structured context proposal into Supabase memory through the memory Edge Function.",
            requiresApproval: true,
            inputContract: "project_id, title, summary, decisions, open_tasks, files_discussed, next_steps, tags, importance",
            outputContract: "saved, project_id, memory_item_id, session_summary_id, tool_event_id, message"
        ),
        VirtualMCPToolDescriptor(
            name: "import_session_after_approval",
            title: "Import Session After Approval",
            description: "Imports pasted session context directly from the app into Supabase memory without using a ChatGPT connector write.",
            requiresApproval: true,
            inputContract: "project_id, title, content, source, tags, importance",
            outputContract: "saved, project_id, memory_item_id, session_summary_id, tool_event_id, message"
        )
    ])

    func descriptor(named name: String) -> VirtualMCPToolDescriptor? {
        tools.first { $0.name == name }
    }
}

struct VirtualMCPSaveContextProposal: Sendable, Hashable {
    var projectID: UUID?
    var title: String
    var summary: String
    var decisions: [String]
    var openTasks: [String]
    var filesDiscussed: [String]
    var nextSteps: [String]
    var tags: [String]
    var importance: Int

    init(
        projectID: UUID? = nil,
        title: String,
        summary: String,
        decisions: [String] = [],
        openTasks: [String] = [],
        filesDiscussed: [String] = [],
        nextSteps: [String] = [],
        tags: [String] = [],
        importance: Int = 3
    ) {
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.openTasks = openTasks
        self.filesDiscussed = filesDiscussed
        self.nextSteps = nextSteps
        self.tags = tags
        self.importance = min(max(importance, 1), 5)
    }
}

struct VirtualMCPSaveContextResult: Sendable, Hashable {
    let saved: Bool
    let projectID: UUID
    let memoryItemID: UUID
    let sessionSummaryID: UUID
    let toolEventID: UUID?
    let toolName: String
    let message: String
}

struct SessionContextImportResult: Sendable, Hashable {
    let saved: Bool
    let projectID: UUID
    let memoryItemID: UUID
    let sessionSummaryID: UUID
    let toolEventID: UUID?
    let toolName: String
    let message: String
}

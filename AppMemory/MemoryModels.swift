import Foundation

public struct MemoryProject: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let status: String?
    public let repo_url: String?
    public let created_at: Date?
    public let updated_at: Date?
}

public struct MemoryItem: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let project_id: UUID
    public let title: String
    public let content: String
    public let tags: [String]
    public let importance: Int?
    public let is_pinned: Bool?
    public let created_at: Date?
    public let updated_at: Date?
}

public struct MemorySession: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let project_id: UUID
    public let title: String
    public let source: String?
    public let external_ref: String?
    public let started_at: Date?
    public let ended_at: Date?
}

public struct MemorySessionSummary: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let project_id: UUID
    public let session_id: UUID?
    public let summary: String
    public let decisions: [String]
    public let open_tasks: [String]
    public let files_discussed: [String]
    public let next_steps: [String]
    public let importance: Int?
    public let created_at: Date?
}

public struct MemoryArtifact: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let artifact_type: String
    public let url_or_path: String?
    public let notes: String?
    public let created_at: Date?
}

public struct MemoryToolEvent: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let project_id: UUID?
    public let session_id: UUID?
    public let action: String
    public let status: String
    public let created_at: Date?
}

public struct ProjectContext: Codable, Sendable, Hashable {
    public let project: MemoryProject
    public let summaries: [MemorySessionSummary]
    public let memories: [MemoryItem]
    public let artifacts: [MemoryArtifact]
}

public struct CreateProjectResponse: Codable, Sendable {
    public let project: MemoryProject
}

public struct ListProjectsResponse: Codable, Sendable {
    public let projects: [MemoryProject]
}

public struct CreateSessionResponse: Codable, Sendable {
    public let session: MemorySession
}

public struct SaveMemoryResponse: Codable, Sendable {
    public let memory: MemoryItem
}

public struct SearchMemoryResponse: Codable, Sendable {
    public let memories: [MemoryItem]
}

public struct SaveSessionSummaryResponse: Codable, Sendable {
    public let session_summary: MemorySessionSummary
}

public struct SaveContextAfterApprovalResponse: Codable, Sendable {
    public let saved: Bool
    public let project_id: UUID
    public let memory_item_id: UUID
    public let session_summary_id: UUID
    public let tool_name: String
    public let memory: MemoryItem
    public let session_summary: MemorySessionSummary
    public let tool_event: MemoryToolEvent?
}

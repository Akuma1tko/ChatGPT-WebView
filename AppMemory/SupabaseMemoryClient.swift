import Foundation

public enum SupabaseMemoryClientError: Error, LocalizedError {
    case invalidResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The memory service returned an invalid response."
        case .serverError(let message):
            return message
        }
    }
}

public actor SupabaseMemoryClient {
    private let functionURL: URL
    private let publishableKey: String
    private let bearerTokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        functionURL: URL,
        publishableKey: String,
        bearerTokenProvider: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared
    ) {
        self.functionURL = functionURL
        self.publishableKey = publishableKey
        self.bearerTokenProvider = bearerTokenProvider
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        self.decoder = decoder
    }

    public func createProject(name: String, description: String? = nil) async throws -> MemoryProject {
        var body: [String: Any] = [
            "action": "create_project",
            "name": name
        ]

        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["content"] = description
        }

        let response: CreateProjectResponse = try await post(body)
        return response.project
    }

    public func listProjects() async throws -> [MemoryProject] {
        let response: ListProjectsResponse = try await post([
            "action": "list_projects"
        ])
        return response.projects
    }

    public func createSession(projectID: UUID, title: String) async throws -> MemorySession {
        let response: CreateSessionResponse = try await post([
            "action": "create_session",
            "project_id": projectID.uuidString,
            "title": title
        ])
        return response.session
    }

    public func saveMemory(
        projectID: UUID,
        sessionID: UUID? = nil,
        title: String,
        content: String,
        tags: [String] = [],
        importance: Int? = nil
    ) async throws -> MemoryItem {
        var body: [String: Any] = [
            "action": "save_memory",
            "project_id": projectID.uuidString,
            "title": title,
            "content": content,
            "tags": tags
        ]

        if let sessionID {
            body["session_id"] = sessionID.uuidString
        }

        if let importance {
            body["importance"] = importance
        }

        let response: SaveMemoryResponse = try await post(body)
        return response.memory
    }

    public func searchMemory(projectID: UUID, query: String) async throws -> [MemoryItem] {
        let response: SearchMemoryResponse = try await post([
            "action": "search_memory",
            "project_id": projectID.uuidString,
            "query": query
        ])
        return response.memories
    }

    public func saveSessionSummary(
        projectID: UUID,
        sessionID: UUID? = nil,
        summary: String,
        decisions: [String] = [],
        openTasks: [String] = [],
        filesDiscussed: [String] = [],
        nextSteps: [String] = [],
        importance: Int? = nil
    ) async throws -> MemorySessionSummary {
        var body: [String: Any] = [
            "action": "save_session_summary",
            "project_id": projectID.uuidString,
            "summary": summary,
            "decisions": decisions,
            "open_tasks": openTasks,
            "files_discussed": filesDiscussed,
            "next_steps": nextSteps
        ]

        if let sessionID {
            body["session_id"] = sessionID.uuidString
        }

        if let importance {
            body["importance"] = importance
        }

        let response: SaveSessionSummaryResponse = try await post(body)
        return response.session_summary
    }

    public func saveContextAfterApproval(
        projectID: UUID,
        sessionID: UUID? = nil,
        title: String,
        summary: String,
        decisions: [String] = [],
        openTasks: [String] = [],
        filesDiscussed: [String] = [],
        nextSteps: [String] = [],
        tags: [String] = [],
        importance: Int = 3
    ) async throws -> SaveContextAfterApprovalResponse {
        var body: [String: Any] = [
            "action": "save_context_after_approval",
            "project_id": projectID.uuidString,
            "title": title,
            "summary": summary,
            "decisions": decisions,
            "open_tasks": openTasks,
            "files_discussed": filesDiscussed,
            "next_steps": nextSteps,
            "tags": tags,
            "importance": importance,
            "metadata": [
                "source": "ios_virtual_mcp",
                "approved": true,
                "tool_name": "save_context_after_approval"
            ]
        ]

        if let sessionID {
            body["session_id"] = sessionID.uuidString
        }

        return try await post(body)
    }

    public func importSessionAfterApproval(
        projectID: UUID,
        title: String,
        content: String,
        source: String = "chatgpt_web",
        tags: [String] = [],
        importance: Int = 3
    ) async throws -> SaveContextAfterApprovalResponse {
        try await post([
            "action": "import_session_after_approval",
            "project_id": projectID.uuidString,
            "title": title,
            "content": content,
            "source": source,
            "tags": tags,
            "importance": importance,
            "metadata": [
                "source": "ios_session_import",
                "approved": true,
                "tool_name": "import_session_after_approval"
            ]
        ])
    }

    public func getProjectContext(projectID: UUID) async throws -> ProjectContext {
        try await post([
            "action": "get_project_context",
            "project_id": projectID.uuidString
        ])
    }

    private func post<T: Decodable>(_ body: [String: Any]) async throws -> T {
        let token = try await bearerTokenProvider()
        var request = URLRequest(url: functionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseMemoryClientError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            if let errorPayload = try? JSONDecoder().decode([String: String].self, from: data),
               let message = errorPayload["error"] {
                throw SupabaseMemoryClientError.serverError(message)
            }
            throw SupabaseMemoryClientError.serverError("Memory service failed with HTTP \(httpResponse.statusCode).")
        }

        return try decoder.decode(T.self, from: data)
    }
}

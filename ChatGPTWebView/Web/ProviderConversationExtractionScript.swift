import Foundation

enum ProviderConversationExtractionScript {
    static func make(provider: AIProvider) -> String {
        let providerIDs = javascriptArray([provider.id.rawValue])
        let providerNames = javascriptArray([provider.displayName])
        let providerURLs = javascriptArray([provider.startURL.absoluteString])

        return parts
            .joined(separator: "\n")
            .replacingOccurrences(of: "__CONTEXTPORT_PROVIDER_IDS__", with: providerIDs)
            .replacingOccurrences(of: "__CONTEXTPORT_PROVIDER_NAMES__", with: providerNames)
            .replacingOccurrences(of: "__CONTEXTPORT_PROVIDER_URLS__", with: providerURLs)
    }

    private static var parts: [String] {
        [
            scriptPart1,
            scriptPart2,
            scriptPart3,
            scriptPart4,
        ]
    }

    private static func javascriptArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

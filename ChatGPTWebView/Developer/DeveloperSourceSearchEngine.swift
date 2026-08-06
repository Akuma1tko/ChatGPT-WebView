import Foundation

enum DeveloperSourceSearchEngine {
    static func search(
        _ sources: [DeveloperSourceFile],
        query: String
    ) -> [DeveloperSourceSearchResult] {
        sources.compactMap { source in
            let metadata = [
                source.sessionTitle,
                source.pageURL,
                source.displayName,
                source.urlString ?? "",
                source.kind,
                source.metadataNote ?? "",
                source.loadError ?? ""
            ].joined(separator: "\n")

            let metadataMatched = metadata.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil

            var matchCount = 0
            var snippets: [String] = []

            if let content = source.content, !content.isEmpty {
                var searchStart = content.startIndex

                while searchStart < content.endIndex,
                      let range = content.range(
                        of: query,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: searchStart..<content.endIndex
                      ) {
                    matchCount += 1

                    if snippets.count < 12 {
                        snippets.append(makeSnippet(content: content, matchRange: range))
                    }

                    guard range.upperBound > searchStart else { break }
                    searchStart = range.upperBound

                    if matchCount >= 10_000 {
                        break
                    }
                }
            }

            guard metadataMatched || matchCount > 0 else { return nil }

            return DeveloperSourceSearchResult(
                source: source,
                matchCount: matchCount,
                snippets: snippets,
                metadataMatched: metadataMatched
            )
        }
        .sorted {
            if $0.matchCount == $1.matchCount {
                return $0.source.displayName.localizedCaseInsensitiveCompare($1.source.displayName) == .orderedAscending
            }
            return $0.matchCount > $1.matchCount
        }
    }

    private static func makeSnippet(content: String, matchRange: Range<String.Index>) -> String {
        let start = content.index(
            matchRange.lowerBound,
            offsetBy: -140,
            limitedBy: content.startIndex
        ) ?? content.startIndex
        let end = content.index(
            matchRange.upperBound,
            offsetBy: 220,
            limitedBy: content.endIndex
        ) ?? content.endIndex

        return String(content[start..<end])
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

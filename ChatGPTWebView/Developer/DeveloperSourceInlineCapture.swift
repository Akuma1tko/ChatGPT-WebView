import Foundation

private let developerInlineCaptureChunkCharacters = 64 * 1024

func loadBudgetedDeveloperInlineSources(
    from descriptors: [DeveloperDiscoveredSource],
    session: DeveloperWebViewSession,
    pageURL: String,
    budget: DeveloperSourceCaptureBudget
) async -> [DeveloperSourceFile] {
    let inlineDescriptors = descriptors.filter { $0.inlineSourceIndex != nil }
    guard !inlineDescriptors.isEmpty else { return [] }

    var combinedData = Data()
    var includedCount = 0
    var omittedCount = 0
    var notes: [String] = []

    for descriptor in inlineDescriptors {
        guard !Task.isCancelled else { break }
        guard let scriptIndex = descriptor.inlineSourceIndex else { continue }

        let result = await loadBudgetedDeveloperInlineScriptData(
            descriptor: descriptor,
            scriptIndex: scriptIndex,
            session: session,
            budget: budget
        )

        switch result {
        case .captured(let data):
            includedCount += 1
            let separator = "\n\n/* ===== ContextPort Inline Script \(scriptIndex + 1): \(descriptor.displayName) ===== */\n"
            combinedData.append(Data(separator.utf8))
            combinedData.append(data)
        case .omitted(let reason):
            omittedCount += 1
            notes.append("Inline Script \(scriptIndex + 1): \(reason)")
        }

        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let metadataLines = [
        "Combined inline scripts: \(includedCount)",
        "Inline scripts retained as metadata only: \(omittedCount)",
        "All captured inline script elements were reconstructed into one logical source file. Original script-element boundaries are marked by comments."
    ] + notes

    if combinedData.isEmpty {
        return [
            DeveloperSourceFile(
                id: "\(session.id)::combined-inline-javascript",
                sessionTitle: session.title,
                pageURL: pageURL,
                displayName: "Combined Inline JavaScript",
                urlString: nil,
                kind: "Inline JavaScript • Combined",
                content: nil,
                metadataNote: metadataLines.joined(separator: "\n"),
                resourceByteCount: nil,
                loadError: nil
            )
        ]
    }

    guard let content = String(data: combinedData, encoding: .utf8) else {
        return [
            DeveloperSourceFile(
                id: "\(session.id)::combined-inline-javascript",
                sessionTitle: session.title,
                pageURL: pageURL,
                displayName: "Combined Inline JavaScript",
                urlString: nil,
                kind: "Inline JavaScript • Combined",
                content: nil,
                metadataNote: metadataLines.joined(separator: "\n"),
                resourceByteCount: combinedData.count,
                loadError: DeveloperSourceInlineCaptureError.invalidUTF8.localizedDescription
            )
        ]
    }

    return [
        DeveloperSourceFile(
            id: "\(session.id)::combined-inline-javascript",
            sessionTitle: session.title,
            pageURL: pageURL,
            displayName: "Combined Inline JavaScript",
            urlString: nil,
            kind: "Inline JavaScript • Combined",
            content: content,
            metadataNote: metadataLines.joined(separator: "\n"),
            resourceByteCount: nil,
            loadError: nil
        )
    ]
}

private enum DeveloperInlineScriptDataResult {
    case captured(Data)
    case omitted(String)
}

private func loadBudgetedDeveloperInlineScriptData(
    descriptor: DeveloperDiscoveredSource,
    scriptIndex: Int,
    session: DeveloperWebViewSession,
    budget: DeveloperSourceCaptureBudget
) async -> DeveloperInlineScriptDataResult {
    let maximumBytes = DeveloperSourceCaptureBudget.maximumInlineSourceBytes
    let reportedCharacterCount = descriptor.inlineSourceCharacterCount ?? 0

    guard reportedCharacterCount <= maximumBytes else {
        await budget.recordOmission()
        return .omitted("The page reported \(reportedCharacterCount) UTF-16 characters, above the per-script capture limit.")
    }

    let reservation = await budget.reserve(upTo: maximumBytes)
    guard reservation > 0 else {
        await budget.recordOmission()
        return .omitted("The shared Developer Sources retention budget was already exhausted.")
    }

    do {
        let lengthScript = """
        (() => {
          const script = document.scripts[\(scriptIndex)];
          if (!script || script.src) return -1;
          return String(script.textContent || '').length;
        })();
        """
        let rawLength = try await session.webView.evaluateJavaScript(lengthScript)
        guard let number = rawLength as? NSNumber else {
            throw DeveloperSourceInlineCaptureError.scriptUnavailable
        }

        let characterCount = number.intValue
        guard characterCount >= 0 else {
            throw DeveloperSourceInlineCaptureError.scriptUnavailable
        }
        guard characterCount <= maximumBytes else {
            await budget.release(reservation: reservation, countAsOmission: true)
            return .omitted("The live script contains \(characterCount) UTF-16 characters, above the per-script capture limit.")
        }

        var data = Data()
        data.reserveCapacity(min(characterCount, reservation))

        var start = 0
        while start < characterCount {
            guard !Task.isCancelled else { throw CancellationError() }

            let end = min(start + developerInlineCaptureChunkCharacters, characterCount)
            let chunkScript = """
            (() => {
              const script = document.scripts[\(scriptIndex)];
              if (!script || script.src) return null;
              return String(script.textContent || '').slice(\(start), \(end));
            })();
            """
            let rawChunk = try await session.webView.evaluateJavaScript(chunkScript)
            guard let chunk = rawChunk as? String else {
                throw DeveloperSourceInlineCaptureError.scriptUnavailable
            }

            let chunkData = Data(chunk.utf8)
            guard data.count + chunkData.count <= reservation else {
                await budget.release(reservation: reservation, countAsOmission: true)
                return .omitted("Its UTF-8 representation exceeded the available per-script or shared retention budget.")
            }

            data.append(chunkData)
            start = end
            await Task.yield()
        }

        await budget.commit(reservation: reservation, actualBytes: data.count)
        return .captured(data)
    } catch is CancellationError {
        await budget.release(reservation: reservation)
        return .omitted("Capture was cancelled before the complete script was reconstructed.")
    } catch {
        await budget.release(reservation: reservation)
        return .omitted(error.localizedDescription)
    }
}

private enum DeveloperSourceInlineCaptureError: LocalizedError {
    case scriptUnavailable
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .scriptUnavailable:
            return "The inline script changed or disappeared before ContextPort could reconstruct it."
        case .invalidUTF8:
            return "The combined inline JavaScript could not be retained as UTF-8 text."
        }
    }
}

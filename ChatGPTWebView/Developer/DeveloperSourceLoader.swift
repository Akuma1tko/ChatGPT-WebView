import Foundation
import WebKit

func developerCookieHeader(for webView: WKWebView) async -> String? {
    let cookies = await withCheckedContinuation { continuation in
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            continuation.resume(returning: cookies)
        }
    }

    guard !cookies.isEmpty else { return nil }
    return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
}

func loadExternalDeveloperSources(
    _ descriptors: [DeveloperDiscoveredSource],
    sessionID: String,
    sessionTitle: String,
    pageURL: String,
    userAgent: String?,
    cookieHeader: String?
) async -> [DeveloperSourceFile] {
    let budget = DeveloperSourceCaptureBudget()
    return await loadExternalDeveloperSources(
        descriptors,
        sessionID: sessionID,
        sessionTitle: sessionTitle,
        pageURL: pageURL,
        userAgent: userAgent,
        cookieHeader: cookieHeader,
        budget: budget
    )
}

func loadExternalDeveloperSources(
    _ descriptors: [DeveloperDiscoveredSource],
    sessionID: String,
    sessionTitle: String,
    pageURL: String,
    userAgent: String?,
    cookieHeader: String?,
    budget: DeveloperSourceCaptureBudget
) async -> [DeveloperSourceFile] {
    guard !descriptors.isEmpty else { return [] }

    var loaded: [DeveloperSourceFile] = []
    loaded.reserveCapacity(descriptors.count)

    for descriptor in descriptors {
        guard !Task.isCancelled else { return loaded }

        loaded.append(
            await loadExternalDeveloperSource(
                descriptor,
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                pageURL: pageURL,
                userAgent: userAgent,
                cookieHeader: cookieHeader,
                budget: budget
            )
        )

        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    return loaded
}

private func loadExternalDeveloperSource(
    _ descriptor: DeveloperDiscoveredSource,
    sessionID: String,
    sessionTitle: String,
    pageURL: String,
    userAgent: String?,
    cookieHeader: String?,
    budget: DeveloperSourceCaptureBudget
) async -> DeveloperSourceFile {
    let sourceID = "\(sessionID)::\(descriptor.key)"

    guard let urlString = descriptor.url,
          let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: descriptor.url,
            kind: descriptor.kind,
            content: nil,
            metadataNote: nil,
            resourceByteCount: nil,
            loadError: "This source uses a non-HTTP URL and cannot be loaded by the source reader."
        )
    }

    if isSourceMapDescriptor(descriptor, url: url) {
        await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: urlString,
            kind: descriptor.kind,
            content: nil,
            metadataNote: "SourceMap retrieval was deferred to Step 4B so map probing, validation, and decoding remain isolated from the normal source-loading stages.",
            resourceByteCount: nil,
            loadError: nil
        )
    }

    let reservation = await budget.reserve(
        upTo: DeveloperSourceCaptureBudget.maximumExternalSourceBytes
    )
    guard reservation > 0 else {
        await budget.recordOmission()
        await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        return budgetMetadataOnlySource(
            sourceID: sourceID,
            descriptor: descriptor,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            note: "Source text was not loaded because the 32 MB Developer Sources refresh budget was already exhausted. URL and provenance were retained as metadata."
        )
    }

    do {
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue(pageURL, forHTTPHeaderField: "Referer")

        let loaded = try await loadDeveloperSourceWithTransientRetry(
            request,
            maximumBytes: reservation
        )
        let data = loaded.response.data
        let response = loaded.response.response

        if let httpResponse = response as? HTTPURLResponse {
            let sourceMapReferences = [
                httpResponse.value(forHTTPHeaderField: "SourceMap"),
                httpResponse.value(forHTTPHeaderField: "X-SourceMap")
            ].compactMap { $0 }

            await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences(
                sourceMapReferences,
                for: sourceID
            )

            if !(200...299).contains(httpResponse.statusCode) {
                throw DeveloperSourceLoadError.httpStatus(httpResponse.statusCode)
            }
        } else {
            await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        }

        let mimeType = response.mimeType?.lowercased() ?? ""
        if url.pathExtension.lowercased() == "wasm" || mimeType == "application/wasm" {
            await budget.release(reservation: reservation)
            return DeveloperSourceFile(
                id: sourceID,
                sessionTitle: sessionTitle,
                pageURL: pageURL,
                displayName: descriptor.displayName,
                urlString: urlString,
                kind: descriptor.kind,
                content: nil,
                metadataNote: "Binary WebAssembly resource reached a successful response and was retained as metadata-only evidence. ContextPort did not decode or execute it.",
                resourceByteCount: data.count,
                loadError: nil
            )
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw DeveloperSourceLoadError.notUTF8
        }

        await budget.commit(reservation: reservation, actualBytes: data.count)
        let retryNote = loaded.attemptCount == 1
            ? ""
            : " after \(loaded.attemptCount) bounded attempts"
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: urlString,
            kind: descriptor.kind,
            content: content,
            metadataNote: "External source text was downloaded sequentially through a bounded response reader\(retryNote).",
            resourceByteCount: nil,
            loadError: nil
        )
    } catch is CancellationError {
        await budget.release(reservation: reservation)
        await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: urlString,
            kind: descriptor.kind,
            content: nil,
            metadataNote: "Source capture was cancelled before the complete source body was retained.",
            resourceByteCount: nil,
            loadError: nil
        )
    } catch let boundedError as DeveloperSourceBoundedLoadError {
        await budget.release(reservation: reservation, countAsOmission: true)
        await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        let measured = boundedError.byteCount.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "an unknown size"
        return budgetMetadataOnlySource(
            sourceID: sourceID,
            descriptor: descriptor,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            note: "Source text was not retained because the response reached \(measured), above the available per-file or scan-wide capture budget. URL and provenance were retained as metadata."
        )
    } catch {
        await budget.release(reservation: reservation)
        await DeveloperSourceResponseMetadataRegistry.shared.recordSourceMapReferences([], for: sourceID)
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: urlString,
            kind: descriptor.kind,
            content: nil,
            metadataNote: nil,
            resourceByteCount: nil,
            loadError: error.localizedDescription
        )
    }
}

private struct DeveloperSourceRetryResult {
    let response: DeveloperSourceBoundedHTTPResponse
    let attemptCount: Int
}

private func loadDeveloperSourceWithTransientRetry(
    _ baseRequest: URLRequest,
    maximumBytes: Int
) async throws -> DeveloperSourceRetryResult {
    let timeoutSchedule: [TimeInterval] = [30, 45, 60]
    let retryDelays: [UInt64] = [500_000_000, 1_500_000_000]
    var lastError: Error?

    for (index, timeout) in timeoutSchedule.enumerated() {
        try Task.checkCancellation()

        var request = baseRequest
        request.timeoutInterval = timeout

        do {
            let boundedRequest = DeveloperSourceBoundedRequest(maximumBytes: maximumBytes)
            let response = try await boundedRequest.load(request)
            return DeveloperSourceRetryResult(
                response: response,
                attemptCount: index + 1
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
            let hasAnotherAttempt = index + 1 < timeoutSchedule.count
            guard hasAnotherAttempt, isTransientDeveloperSourceError(error) else {
                throw error
            }

            try await Task.sleep(nanoseconds: retryDelays[index])
        }
    }

    throw DeveloperSourceRetryError.exhausted(
        attempts: timeoutSchedule.count,
        lastError: lastError
    )
}

private func isTransientDeveloperSourceError(_ error: Error) -> Bool {
    let code: URLError.Code?
    if let urlError = error as? URLError {
        code = urlError.code
    } else {
        let nsError = error as NSError
        code = nsError.domain == NSURLErrorDomain
            ? URLError.Code(rawValue: nsError.code)
            : nil
    }

    guard let code else { return false }
    switch code {
    case .timedOut,
         .networkConnectionLost,
         .cannotConnectToHost,
         .cannotFindHost,
         .dnsLookupFailed,
         .resourceUnavailable:
        return true
    default:
        return false
    }
}

private func isSourceMapDescriptor(_ descriptor: DeveloperDiscoveredSource, url: URL) -> Bool {
    let path = url.path.lowercased()
    if path.hasSuffix(".map") { return true }
    return descriptor.kind.localizedCaseInsensitiveContains("source map")
}

private func budgetMetadataOnlySource(
    sourceID: String,
    descriptor: DeveloperDiscoveredSource,
    sessionTitle: String,
    pageURL: String,
    note: String
) -> DeveloperSourceFile {
    DeveloperSourceFile(
        id: sourceID,
        sessionTitle: sessionTitle,
        pageURL: pageURL,
        displayName: descriptor.displayName,
        urlString: descriptor.url,
        kind: descriptor.kind,
        content: nil,
        metadataNote: note,
        resourceByteCount: nil,
        loadError: nil
    )
}

private enum DeveloperSourceRetryError: LocalizedError {
    case exhausted(attempts: Int, lastError: Error?)

    var errorDescription: String? {
        switch self {
        case .exhausted(let attempts, let lastError):
            let detail = lastError?.localizedDescription ?? "Unknown network failure."
            return "The source request failed after \(attempts) bounded attempts. \(detail)"
        }
    }
}

private enum DeveloperSourceLoadError: LocalizedError {
    case httpStatus(Int)
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "Source request returned HTTP \(statusCode)."
        case .notUTF8:
            return "Source response is not valid UTF-8 text and was recorded without indexed content."
        }
    }
}

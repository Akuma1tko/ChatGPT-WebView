import Foundation

actor DeveloperSourceCaptureBudget {
    struct Snapshot: Sendable {
        let retainedBytes: Int
        let maximumBytes: Int
        let omittedTextCount: Int

        var remainingBytes: Int {
            max(0, maximumBytes - retainedBytes)
        }
    }

    static let maximumRetainedTextBytes = 32 * 1024 * 1024
    static let maximumExternalSourceBytes = 8 * 1024 * 1024
    static let maximumInlineSourceBytes = 2 * 1024 * 1024

    private let maximumBytes: Int
    private var retainedBytes = 0
    private var omittedTextCount = 0

    init(maximumBytes: Int = DeveloperSourceCaptureBudget.maximumRetainedTextBytes) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func reserve(upTo requestedBytes: Int) -> Int {
        guard requestedBytes > 0 else { return 0 }
        let available = max(0, maximumBytes - retainedBytes)
        let granted = min(requestedBytes, available)
        retainedBytes += granted
        return granted
    }

    func commit(reservation: Int, actualBytes: Int) {
        guard reservation > 0 else { return }
        let committed = max(0, min(actualBytes, reservation))
        retainedBytes = max(0, retainedBytes - (reservation - committed))
    }

    func release(reservation: Int, countAsOmission: Bool = false) {
        retainedBytes = max(0, retainedBytes - max(0, reservation))
        if countAsOmission {
            omittedTextCount += 1
        }
    }

    func recordOmission() {
        omittedTextCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            retainedBytes: retainedBytes,
            maximumBytes: maximumBytes,
            omittedTextCount: omittedTextCount
        )
    }
}

struct DeveloperSourceBoundedHTTPResponse {
    let data: Data
    let response: URLResponse
}

enum DeveloperSourceBoundedLoadError: LocalizedError {
    case responseTooLarge(Int)
    case missingResponse

    var byteCount: Int? {
        switch self {
        case .responseTooLarge(let byteCount):
            return byteCount
        case .missingResponse:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .responseTooLarge(let byteCount):
            return "The source response exceeded the bounded capture limit at \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))."
        case .missingResponse:
            return "The source request completed without a readable response."
        }
    }
}

final class DeveloperSourceBoundedRequest: NSObject, URLSessionDataDelegate {
    private let maximumBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<DeveloperSourceBoundedHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var data = Data()
    private var completed = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(1, maximumBytes)
        super.init()
    }

    func load(_ request: URLRequest) async throws -> DeveloperSourceBoundedHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility

                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: queue
                )
                let task = session.dataTask(with: request)

                lock.lock()
                if completed {
                    lock.unlock()
                    task.cancel()
                    session.invalidateAndCancel()
                    return
                }
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let expectedLength = response.expectedContentLength
        if expectedLength != NSURLSessionTransferSizeUnknown,
           expectedLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(
                .failure(
                    DeveloperSourceBoundedLoadError.responseTooLarge(Int(expectedLength))
                )
            )
            return
        }

        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive newData: Data
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }

        let nextCount = data.count + newData.count
        guard nextCount <= maximumBytes else {
            lock.unlock()
            dataTask.cancel()
            finish(
                .failure(
                    DeveloperSourceBoundedLoadError.responseTooLarge(nextCount)
                )
            )
            return
        }

        data.append(newData)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        let response = self.response
        let data = self.data
        lock.unlock()

        guard let response else {
            finish(.failure(DeveloperSourceBoundedLoadError.missingResponse))
            return
        }

        finish(.success(DeveloperSourceBoundedHTTPResponse(data: data, response: response)))
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<DeveloperSourceBoundedHTTPResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }

        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

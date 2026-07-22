// Transport abstraction so APIClient is testable on Linux without a live
// server or URLProtocol machinery: tests inject a mock transport.

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct HTTPResponseInfo: Sendable {
    public var statusCode: Int
    /// Header names lowercased.
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPTransport: Sendable {
    /// Buffered request/response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo)
    /// Streaming response body (SSE). Chunks arrive as they are received.
    func stream(_ request: URLRequest) async throws -> (
        AsyncThrowingStream<Data, Error>, HTTPResponseInfo
    )
}

public struct TransportError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) { self.message = message }
}

/// URLSession-backed transport. Streaming uses a data-task delegate rather
/// than URLSession.bytes so behavior is identical on Darwin and Linux.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: TransportError("non-HTTP response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), Self.info(from: http)))
            }
            task.resume()
        }
    }

    public func stream(_ request: URLRequest) async throws -> (
        AsyncThrowingStream<Data, Error>, HTTPResponseInfo
    ) {
        let delegate = StreamingDelegate()
        let session = URLSession(
            configuration: self.session.configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        let info = try await delegate.waitForResponse()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            delegate.continuation.withLock { $0 = continuation }
            delegate.flushBuffered()
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
        }
        return (stream, info)
    }

    static func info(from response: HTTPURLResponse) -> HTTPResponseInfo {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let name = key as? String, let val = value as? String {
                headers[name.lowercased()] = val
            }
        }
        return HTTPResponseInfo(statusCode: response.statusCode, headers: headers)
    }
}

/// Locked box for cross-thread mutation under Swift 6 strict concurrency.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation = Locked<AsyncThrowingStream<Data, Error>.Continuation?>(nil)
    private let buffered = Locked<[Data]>([])
    private let responseBox = Locked<CheckedContinuation<HTTPResponseInfo, Error>?>(nil)
    private let finished = Locked<Bool>(false)

    func waitForResponse() async throws -> HTTPResponseInfo {
        try await withCheckedThrowingContinuation { continuation in
            responseBox.withLock { $0 = continuation }
        }
    }

    func flushBuffered() {
        let chunks = buffered.withLock { chunks in
            defer { chunks = [] }
            return chunks
        }
        for chunk in chunks {
            continuation.withLock { $0 }?.yield(chunk)
        }
        if finished.withLock({ $0 }) {
            continuation.withLock { $0 }?.finish()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            responseBox.withLock { box in
                box?.resume(returning: URLSessionTransport.info(from: http))
                box = nil
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let continuation = continuation.withLock({ $0 }) {
            continuation.yield(data)
        } else {
            buffered.withLock { $0.append(data) }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        responseBox.withLock { box in
            box?.resume(throwing: error ?? TransportError("connection closed before response"))
            box = nil
        }
        finished.withLock { $0 = true }
        if let continuation = continuation.withLock({ $0 }) {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

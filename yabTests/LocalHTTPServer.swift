import Foundation
import Network
import Synchronization

/// Serves one HTML page over plain HTTP on a local port, for tests that need real
/// http navigation (WebKit treats `localhost` and `127.0.0.1` as different sites).
/// It records every request it gets.
final class LocalHTTPServer: Sendable {
    struct Request: Sendable {
        /// Like `/out?to=…`.
        var path: String
        /// Header names in lowercase.
        var headers: [String: String]
    }

    let port: UInt16
    private let listener: NWListener
    private let log: RequestLog

    var requests: [Request] {
        log.requests.withLock { $0 }
    }

    init(html: String) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let log = RequestLog()
        let body = Data(html.utf8)
        listener.newConnectionHandler = { [log] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data, let request = Self.parse(data) {
                    log.requests.withLock { $0.append(request) }
                }
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        let ready = ReadyContinuation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ready.set(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.take()?.resume()
                case .failed(let error): ready.take()?.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
        self.log = log
        self.port = listener.port?.rawValue ?? 0
    }

    deinit {
        listener.cancel()
    }

    private static func parse(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(path: String(requestLine[1]), headers: headers)
    }

    /// Shared with the connection handler, which cannot capture `self` during `init`.
    private final class RequestLog: Sendable {
        let requests = Mutex<[Request]>([])
    }

    /// Resumes the waiting `init` exactly once.
    private final class ReadyContinuation: Sendable {
        private let continuation = Mutex<CheckedContinuation<Void, any Error>?>(nil)

        func set(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation.withLock { $0 = continuation }
        }

        func take() -> CheckedContinuation<Void, any Error>? {
            continuation.withLock { $0.take() }
        }
    }
}

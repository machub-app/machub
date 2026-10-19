import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that receives the browser redirect at the end of Steam sign-in.
/// Loopback-only, random port, single `GET /callback`; anything else gets a 404. It never sees credentials,
/// only the signed OpenID assertion that is then re-verified with Steam.
final class LoopbackServer: @unchecked Sendable {
    enum Failure: Error { case couldNotStart(String), timedOut }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "machub.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// A callback that arrived before anyone waited for it.
    private var pending: [String: String]?
    private var finished = false
    let successPage: String

    private init(listener: NWListener, successPage: String) {
        self.listener = listener
        self.successPage = successPage
    }

    /// Starts listening and returns once the port is known.
    static func start(successPage: String) async throws -> (LoopbackServer, port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw Failure.couldNotStart(error.localizedDescription) }
        let server = LoopbackServer(listener: listener, successPage: successPage)
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take(), let port = listener.port?.rawValue { ready.resume(returning: port) }
                case .failed(let error):
                    if once.take() { ready.resume(throwing: Failure.couldNotStart(error.localizedDescription)) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }
            listener.start(queue: server.queue)
        }
        return (server, port)
    }

    /// Waits for `GET /callback?...` and returns its query items.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        if let pending = self.pending {
                            self.pending = nil
                            continuation.resume(returning: pending)
                        } else if self.finished {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            self.continuation = continuation
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll(); stop() }
            return try await group.next()!
        }
    }

    func stop() {
        queue.async {
            self.finished = true
            self.listener.cancel()
            self.continuation?.resume(throwing: CancellationError())
            self.continuation = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard request.hasPrefix("GET "), target.hasPrefix("/callback"),
                  let components = URLComponents(string: "http://127.0.0.1" + target)
            else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
            self.respond(connection, status: "200 OK", body: self.successPage)
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: params)
            } else {
                self.pending = params
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Thread-safe "first caller wins" flag for one-shot continuations.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

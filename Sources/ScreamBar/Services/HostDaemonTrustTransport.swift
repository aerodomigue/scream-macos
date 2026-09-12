import Foundation
import Security

/// One ephemeral, bounded HTTPS exchange; cancellation affects only this request.
final class HostDaemonTrustTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: Data
    }

    private static let REQUEST_TIMEOUT: TimeInterval = 15
    private static let MAX_RESPONSE_BYTES = 65_536
    private let endpoint: HostDaemonEndpoint
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var responseBody = Data()
    private var cancelled = false

    init(endpoint: HostDaemonEndpoint) { self.endpoint = endpoint }

    func perform(_ request: URLRequest) async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pendingContinuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    pendingContinuation.resume(throwing: CancellationError())
                    return
                }
                continuation = pendingContinuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = Self.REQUEST_TIMEOUT
                configuration.timeoutIntervalForResource = Self.REQUEST_TIMEOUT
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.waitsForConnectivity = false
                configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
                let requestSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let requestTask = requestSession.dataTask(with: request)
                session = requestSession
                task = requestTask
                lock.unlock()
                requestTask.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.lock.unlock()
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        validate(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        validate(challenge, completionHandler: completionHandler)
    }

    private func validate(_ challenge: URLAuthenticationChallenge,
                          completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let peerHost = challenge.protectionSpace.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              peerHost == endpoint.host, challenge.protectionSpace.port == endpoint.port,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(HostDaemonClientError.certificateRejected))
            return
        }
        do {
            try HostDaemonTrustValidator.evaluate(serverTrust, identity: endpoint.trust)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } catch {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(HostDaemonClientError.certificateRejected))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(HostDaemonClientError.redirectRejected))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(HostDaemonClientError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Self.MAX_RESPONSE_BYTES else {
            completionHandler(.cancel)
            finish(.failure(HostDaemonClientError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = httpResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.lock()
        guard bytes.count <= Self.MAX_RESPONSE_BYTES - responseBody.count else {
            lock.unlock()
            finish(.failure(HostDaemonClientError.responseTooLarge))
            return
        }
        responseBody.append(bytes)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let networkError = error as NSError
            finish(.failure(HostDaemonClientError.network(networkError.code)))
            return
        }
        lock.lock()
        let completedResponse = response
        let completedBody = responseBody
        lock.unlock()
        guard let completedResponse else {
            finish(.failure(HostDaemonClientError.invalidResponse))
            return
        }
        let contentType = completedResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        finish(.success(Response(status: completedResponse.statusCode, contentType: contentType, body: completedBody)))
    }

    private func finish(_ outcome: Result<Response, Error>) {
        lock.lock()
        guard let pendingContinuation = continuation else { lock.unlock(); return }
        continuation = nil
        let completedSession = session
        session = nil
        task = nil
        lock.unlock()
        completedSession?.invalidateAndCancel()
        pendingContinuation.resume(with: outcome)
    }
}

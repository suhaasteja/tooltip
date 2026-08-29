import Foundation

/// Intercepts every request on a session so the client can be exercised with no
/// network at all.
final class StubURLProtocol: URLProtocol {

    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub = Stub()
    nonisolated(unsafe) private static var _lastRequest: URLRequest?
    /// Bodies are stripped from `URLProtocol`'s copy of the request, so capture
    /// the stream separately.
    nonisolated(unsafe) private static var _lastBody: Data?

    static var stub: Stub {
        get { lock.withLock { _stub } }
        set { lock.withLock { _stub = newValue } }
    }
    static var lastRequest: URLRequest? { lock.withLock { _lastRequest } }
    static var lastBody: Data? { lock.withLock { _lastBody } }

    static func reset() {
        lock.withLock {
            _stub = Stub()
            _lastRequest = nil
            _lastBody = nil
        }
    }

    /// A session wired to this protocol and nothing else.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self._lastRequest = request
            Self._lastBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        }

        let stub = Self.stub
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

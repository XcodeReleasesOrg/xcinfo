import Foundation
import os

struct StubResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data = .init()
    var error: URLError?
    var isHanging = false

    static func json(_ string: String, statusCode: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(
            statusCode: statusCode,
            headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
            body: Data(string.utf8)
        )
    }

    static func failure(_ code: URLError.Code, userInfo: [String: any Sendable] = [:]) -> StubResponse {
        StubResponse(error: URLError(code, userInfo: userInfo))
    }
}

final class StubServer: Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    let requests = Recorder<URLRequest>()
    fileprivate let token = UUID().uuidString
    fileprivate let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
        StubURLProtocol.register(self)
    }

    deinit {
        StubURLProtocol.unregister(token)
    }

    func configuration(_ base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        base.protocolClasses = [StubURLProtocol.self]
        base.httpAdditionalHeaders = [StubURLProtocol.tokenHeader: token]
        return base
    }

    func session(delegate: URLSessionDelegate? = nil) -> URLSession {
        URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
    }

    func requests(to path: String) -> [URLRequest] {
        requests.values.filter { $0.url?.path == path }
    }
}

final class StubURLProtocol: URLProtocol {
    static let tokenHeader = "X-Stub-Token"
    private static let servers = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])

    fileprivate static func register(_ server: StubServer) {
        servers.withLock { $0[server.token] = server }
    }

    fileprivate static func unregister(_ token: String) {
        _ = servers.withLock { $0.removeValue(forKey: token) }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = recordedRequest.httpBodyStream {
            recordedRequest.httpBody = Data(reading: stream)
        }
        guard
            let token = request.value(forHTTPHeaderField: Self.tokenHeader),
            let server = Self.servers.withLock({ $0[token] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        server.requests.append(recordedRequest)
        let stub = server.handler(recordedRequest)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        if !stub.isHanging {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}

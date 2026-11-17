import Foundation
import Testing
import XCModel
@testable import xcinfoCore

struct XCReleasesAPITests {
    private let baseURL = URL(string: "https://xcodereleases.example.invalid/data.json")!

    @Test
    func `list decodes the xcodes from the response`() async throws {
        let xcodes = [
            Xcode.fixture("15.0", build: "15A240d"),
            Xcode.fixture("15.1", build: "15C5028h", release: .beta(1)),
        ]
        let body = try JSONEncoder().encode(xcodes)
        let server = StubServer { _ in StubResponse(body: body) }
        let api = XCReleasesAPI(baseURL: baseURL, session: server.session())

        let result = try await api.listXcodes()

        #expect(result.map(\.version.build) == ["15A240d", "15C5028h"])
        #expect(server.requests.values.map(\.url) == [baseURL])
    }

    @Test(arguments: [199, 300, 404, 500])
    func `list rejects a non-success status code`(statusCode: Int) async throws {
        let server = StubServer { _ in .json("[]", statusCode: statusCode) }
        let api = XCReleasesAPI(baseURL: baseURL, session: server.session())

        await #expect {
            try await api.listXcodes()
        } throws: { error in
            guard case XCAPIError.invalidResponse = error else { return false }
            return true
        }
    }

    @Test
    func `list fails on malformed json`() async throws {
        let server = StubServer { _ in .json("{ not json") }
        let api = XCReleasesAPI(baseURL: baseURL, session: server.session())

        await #expect(throws: DecodingError.self) {
            try await api.listXcodes()
        }
    }

    @Test
    func `list fails when the request fails`() async throws {
        let server = StubServer { _ in .failure(.notConnectedToInternet) }
        let api = XCReleasesAPI(baseURL: baseURL, session: server.session())

        await #expect(throws: URLError.self) {
            try await api.listXcodes()
        }
    }

    @Test
    func `remove cookies empties the session cookie storage`() throws {
        let server = StubServer { _ in StubResponse() }
        let session = server.session()
        let storage = try #require(session.configuration.httpCookieStorage)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "example.invalid",
            .path: "/",
            .name: "token",
            .value: "1",
        ]))
        storage.setCookie(cookie)
        #expect(storage.cookies?.isEmpty == false)

        XCReleasesAPI(baseURL: baseURL, session: session).apiClient.removeCookies()

        #expect(storage.cookies?.isEmpty ?? true)
    }
}

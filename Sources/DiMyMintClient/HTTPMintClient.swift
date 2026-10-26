import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DiMyPaymentTypes

public enum MintClientEnvironment {
    public static func defaultBaseURL(from processInfo: ProcessInfo = .processInfo) -> URL? {
        guard let raw = processInfo.environment["DIMY_MINT_BASE_URL"], !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    public static func internalToken(from processInfo: ProcessInfo = .processInfo) -> String? {
        guard let raw = processInfo.environment["DIMY_MINT_INTERNAL_TOKEN"] else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

public actor MintClientRegistry {
    public static let shared = MintClientRegistry()

    private var factory: @Sendable () -> any MintClient

    public init() {
        factory = {
            if let baseURL = MintClientEnvironment.defaultBaseURL() {
                return HTTPMintClient(baseURL: baseURL)
            }
            return InMemoryMintClient()
        }
    }

    public func setFactory(_ factory: @escaping @Sendable () -> any MintClient) {
        self.factory = factory
    }

    public func makeClient() -> any MintClient {
        factory()
    }

    public func useEnvironmentDefault() {
        factory = {
            if let baseURL = MintClientEnvironment.defaultBaseURL() {
                return HTTPMintClient(baseURL: baseURL)
            }
            return InMemoryMintClient()
        }
    }
}

public actor HTTPMintClient: MintClient {
    private let baseURL: URL
    private let session: URLSession
    private let internalToken: String?

    public init(baseURL: URL, session: URLSession = .shared, internalToken: String? = MintClientEnvironment.internalToken()) {
        self.baseURL = baseURL
        self.session = session
        self.internalToken = internalToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func issue(_ request: IssueRequest) async throws -> IssueResponse {
        try await post(path: "issue", body: request, as: IssueResponse.self)
    }

    public func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        try await post(path: "redeem", body: request, as: RedeemResponse.self)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        as responseType: Response.Type
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let internalToken, !internalToken.isEmpty {
            request.setValue(internalToken, forHTTPHeaderField: "X-DiMy-Mint-Token")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MintClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw MintClientError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(responseType, from: data)
    }
}

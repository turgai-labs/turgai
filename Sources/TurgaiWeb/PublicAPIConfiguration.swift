import HTTPTypes
import Hummingbird

public enum APIAuthMode: String, Codable, Sendable {
    case local
    case apiKey = "api-key"
    case trustedProxy = "trusted-proxy"
}

public struct APIConfiguration: Sendable {
    public let authMode: APIAuthMode
    private let apiKey: String?

    public init(authMode: APIAuthMode = .local, apiKey: String? = nil) {
        self.authMode = authMode
        self.apiKey = apiKey
    }

    func authorizes(_ request: Request) -> Bool {
        switch authMode {
        case .local, .trustedProxy:
            return true
        case .apiKey:
            guard let authorizationName = HTTPField.Name("Authorization"),
                let authorization = request.headers[authorizationName],
                let apiKey,
                authorization.hasPrefix("Bearer ")
            else { return false }
            return String(authorization.dropFirst("Bearer ".count)) == apiKey
        }
    }
}

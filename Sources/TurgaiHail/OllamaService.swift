import AsyncHTTPClient
import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct OllamaConfiguration: Sendable, Equatable {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

public enum OllamaServiceError: Error, Sendable, Equatable {
    case requestFailed(String)
    case unexpectedStatus(Int)
    case invalidResponse
}

/// Client for Ollama's control-plane API.
///
/// This is deliberately a value, not an actor: it owns no mutable state. It
/// centralizes model discovery and metadata requests. Generation is routed
/// through Hail's AnyLanguageModel adapter.
public struct OllamaService: Sendable {
    public let configuration: OllamaConfiguration

    public init(configuration: OllamaConfiguration) {
        self.configuration = configuration
    }

    public func models() async throws(OllamaServiceError) -> [AgentModelID] {
        let data = try await request(path: "api/tags", method: "GET")
        let response: TagsResponse
        do {
            response = try JSONDecoder().decode(TagsResponse.self, from: data)
        } catch {
            throw .invalidResponse
        }
        return response.models
            .compactMap { model in
                let name = model.name.trimmed()
                return name.isEmpty ? nil : AgentModelID(rawValue: name)
            }
            .sorted { $0.rawValue.lowercased() < $1.rawValue.lowercased() }
    }

    public func contextWindow(for model: AgentModelID) async throws(OllamaServiceError) -> Int {
        do {
            return try await OllamaContextWindowProvider.resolve(
                model: model.rawValue,
                baseURL: configuration.baseURL
            )
        } catch {
            throw .requestFailed(String(describing: error))
        }
    }

    private func request(
        path: String,
        method: String
    ) async throws(OllamaServiceError) -> Data {
        var request = HTTPClientRequest(url: configuration.baseURL.appendingPathComponent(path).absoluteString)
        request.method = .init(rawValue: method)
        do {
            let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
            guard (200..<300).contains(response.status.code) else {
                throw OllamaServiceError.unexpectedStatus(Int(response.status.code))
            }
            let body = try await response.body.collect(upTo: Self.maximumResponseBytes)
            return Data(body.readableBytesView)
        } catch let error as OllamaServiceError {
            throw error
        } catch {
            throw .requestFailed(String(describing: error))
        }
    }

    /// The most of an answer that's read.
    private static let maximumResponseBytes = 16 * 1024 * 1024

    private struct TagsResponse: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        let name: String
    }
}

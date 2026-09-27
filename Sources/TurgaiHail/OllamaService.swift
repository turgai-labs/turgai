import Hail

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
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : AgentModelID(rawValue: name)
            }
            .sorted { $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == .orderedAscending }
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
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw OllamaServiceError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw OllamaServiceError.unexpectedStatus(response.statusCode)
            }
            return data
        } catch let error as OllamaServiceError {
            throw error
        } catch {
            throw .requestFailed(String(describing: error))
        }
    }

    private struct TagsResponse: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        let name: String
    }
}

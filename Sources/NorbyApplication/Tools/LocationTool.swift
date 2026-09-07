import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Resolves a human place name into data needed by other tools.
///
/// The tool deliberately has no profile or conversation storage. The agent
/// supplies the place it already knows from the conversation or memory, and
/// receives a typed geographic result that can be used by a following tool.
public struct LocationTool: Tool {
    public typealias Effect = LocationEffect

    public struct Input: Codable, Sendable {
        public let query: String

        public init(query: String) {
            self.query = query
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyQuery
        case queryTooLong
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case locationNotFound(String)
    }

    public let name = "location"
    public let description =
        "Resolve a place name into coordinates and its IANA time zone. Use the place you know from the conversation or memory. Use the returned time_zone with now, weather, timers, or schedules; this tool does not save the location."

    public init() {}

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "query": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "A city, place, or postal code, preferably with a country or region when ambiguous.",
                            enumValues: nil
                        )
                    ],
                    required: ["query"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> Effect {
        let query = try validatedQuery(input.query)
        var components = URLComponents(
            string: "https://geocoding-api.open-meteo.com/v1/search"
        )!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw Error.invalidURL
        }
        return LocationEffect(
            query: query,
            network: NetworkEffect(
                host: "geocoding-api.open-meteo.com",
                operation: "geocode",
                request: NetworkRequest(
                    url: url.absoluteString,
                    headers: [
                        "User-Agent": "Norby/1.0 (+https://github.com/akbashev/norby)",
                        "Accept": "application/json",
                    ],
                    maximumResponseBytes: 128 * 1024
                )
            )
        )
    }

    public func run(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> String {
        let results = try await LocationEffect.run(in: token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(results)
        guard let output = String(data: data, encoding: .utf8) else {
            throw Error.invalidResponse
        }
        return output
    }

    private func validatedQuery(_ value: String) throws -> String {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw Error.emptyQuery }
        guard query.count <= 200 else { throw Error.queryTooLong }
        return query
    }

}

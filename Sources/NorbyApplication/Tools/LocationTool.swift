import AnyLanguageModel
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
@Tool
public struct LocationTool {
    public typealias Effect = LocationEffect

    @Generable
    public struct Input: Sendable {
        public let query: String
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

/// The semantic capability to resolve one place supplied by the agent.
///
/// The effect carries intent; the composed network effect authorizes the
/// provider call that interprets it. It does not persist or imply a current
/// user location.
public struct LocationEffect: CompositeScopedEffect, Sendable {

    public let name = "location"
    public let query: String
    public let network: NetworkEffect

    public struct Result: Codable, Sendable, Equatable {
        public let name: String
        public let region: String?
        public let country: String?
        public let latitude: Double
        public let longitude: Double
        public let timeZone: String

        private enum CodingKeys: String, CodingKey {
            case name
            case region
            case country
            case latitude
            case longitude
            case timeZone = "time_zone"
        }

        public init(
            name: String,
            region: String?,
            country: String?,
            latitude: Double,
            longitude: Double,
            timeZone: String
        ) {
            self.name = name
            self.region = region
            self.country = country
            self.latitude = latitude
            self.longitude = longitude
            self.timeZone = timeZone
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidResponse
        case httpStatus(Int)
        case locationNotFound(String)
    }

    public init(
        query: String,
        network: NetworkEffect
    ) {
        self.query = query
        self.network = network
    }

    public func decision(using authority: any Authority) -> EffectDecision {
        authority.decision(on: network)
    }

    public static func run(
        in token: borrowing EffectToken<LocationEffect>
    ) async throws -> [Result] {
        let configuration = token.withConfiguration { ($0.query, $0.network) }
        let response = try await token.withChild(configuration.1) { networkToken in
            try await NetworkEffect.run(in: networkToken)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Error.httpStatus(response.statusCode)
        }

        struct Response: Decodable {
            let results: [Place]?
        }

        struct Place: Decodable {
            let name: String
            let country: String?
            let admin1: String?
            let latitude: Double
            let longitude: Double
            let timezone: String?
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw Error.invalidResponse
        }

        let places = decoded.results ?? []
        let results = places.compactMap { place -> Result? in
            guard let timezone = place.timezone,
                TimeZone(identifier: timezone) != nil
            else {
                return nil
            }
            return Result(
                name: place.name,
                region: place.admin1,
                country: place.country,
                latitude: place.latitude,
                longitude: place.longitude,
                timeZone: timezone
            )
        }
        guard !results.isEmpty else {
            throw Error.locationNotFound(configuration.0)
        }
        return results
    }
}

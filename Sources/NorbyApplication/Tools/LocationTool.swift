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
@Tool(
    "location",
    description:
        "Resolve a city, town, or place name into coordinates and its IANA time zone. Pass the actual place name separately from optional region and country fields; use region for a state, province, county, or Landkreis such as Landkreis München. Use the returned time_zone with now, weather, timers, or schedules; this tool does not save the location."
)
public struct LocationTool {
    public typealias Effect = LocationEffect

    @Generable
    public struct Input: Sendable {
        @Guide(description: "The actual city, town, or place name, such as Haar or Munich.")
        public let place: String
        @Guide(
            description:
                "An optional state, province, county, or Landkreis used to distinguish places with the same name.")
        public let region: String?
        @Guide(description: "An optional country name used to disambiguate the place.")
        public let country: String?
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyQuery
        case queryTooLong
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case locationNotFound(String)
    }

    public init() {}

    public func effect(for input: Input) throws -> Effect {
        let place = try validatedPlace(input.place)
        let region = try validatedRegion(input.region)
        let country = try validatedCountry(input.country)
        var components = URLComponents(
            string: "https://geocoding-api.open-meteo.com/v1/search"
        )!
        components.queryItems = [
            URLQueryItem(name: "name", value: place),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw Error.invalidURL
        }
        return LocationEffect(
            query: place,
            region: region,
            country: country,
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

    public func runOutput(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> ToolOutput {
        let results = try await LocationEffect.run(in: token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(results)
        guard let output = String(data: data, encoding: .utf8) else {
            throw Error.invalidResponse
        }
        return .text(output)
    }

    private func validatedPlace(_ value: String) throws -> String {
        let place = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { throw Error.emptyQuery }
        guard place.count <= 200 else { throw Error.queryTooLong }
        return place
    }

    private func validatedCountry(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let country = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !country.isEmpty else { return nil }
        guard country.count <= 100 else { throw Error.queryTooLong }
        return country
    }

    private func validatedRegion(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let region = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else { return nil }
        guard region.count <= 200 else { throw Error.queryTooLong }
        return region
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
    public let region: String?
    public let country: String?
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
        region: String? = nil,
        country: String? = nil,
        network: NetworkEffect
    ) {
        self.query = query
        self.region = region
        self.country = country
        self.network = network
    }

    public var childEffects: [any ScopedEffect] {
        [network]
    }

    public static func run(
        in token: borrowing EffectToken<LocationEffect>
    ) async throws -> [Result] {
        let configuration = token.withConfiguration { ($0.query, $0.region, $0.country, $0.network) }
        let response = try await token.withChild(configuration.3) { networkToken in
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
            let admin2: String?
            let admin3: String?
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
        let matchingPlaces = places.filter { place in
            let countryMatches: Bool
            if let country = configuration.2 {
                countryMatches = place.country?.localizedCaseInsensitiveContains(country) == true
            } else {
                countryMatches = true
            }
            guard countryMatches else { return false }

            guard let region = configuration.1 else { return true }
            return [place.admin1, place.admin2, place.admin3].compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(region)
            }
        }
        let results = matchingPlaces.compactMap { place -> Result? in
            guard let timezone = place.timezone,
                TimeZone(identifier: timezone) != nil
            else {
                return nil
            }
            return Result(
                name: place.name,
                region: place.admin3 ?? place.admin2 ?? place.admin1,
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

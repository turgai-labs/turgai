import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The semantic capability to resolve one place supplied by the agent.
///
/// The effect carries intent; the composed network effect authorizes the
/// provider call that interprets it. It does not persist or imply a current
/// user location.
public struct LocationEffect: CompositeScopedEffect, Sendable {
    public typealias Output = [Result]

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

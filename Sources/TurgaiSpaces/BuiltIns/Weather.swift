import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import VirtualActors

/// Live weather for a place, from Open-Meteo.
@Discoverable
@VirtualActor
public distributed actor Weather {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = SpaceID

    /// The space whose it is.
    private let space: SpaceID

    /// `space`'s weather, wherever and whenever it runs.
    public static func of(_ space: SpaceID, on actorSystem: ClusterSystem) async throws -> Weather {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: .owned(by: space, "builtin", "weather"), dependency: space)
    }

    public init(actorSystem: ActorSystem, dependency space: SpaceID) async throws {
        self.actorSystem = actorSystem
        self.space = space
    }

    /// It holds nothing: idle, it stops, and a call starts it again.
    public func shouldDeactivate() async -> Bool { true }

    /// The weather at a place now.
    /// - Parameters:
    ///   - place: The city, town or place's name.
    ///   - region: Its state, province or county, for a name places share.
    ///   - country: Its country, for a name places share.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func current(place: String, region: String? = nil, country: String? = nil) async throws
        -> WeatherReport
    {
        try await report(try Self.effect(place, region, country, .current))
    }

    /// The rest of today at a place, hour by hour from the current hour.
    /// - Parameters:
    ///   - place: The city, town or place's name.
    ///   - region: Its state, province or county, for a name places share.
    ///   - country: Its country, for a name places share.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func hourly(place: String, region: String? = nil, country: String? = nil) async throws
        -> WeatherReport
    {
        try await report(try Self.effect(place, region, country, .hourly))
    }

    /// The days ahead at a place: each day's high and low, conditions and chance of precipitation.
    /// - Parameters:
    ///   - place: The city, town or place's name.
    ///   - region: Its state, province or county, for a name places share.
    ///   - country: Its country, for a name places share.
    ///   - days: How many days, from 1 through 7.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func daily(place: String, region: String? = nil, country: String? = nil, days: Int)
        async throws -> WeatherReport
    {
        guard (1...7).contains(days) else { throw ToolError.invalidArgument("days", value: String(days)) }
        return try await report(try Self.effect(place, region, country, .daily(days: days)))
    }

    /// The weather `horizon` asks for at a place: its geocoding, the clock and its forecast.
    static func effect(_ place: String, _ region: String?, _ country: String?, _ horizon: WeatherEffect.Horizon)
        throws -> WeatherEffect
    {
        WeatherEffect(
            geocoding: try WeatherSupport.geocodingEffect(
                place: try WeatherSupport.validatedPlace(place),
                region: try WeatherSupport.validatedRegion(region),
                country: try WeatherSupport.validatedCountry(country)),
            clock: ClockEffect(),
            horizon: horizon)
    }

    /// The report, its requests decided on behalf of whoever the call is for, by what decides every
    /// effect on the node it runs on.
    private func report(_ effect: WeatherEffect) async throws -> WeatherReport {
        let authority = await actorSystem.agentRuntime.authority(actorSystem)
        return try await withEffect(effect, authority: authority) { token in
            try await WeatherEffect.run(in: token)
        }
    }
}

/// Read by everyone and written by no one, as any built-in object.
extension Weather: AccessControlled {
    /// Everyone in its space may use it, and no one from another.
    public distributed func access(for chain: CallChain) -> Access {
        .readByEveryone
    }
}

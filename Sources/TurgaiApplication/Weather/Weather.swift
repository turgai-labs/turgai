import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiObjects
import VirtualActors

/// Live weather for a place, from Open-Meteo.
@Discoverable
@VirtualActor
public distributed actor Weather {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = ObjectIdentity

    public init(actorSystem: ActorSystem, dependency: ObjectIdentity) async throws {
        self.actorSystem = actorSystem
    }

    /// The one weather, by the id it always has: a reference to it reaches it after any restart.
    public static func resolve(on actorSystem: ClusterSystem) async throws -> Weather {
        try await actorSystem.virtualActors.getActor(identifiedBy: actorID, dependency: identity)
    }

    /// Starts it, and lists it among the objects by its lasting reference.
    public static func start(on actorSystem: ClusterSystem) async throws {
        let weather = try await resolve(on: actorSystem)
        let object = try DiscoverableObject.resolve(id: weather.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    static let identity = ObjectIdentity(rawValue: "weather")
    static let actorID = VirtualActorID(rawValue: "builtin/weather")

    /// It's there for as long as its node runs: what holds it finds it.
    public func shouldDeactivate() async -> Bool { false }

    /// The weather at a place now.
    /// - Parameters:
    ///   - place: The city, town or place's name.
    ///   - region: Its state, province or county, for a name places share.
    ///   - country: Its country, for a name places share.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func current(place: String, region: String? = nil, country: String? = nil) async throws
        -> WeatherReport
    {
        try await Self.report(try Self.effect(place, region, country, .current))
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
        try await Self.report(try Self.effect(place, region, country, .hourly))
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
        return try await Self.report(try Self.effect(place, region, country, .daily(days: days)))
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

    /// The report, its requests decided on behalf of whoever the call is for.
    private static func report(_ effect: WeatherEffect) async throws -> WeatherReport {
        try await withEffect(effect, authority: TurgaiAuthority()) { token in
            try await WeatherEffect.run(in: token)
        }
    }
}

/// Read by everyone and written by no one, as any built-in object.
extension Weather: AccessControlled {
    public func access(for chain: CallChain) -> Access { .readByEveryone }
}

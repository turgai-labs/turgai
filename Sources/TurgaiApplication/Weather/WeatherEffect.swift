import DiscoverableActors
import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// One weather capability, declared as what it needs: geocoding, the clock,
/// and (spawned dynamically, once coordinates exist) one Open-Meteo request.
/// Being composite, the effect introduces no authority domain of its own —
/// its decision derives from the declared components.
public struct WeatherEffect: CompositeScopedEffect, Sendable {
    public enum Horizon: Sendable, Equatable {
        case current
        case hourly
        case daily(days: Int)
    }

    public let name = "weather"
    public let geocoding: LocationEffect
    public let clock: ClockEffect
    public let horizon: Horizon

    public init(geocoding: LocationEffect, clock: ClockEffect, horizon: Horizon) {
        self.geocoding = geocoding
        self.clock = clock
        self.horizon = horizon
    }

    public var childEffects: [any ScopedEffect] {
        [geocoding, clock]
    }

    public static func run(
        in token: borrowing EffectToken<WeatherEffect>
    ) async throws -> WeatherReport {
        let configuration = token.withConfiguration { $0 }
        let places = try await token.withChild(configuration.geocoding) { locationToken in
            try await LocationEffect.run(in: locationToken)
        }
        // LocationEffect.run guarantees a non-empty result.
        guard let location = places.first else {
            throw LocationEffect.Error.locationNotFound(configuration.geocoding.query)
        }
        let now = try await token.withChild(configuration.clock) { clockToken in
            try await ClockEffect.run(in: clockToken)
        }
        // The forecast request is genuinely dynamic: its coordinates only
        // exist after geocoding. The spawned child is checked against the
        // same authority at spawn time.
        let forecastRequest = try WeatherSupport.forecastEffect(
            latitude: location.latitude,
            longitude: location.longitude,
            horizon: configuration.horizon
        )
        let response = try await token.withChild(forecastRequest) { networkToken in
            try await NetworkEffect.run(in: networkToken)
        }
        return try WeatherSupport.makeReport(
            location: location,
            forecast: WeatherSupport.decodeForecast(response),
            horizon: configuration.horizon,
            now: now
        )
    }
}

/// The weather pipeline the Weather object's actions share: Open-Meteo's requests and answers.
public enum WeatherSupport {
    static let maximumResponseBytes = 512 * 1024
    static let userAgent = "Turgai/1.0 (+https://github.com/akbashev/turgai)"

    static func forecastEffect(
        latitude: Double,
        longitude: Double,
        horizon: WeatherEffect.Horizon
    ) throws -> NetworkEffect {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(
                name: "current",
                value:
                    "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m"
            ),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        switch horizon {
        case .current:
            break
        case .hourly:
            components.queryItems?.append(
                URLQueryItem(name: "timeformat", value: "unixtime")
            )
            components.queryItems?.append(
                URLQueryItem(
                    name: "hourly",
                    value:
                        "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m"
                )
            )
            components.queryItems?.append(URLQueryItem(name: "forecast_days", value: "1"))
        case .daily(let days):
            components.queryItems?.append(
                URLQueryItem(
                    name: "daily",
                    value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
                )
            )
            components.queryItems?.append(
                URLQueryItem(name: "forecast_days", value: String(days))
            )
        }
        guard let url = components.url else { throw Error.invalidURL }
        return NetworkEffect(
            host: "api.open-meteo.com",
            operation: "weather",
            request: NetworkRequest(
                url: url.absoluteString,
                headers: [
                    "User-Agent": userAgent,
                    "Accept": "application/json",
                ],
                maximumResponseBytes: maximumResponseBytes
            )
        )
    }

    static func decodeForecast(
        _ response: NetworkResponse
    ) throws -> ForecastResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw Error.httpStatus(response.statusCode)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(
                ForecastResponse.self,
                from: response.body
            )
        } catch {
            throw Error.invalidResponse
        }
    }

    static func makeReport(
        location: LocationEffect.Result,
        forecast: ForecastResponse,
        horizon: WeatherEffect.Horizon,
        now: Date
    ) throws -> WeatherReport {
        guard let timeZone = TimeZone(identifier: forecast.timezone) else {
            throw Error.invalidResponse
        }

        let localNow = try localDateTime(now, in: timeZone)
        let current = WeatherCurrent(
            temperatureCelsius: forecast.current.temperature,
            apparentTemperatureCelsius: forecast.current.apparentTemperature,
            relativeHumidityPercent: forecast.current.relativeHumidity,
            precipitationMillimeters: forecast.current.precipitation,
            weatherCode: forecast.current.weatherCode,
            condition: condition(forecast.current.weatherCode),
            windSpeedKilometersPerHour: forecast.current.windSpeed,
            windDirectionDegrees: forecast.current.windDirection,
            windDirection: compassDirection(forecast.current.windDirection)
        )

        let hourly: [WeatherHourlyPoint]
        let daily: [WeatherDailyPoint]
        let fromLocalHour: Int?
        switch horizon {
        case .current:
            hourly = []
            daily = []
            fromLocalHour = nil
        case .hourly:
            let startHour = localNow.hour
            fromLocalHour = startHour
            if let source = forecast.hourly {
                hourly = try source.points
                    .map { try makeHourlyPoint($0, in: timeZone) }
                    .filter { $0.localTime.hour >= startHour }
            } else {
                hourly = []
            }
            daily = []
        case .daily(let days):
            fromLocalHour = nil
            hourly = []
            if let source = forecast.daily {
                daily = source.points.prefix(days).map { point in
                    WeatherDailyPoint(
                        date: point.date,
                        weatherCode: point.weatherCode,
                        condition: condition(point.weatherCode),
                        maximumTemperatureCelsius: point.maximumTemperature,
                        minimumTemperatureCelsius: point.minimumTemperature,
                        precipitationProbabilityPercent: point.precipitationProbability
                    )
                }
            } else {
                daily = []
            }
        }

        return WeatherReport(
            location: WeatherLocation(
                name: location.name,
                region: location.region,
                country: location.country,
                latitude: location.latitude,
                longitude: location.longitude
            ),
            timezone: forecast.timezone,
            toolNow: now,
            localNow: localNow,
            requestedDays: horizon.days,
            fromLocalHour: fromLocalHour,
            current: current,
            hourly: hourly,
            daily: daily,
            source: "Open-Meteo"
        )
    }

    static func validatedPlace(_ value: String) throws -> String {
        let place = value.trimmed()
        guard !place.isEmpty else {
            throw ToolError.invalidArgument("place", value: value)
        }
        guard place.count <= 200 else {
            throw ToolError.invalidArgument("place", value: "place is too long")
        }
        return place
    }

    static func validatedCountry(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let country = value.trimmed()
        guard !country.isEmpty else { return nil }
        guard country.count <= 100 else {
            throw ToolError.invalidArgument("country", value: "country is too long")
        }
        return country
    }

    static func validatedRegion(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let region = value.trimmed()
        guard !region.isEmpty else { return nil }
        guard region.count <= 200 else { throw ToolError.invalidArgument("region", value: region) }
        return region
    }

    static func geocodingEffect(
        place: String,
        region: String?,
        country: String?
    ) throws -> LocationEffect {
        try LocationTool().effect(
            for: LocationToolInput(place: place, region: region, country: country)
        )
    }

    private static func makeHourlyPoint(
        _ point: Hourly.Point,
        in timeZone: TimeZone
    ) throws -> WeatherHourlyPoint {
        WeatherHourlyPoint(
            localTime: try localDateTime(point.time, in: timeZone),
            temperatureCelsius: point.temperature,
            apparentTemperatureCelsius: point.apparentTemperature,
            precipitationProbabilityPercent: point.precipitationProbability,
            condition: condition(point.weatherCode),
            windSpeedKilometersPerHour: point.windSpeed,
            windDirection: compassDirection(point.windDirection)
        )
    }

    private static func localDateTime(
        _ date: Date,
        in timeZone: TimeZone
    ) throws -> LocalDateTime {
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: timeZone, from: date)
        guard let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour,
            let minute = components.minute,
            let weekday = components.weekday
        else {
            throw Error.invalidResponse
        }

        return LocalDateTime(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            weekday: weekday
        )
    }

    private static func compassDirection(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees + 22.5) / 45.0) % directions.count
        return directions[index]
    }

    static func condition(_ code: Int) -> String {
        switch code {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51...57: "drizzle"
        case 61...67: "rain"
        case 71...77: "snow"
        case 80...82: "rain showers"
        case 85...86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unknown conditions"
        }
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
    }

    struct ForecastResponse: Decodable {
        let timezone: String
        let current: Current
        let daily: Daily?
        let hourly: Hourly?
    }

    struct Current: Decodable {
        let temperature: Double
        let apparentTemperature: Double
        let relativeHumidity: Double
        let precipitation: Double
        let weatherCode: Int
        let windSpeed: Double
        let windDirection: Double

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity = "relative_humidity_2m"
            case precipitation
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
            case windDirection = "wind_direction_10m"
        }
    }

    struct Daily: Decodable {
        struct Point {
            let date: String
            let weatherCode: Int
            let maximumTemperature: Double
            let minimumTemperature: Double
            let precipitationProbability: Int?
        }

        let points: [Point]

        enum CodingKeys: String, CodingKey {
            case dates = "time"
            case weatherCodes = "weather_code"
            case maximumTemperatures = "temperature_2m_max"
            case minimumTemperatures = "temperature_2m_min"
            case precipitationProbabilities = "precipitation_probability_max"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let dates = try container.decode([String].self, forKey: .dates)
            let weatherCodes = try container.decode([Int].self, forKey: .weatherCodes)
            let maximumTemperatures = try container.decode(
                [Double].self,
                forKey: .maximumTemperatures
            )
            let minimumTemperatures = try container.decode(
                [Double].self,
                forKey: .minimumTemperatures
            )
            let precipitationProbabilities = try container.decode(
                [Int?].self,
                forKey: .precipitationProbabilities
            )
            let counts: [Int] = [
                dates.count,
                weatherCodes.count,
                maximumTemperatures.count,
                minimumTemperatures.count,
                precipitationProbabilities.count,
            ]
            guard Set(counts).count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .dates,
                    in: container,
                    debugDescription: "Daily weather series have different lengths."
                )
            }

            self.points = dates.indices.map { (index: Int) -> Point in
                Point(
                    date: dates[index],
                    weatherCode: weatherCodes[index],
                    maximumTemperature: maximumTemperatures[index],
                    minimumTemperature: minimumTemperatures[index],
                    precipitationProbability: precipitationProbabilities[index]
                )
            }
        }
    }

    struct Hourly: Decodable {
        struct Point {
            let time: Date
            let temperature: Double
            let apparentTemperature: Double
            let precipitationProbability: Int?
            let precipitation: Double
            let weatherCode: Int
            let windSpeed: Double
            let windDirection: Double
        }

        let points: [Point]

        enum CodingKeys: String, CodingKey {
            case times = "time"
            case temperatures = "temperature_2m"
            case apparentTemperatures = "apparent_temperature"
            case precipitationProbabilities = "precipitation_probability"
            case precipitations = "precipitation"
            case weatherCodes = "weather_code"
            case windSpeeds = "wind_speed_10m"
            case windDirections = "wind_direction_10m"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let times = try container.decode([Date].self, forKey: .times)
            let temperatures = try container.decode([Double].self, forKey: .temperatures)
            let apparentTemperatures = try container.decode(
                [Double].self,
                forKey: .apparentTemperatures
            )
            let precipitationProbabilities = try container.decode(
                [Int?].self,
                forKey: .precipitationProbabilities
            )
            let precipitations = try container.decode(
                [Double].self,
                forKey: .precipitations
            )
            let weatherCodes = try container.decode([Int].self, forKey: .weatherCodes)
            let windSpeeds = try container.decode([Double].self, forKey: .windSpeeds)
            let windDirections = try container.decode([Double].self, forKey: .windDirections)
            let counts: [Int] = [
                times.count,
                temperatures.count,
                apparentTemperatures.count,
                precipitationProbabilities.count,
                precipitations.count,
                weatherCodes.count,
                windSpeeds.count,
                windDirections.count,
            ]
            guard Set(counts).count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .times,
                    in: container,
                    debugDescription: "Hourly weather series have different lengths."
                )
            }

            self.points = times.indices.map { (index: Int) -> Point in
                Point(
                    time: times[index],
                    temperature: temperatures[index],
                    apparentTemperature: apparentTemperatures[index],
                    precipitationProbability: precipitationProbabilities[index],
                    precipitation: precipitations[index],
                    weatherCode: weatherCodes[index],
                    windSpeed: windSpeeds[index],
                    windDirection: windDirections[index]
                )
            }
        }
    }
}

extension WeatherEffect.Horizon {
    fileprivate var days: Int {
        switch self {
        case .current: 0
        case .hourly: 1
        case .daily(let days): days
        }
    }
}

/// The weather at a place: now, and the hours or days ahead that were asked for.
@Describable
public struct WeatherReport: Codable, Sendable {
    /// The place it's for.
    public let location: WeatherLocation
    /// The place's IANA time zone.
    public let timezone: String
    /// The instant it was made.
    public let toolNow: Date
    /// The date and time at the place as it was made.
    public let localNow: LocalDateTime
    /// The days of outlook asked for.
    public let requestedDays: Int
    /// The local hour the hours start from, when hours were asked for.
    public let fromLocalHour: Int?
    /// The conditions now.
    public let current: WeatherCurrent
    /// The rest of today, hour by hour, when hours were asked for.
    public let hourly: [WeatherHourlyPoint]
    /// The days ahead, when days were asked for.
    public let daily: [WeatherDailyPoint]
    /// Where the weather comes from.
    public let source: String
}

/// A place, as the weather found it.
@Describable
public struct WeatherLocation: Codable, Sendable {
    /// Its name.
    public let name: String
    /// Its state, province or county.
    public let region: String?
    /// Its country.
    public let country: String?
    /// Its latitude, in degrees.
    public let latitude: Double
    /// Its longitude, in degrees.
    public let longitude: Double
}

/// The conditions now.
@Describable
public struct WeatherCurrent: Codable, Sendable {
    /// The temperature, in °C.
    public let temperatureCelsius: Double
    /// What it feels like, in °C.
    public let apparentTemperatureCelsius: Double
    /// The relative humidity, in percent.
    public let relativeHumidityPercent: Double
    /// The precipitation, in mm.
    public let precipitationMillimeters: Double
    /// Open-Meteo's weather code.
    public let weatherCode: Int
    /// The conditions, in words.
    public let condition: String
    /// The wind's speed, in km/h.
    public let windSpeedKilometersPerHour: Double
    /// Where the wind comes from, in degrees.
    public let windDirectionDegrees: Double
    /// Where the wind comes from, as a compass point.
    public let windDirection: String
}

/// One hour of today. It's in local time only: the UTC instant beside it reads as a shift.
@Describable
public struct WeatherHourlyPoint: Codable, Sendable {
    /// The hour, at the place.
    public let localTime: LocalDateTime
    /// The temperature, in °C.
    public let temperatureCelsius: Double
    /// What it feels like, in °C.
    public let apparentTemperatureCelsius: Double
    /// The chance of precipitation, in percent.
    public let precipitationProbabilityPercent: Int?
    /// The conditions, in words.
    public let condition: String
    /// The wind's speed, in km/h.
    public let windSpeedKilometersPerHour: Double
    /// Where the wind comes from, as a compass point.
    public let windDirection: String
}

/// One day ahead.
@Describable
public struct WeatherDailyPoint: Codable, Sendable {
    /// The day, at the place.
    public let date: String
    /// Open-Meteo's weather code.
    public let weatherCode: Int
    /// The conditions, in words.
    public let condition: String
    /// The day's high, in °C.
    public let maximumTemperatureCelsius: Double
    /// The day's low, in °C.
    public let minimumTemperatureCelsius: Double
    /// The chance of precipitation, in percent.
    public let precipitationProbabilityPercent: Int?
}

/// A date and time at a place.
@Describable
public struct LocalDateTime: Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    /// The day of the week, from 1 for Sunday.
    public let weekday: Int
}

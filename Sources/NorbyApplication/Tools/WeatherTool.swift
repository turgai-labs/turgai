import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Looks up a place and returns its current weather plus a short forecast.
///
/// This intentionally talks to Open-Meteo directly. The tool is small enough
/// that introducing a provider abstraction would add more surface than value
/// at this stage.
public struct WeatherTool: Tool {
    public typealias Effect = CombinedEffect<LocationEffect, ClockEffect>

    private static let maximumResponseBytes = 512 * 1024
    private static let userAgent = "Norby/1.0 (+https://github.com/akbashev/norby)"

    public let name = "weather"
    public let description =
        "Get structured current weather and forecast data for a place. A one-day forecast is hourly; longer forecasts are daily. The result includes the tool clock, timezone, and local date/time components. Pass a city, place name, or postal code; include the country when the name is ambiguous. If the user has not provided a location, ask for it before calling this tool."

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
                        "location": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "City, place name, or postal code, preferably with a country.",
                            enumValues: nil
                        ),
                        "days": LLMToolSchema.PropertySchema(
                            type: "integer",
                            description:
                                "Forecast length in days, from 1 to 7. One day returns hourly weather; seven days returns the upcoming week by day.",
                            enumValues: nil,
                        ),
                        "from_hour": LLMToolSchema.PropertySchema(
                            type: "integer",
                            description:
                                "Optional local hour from which today's hourly forecast should start, from 0 to 23. Only used when days is 1.",
                            enumValues: nil
                        ),
                    ],
                    required: ["location", "days"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> Effect {
        let location = try validatedLocation(input.location)
        _ = try validatedHorizon(input)
        let locationEffect = try LocationTool().effect(
            for: LocationTool.Input(query: location)
        )
        return
            locationEffect
            .combined(with: ClockEffect())
    }

    public func run(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> String {
        let location = try await token.withLeft { locationToken in
            let locationQuery = try validatedLocation(input.location)
            do {
                let places = try await LocationEffect.run(in: locationToken)
                guard let place = places.first else {
                    throw Error.locationNotFound(locationQuery)
                }
                return place
            } catch let error as LocationEffect.Error {
                switch error {
                case .invalidResponse:
                    throw Error.invalidResponse
                case .httpStatus(let status):
                    throw Error.httpStatus(status)
                case .locationNotFound(let query):
                    throw Error.locationNotFound(query)
                }
            }
        }
        let now = try await token.withRight { clock in
            clock.now()
        }

        let horizon = try validatedHorizon(input)
        let forecastEffect = try forecastEffect(
            latitude: location.latitude,
            longitude: location.longitude,
            horizon: horizon
        )
        let forecast = try await token.withChild(forecastEffect) { networkToken in
            try await NetworkEffect.run(in: networkToken)
        }
        let report = try makeReport(
            location: location,
            forecast: try decodeForecast(forecast),
            horizon: horizon,
            now: now
        )
        return try encode(report)
    }

    private func forecastEffect(
        latitude: Double,
        longitude: Double,
        horizon: ForecastHorizon
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
        case .currentDay:
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
        case .days(let days):
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
                    "User-Agent": Self.userAgent,
                    "Accept": "application/json",
                ],
                maximumResponseBytes: Self.maximumResponseBytes
            )
        )
    }

    private func decodeForecast(
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

    private func makeReport(
        location: LocationEffect.Result,
        forecast: ForecastResponse,
        horizon: ForecastHorizon,
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
        case .currentDay(let fromHour):
            let startHour = fromHour ?? localNow.hour
            fromLocalHour = startHour
            if let source = forecast.hourly {
                hourly = try source.points
                    .map { try makeHourlyPoint($0, in: timeZone) }
                    .filter { $0.localTime.hour >= startHour }
            } else {
                hourly = []
            }
            daily = []
        case .days(let days):
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

    private func makeHourlyPoint(
        _ point: Hourly.Point,
        in timeZone: TimeZone
    ) throws -> WeatherHourlyPoint {
        WeatherHourlyPoint(
            time: point.time,
            localTime: try localDateTime(point.time, in: timeZone),
            temperatureCelsius: point.temperature,
            apparentTemperatureCelsius: point.apparentTemperature,
            precipitationProbabilityPercent: point.precipitationProbability,
            precipitationMillimeters: point.precipitation,
            weatherCode: point.weatherCode,
            condition: condition(point.weatherCode),
            windSpeedKilometersPerHour: point.windSpeed,
            windDirectionDegrees: point.windDirection,
            windDirection: compassDirection(point.windDirection)
        )
    }

    private func localDateTime(
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

    private func encode(_ report: WeatherReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        guard let result = String(data: data, encoding: .utf8) else {
            throw Error.invalidResponse
        }
        return result
    }

    private func validatedLocation(_ value: String) throws -> String {
        let location = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else {
            throw ToolError.invalidArgument("location", value: value)
        }
        guard location.count <= 200 else {
            throw ToolError.invalidArgument("location", value: "location is too long")
        }
        return location
    }

    private func validatedHorizon(_ input: Input) throws -> ForecastHorizon {
        let days = input.days
        guard (1...7).contains(days) else {
            throw ToolError.invalidArgument("days", value: String(days))
        }

        switch days {
        case 1:
            if let fromHour = input.fromHour, !(0...23).contains(fromHour) {
                throw ToolError.invalidArgument("from_hour", value: String(fromHour))
            }
            return .currentDay(fromHour: input.fromHour)
        default:
            guard input.fromHour == nil else {
                throw ToolError.invalidArgument("from_hour", value: "only valid when days is 1")
            }
            return .days(days)
        }
    }

    private func compassDirection(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees + 22.5) / 45.0) % directions.count
        return directions[index]
    }

    private func condition(_ code: Int) -> String {
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
}

extension WeatherTool {
    /// The domain meaning of the forecast requested by the caller.
    public enum ForecastHorizon: Equatable, Sendable {
        case currentDay(fromHour: Int?)
        case days(Int)

        public static let today = Self.currentDay(fromHour: nil)
        public static let upcomingWeek = Self.days(7)

        public static func today(from hour: Int) -> Self {
            .currentDay(fromHour: hour)
        }

        var days: Int {
            switch self {
            case .currentDay:
                1
            case .days(let days):
                days
            }
        }
    }

    public struct Input: Codable, Sendable {
        public let location: String
        public let days: Int
        public let fromHour: Int?

        enum CodingKeys: String, CodingKey {
            case location
            case days
            case fromHour = "from_hour"
        }

        public init(
            location: String,
            horizon: ForecastHorizon = .today
        ) {
            self.location = location
            switch horizon {
            case .currentDay(let fromHour):
                self.days = 1
                self.fromHour = fromHour
            case .days(let days):
                self.days = days
                self.fromHour = nil
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidURL
        case locationNotFound(String)
        case invalidResponse
        case httpStatus(Int)
    }

    private struct ForecastResponse: Decodable {
        let timezone: String
        let current: Current
        let daily: Daily?
        let hourly: Hourly?
    }

    private struct Current: Decodable {
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

    /// Data returned to the model. Presentation belongs to the model-facing
    /// conversation, not to this provider adapter.
    private struct WeatherReport: Encodable, Sendable {
        let location: WeatherLocation
        let timezone: String
        let toolNow: Date
        let localNow: LocalDateTime
        let requestedDays: Int
        let fromLocalHour: Int?
        let current: WeatherCurrent
        let hourly: [WeatherHourlyPoint]
        let daily: [WeatherDailyPoint]
        let source: String
    }

    private struct WeatherLocation: Encodable, Sendable {
        let name: String
        let region: String?
        let country: String?
        let latitude: Double
        let longitude: Double
    }

    private struct WeatherCurrent: Encodable, Sendable {
        let temperatureCelsius: Double
        let apparentTemperatureCelsius: Double
        let relativeHumidityPercent: Double
        let precipitationMillimeters: Double
        let weatherCode: Int
        let condition: String
        let windSpeedKilometersPerHour: Double
        let windDirectionDegrees: Double
        let windDirection: String
    }

    private struct WeatherHourlyPoint: Encodable, Sendable {
        let time: Date
        let localTime: LocalDateTime
        let temperatureCelsius: Double
        let apparentTemperatureCelsius: Double
        let precipitationProbabilityPercent: Int?
        let precipitationMillimeters: Double
        let weatherCode: Int
        let condition: String
        let windSpeedKilometersPerHour: Double
        let windDirectionDegrees: Double
        let windDirection: String
    }

    private struct WeatherDailyPoint: Encodable, Sendable {
        let date: String
        let weatherCode: Int
        let condition: String
        let maximumTemperatureCelsius: Double
        let minimumTemperatureCelsius: Double
        let precipitationProbabilityPercent: Int?
    }

    private struct LocalDateTime: Encodable, Sendable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let weekday: Int
    }

    private struct Daily: Decodable {
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
            guard
                Set([
                    dates.count,
                    weatherCodes.count,
                    maximumTemperatures.count,
                    minimumTemperatures.count,
                    precipitationProbabilities.count,
                ]).count == 1
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .dates,
                    in: container,
                    debugDescription: "Daily weather series have different lengths."
                )
            }

            self.points = dates.indices.map { index in
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

    private struct Hourly: Decodable {
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
            guard
                Set([
                    times.count,
                    temperatures.count,
                    apparentTemperatures.count,
                    precipitationProbabilities.count,
                    precipitations.count,
                    weatherCodes.count,
                    windSpeeds.count,
                    windDirections.count,
                ]).count == 1
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .times,
                    in: container,
                    debugDescription: "Hourly weather series have different lengths."
                )
            }

            self.points = times.indices.map { index in
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

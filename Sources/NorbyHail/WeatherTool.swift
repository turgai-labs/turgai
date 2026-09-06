import AsyncHTTPClient
import Foundation
import Hail
import NIOCore

/// Looks up a place and returns its current weather plus a short forecast.
///
/// This intentionally talks to Open-Meteo directly. The tool is small enough
/// that introducing a provider abstraction would add more surface than value
/// at this stage.
public struct WeatherTool: Tool {
    public typealias Effect = CombinedEffect<ClockEffect, NetworkEffect>

    public struct Configuration: Sendable {
        public let now: @Sendable () -> Date

        public init(now: @escaping @Sendable () -> Date = Date.init) {
            self.now = now
        }
    }

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

    private struct GeocodingResponse: Decodable {
        let results: [Location]?
    }

    private struct Location: Decodable {
        let name: String
        let country: String?
        let admin1: String?
        let latitude: Double
        let longitude: Double
        let timezone: String?
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

    private struct Daily: Decodable {
        let dates: [String]
        let weatherCodes: [Int]
        let maximumTemperatures: [Double]
        let minimumTemperatures: [Double]
        let precipitationProbabilities: [Int?]

        enum CodingKeys: String, CodingKey {
            case dates = "time"
            case weatherCodes = "weather_code"
            case maximumTemperatures = "temperature_2m_max"
            case minimumTemperatures = "temperature_2m_min"
            case precipitationProbabilities = "precipitation_probability_max"
        }
    }

    private struct Hourly: Decodable {
        let times: [Date]
        let temperatures: [Double]
        let apparentTemperatures: [Double]
        let precipitationProbabilities: [Int?]
        let precipitations: [Double]
        let weatherCodes: [Int]
        let windSpeeds: [Double]
        let windDirections: [Double]

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
    }

    private static let httpClient: HTTPClient = {
        var configuration = HTTPClient.Configuration()
        configuration.timeout = .init(connect: .seconds(10), read: .seconds(15))
        return HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configuration
        )
    }()

    private static let maximumResponseBytes = 512 * 1024

    public let name = "weather"
    public let description =
        "Get the current weather and forecast for a place. A one-day forecast is hourly; longer forecasts are daily. Pass a city, place name, or postal code; include the country when the name is ambiguous. If the user has not provided a location, ask for it before calling this tool."

    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

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
                            description: "Forecast length in days, from 1 to 7. One day returns hourly weather; seven days returns the upcoming week by day.",
                            enumValues: nil,
                        ),
                        "from_hour": LLMToolSchema.PropertySchema(
                            type: "integer",
                            description: "Optional local hour from which today's hourly forecast should start, from 0 to 23. Only used when days is 1.",
                            enumValues: nil
                        ),
                    ],
                    required: ["location", "days"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> Effect {
        _ = try validatedLocation(input.location)
        _ = try validatedHorizon(input)
        // Geocoding and forecast are both Open-Meteo operations. The effect
        // uses the provider domain rather than exposing the two subdomains.
        // Weather also needs the local clock to choose the default starting
        // hour for today's forecast, so both capabilities are required by the
        // operation.
        return ClockEffect(now: configuration.now)
            .combined(
                with: NetworkEffect(
                    host: "open-meteo.com",
                    operation: "weather"
                )
            )
    }

    public func execute(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> String {
        let now = await token.withLeft { clock in
            clock.now()
        }

        return try await token.withRight { _ in
            let locationQuery = try validatedLocation(input.location)
            let horizon = try validatedHorizon(input)
            let location = try await geocode(locationQuery)
            let forecast = try await forecast(
                latitude: location.latitude,
                longitude: location.longitude,
                horizon: horizon
            )
            return try format(location: location, forecast: forecast, horizon: horizon, now: now)
        }
    }

    private func geocode(_ location: String) async throws -> Location {
        var components = URLComponents(
            string: "https://geocoding-api.open-meteo.com/v1/search"
        )!
        components.queryItems = [
            URLQueryItem(name: "name", value: location),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw Error.invalidURL }

        let response: GeocodingResponse = try await fetch(url)
        guard let result = response.results?.first else {
            throw Error.locationNotFound(location)
        }
        return result
    }

    private func forecast(
        latitude: Double,
        longitude: Double,
        horizon: ForecastHorizon
    ) async throws -> ForecastResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m"
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
                    value: "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m"
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
        return try await fetch(url)
    }

    private func fetch<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.headers.add(
            name: "User-Agent",
            value: "Norby/1.0 (+https://github.com/akbashev/norby)"
        )
        request.headers.add(name: "Accept", value: "application/json")

        let response = try await Self.httpClient.execute(
            request,
            timeout: .seconds(15)
        )
        guard (200..<300).contains(response.status.code) else {
            throw Error.httpStatus(Int(response.status.code))
        }

        let body = try await response.body.collect(upTo: Self.maximumResponseBytes)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(
                Response.self,
                from: Data(body.readableBytesView)
            )
        } catch {
            throw Error.invalidResponse
        }
    }

    private func format(
        location: Location,
        forecast: ForecastResponse,
        horizon: ForecastHorizon,
        now: Date
    ) throws -> String {
        guard let timeZone = TimeZone(identifier: forecast.timezone) else {
            throw Error.invalidResponse
        }

        let place = [location.name, location.admin1, location.country]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")

        let localTime = localClock(
            in: timeZone,
            at: now
        )
        var lines = [
            "Weather for \(place) (local time: \(forecast.timezone))",
            "Current local time from the tool clock: \(localTime)",
            "Now: \(format(forecast.current.temperature)) °C, \(condition(forecast.current.weatherCode))",
            "Feels like: \(format(forecast.current.apparentTemperature)) °C; humidity: \(format(forecast.current.relativeHumidity))%",
            "Precipitation: \(format(forecast.current.precipitation)) mm; wind: \(format(forecast.current.windSpeed)) km/h \(compassDirection(forecast.current.windDirection))",
        ]

        switch horizon {
        case .currentDay(let fromHour):
            lines.append("Hourly forecast:")
            if let hourly = forecast.hourly {
                lines.append(contentsOf: formatHourly(
                    hourly,
                    fromHour: fromHour ?? currentLocalHour(
                        in: timeZone,
                        at: now
                    ),
                    in: timeZone
                ))
            }
        case .days(let days):
            lines.append("Daily forecast:")
            if let daily = forecast.daily {
                let count = min(
                    days,
                    daily.dates.count,
                    daily.weatherCodes.count,
                    daily.maximumTemperatures.count,
                    daily.minimumTemperatures.count,
                    daily.precipitationProbabilities.count
                )
                for index in 0..<count {
                    let precipitation = daily.precipitationProbabilities[index]
                        .map { "\($0)% rain" }
                        ?? "rain chance unavailable"
                    let date = try formatDailyDate(
                        daily.dates[index],
                        in: timeZone
                    )
                    lines.append(
                        "- \(date): \(condition(daily.weatherCodes[index])), \(format(daily.minimumTemperatures[index]))–\(format(daily.maximumTemperatures[index])) °C, \(precipitation)"
                    )
                }
            }
        }
        lines.append("Source: Open-Meteo")
        return lines.joined(separator: "\n")
    }

    private func formatHourly(
        _ hourly: Hourly,
        fromHour: Int,
        in timeZone: TimeZone
    ) -> [String] {
        let count = min(
            hourly.times.count,
            hourly.temperatures.count,
            hourly.apparentTemperatures.count,
            hourly.precipitationProbabilities.count,
            hourly.precipitations.count,
            hourly.weatherCodes.count,
            hourly.windSpeeds.count,
            hourly.windDirections.count
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return (0..<count).compactMap { index in
            let date = hourly.times[index]
            guard calendar.component(.hour, from: date) >= fromHour else {
                return nil
            }
            let precipitation = hourly.precipitationProbabilities[index]
                .map { "\($0)% rain" }
                ?? "rain chance unavailable"
            let time = date.formatted(
                Date.FormatStyle(
                    date: .omitted,
                    time: .shortened,
                    locale: Locale(identifier: "en_GB"),
                    timeZone: timeZone
                )
            )
            return "- \(time): \(format(hourly.temperatures[index])) °C, \(condition(hourly.weatherCodes[index])), feels like \(format(hourly.apparentTemperatures[index])) °C, \(precipitation), \(format(hourly.precipitations[index])) mm, wind \(format(hourly.windSpeeds[index])) km/h \(compassDirection(hourly.windDirections[index]))"
        }
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

    private func currentLocalHour(
        in timeZone: TimeZone,
        at date: Date
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: date)
    }

    private func localClock(
        in timeZone: TimeZone,
        at date: Date
    ) -> String {
        return date.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .shortened,
                locale: Locale(identifier: "en_GB"),
                timeZone: timeZone
            )
        )
    }

    private func formatDailyDate(_ value: String, in timeZone: TimeZone) throws -> String {
        let strategy = Date.ParseStrategy(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)",
            locale: Locale(identifier: "en_GB"),
            timeZone: timeZone
        )
        guard let date = try? Date(value, strategy: strategy) else {
            throw Error.invalidResponse
        }
        return date.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .omitted,
                locale: Locale(identifier: "en_GB"),
                timeZone: timeZone
            )
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
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

import Testing
import TurgaiObjects

/// An object's name, as its id and its type: its words kept, an acronym being one.
struct ObjectNamesTests {
    @Test func anAcronymIsOneWord() {
        #expect(ObjectNames.handle(for: "WeatherForecastAPI") == "weather-forecast-api")
        #expect(ObjectNames.handle(for: "APIClient") == "api-client")
        #expect(ObjectNames.handle(for: "Refund manager Ann") == "refund-manager-ann")
        #expect(ObjectNames.handle(for: "ReminderList") == "reminder-list")
        #expect(ObjectNames.handle(for: "open-meteo") == "open-meteo")
        #expect(ObjectNames.typeName(of: "WeatherForecastAPI") == "WeatherForecastAPI")
        #expect(ObjectNames.typeName(of: "Refund manager Ann") == "RefundManagerAnn")
        #expect(ObjectNames.typeName(of: "open-meteo") == "OpenMeteo")
        #expect(ObjectNames.typeName(of: "2048 game") == "Object2048Game")
    }
}

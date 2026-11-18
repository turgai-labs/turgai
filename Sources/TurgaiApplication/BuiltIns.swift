import TurgaiObjects

extension BuiltInKind {
    /// What a new space starts with: every built-in object there is.
    public static let installedInNewSpaces: [BuiltInKind] = [Weather.kind, Website.kind, Scheduler.kind, Timers.kind]
}

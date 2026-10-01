import DistributedCluster

/// The Mac's own objects. Hold on to them: the cluster receptionist doesn't keep
/// actors alive, so they live as long as this value does.
public struct MacObjects: Sendable {
    public let mac: Mac
    public let reminders: Reminders
    public let calendar: Calendar
    public let contacts: Contacts
    public let music: Music

    /// Creates the objects, which check themselves in. Calendar and Contacts ask for
    /// access on first use; Music requests access when its actions are used.
    public init(actorSystem system: ClusterSystem) async throws {
        self.mac = try await Mac(actorSystem: system)
        self.reminders = try await Reminders(actorSystem: system, client: .live)
        self.calendar = try await Calendar(actorSystem: system, client: .live)
        self.contacts = try await Contacts(actorSystem: system, client: .live)
        self.music = try await Music(actorSystem: system, client: .live)
    }
}

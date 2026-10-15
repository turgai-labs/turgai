import DistributedCluster

/// The Mac's own objects. Hold on to them: the cluster receptionist doesn't keep
/// actors alive, so they live as long as this value does.
public struct MacObjects: Sendable {
    public let mac: Mac
    public let reminders: Reminders
    public let calendar: Calendar
    public let contacts: Contacts
    public let media: MediaControl
    public let website: Website

    /// Creates the objects, which check themselves in. Calendar and Contacts ask for
    /// access on first use; MediaControl asks to press media keys the first time it's used. The
    /// website serves on `websitePort`.
    public init(actorSystem system: ClusterSystem, websitePort: Int) async throws {
        self.mac = try await Mac(actorSystem: system)
        self.reminders = try await Reminders(actorSystem: system, client: .live)
        self.calendar = try await Calendar(actorSystem: system, client: .live)
        self.contacts = try await Contacts(actorSystem: system, client: .live)
        self.media = try await MediaControl(actorSystem: system)
        self.website = try await Website(actorSystem: system, port: websitePort)
    }
}

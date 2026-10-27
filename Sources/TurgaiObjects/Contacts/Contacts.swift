import Contacts
import DiscoverableActors
import DistributedCluster
import Foundation

/// The user's address book.
@Discoverable
public distributed actor Contacts {
    public typealias ActorSystem = ClusterSystem

    private let client: ContactsClient
    private var known: [ContactID: Contact] = [:]

    public init(actorSystem: ActorSystem, client: ContactsClient) async throws {
        self.actorSystem = actorSystem
        self.client = client
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    /// Search names, email addresses, and phone numbers.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func search(_ query: String) async throws -> [Contact] {
        let records = try await client.search(query)
        var contacts: [Contact] = []
        for record in records {
            if let contact = known[record.id] {
                try await contact.refresh(record)
                contacts.append(contact)
                continue
            }
            let contact = Contact(actorSystem: actorSystem, record: record)
            known[record.id] = contact
            contacts.append(contact)
        }
        return contacts
    }
}

/// A person in the user's contacts.
@Discoverable
public distributed actor Contact {
    public typealias ActorSystem = ClusterSystem
    private var record: ContactRecord

    init(actorSystem: ActorSystem, record: ContactRecord) {
        self.actorSystem = actorSystem
        self.record = record
    }

    public distributed var name: String { record.name }
    public distributed var organization: String? { record.organization }
    public distributed var emails: [String] { record.emails }
    public distributed var phoneNumbers: [String] { record.phoneNumbers }

    distributed func refresh(_ record: ContactRecord) { self.record = record }
}

public struct ContactsClient: Sendable {
    public var search: @Sendable (String) async throws -> [ContactRecord]
    public init(search: @escaping @Sendable (String) async throws -> [ContactRecord]) { self.search = search }
}

public struct ContactID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ContactRecord: Codable, Sendable, Equatable {
    public var id: ContactID
    public var name: String
    public var organization: String?
    public var emails: [String]
    public var phoneNumbers: [String]
    public init(
        id: ContactID, name: String, organization: String? = nil,
        emails: [String] = [], phoneNumbers: [String] = []
    ) {
        self.id = id
        self.name = name
        self.organization = organization
        self.emails = emails
        self.phoneNumbers = phoneNumbers
    }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Contacts: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Contact: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}

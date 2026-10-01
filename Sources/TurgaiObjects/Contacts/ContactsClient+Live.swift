import Contacts
import Foundation

extension ContactsClient {
    public static let live: ContactsClient = {
        let store = AddressBookStore()
        return ContactsClient { query in
            try await store.search(query)
        }
    }()
}

private actor AddressBookStore {
    private let store = CNContactStore()
    private let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    func search(_ query: String) async throws -> [ContactRecord] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let authorization = CNContactStore.authorizationStatus(for: .contacts)
        if authorization == .notDetermined {
            guard try await store.requestAccess(for: .contacts) else { throw ContactsError.accessDenied }
        } else if authorization != .authorized {
            throw ContactsError.accessDenied
        }

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var matches: [ContactRecord] = []
        let needle = query.localizedLowercase
        try store.enumerateContacts(with: request) { contact, stop in
            let emails = contact.emailAddresses.map { String($0.value) }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            let searchable = [contact.givenName, contact.familyName, contact.organizationName] + emails + phones
            guard searchable.contains(where: { $0.localizedLowercase.contains(needle) }) else { return }
            matches.append(
                ContactRecord(
                    id: ContactID(rawValue: contact.identifier),
                    name: CNContactFormatter.string(from: contact, style: .fullName)
                        ?? contact.organizationName,
                    organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                    emails: emails,
                    phoneNumbers: phones
                ))
            if matches.count >= 50 { stop.pointee = true }
        }
        return matches
    }
}

public enum ContactsError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case accessDenied
    public var description: String {
        "Turgai isn't allowed to use Contacts. Allow it in System Settings › Privacy & Security › Contacts."
    }
}

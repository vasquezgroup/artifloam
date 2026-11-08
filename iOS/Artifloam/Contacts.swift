import Contacts
import SwiftUI

struct ContactKey {
    let id: String
    let name: String
    let phones: Set<String>
    let emails: Set<String>
}

/// Same full name plus a shared phone or email. A shared name alone isn't enough: two people can have one.
func duplicateContactGroups(_ contacts: [ContactKey]) -> [[String]] {
    Dictionary(grouping: contacts.filter { !$0.name.isEmpty }) { $0.name.lowercased() }.values.flatMap { sameName -> [[String]] in
        var left = sameName
        var groups: [[String]] = []
        while let seed = left.popLast() {
            var group = [seed]
            var phones = seed.phones, emails = seed.emails
            var grew = true
            while grew {
                grew = false
                for (index, other) in left.enumerated().reversed() where !other.phones.isDisjoint(with: phones) || !other.emails.isDisjoint(with: emails) {
                    group.append(left.remove(at: index))
                    phones.formUnion(other.phones)
                    emails.formUnion(other.emails)
                    grew = true
                }
            }
            if group.count > 1 { groups.append(group.map(\.id)) }
        }
        return groups
    }
}

/// Keeps the last 9 digits, so +41 79 123 45 67 and 079 123 45 67 match.
func normalizedPhone(_ phone: String) -> String { String(phone.filter(\.isNumber).suffix(9)) }

enum ContactsCleanup {
    /// Every field the merge touches, by name: reading one that wasn't asked for crashes the app.
    /// Notes need a special Apple entitlement, so they aren't read, and the screen says so.
    static var keys: [CNKeyDescriptor] {
        let fields = [CNContactIdentifierKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactSocialProfilesKey,
                      CNContactInstantMessageAddressesKey, CNContactRelationsKey, CNContactDatesKey, CNContactBirthdayKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
                      CNContactDepartmentNameKey, CNContactNicknameKey, CNContactImageDataKey, CNContactImageDataAvailableKey]
        return fields.map { $0 as CNKeyDescriptor } + [CNContactVCardSerialization.descriptorForRequiredKeys(), CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    }

    static func fetchGroups(_ store: CNContactStore) -> [[CNContact]] {
        var all: [String: CNContact] = [:]
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in all[contact.identifier] = contact }
        let keyed = all.values.map { contact in
            ContactKey(id: contact.identifier, name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                       phones: Set(contact.phoneNumbers.map { normalizedPhone($0.value.stringValue) }.filter { !$0.isEmpty }),
                       emails: Set(contact.emailAddresses.map { ($0.value as String).lowercased() }))
        }
        return duplicateContactGroups(keyed).map { $0.compactMap { all[$0] } }
    }

    /// For the main scan: never asks for access, and says nothing if it wasn't already given.
    nonisolated static func groupCountIfAllowed() -> Int? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        return fetchGroups(CNContactStore()).count
    }

    private static func detail(_ contact: CNContact) -> Int {
        contact.phoneNumbers.count + contact.emailAddresses.count + contact.postalAddresses.count + contact.urlAddresses.count + (contact.birthday == nil ? 0 : 1) + (contact.imageDataAvailable ? 1 : 0)
    }
    static func keeper(of group: [CNContact]) -> CNContact {
        group.max { detail($0) < detail($1) } ?? group[0]
    }

    /// The fullest card, plus everything the others have that it doesn't. Nothing it already has is overwritten.
    static func merged(_ group: [CNContact]) -> CNMutableContact? {
        guard let merged = keeper(of: group).mutableCopy() as? CNMutableContact else { return nil }
        let keepID = merged.identifier
        func add<T>(_ source: [CNLabeledValue<T>], to current: inout [CNLabeledValue<T>], _ key: (T) -> String) {
            for item in source where !current.contains(where: { key($0.value) == key(item.value) }) { current.append(item) }
        }
        for other in group where other.identifier != keepID {
            add(other.phoneNumbers, to: &merged.phoneNumbers) { normalizedPhone($0.stringValue) }
            add(other.emailAddresses, to: &merged.emailAddresses) { ($0 as String).lowercased() }
            add(other.postalAddresses, to: &merged.postalAddresses) { CNPostalAddressFormatter.string(from: $0, style: .mailingAddress).lowercased() }
            add(other.urlAddresses, to: &merged.urlAddresses) { ($0 as String).lowercased() }
            add(other.socialProfiles, to: &merged.socialProfiles) { "\($0.service)\($0.username)".lowercased() }
            add(other.instantMessageAddresses, to: &merged.instantMessageAddresses) { "\($0.service)\($0.username)".lowercased() }
            add(other.contactRelations, to: &merged.contactRelations) { $0.name.lowercased() }
            add(other.dates, to: &merged.dates) { $0.description }
            if merged.birthday == nil { merged.birthday = other.birthday }
            if merged.organizationName.isEmpty { merged.organizationName = other.organizationName }
            if merged.jobTitle.isEmpty { merged.jobTitle = other.jobTitle }
            if merged.departmentName.isEmpty { merged.departmentName = other.departmentName }
            if merged.nickname.isEmpty { merged.nickname = other.nickname }
            if merged.imageData == nil, other.imageDataAvailable { merged.imageData = other.imageData }
        }
        return merged
    }

    /// A vCard file of the cards about to change, so a merge can be undone by opening it in Contacts.
    static func backup(_ contacts: [CNContact]) throws -> URL {
        let folder = URL.documentsDirectory.appending(path: "Contacts backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Contacts before merge " + Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-") + ".vcf"
        let url = folder.appending(path: name)
        try CNContactVCardSerialization.data(with: contacts).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func merge(_ groups: [[CNContact]], in store: CNContactStore) throws -> URL {
        let url = try backup(groups.flatMap { $0 })
        let save = CNSaveRequest()
        for group in groups {
            guard let keep = merged(group) else { continue }
            for other in group where other.identifier != keep.identifier {
                if let copy = other.mutableCopy() as? CNMutableContact { save.delete(copy) }
            }
            save.update(keep)
        }
        try store.execute(save)
        return url
    }
}

struct ContactsCleanupView: View {
    @State private var groups: [[CNContact]]?
    @State private var denied = false
    @State private var pending: [[CNContact]]?
    @State private var failure: String?
    @State private var lastBackup: URL?
    @State private var mergedCount = 0
    @State private var saved: Saving?
    private let store = CNContactStore()

    var body: some View {
        DetailPage(theme: .space, title: "Merge contacts") {
            Text("Cards with the same name and a shared phone number or email. Merging keeps the fullest card and adds everything the others have.").font(.subheadline)
            if denied {
                GlassCard {
                    Text("Allow Contacts access in Settings to check for duplicates.")
                    if let url = URL(string: UIApplication.openSettingsURLString) { Link("Give permission", destination: url).fontWeight(.medium) }
                }
            } else if let groups {
                if mergedCount > 0 {
                    GlassCard {
                        Label("Merged ^[\(mergedCount) group](inflect: true).", systemImage: "checkmark.seal.fill").font(.headline)
                        Text("A backup of the original cards is on this iPhone. To undo, open it and add the cards back to Contacts.").font(.footnote).foregroundStyle(.white.opacity(0.75))
                        if let lastBackup { ShareLink("Open or save the backup", item: lastBackup).fontWeight(.medium) }
                    }
                }
                if groups.isEmpty { GlassCard { Label("No duplicates found.", systemImage: "checkmark.seal.fill") } }
                else if groups.count > 1 {
                    Button { pending = groups } label: { Text("Merge all ^[\(groups.count) group](inflect: true)").fontWeight(.semibold).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(StewardTheme.space.vivid).controlSize(.large)
                }
                ForEach(groups, id: \.first?.identifier) { group in card(group) }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .confirmationDialog("Merge these contacts?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { chosen in
            Button("Merge ^[\(chosen.count) group](inflect: true)", role: .destructive) { merge(chosen) }
        } message: { _ in
            Text("The extra cards are deleted, and a backup of them is saved first. Notes on the extra cards can't be copied, because iOS keeps them private, so check any that matter in Contacts first.")
        }
        .savedStage($saved, theme: .space, note: "A backup of the original cards is on this iPhone. To undo, open it and add the cards back to Contacts.",
                    accessory: lastBackup.map { AnyView(ShareLink("Open or save the backup", item: $0)) },
                    detail: { Text("Merged ^[\($0.count) group](inflect: true).") })
        .alert("Couldn't merge", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    /// Shows the result before anything changes.
    private func card(_ group: [CNContact]) -> some View {
        let result = ContactsCleanup.merged(group)
        return GlassCard {
            Text(result.flatMap { CNContactFormatter.string(from: $0, style: .fullName) } ?? "").font(.headline)
            Text("^[\(group.count) card](inflect: true) become one:").font(.footnote).foregroundStyle(.white.opacity(0.7))
            ForEach(result?.phoneNumbers.map(\.value.stringValue) ?? [], id: \.self) { Label($0, systemImage: "phone").font(.subheadline) }
            ForEach(result?.emailAddresses.map { $0.value as String } ?? [], id: \.self) { Label($0, systemImage: "envelope").font(.subheadline) }
            if let addresses = result?.postalAddresses.count, addresses > 0 { Label("^[\(addresses) address](inflect: true)", systemImage: "house").font(.subheadline) }
            Button("Merge") { pending = [group] }.buttonStyle(.bordered).tint(.white)
        }
    }

    private func load() async {
        guard (try? await store.requestAccess(for: .contacts)) == true else { denied = true; return }
        groups = await Task.detached(priority: .userInitiated) { ContactsCleanup.fetchGroups(CNContactStore()) }.value
    }

    private func merge(_ chosen: [[CNContact]]) {
        do {
            lastBackup = try ContactsCleanup.merge(chosen, in: store)
            mergedCount += chosen.count
            // Each group becomes one card.
            saved = Saving(before: Int64(chosen.reduce(0) { $0 + $1.count }), after: Int64(chosen.count), count: chosen.count, counts: true)
            let gone = Set(chosen.compactMap { $0.first?.identifier })
            groups?.removeAll { gone.contains($0.first?.identifier ?? "") }
        } catch {
            failure = error.localizedDescription
        }
    }
}

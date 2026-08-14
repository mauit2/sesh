// ContactDiscovery — find people you already know, without handing us your
// address book.
//
// THE CONTRACT (mirrored in migration 098):
// Every phone number and email is normalised, salted and SHA-256'd ON THIS
// DEVICE. Only digests are ever sent. The server compares them in one query
// and writes nothing about anyone who isn't already a user — the people in
// your contacts never agreed to us processing their data, so we don't.
//
// Digests are deliberately PLURAL per value. The same Swedish mobile is
// stored as "+46 70 123 45 67" in one phone and "070-1234567" in another;
// emitting every plausible normalisation and matching on any overlap is
// what makes discovery work across address books that disagree.
//
// Honest limit, same as the migration says: a phone digest is brute-forceable
// (~10^9 candidates per country). The salt stops generic rainbow tables and
// nothing more. That's why raw numbers are never stored anywhere — not on
// the server, not here.

import Foundation
import Combine
import Contacts
import CryptoKit
import Supabase

struct MatchedProfile: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let username: String?
    let avatarURL: String?
    enum CodingKeys: String, CodingKey {
        case id, name, username
        case avatarURL = "avatar_url"
    }
}

/// A contact who isn't on Sesh yet — offered for an invite, never uploaded.
struct InvitableContact: Identifiable, Hashable {
    let id: String          // the contact identifier, local to this device
    let name: String
    let phone: String?      // kept in memory only, for the message composer
}

@MainActor
final class ContactDiscovery: ObservableObject {
    @Published private(set) var matched: [MatchedProfile] = []
    @Published private(set) var invitable: [InvitableContact] = []
    @Published private(set) var scanning = false
    @Published private(set) var denied = false
    @Published private(set) var error: String?
    /// How many contacts were considered — shown so "no matches" reads as a
    /// real answer ("looked at 312") rather than a silent failure.
    @Published private(set) var scanned = 0

    /// App-wide salt. Not a secret — it ships in the binary — but it means a
    /// stolen digest can't be looked up in a precomputed table of bare
    /// phone-number hashes.
    private static let salt = "sesh.contact.v1:"

    // MARK: - Normalisation

    /// Every digest worth trying for one raw phone number.
    ///
    /// The device's own region resolves national numbers: a Swedish phone
    /// writing "070…" means +46 70…. The last-9-digits variant is the
    /// safety net for numbers stored with a wrong or missing prefix, which
    /// is extremely common in real address books.
    static func phoneKeys(_ raw: String, region: String? = Locale.current.region?.identifier) -> Set<String> {
        var digits = raw.filter { $0.isNumber }
        guard digits.count >= 6 else { return [] }
        var out = Set<String>()

        // International forms already carrying a country code.
        if raw.hasPrefix("+") {
            out.insert("+" + digits)
        } else if digits.hasPrefix("00") {
            digits = String(digits.dropFirst(2))
            out.insert("+" + digits)
        } else if digits.hasPrefix("0"), let cc = callingCode(for: region) {
            // National notation: drop the trunk 0, prepend the country code.
            out.insert("+" + cc + digits.dropFirst())
        } else if let cc = callingCode(for: region) {
            out.insert("+" + cc + digits)
        }
        // Bare digits and the last nine, so mismatched prefixes still meet.
        out.insert("+" + digits)
        if digits.count >= 9 { out.insert("n" + String(digits.suffix(9))) }
        return out
    }

    static func emailKey(_ raw: String) -> String? {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), e.count > 3 else { return nil }
        return "e" + e
    }

    static func digest(_ value: String) -> String {
        let d = SHA256.hash(data: Data((salt + value).utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    /// A country's calling code. Deliberately a short table of the places
    /// this app actually has users, plus the obvious neighbours — a wrong
    /// guess just means one variant doesn't match, and the last-9 fallback
    /// still catches it.
    private static func callingCode(for region: String?) -> String? {
        guard let r = region?.uppercased() else { return nil }
        return [
            "SE": "46", "NO": "47", "DK": "45", "FI": "358", "IS": "354",
            "DE": "49", "NL": "31", "BE": "32", "FR": "33", "ES": "34",
            "IT": "39", "PT": "351", "PL": "48", "CZ": "420", "AT": "43",
            "CH": "41", "GB": "44", "IE": "353", "US": "1", "CA": "1",
            "AU": "61", "NZ": "64", "JP": "81", "SG": "65", "TH": "66",
            "EE": "372", "LV": "371", "LT": "370"
        ][r]
    }

    // MARK: - My own keys

    /// Publish digests for ONE kind, so friends can find me.
    ///
    /// Per-kind by contract (migration 099): the email digest is published
    /// automatically on launch, the phone digest only when the user types a
    /// number. Publishing one must never clear the other, and this is also
    /// why the raw phone number is never stored anywhere — the email publish
    /// doesn't need it, so nothing has to remember it.
    private func publish(keys: [String], kind: String) async -> Bool {
        guard !keys.isEmpty else { return false }
        let payload = keys.map { ["hash": Self.digest($0), "kind": kind] }
        struct P: Encodable { let p_keys: [[String: String]] }
        do {
            _ = try await supabase.rpc("set_my_contact_keys", params: P(p_keys: payload)).execute()
            return true
        } catch { return false }
    }

    /// Called once per launch. Idempotent — replaces only the email key.
    func publishEmailKey(_ email: String?) async {
        guard let email, let k = Self.emailKey(email) else { return }
        _ = await publish(keys: [k], kind: "email")
    }

    /// Called when the user gives us a number, at signup or from the profile.
    @discardableResult
    func publishPhoneKey(_ phone: String) async -> Bool {
        let keys = Array(Self.phoneKeys(phone))
        guard !keys.isEmpty else { return false }
        return await publish(keys: keys, kind: "phone")
    }

    /// Stop being discoverable, without touching the account.
    func clearMyKeys() async {
        _ = try? await supabase.rpc("clear_my_contact_keys").execute()
    }

    // MARK: - Scan

    /// Ask for contacts, hash them, and ask the server who's already here.
    func scan() async {
        scanning = true; error = nil; denied = false
        defer { scanning = false }

        let store = CNContactStore()
        let granted: Bool
        do {
            granted = try await store.requestAccess(for: .contacts)
        } catch {
            self.error = "Couldn't open your contacts."
            return
        }
        guard granted else { denied = true; return }

        // Read on a background queue — enumerating a big address book on the
        // main actor drops frames on the sheet that's presenting this.
        let harvest: (keys: [String], invitable: [InvitableContact], count: Int)
        do {
            harvest = try await Task.detached(priority: .userInitiated) {
                let keysReq = [CNContactGivenNameKey, CNContactFamilyNameKey,
                               CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
                    as [CNKeyDescriptor]
                let req = CNContactFetchRequest(keysToFetch: keysReq)
                var hashes = Set<String>()
                var people: [InvitableContact] = []
                var seen = 0
                try store.enumerateContacts(with: req) { c, _ in
                    seen += 1
                    var any = false
                    for p in c.phoneNumbers {
                        for k in Self.phoneKeys(p.value.stringValue) {
                            hashes.insert(Self.digest(k)); any = true
                        }
                    }
                    for e in c.emailAddresses {
                        if let k = Self.emailKey(e.value as String) {
                            hashes.insert(Self.digest(k)); any = true
                        }
                    }
                    guard any else { return }
                    let name = [c.givenName, c.familyName]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    guard !name.isEmpty else { return }
                    people.append(InvitableContact(
                        id: c.identifier, name: name,
                        phone: c.phoneNumbers.first?.value.stringValue))
                }
                // 4000 is the server's cap; take the first slice rather than
                // failing the whole scan on a huge address book.
                return (Array(hashes.prefix(4000)),
                        people.sorted { $0.name < $1.name },
                        seen)
            }.value
        } catch {
            self.error = "Couldn't read your contacts."
            return
        }

        scanned = harvest.count
        guard !harvest.keys.isEmpty else { invitable = harvest.invitable; return }

        struct P: Encodable { let p_hashes: [String] }
        do {
            let rows: [MatchedProfile] = try await supabase
                .rpc("match_contacts", params: P(p_hashes: harvest.keys))
                .execute().value
            matched = rows
            // Anyone we matched shouldn't also appear in the invite list.
            let takenNames = Set(rows.map { $0.name.lowercased() })
            invitable = harvest.invitable.filter { !takenNames.contains($0.name.lowercased()) }
        } catch {
            let msg = String(describing: error)
            self.error = msg.contains("rate_limited")
                ? "That's a lot of scanning — try again later."
                : "Couldn't check your contacts just now."
            invitable = harvest.invitable
        }
    }
}

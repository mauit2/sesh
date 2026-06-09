// Role state + admin management for the beverage-barcode catalog.
//
// Roles are owner-controlled and live server-side in `app_admins`
// (migration 014). This service mirrors the current user's role into the
// UI and drives the owner's grant/demote management screen. All mutations
// go through the owner-only SECURITY DEFINER RPCs — the client can't write
// `app_admins` directly, so there's no way to self-promote.

import Combine
import Foundation
import Supabase

@MainActor
final class AdminService: ObservableObject {
    /// True when the current user can add catalog entries without the
    /// 5-user consensus (owner OR admin).
    @Published private(set) var isAdmin = false
    /// True only for the single owner account — gates the grant/demote UI.
    @Published private(set) var isOwner = false
    /// Full admin roster, for the owner's management list.
    @Published private(set) var admins: [AdminEntry] = []

    struct AdminEntry: Identifiable, Equatable {
        let userId: UUID
        let isOwner: Bool
        let name: String
        var id: UUID { userId }
    }

    private struct RoleRow: Decodable { let user_id: UUID; let is_owner: Bool }

    /// Pull the current user's role (and, for owners, the full roster).
    /// Called on sign-in and after any grant/demote.
    func refresh() async {
        guard let uid = supabase.auth.currentUser?.id else {
            isAdmin = false; isOwner = false; admins = []
            return
        }
        do {
            let mine: [RoleRow] = try await supabase
                .from("app_admins")
                .select("user_id,is_owner")
                .eq("user_id", value: uid.uuidString.lowercased())
                .execute()
                .value
            isAdmin = !mine.isEmpty
            isOwner = mine.first?.is_owner ?? false
        } catch {
            isAdmin = false; isOwner = false
        }
        await loadAdmins()
    }

    /// Load every admin + their display name for the management list.
    func loadAdmins() async {
        do {
            let rows: [RoleRow] = try await supabase
                .from("app_admins")
                .select("user_id,is_owner")
                .execute()
                .value
            var names: [UUID: String] = [:]
            let ids = rows.map { $0.user_id.uuidString.lowercased() }
            if !ids.isEmpty {
                struct P: Decodable { let id: UUID; let name: String }
                let ps: [P] = try await supabase
                    .from("profiles")
                    .select("id,name")
                    .in("id", values: ids)
                    .execute()
                    .value
                for p in ps { names[p.id] = p.name }
            }
            admins = rows
                .map { AdminEntry(userId: $0.user_id, isOwner: $0.is_owner, name: names[$0.user_id] ?? "Unknown") }
                .sorted { lhs, rhs in
                    if lhs.isOwner != rhs.isOwner { return lhs.isOwner }   // owner first
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        } catch {
            // Leave the previous list in place on a transient failure.
        }
    }

    /// Owner-only. Grant admin to a user by email. Returns the granted
    /// user's name on success, nil if not found / not permitted.
    @discardableResult
    func grant(email: String) async -> String? {
        struct Params: Encodable { let p_email: String }
        struct Resp: Decodable { let ok: Bool; let name: String?; let reason: String? }
        do {
            let r: Resp = try await supabase
                .rpc("grant_admin_by_email", params: Params(p_email: email))
                .execute()
                .value
            guard r.ok else { return nil }
            await loadAdmins()
            return r.name
        } catch {
            return nil
        }
    }

    /// Owner-only. Demote an admin back to a normal user.
    func revoke(userId: UUID) async {
        struct Params: Encodable { let p_user_id: String }
        do {
            _ = try await supabase
                .rpc("revoke_admin", params: Params(p_user_id: userId.uuidString.lowercased()))
                .execute()
            await loadAdmins()
        } catch {
            // no-op; the list stays as-is on failure
        }
    }
}

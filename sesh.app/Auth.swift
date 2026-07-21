// Auth — the AuthService (Supabase session + profile bootstrap) and the
// sign-in / sign-up / password-reset / email-confirm screens. RootView
// (the app shell) stays in content_view.swift since it owns SessionView.
// Extracted; pure relocation.

import SwiftUI
import Combine
import PhotosUI
import Foundation
import Supabase

// MARK: - Auth

enum AuthError: LocalizedError {
    case emailConfirmationRequired
    case profileMissing
    case emailAlreadyRegistered
    case invalidLogin

    var errorDescription: String? {
        switch self {
        case .emailConfirmationRequired:
            return "Check your email to confirm the account, then sign in."
        case .profileMissing:
            return "We couldn't find your profile. Try signing up again."
        case .emailAlreadyRegistered:
            return "This email already has an account. Try signing in instead."
        case .invalidLogin:
            return "Wrong username/email or password."
        }
    }
}

@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(Profile)
    }

    @Published var state: State = .loading {
        didSet { syncProfileCacheForLockScreen() }
    }

    /// Stashed sign-up details, kept between requesting the email code and
    /// verifying it (when email confirmation is on and there's no session yet).
    private struct PendingSignUp {
        let email: String
        let password: String
        let name: String
        let username: String
        let age: Int
        let sex: Sex
        let weightKg: Double
        let avatarData: Data?
    }
    private var pendingSignUp: PendingSignUp?

    /// True while we're verifying a code + inserting the profile. The auth
    /// state listener checks this so it doesn't briefly flip to .signedOut
    /// when it sees the new session before the profile row exists.
    private var profileCreationInFlight = false

    /// Result of a sign-up attempt.
    enum SignUpOutcome { case completed, needsEmailCode }

    /// Mirror the user's BAC-relevant profile primitives into
    /// UserDefaults so the lock-screen App Intent can run Widmark
    /// without booting the SwiftUI hierarchy. See `LockScreenStorageKeys`
    /// — those keys are the contract between this method and
    /// `LockScreenDrinkLogger.append`. Cleared on sign-out so the
    /// next user doesn't inherit the previous user's body weight.
    private func syncProfileCacheForLockScreen() {
        switch state {
        case .signedIn(let p):
            UserDefaults.standard.set(p.weightKg, forKey: LockScreenStorageKeys.profileWeightKg)
            UserDefaults.standard.set(p.sex.rawValue, forKey: LockScreenStorageKeys.profileSexRaw)
        case .signedOut, .loading:
            UserDefaults.standard.removeObject(forKey: LockScreenStorageKeys.profileWeightKg)
            UserDefaults.standard.removeObject(forKey: LockScreenStorageKeys.profileSexRaw)
        }
    }

    init() {
        Task { [weak self] in
            guard let self else { return }
            for await (event, session) in supabase.auth.authStateChanges {
                await self.handle(event: event, session: session)
            }
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
            // A sign-up confirmation is mid-flight (session exists but the
            // profile row hasn't been inserted yet) — let confirmSignUp drive
            // the state instead of prematurely flipping to .signedOut.
            if profileCreationInFlight { return }
            if let userId = session?.user.id,
               let profile = try? await loadProfile(userId: userId) {
                state = .signedIn(profile)
            } else {
                state = .signedOut
            }
        case .signedOut:
            state = .signedOut
        default:
            break
        }
    }

    /// Create the auth user. If email confirmation is on (no session yet),
    /// stash the profile details and signal that a 6-digit code is needed;
    /// confirmSignUp finishes the job once the code is verified. If
    /// confirmation is off, the profile is created immediately.
    @discardableResult
    func signUp(email: String, password: String, name: String, username: String, age: Int, sex: Sex, weightKg: Double, avatarData: Data? = nil) async throws -> SignUpOutcome {
        let cleanEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let response = try await supabase.auth.signUp(email: cleanEmail, password: password)
        let pending = PendingSignUp(email: cleanEmail, password: password, name: name,
                                    username: username.trimmingCharacters(in: .whitespaces).lowercased(),
                                    age: age, sex: sex, weightKg: weightKg, avatarData: avatarData)
        if response.session != nil {
            try await createProfile(userId: response.user.id, from: pending)
            return .completed
        }
        // Anti-enumeration: when the email already belongs to a registered
        // account, Supabase returns an obfuscated user with NO identities and
        // no session (rather than erroring). Surface that as a clear message
        // instead of dead-ending on the confirm-code screen.
        if let identities = response.user.identities, identities.isEmpty {
            throw AuthError.emailAlreadyRegistered
        }
        pendingSignUp = pending
        return .needsEmailCode
    }

    /// Verify the emailed 6-digit signup code, then — now that we have a
    /// session — create the profile and sign the user in.
    func confirmSignUp(code: String) async throws {
        guard let pending = pendingSignUp else { throw AuthError.profileMissing }
        try await supabase.auth.verifyOTP(
            email: pending.email,
            token: code.trimmingCharacters(in: .whitespaces),
            type: .signup
        )
        guard let userId = supabase.auth.currentUser?.id else { throw AuthError.profileMissing }
        try await createProfile(userId: userId, from: pending)
        pendingSignUp = nil
    }

    /// Re-send the signup confirmation email (Supabase resends for an
    /// existing unconfirmed user when signUp is called again).
    func resendSignUpCode() async throws {
        guard let pending = pendingSignUp else { return }
        _ = try await supabase.auth.signUp(email: pending.email, password: pending.password)
    }

    /// Insert the profile row + optional avatar and flip to signed-in. Shared
    /// by the confirmation-off and code-verified paths.
    private func createProfile(userId: UUID, from p: PendingSignUp) async throws {
        profileCreationInFlight = true
        defer { profileCreationInFlight = false }

        let avatarURL = try? await uploadAvatar(data: p.avatarData, userId: userId)

        struct InsertProfile: Encodable {
            let id: String
            let name: String
            let username: String?
            let age: Int
            let sex: String
            let weight_kg: Double
            let avatar_url: String?
        }

        let payload = InsertProfile(
            id: userId.uuidString.lowercased(),
            name: p.name,
            username: p.username.isEmpty ? nil : p.username,
            age: p.age,
            sex: p.sex.rawValue,
            weight_kg: p.weightKg,
            avatar_url: avatarURL
        )
        try await supabase.from("profiles").insert(payload).execute()

        let profile = try await loadProfile(userId: userId)
        state = .signedIn(profile)
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        let profile = try await loadProfile(userId: session.user.id)
        state = .signedIn(profile)
    }

    /// Live username-availability check for the sign-up form (works while
    /// signed out — the RPC is granted to anon). Returns true only for a
    /// well-formed, unclaimed username.
    func isUsernameAvailable(_ username: String) async -> Bool {
        struct P: Encodable { let p_username: String }
        do {
            return try await supabase
                .rpc("username_available", params: P(p_username: username))
                .execute().value
        } catch {
            return false
        }
    }

    /// Sign in with a @username instead of email. The `username-login` Edge
    /// Function resolves the email server-side (never exposed) and returns
    /// session tokens, which we install locally.
    func signInWithUsername(username: String, password: String) async throws {
        struct Body: Encodable { let username: String; let password: String }
        struct Resp: Decodable { let access_token: String?; let refresh_token: String? }
        let resp: Resp
        do {
            resp = try await supabase.functions.invoke(
                "username-login",
                options: FunctionInvokeOptions(body: Body(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                ))
            )
        } catch {
            // 400 from the function (bad username/password) surfaces here.
            throw AuthError.invalidLogin
        }
        guard let at = resp.access_token, let rt = resp.refresh_token else {
            throw AuthError.invalidLogin
        }
        let session = try await supabase.auth.setSession(accessToken: at, refreshToken: rt)
        let profile = try await loadProfile(userId: session.user.id)
        state = .signedIn(profile)
    }

    /// Step 1 of password recovery: email the user a 6-digit recovery code.
    /// (The Supabase "Reset Password" email template must include `{{ .Token }}`
    /// for the code to be delivered.) We don't reveal whether the email exists.
    func sendPasswordReset(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(
            email.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

    /// Step 2 of password recovery: verify the emailed code, which yields a
    /// short-lived recovery session, then set the new password. On success the
    /// user is signed in with the new password (authStateChanges → .signedIn).
    func confirmPasswordReset(email: String, code: String, newPassword: String) async throws {
        try await supabase.auth.verifyOTP(
            email: email.trimmingCharacters(in: .whitespaces).lowercased(),
            token: code.trimmingCharacters(in: .whitespaces),
            type: .recovery
        )
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
    }

    /// Set / change the signed-in user's @username via the migration-018 RPC.
    /// Returns nil on success, or a short user-facing error string.
    func setUsername(_ username: String) async -> String? {
        struct P: Encodable { let p_username: String }
        struct R: Decodable { let ok: Bool; let username: String?; let reason: String? }
        do {
            let r: R = try await supabase
                .rpc("set_username", params: P(p_username: username))
                .execute().value
            if r.ok {
                if case .signedIn(var p) = state {
                    p.username = r.username
                    state = .signedIn(p)
                }
                return nil
            }
            switch r.reason {
            case "taken":   return "That username is taken."
            case "invalid": return "3–20 chars: lowercase letters, numbers, underscore."
            default:        return "Couldn't save username."
            }
        } catch {
            return "Couldn't save username."
        }
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        // Tear down any in-flight lock-screen activity AND wipe the
        // home-screen widget snapshot. The next user to sign in
        // shouldn't inherit the previous user's BAC card OR see
        // their roster on the home-screen widget. Local LiveSeshState
        // gets cleared by the auth state transition anyway — these
        // calls keep the cross-process surfaces in lockstep.
        await MainActor.run {
            LiveActivityController.shared.end()
            WidgetSharedStore.clear()
        }
        state = .signedOut
    }

    func updateProfile(_ profile: Profile, newAvatarData: Data? = nil, removeAvatar: Bool = false) async throws {
        var finalURL = profile.avatarURL
        if let data = newAvatarData {
            finalURL = try await uploadAvatar(data: data, userId: profile.id)
        } else if removeAvatar {
            finalURL = nil
            _ = try? await supabase.storage.from("avatars").remove(paths: ["\(profile.id.uuidString.lowercased())/avatar.jpg"])
        }

        struct UpdatePayload: Encodable {
            let name: String
            let age: Int
            let sex: String
            let weight_kg: Double
            let avatar_url: String?
        }
        let payload = UpdatePayload(
            name: profile.name,
            age: profile.age,
            sex: profile.sex.rawValue,
            weight_kg: profile.weightKg,
            avatar_url: finalURL
        )
        try await supabase
            .from("profiles")
            .update(payload)
            .eq("id", value: profile.id.uuidString.lowercased())
            .execute()

        var updated = profile
        updated.avatarURL = finalURL
        state = .signedIn(updated)
    }

    private func uploadAvatar(data: Data?, userId: UUID) async throws -> String? {
        guard let data else { return nil }
        // Avatars display at most ~72pt (~216px @3x) but appear EVERYWHERE
        // (friends, stories, chats, map pins, every post) — a full-res upload
        // was ~750 KB re-downloaded constantly. Downscale to 256px (~30 KB).
        let small = ImageDownscale.jpeg(data, maxDim: 256, quality: 0.82) ?? data
        let path = "\(userId.uuidString.lowercased())/avatar.jpg"
        // No thumbnail sibling — the avatar itself is already thumbnail-sized.
        try await StorageUploader.uploadImage(
            bucket: "avatars", path: path, data: small, upsert: true, thumbnail: false
        )
        let url = try supabase.storage.from("avatars").getPublicURL(path: path)
        // Add a cache-buster so AsyncImage re-fetches after replace.
        return url.absoluteString + "?v=\(Int(Date().timeIntervalSince1970))"
    }

    private func loadProfile(userId: UUID) async throws -> Profile {
        let profile: Profile = try await supabase
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return profile
    }
}


// MARK: - Loading screen

struct LoadingView: View {
    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 14) {
                Circle()
                    .fill(Color.whiskey)
                    .frame(width: 10, height: 10)
                    .shadow(color: Color.whiskey.opacity(0.9), radius: 12)
                Text("sesh")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .italic()
                    .tracking(-1.5)
                    .foregroundStyle(Color.cream)
                ProgressView()
                    .tint(Color.whiskey)
                    .padding(.top, 6)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Auth screen

struct AuthView: View {
    @ObservedObject var auth: AuthService

    enum Mode: String { case signIn, signUp }
    @State private var mode: Mode = .signIn

    @State private var email = ""
    @State private var password = ""

    @State private var name = ""
    @State private var username = ""
    @State private var age: Double = 25
    @State private var sex: Sex = .male
    @State private var weightKg: Double = 75
    @State private var avatarData: Data?

    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showReset = false
    @State private var showSignupConfirm = false
    /// Live username availability for sign-up: nil = unknown/checking,
    /// true = free, false = taken/invalid. Debounced via usernameCheckTask.
    @State private var usernameAvailable: Bool? = nil
    @State private var checkingUsername = false
    @State private var usernameCheckTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    enum Field { case email, password, name, username }

    private var cleanUsername: String { username.lowercased().trimmingCharacters(in: .whitespaces) }
    private var usernameFormatValid: Bool {
        cleanUsername.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    /// A single password requirement and whether the current input meets it.
    /// Mirrors the server-side rules configured in Supabase Auth
    /// (min length 8 + lower/upper/digit/symbol) so users get instant
    /// feedback instead of a round-trip rejection on submit.
    struct PasswordRule: Identifiable {
        let id: String
        let label: String
        let satisfied: Bool
    }

    private var passwordRules: [PasswordRule] {
        func has(_ pattern: String) -> Bool {
            password.range(of: pattern, options: .regularExpression) != nil
        }
        return [
            PasswordRule(id: "len", label: "At least 8 characters", satisfied: password.count >= 8),
            PasswordRule(id: "case", label: "Upper & lowercase letters", satisfied: has("[a-z]") && has("[A-Z]")),
            PasswordRule(id: "digit", label: "A number", satisfied: has("[0-9]")),
            PasswordRule(id: "symbol", label: "A symbol (!@#$…)", satisfied: has("[^A-Za-z0-9]"))
        ]
    }

    /// True when every sign-up password rule is satisfied.
    private var passwordMeetsRules: Bool { passwordRules.allSatisfy(\.satisfied) }

    private var canSubmit: Bool {
        if mode == .signUp {
            return email.contains("@")
                && passwordMeetsRules
                && !name.trimmingCharacters(in: .whitespaces).isEmpty
                && usernameFormatValid
                && usernameAvailable == true
        }
        // Sign-in accepts an email OR a username as the identifier; the
        // server validates the actual password.
        return !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    modeSwitcher
                    fields
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    submitButton
                    if mode == .signIn {
                        forgotPasswordLink
                    }
                    footnote
                }
                .padding(.horizontal, 28)
                .padding(.top, 56)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onChange(of: username) { _, _ in scheduleUsernameCheck() }
        .sheet(isPresented: $showReset) {
            PasswordResetView(auth: auth, prefillEmail: email)
        }
        .sheet(isPresented: $showSignupConfirm) {
            SignUpConfirmView(auth: auth, email: email)
        }
    }

    private var forgotPasswordLink: some View {
        Button {
            focus = nil
            showReset = true
        } label: {
            Text("Forgot your password?")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.whiskey)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.whiskey.opacity(0.9), radius: 8)
                Text("EST. TONIGHT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
            }
            Text("sesh")
                .font(.system(size: 72, weight: .black, design: .rounded))
                .italic()
                .tracking(-3)
                .foregroundStyle(Color.cream)
            Text(mode == .signIn ? "Welcome back." : "Join the tab.")
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .italic()
                .foregroundStyle(Color.cream.opacity(0.7))
                .padding(.top, 2)
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            ModePill(label: "Sign in", selected: mode == .signIn) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    mode = .signIn
                    errorMessage = nil
                }
            }
            ModePill(label: "Create account", selected: mode == .signUp) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    mode = .signUp
                    errorMessage = nil
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(spacing: 10) {
            LoungeField(
                label: mode == .signUp ? "EMAIL" : "EMAIL OR USERNAME",
                text: $email,
                placeholder: mode == .signUp ? "you@seshapp.xyz" : "you@seshapp.xyz or yourname",
                keyboard: mode == .signUp ? .emailAddress : .default,
                autocapitalize: false
            )
            .focused($focus, equals: .email)

            LoungeSecureField(
                label: "PASSWORD",
                text: $password,
                placeholder: mode == .signUp ? "8+ with a number & symbol" : "your password"
            )
            .focused($focus, equals: .password)

            passwordRequirements

            if mode == .signUp {
                HStack(spacing: 14) {
                    AvatarPicker(
                        existingURL: nil,
                        initial: name.isEmpty ? "?" : String(name.prefix(1)).uppercased(),
                        size: 72,
                        imageData: $avatarData,
                        onRemove: { avatarData = nil }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PHOTO")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.bronze)
                        Text("Optional — tap to add.")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                LoungeField(
                    label: "NAME",
                    text: $name,
                    placeholder: "What should we call you?"
                )
                .focused($focus, equals: .name)

                LoungeField(
                    label: "USERNAME",
                    text: $username,
                    placeholder: "yourname",
                    autocapitalize: false,
                    prefix: "@"
                )
                .focused($focus, equals: .username)
                usernameStatus

                LoungeNumberField(
                    label: "AGE",
                    value: $age,
                    range: 18...100,
                    step: 1,
                    unit: "years"
                )

                LoungePickerField(label: "SEX") {
                    SexToggle(sex: $sex, accent: .whiskey)
                }

                LoungeNumberField(
                    label: "WEIGHT",
                    value: $weightKg,
                    range: 40...160,
                    step: 1,
                    unit: "kg"
                )
            }
        }
    }

    /// Live checklist of password requirements, shown only while creating an
    /// account and only once the user has started typing a password.
    @ViewBuilder
    private var passwordRequirements: some View {
        if mode == .signUp, !password.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(passwordRules) { rule in
                    HStack(spacing: 8) {
                        Image(systemName: rule.satisfied ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(rule.satisfied ? Color.whiskey : Color.bronze.opacity(0.55))
                        Text(rule.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(rule.satisfied ? Color.cream.opacity(0.9) : Color.cream.opacity(0.5))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bronze.opacity(0.2), lineWidth: 1))
            .animation(.easeInOut(duration: 0.2), value: password)
            .transition(.opacity)
        }
    }

    /// Inline availability/format feedback under the sign-up username field.
    @ViewBuilder
    private var usernameStatus: some View {
        if mode == .signUp, !username.isEmpty {
            HStack(spacing: 8) {
                if !usernameFormatValid {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.bronze)
                    Text("3–20 chars: lowercase letters, numbers, underscore")
                        .foregroundStyle(Color.cream.opacity(0.6))
                } else if checkingUsername {
                    ProgressView().controlSize(.mini).tint(Color.bronze)
                    Text("Checking…").foregroundStyle(Color.cream.opacity(0.6))
                } else if usernameAvailable == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.whiskey)
                    Text("@\(cleanUsername) is available").foregroundStyle(Color.cream.opacity(0.85))
                } else if usernameAvailable == false {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Status.drunk.color)
                    Text("That username is taken").foregroundStyle(Color.cream.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 4)
        }
    }

    /// Debounced availability check, called from the body's onChange.
    private func scheduleUsernameCheck() {
        usernameCheckTask?.cancel()
        usernameAvailable = nil
        guard mode == .signUp, usernameFormatValid else { return }
        let candidate = cleanUsername
        checkingUsername = true
        usernameCheckTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let ok = await auth.isUsernameAvailable(candidate)
            if Task.isCancelled || candidate != cleanUsername { return }
            usernameAvailable = ok
            checkingUsername = false
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Status.drunk.color)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cream.opacity(0.9))
                .lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Status.drunk.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Status.drunk.color.opacity(0.35), lineWidth: 1))
    }

    private var submitButton: some View {
        Button {
            focus = nil
            submit()
        } label: {
            HStack {
                if loading {
                    ProgressView().tint(Color.ink)
                    Spacer()
                } else {
                    Text(mode == .signIn ? "SIGN IN" : "CREATE ACCOUNT")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(canSubmit ? Color.cream : Color.cream.opacity(0.4))
            )
            .shadow(color: Color.whiskey.opacity(canSubmit ? 0.5 : 0), radius: 20, y: 10)
        }
        .disabled(!canSubmit || loading)
        .buttonStyle(PressScaleStyle())
    }

    private var footnote: some View {
        Text("By continuing you accept that sesh is a fun BAC estimate, not a legal or medical reference. Never use it to decide whether to drive.")
            .font(.system(size: 10))
            .lineSpacing(3)
            .foregroundStyle(Color.bronze)
            .padding(.top, 4)
    }

    private func submit() {
        loading = true
        errorMessage = nil
        Task { @MainActor in
            do {
                switch mode {
                case .signIn:
                    let identifier = email.trimmingCharacters(in: .whitespaces)
                    if identifier.contains("@") {
                        try await auth.signIn(email: identifier, password: password)
                    } else {
                        try await auth.signInWithUsername(username: identifier, password: password)
                    }
                case .signUp:
                    let outcome = try await auth.signUp(
                        email: email,
                        password: password,
                        name: name.trimmingCharacters(in: .whitespaces),
                        username: cleanUsername,
                        age: Int(age),
                        sex: sex,
                        weightKg: weightKg,
                        avatarData: avatarData
                    )
                    if outcome == .needsEmailCode {
                        showSignupConfirm = true
                    }
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Password reset (OTP code flow)

/// Two-step in-app password recovery: request a 6-digit code by email, then
/// enter the code + a new password. Uses the same strength rules as sign-up.
/// On success the user is signed in with the new password.
private struct PasswordResetView: View {
    @ObservedObject var auth: AuthService
    let prefillEmail: String
    @Environment(\.dismiss) private var dismiss

    enum Phase { case request, verify }
    @State private var phase: Phase = .request
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var info: String?

    init(auth: AuthService, prefillEmail: String) {
        self.auth = auth
        self.prefillEmail = prefillEmail
        _email = State(initialValue: prefillEmail)
    }

    private func has(_ pattern: String) -> Bool {
        newPassword.range(of: pattern, options: .regularExpression) != nil
    }
    private var newPasswordValid: Bool {
        newPassword.count >= 8 && has("[a-z]") && has("[A-Z]") && has("[0-9]") && has("[^A-Za-z0-9]")
    }
    private var canAct: Bool {
        switch phase {
        case .request: return email.contains("@")
        case .verify:  return code.trimmingCharacters(in: .whitespaces).count >= 8 && newPasswordValid
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if phase == .request {
                        LoungeField(label: "EMAIL", text: $email,
                                    placeholder: "you@seshapp.xyz",
                                    keyboard: .emailAddress, autocapitalize: false)
                    } else {
                        LoungeField(label: "8-DIGIT CODE", text: $code,
                                    placeholder: "12345678", keyboard: .numberPad)
                        LoungeSecureField(label: "NEW PASSWORD", text: $newPassword,
                                          placeholder: "8+ with a number & symbol")
                        if !newPassword.isEmpty { rules }
                    }
                    if let errorMessage { banner(errorMessage, bad: true) }
                    if let info { banner(info, bad: false) }
                    actionButton
                    if phase == .verify { resendRow }
                }
                .padding(.horizontal, 28)
                .padding(.top, 52)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .padding(12)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16)
            .padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(phase == .request ? "RESET PASSWORD" : "ENTER CODE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text(phase == .request ? "Forgot it? Happens." : "Check your email.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic()
                .tracking(-1)
                .foregroundStyle(Color.cream)
            Text(phase == .request
                 ? "Enter your email and we'll send an 8-digit code to reset your password."
                 : "We sent an 8-digit code to \(email). Enter it below with your new password.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
                .lineSpacing(2)
        }
    }

    private var rules: some View {
        let items: [(String, Bool)] = [
            ("At least 8 characters", newPassword.count >= 8),
            ("Upper & lowercase letters", has("[a-z]") && has("[A-Z]")),
            ("A number", has("[0-9]")),
            ("A symbol (!@#$…)", has("[^A-Za-z0-9]"))
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { label, ok in
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ok ? Color.whiskey : Color.bronze.opacity(0.55))
                    Text(label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(ok ? Color.cream.opacity(0.9) : Color.cream.opacity(0.5))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bronze.opacity(0.2), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: newPassword)
    }

    private func banner(_ message: String, bad: Bool) -> some View {
        let tint = bad ? Status.drunk.color : Color.whiskey
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cream.opacity(0.9)).lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var actionButton: some View {
        Button { act() } label: {
            HStack {
                if loading { ProgressView().tint(Color.ink); Spacer() }
                else {
                    Text(phase == .request ? "SEND CODE" : "SET NEW PASSWORD")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(canAct ? Color.cream : Color.cream.opacity(0.4)))
            .shadow(color: Color.whiskey.opacity(canAct ? 0.5 : 0), radius: 20, y: 10)
        }
        .disabled(!canAct || loading)
        .buttonStyle(PressScaleStyle())
    }

    private var resendRow: some View {
        Button {
            phase = .request
            code = ""; newPassword = ""; errorMessage = nil; info = nil
        } label: {
            Text("Didn't get a code? Send again")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func act() {
        loading = true; errorMessage = nil; info = nil
        Task { @MainActor in
            do {
                switch phase {
                case .request:
                    try await auth.sendPasswordReset(email: email)
                    info = "If an account exists for that email, a code is on its way."
                    phase = .verify
                case .verify:
                    try await auth.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
                    dismiss() // auth state flips to .signedIn with the new password
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Sign-up email confirmation (OTP code flow)

/// Shown after creating an account when email confirmation is on. The user
/// enters the 6-digit code from their email; on success their profile is
/// created and they're signed in. No web link / redirect involved.
private struct SignUpConfirmView: View {
    @ObservedObject var auth: AuthService
    let email: String
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var loading = false
    @State private var resending = false
    @State private var errorMessage: String?
    @State private var info: String?

    private var canVerify: Bool { code.trimmingCharacters(in: .whitespaces).count >= 8 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LoungeField(label: "8-DIGIT CODE", text: $code,
                                placeholder: "12345678", keyboard: .numberPad)
                    if let errorMessage { banner(errorMessage, bad: true) }
                    if let info { banner(info, bad: false) }
                    verifyButton
                    resendRow
                }
                .padding(.horizontal, 28)
                .padding(.top, 52)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .padding(12)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFIRM EMAIL")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text("One last thing.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic().tracking(-1)
                .foregroundStyle(Color.cream)
            Text("We sent an 8-digit code to \(email). Enter it to finish creating your account.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
                .lineSpacing(2)
        }
    }

    private func banner(_ message: String, bad: Bool) -> some View {
        let tint = bad ? Status.drunk.color : Color.whiskey
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cream.opacity(0.9)).lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var verifyButton: some View {
        Button { verify() } label: {
            HStack {
                if loading { ProgressView().tint(Color.ink); Spacer() }
                else {
                    Text("CONFIRM & ENTER")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(canVerify ? Color.cream : Color.cream.opacity(0.4)))
            .shadow(color: Color.whiskey.opacity(canVerify ? 0.5 : 0), radius: 20, y: 10)
        }
        .disabled(!canVerify || loading)
        .buttonStyle(PressScaleStyle())
    }

    private var resendRow: some View {
        Button { resend() } label: {
            Text(resending ? "Sending…" : "Didn't get a code? Send again")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(maxWidth: .infinity)
        }
        .disabled(resending)
        .buttonStyle(PressScaleStyle())
    }

    private func verify() {
        loading = true; errorMessage = nil; info = nil
        Task { @MainActor in
            do {
                try await auth.confirmSignUp(code: code)
                dismiss() // auth state flips to .signedIn
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }

    private func resend() {
        resending = true; errorMessage = nil; info = nil
        Task { @MainActor in
            do {
                try await auth.resendSignUpCode()
                info = "Sent a new code to \(email)."
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            resending = false
        }
    }
}


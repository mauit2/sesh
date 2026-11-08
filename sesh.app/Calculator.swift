import SwiftUI
import Supabase

// MARK: - Calculator
//
// The pre-night planner, rebuilt as a plain calculator (owner, 8 Nov 2026):
// pick WHO is drinking (just me, an anonymous headcount of men and women at
// average weights, or real friends whose profile weights are used), add the
// DRINKS each person has, set HOW LONG the night runs, and read the
// estimated level per person plus the total to buy. No group, no invites,
// no sync — everything is local and recomputed on every change.
//
// Math is the same steady-drinking Widmark the old planner used: with the
// drinks spread over H hours, BAC at the end of the window is
// grams / (weight·1000·r) · 100 − 0.015·H, which is also the peak.

/// Who the numbers are for.
enum CalcCrew: String, CaseIterable, Identifiable, Codable {
    case me, people, friends
    var id: String { rawValue }
    var label: String {
        switch self {
        case .me:      return "Just me"
        case .people:  return "Headcount"
        case .friends: return "Friends"
        }
    }
    var icon: String {
        switch self {
        case .me:      return "person.fill"
        case .people:  return "person.3.fill"
        case .friends: return "person.2.fill"
        }
    }
}

/// Average adult body weights for an anonymous headcount. Statistics
/// Sweden (SCB), self-reported, 2022–23: men ≈ 84 kg, women ≈ 69 kg.
enum CalcAverages {
    static let manKg: Double = 84
    static let womanKg: Double = 69
}

/// One drink line, stored with its own volume/ABV so saved and scanned
/// drinks (not in the catalog) survive a relaunch.
struct CalcDrink: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let detail: String
    let category: DrinkCategory
    let volumeML: Double
    let abv: Double
    var count: Int

    init(option: DrinkOption, count: Int) {
        name = option.name; detail = option.detail; category = option.category
        volumeML = option.volumeML; abv = option.abv; self.count = count
    }
    var option: DrinkOption {
        DrinkCatalog.allOptions.first { $0.name == name }
            ?? DrinkOption(category: category, name: name, detail: detail, volumeML: volumeML, abv: abv)
    }
    var grams: Double { volumeML * abv * 0.789 }
}

/// How the drink list relates to the people: everyone drinks the list
/// (each), or the list is one pool split evenly between them (shared).
enum CalcSharing: String, Codable, CaseIterable, Identifiable {
    case each, shared
    var id: String { rawValue }
    var label: String { self == .each ? "EACH" : "SHARED" }
}

/// Everything the calculator remembers between openings.
struct CalcState: Codable, Equatable {
    var crew: CalcCrew = .me
    var men: Int = 2
    var women: Int = 2
    var friendIds: [UUID] = []
    var includeMe: Bool = true
    /// The drink list: per person in `.each`, the whole pool in `.shared`.
    var drinks: [CalcDrink] = []
    var sharing: CalcSharing = .each
    /// `.each` only: a person's own list when they differ from the rest,
    /// keyed by CalcPerson.id ("me", a friend's id, "men", "women").
    var perPerson: [String: [CalcDrink]] = [:]
    var hours: Double = 4

    init() {}

    /// Missing keys fall back to defaults, so adding a field later never
    /// throws the saved state away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crew = try c.decodeIfPresent(CalcCrew.self, forKey: .crew) ?? .me
        men = try c.decodeIfPresent(Int.self, forKey: .men) ?? 2
        women = try c.decodeIfPresent(Int.self, forKey: .women) ?? 2
        friendIds = try c.decodeIfPresent([UUID].self, forKey: .friendIds) ?? []
        includeMe = try c.decodeIfPresent(Bool.self, forKey: .includeMe) ?? true
        drinks = try c.decodeIfPresent([CalcDrink].self, forKey: .drinks) ?? []
        sharing = try c.decodeIfPresent(CalcSharing.self, forKey: .sharing) ?? .each
        perPerson = try c.decodeIfPresent([String: [CalcDrink]].self, forKey: .perPerson) ?? [:]
        hours = try c.decodeIfPresent(Double.self, forKey: .hours) ?? 4
    }

    static let storageKey = "sesh.calculator.state.v2"

    static func load() -> CalcState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(CalcState.self, from: data) else { return CalcState() }
        return s
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// One line in the result: a real person, or a stand-in for N people of
/// the same build.
struct CalcPerson: Identifiable {
    let id: String
    let name: String
    let detail: String
    let avatarURL: String?
    let weightKg: Double
    let sex: Sex
    let count: Int
}

enum CalcMath {
    static let decayPerHour = 0.015

    /// Level at the end of `hours` of steady drinking — also the peak.
    static func bac(grams: Double, weightKg: Double, sex: Sex, hours: Double) -> Double {
        guard weightKg > 0 else { return 0 }
        let raw = grams / (weightKg * 1000 * sex.r) * 100
        return max(0, raw - decayPerHour * hours)
    }

    static func status(_ bac: Double) -> Status {
        switch bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    static func option(named name: String) -> DrinkOption? {
        DrinkCatalog.allOptions.first { $0.name == name }
    }

    /// "25m", "1h 40m", "3h".
    static func formatDuration(_ hours: Double) -> String {
        let mins = Int((hours * 60).rounded())
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Entry card (Events tab)

/// Replaces the collapsible "Plan tonight's drinks" row. One tap opens
/// the calculator sheet.
struct CalculatorEntryCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 38, height: 38)
                        .shadow(color: Color.whiskey.opacity(0.5), radius: 9, y: 2)
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(Color.ink)
                }
                Text("Calculator")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [Color.whiskey.opacity(0.40), Color.whiskey.opacity(0.10), .clear],
                                    center: UnitPoint(x: 0.08, y: 0.5),
                                    startRadius: 4, endRadius: 320
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.whiskey.opacity(0.95), Color.whiskey.opacity(0.5), Color.whiskey.opacity(0.25)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            .shadow(color: Color.whiskey.opacity(0.35), radius: 20, y: 4)
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Sheet

struct CalculatorSheet: View {
    let profile: Profile
    @ObservedObject var friends: FriendsService
    @Environment(\.dismiss) private var dismiss

    @State private var state = CalcState.load()
    /// Friends' full profiles (weight + sex), fetched once per opening.
    /// RLS lets you read an accepted friend's profile row.
    @State private var friendProfiles: [UUID: Profile] = [:]
    @State private var loadingFriends = false
    @State private var menuOpen = false
    @State private var friendPickerOpen = false
    /// Same persisted list the live menu shows under SAVED DRINKS.
    @StateObject private var saved = SavedDrinksStore()

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    // MARK: derived

    private static func grams(_ list: [CalcDrink]) -> Double { list.reduce(0) { $0 + $1.grams * Double($1.count) } }
    private static func count(_ list: [CalcDrink]) -> Int { list.reduce(0) { $0 + $1.count } }

    private var listCount: Int { Self.count(state.drinks) }
    private var hasDrinks: Bool { Self.grams(state.drinks) > 0 || state.perPerson.values.contains { Self.grams($0) > 0 } }
    /// Sharing only applies to more than one person.
    private var isShared: Bool { state.sharing == .shared && state.crew != .me }
    private var hasOverrides: Bool { !isShared && people.contains { state.perPerson[$0.id] != nil } }

    /// The list one person drinks.
    private func drinks(for p: CalcPerson) -> [CalcDrink] {
        isShared ? state.drinks : (state.perPerson[p.id] ?? state.drinks)
    }
    private func grams(for p: CalcPerson) -> Double {
        isShared ? Self.grams(state.drinks) / Double(max(headcount, 1)) : Self.grams(drinks(for: p))
    }
    /// "6 large beer · 2 shot of vodka" — or the even share in shared mode.
    private func drinksText(for p: CalcPerson) -> String {
        let list = drinks(for: p)
        guard !list.isEmpty else { return "no drinks" }
        if isShared {
            let n = Double(max(headcount, 1))
            return list.map { d -> String in
                let share = Double(d.count) / n
                let num = share == share.rounded() ? "\(Int(share))" : String(format: "%.1f", share)
                return "\(num) \(d.name.lowercased())"
            }.joined(separator: " · ")
        }
        return list.map { "\($0.count) \($0.name.lowercased())" }.joined(separator: " · ")
    }
    /// Everything that has to be bought: the sum of every person's list.
    private var totalDrinks: [(name: String, count: Int)] {
        var totals: [String: Int] = [:]
        var order: [String] = []
        func addAll(_ list: [CalcDrink], times: Int) {
            for d in list {
                if totals[d.name] == nil { order.append(d.name) }
                totals[d.name, default: 0] += d.count * times
            }
        }
        if isShared { addAll(state.drinks, times: 1) }
        else { for p in people { addAll(drinks(for: p), times: p.count) } }
        return order.map { ($0, totals[$0] ?? 0) }
    }

    private var people: [CalcPerson] {
        switch state.crew {
        case .me:
            return [me]
        case .people:
            var rows: [CalcPerson] = []
            if state.men > 0 {
                rows.append(CalcPerson(id: "men", name: state.men == 1 ? "1 man" : "\(state.men) men",
                                       detail: "avg \(Int(CalcAverages.manKg)) kg", avatarURL: nil,
                                       weightKg: CalcAverages.manKg, sex: .male, count: state.men))
            }
            if state.women > 0 {
                rows.append(CalcPerson(id: "women", name: state.women == 1 ? "1 woman" : "\(state.women) women",
                                       detail: "avg \(Int(CalcAverages.womanKg)) kg", avatarURL: nil,
                                       weightKg: CalcAverages.womanKg, sex: .female, count: state.women))
            }
            return rows
        case .friends:
            var rows: [CalcPerson] = []
            if state.includeMe { rows.append(me) }
            for f in friends.friends where state.friendIds.contains(f.id) {
                let first = f.name.split(separator: " ").first.map(String.init) ?? f.name
                if let p = friendProfiles[f.id] {
                    // Their weight drives the math but is never shown.
                    rows.append(CalcPerson(id: f.id.uuidString, name: first, detail: "",
                                           avatarURL: f.avatarURL, weightKg: p.weightKg, sex: p.sex, count: 1))
                } else {
                    rows.append(CalcPerson(id: f.id.uuidString, name: first,
                                           detail: loadingFriends ? "loading…" : "no weight on file",
                                           avatarURL: f.avatarURL, weightKg: 0, sex: .male, count: 1))
                }
            }
            return rows
        }
    }
    private var me: CalcPerson {
        CalcPerson(id: "me", name: "You", detail: "\(Int(profile.weightKg.rounded())) kg · \(profile.sex.short)",
                   avatarURL: profile.avatarURL, weightKg: profile.weightKg, sex: profile.sex, count: 1)
    }
    private var headcount: Int { people.reduce(0) { $0 + $1.count } }
    private var selectedFriendCount: Int { friends.friends.filter { state.friendIds.contains($0.id) }.count }

    private func bac(for p: CalcPerson) -> Double {
        CalcMath.bac(grams: grams(for: p), weightKg: p.weightKg, sex: p.sex, hours: state.hours)
    }

    /// Which person's own list the menu is editing (nil = the shared list).
    @State private var editing: CalcPerson? = nil

    private func orderBinding(for list: [CalcDrink]) -> Binding<[OrderItem]> {
        Binding(
            get: { list.flatMap { d in (0..<max(d.count, 0)).map { _ in OrderItem(option: d.option) } } },
            set: { _ in }
        )
    }
    private static func adding(_ o: DrinkOption, to list: [CalcDrink]) -> [CalcDrink] {
        var l = list
        if let i = l.firstIndex(where: { $0.name == o.name }) { l[i].count += 1 } else { l.append(CalcDrink(option: o, count: 1)) }
        return l
    }
    private static func removing(_ o: DrinkOption, from list: [CalcDrink]) -> [CalcDrink] {
        var l = list
        guard let i = l.firstIndex(where: { $0.name == o.name }) else { return l }
        l[i].count -= 1
        if l[i].count <= 0 { l.remove(at: i) }
        return l
    }

    private func add(_ o: DrinkOption) { state.drinks = Self.adding(o, to: state.drinks) }
    private func removeOne(_ o: DrinkOption) { state.drinks = Self.removing(o, from: state.drinks) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                resultCard
                whoSection
                hoursCard
                drinksSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(Color.ink.ignoresSafeArea())
        .onChange(of: state) { _, s in s.save() }
        .task(id: state.crew) {
            if state.crew == .friends { await loadFriendProfiles() }
        }
        .task(id: state.friendIds) {
            if state.crew == .friends { await loadFriendProfiles() }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.crew)
        .sheet(isPresented: $menuOpen) {
            MenuSheet(
                order: orderBinding(for: state.drinks),
                shareMode: .constant(false),
                saved: saved,
                title: "Drinks",
                countHint: state.crew == .me ? "in total" : (isShared ? "shared" : "each"),
                doneHint: "BACK TO CALCULATOR",
                onAdd: { add($0) },
                onRemove: { removeOne($0) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        .sheet(item: $editing) { p in
            // This person's own list; starts as a copy of the common list.
            MenuSheet(
                order: orderBinding(for: state.perPerson[p.id] ?? state.drinks),
                shareMode: .constant(false),
                saved: saved,
                title: p.id == "me" ? "Your drinks" : p.name,
                countHint: p.count > 1 ? "each" : "drinks",
                doneHint: "BACK TO CALCULATOR",
                onAdd: { o in state.perPerson[p.id] = Self.adding(o, to: state.perPerson[p.id] ?? state.drinks) },
                onRemove: { o in state.perPerson[p.id] = Self.removing(o, from: state.perPerson[p.id] ?? state.drinks) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $friendPickerOpen) {
            CalcFriendPicker(friends: friends, profile: profile,
                             selected: $state.friendIds, includeMe: $state.includeMe)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Calculator")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(Color.cream)
            Spacer(minLength: 12)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.cream.opacity(0.07)))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Close")
        }
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    // MARK: result (top)

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasDrinks, headcount > 1 {
                HStack {
                    Spacer()
                    Text(isShared
                         ? "\(listCount) \(listCount == 1 ? "drink" : "drinks") shared by \(headcount)"
                         : (hasOverrides ? "own drinks per person" : "\(listCount) \(listCount == 1 ? "drink" : "drinks") each"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Color.bronze)
                }
            }
            if !hasDrinks {
                Text("Add drinks to see the level.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
            } else if people.isEmpty {
                Text("Add someone below.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
            } else {
                VStack(spacing: 6) {
                    ForEach(people) { p in personRow(p) }
                }
                if headcount > 1 {
                    Rectangle().fill(Color.cream.opacity(0.08)).frame(height: 1)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SectionLabel(isShared ? "Shared" : "Total")
                        Text(totalDrinks.map { "\($0.count) × \($0.name.lowercased())" }.joined(separator: " · "))
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.85))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 4)
                        if !isShared && !hasOverrides {
                            Text("\(headcount) × \(listCount)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(Color.bronze)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(Color.inkElev))
        .overlay(cardShape.strokeBorder(Color.whiskey.opacity(hasDrinks ? 0.35 : 0.12), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
        .shadow(color: Color.whiskey.opacity(hasDrinks ? 0.18 : 0), radius: 16, y: 4)
    }

    /// One person: who, what they drink, what it does to them. In EACH mode
    /// with more than one person the row opens that person's own list.
    private func personRow(_ p: CalcPerson) -> some View {
        let value = bac(for: p)
        let st = CalcMath.status(value)
        let editable = !isShared && state.crew != .me
        let custom = editable && state.perPerson[p.id] != nil
        return HStack(spacing: 10) {
                if state.crew == .people {
                    ZStack {
                        Circle().fill(Color.whiskey.opacity(0.18)).frame(width: 32, height: 32)
                        Image(systemName: p.sex == .male ? "figure.stand" : "figure.stand.dress")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                    }
                } else {
                    AvatarView(urlString: p.avatarURL, initial: String(p.name.prefix(1)).uppercased(), size: 32)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        if !p.detail.isEmpty {
                            Text(p.detail)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.cream.opacity(0.45))
                                .lineLimit(1)
                        }
                        if custom {
                            // Tap: back to the default list.
                            HStack(spacing: 3) {
                                Text("OWN")
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .black, design: .rounded))
                            }
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.whiskey))
                            .contentShape(Capsule())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    state.perPerson[p.id] = nil
                                }
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        Text(p.weightKg > 0 ? drinksText(for: p) : "no weight on file")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if editable {
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.whiskey.opacity(0.8))
                        }
                    }
                }
                Spacer(minLength: 8)
                if p.weightKg > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(bacUnit.formatted(value))
                                .font(.system(size: 21, weight: .black, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(st.color)
                                .contentTransition(.numericText(value: value))
                            Text(bacUnit.symbol)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.bronze)
                        }
                        Text(st.label.uppercased())
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(st.color.opacity(0.9))
                    }
                }
            }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.cream.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(st.color.opacity(p.weightKg > 0 ? 0.35 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if editable { editing = p } }
    }

    // MARK: who

    private var whoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(CalcCrew.allCases) { c in
                    Button {
                        state.crew = c
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.icon)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                            Text(c.label)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(state.crew == c ? Color.ink : Color.cream.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(state.crew == c ? Color.whiskey : Color.cream.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.cream.opacity(state.crew == c ? 0 : 0.1), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }

            switch state.crew {
            case .me:
                EmptyView()
            case .people:
                HStack(spacing: 8) {
                    stepperRow(title: "Men", detail: "\(Int(CalcAverages.manKg)) kg", value: $state.men)
                    stepperRow(title: "Women", detail: "\(Int(CalcAverages.womanKg)) kg", value: $state.women)
                }
            case .friends:
                Button { friendPickerOpen = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                        Text(friendSummary)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey.opacity(0.8))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    private var friendSummary: String {
        let n = selectedFriendCount
        if n == 0 { return state.includeMe ? "Choose friends" : "Choose who's drinking" }
        let f = n == 1 ? "1 friend" : "\(n) friends"
        return state.includeMe ? "You + \(f)" : f
    }

    private func stepperRow(title: String, detail: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.5))
            }
            counter(value: value, range: 0...50)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }

    private func counter(value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 10) {
            roundButton("minus", enabled: value.wrappedValue > range.lowerBound) {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
            }
            Text("\(value.wrappedValue)")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.cream)
                .frame(minWidth: 22)
                .contentTransition(.numericText(value: Double(value.wrappedValue)))
            roundButton("plus", enabled: value.wrappedValue < range.upperBound) {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value.wrappedValue)
    }

    private func roundButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(enabled ? Color.ink : Color.cream.opacity(0.3))
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled ? Color.whiskey : Color.cream.opacity(0.06)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
    }

    // MARK: hours

    private var hoursCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("How long")
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(formatHours(state.hours))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.cream)
                        .contentTransition(.numericText(value: state.hours))
                    Text("H")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.bronze)
                }
            }
            TintedSlider(value: $state.hours, range: 0.5...12, step: 0.5, accent: .whiskey)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(cardShape.fill(Color.cream.opacity(0.035)))
        .overlay(cardShape.strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }

    // MARK: drinks

    /// Same structure as the DRINKS list on LIVE: one row per drink with
    /// glyph, name and size, a bookmark into My Drinks, and a – N + stepper.
    private var drinksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrimaryGlowButton(title: "Add drinks", systemImage: "plus") {
                menuOpen = true
            }
            if hasDrinks || state.crew != .me {
                HStack(alignment: .center, spacing: 10) {
                    SectionLabel(state.crew == .me ? "Your drinks"
                                 : isShared ? "Shared by everyone"
                                 : hasOverrides ? "Everyone else drinks" : "Each person drinks")
                    Spacer()
                    if state.crew != .me { sharingSwitch }
                    if hasDrinks {
                        Button { state.drinks = []; state.perPerson = [:] } label: {
                            Text("CLEAR")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(Color.bronze)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if hasDrinks {
                VStack(spacing: 8) {
                    ForEach(state.drinks) { d in
                        calcDrinkRow(d)
                    }
                }
            }
        }
    }

    /// EACH: everyone drinks the list. SHARED: the list is one pool split
    /// evenly. Switching to SHARED drops per-person lists, which only make
    /// sense in EACH.
    private var sharingSwitch: some View {
        HStack(spacing: 2) {
            ForEach(CalcSharing.allCases) { m in
                let on = state.sharing == m
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        state.sharing = m
                        if m == .shared { state.perPerson = [:] }
                    }
                } label: {
                    Text(m.label)
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(on ? Color.ink : Color.bronze)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(on ? Color.whiskey : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.cream.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }

    private func calcDrinkRow(_ d: CalcDrink) -> some View {
        let o = d.option
        let isSaved = saved.isSaved(o)
        return HStack(spacing: 12) {
            DrinkGlyph(option: o, size: 22)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoke))
                .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Text(d.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { saved.toggle(o) }
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isSaved ? Color.whiskey : Color.cream.opacity(0.4))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(isSaved ? "Remove from my drinks" : "Save to my drinks")
            HStack(spacing: 0) {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { removeOne(o) } } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.8))
                        .frame(width: 34, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                Text("\(d.count)")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .monospacedDigit()
                    .frame(minWidth: 22)
                    .contentTransition(.numericText(value: Double(d.count)))
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { add(o) } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .frame(width: 34, height: 32)
                        .background(Color.whiskey)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.07), lineWidth: 1))
    }

    // MARK: data

    private func loadFriendProfiles() async {
        let ids = friends.friends.map(\.id).filter { friendProfiles[$0] == nil }
        guard !ids.isEmpty else { return }
        loadingFriends = true
        defer { loadingFriends = false }
        do {
            let rows: [Profile] = try await supabase.from("profiles")
                .select()
                .in("id", values: ids.map { $0.uuidString.lowercased() })
                .execute()
                .value
            for p in rows { friendProfiles[p.id] = p }
        } catch {
            // Rows stay missing; the row says "no weight on file".
        }
    }
}

// MARK: - Friend picker

/// Searchable list of accepted friends with a tick per row, plus a "You"
/// row. Nothing is sent to anyone; it only decides whose weights the
/// calculator uses.
struct CalcFriendPicker: View {
    @ObservedObject var friends: FriendsService
    let profile: Profile
    @Binding var selected: [UUID]
    @Binding var includeMe: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Friend] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return friends.friends }
        return friends.friends.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.username ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Who's drinking")
                    Text("Friends")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(Color.cream)
                }
                Spacer()
                Button { dismiss() } label: {
                    Text("DONE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.cream))
                }
                .buttonStyle(PressScaleStyle())
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bronze)
                TextField("", text: $query, prompt: Text("Search friends").foregroundColor(Color.cream.opacity(0.35)))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.bronze)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))

            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    if query.isEmpty {
                        row(avatar: profile.avatarURL, initial: "Y", name: "You",
                            sub: "\(Int(profile.weightKg.rounded())) kg · \(profile.sex.short)",
                            on: includeMe) { includeMe.toggle() }
                    }
                    ForEach(filtered) { f in
                        let on = selected.contains(f.id)
                        row(avatar: f.avatarURL, initial: String(f.name.prefix(1)).uppercased(),
                            name: f.name, sub: f.username.map { "@" + $0 } ?? "", on: on) {
                            if on { selected.removeAll { $0 == f.id } } else { selected.append(f.id) }
                        }
                    }
                    if friends.friends.isEmpty {
                        Text("No friends yet.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .padding(.top, 12)
                    } else if filtered.isEmpty {
                        Text("No match.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .background(Color.ink.ignoresSafeArea())
    }

    private func row(avatar: String?, initial: String, name: String, sub: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(urlString: avatar, initial: initial, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(on ? Color.whiskey : Color.cream.opacity(0.06))
                        .frame(width: 26, height: 26)
                    Circle()
                        .strokeBorder(on ? Color.whiskey : Color.cream.opacity(0.2), lineWidth: 1)
                        .frame(width: 26, height: 26)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(Color.ink)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(on ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

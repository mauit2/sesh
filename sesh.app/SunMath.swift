// SunMath — sun position, and whether a terrace is in it.
//
// Deliberately free of SwiftUI/Supabase so it can be compiled and checked on
// its own (and it was: the sun windows below were cross-checked against an
// independent Python implementation of the same NOAA equations before any UI
// existed).
//
// The shading model is a HORIZON PROFILE: 72 bins of 5° compass, each holding
// the highest elevation angle blocked by buildings in that direction. Sun is
// on the terrace when the sun's altitude exceeds the horizon in the sun's
// direction — one array lookup, so a whole day of sun/shade is instant and
// works offline.

import Foundation

// MARK: - Solar position

/// Where the sun is, in the sky, for a place and instant.
struct SunPosition {
    /// Degrees above the horizon. Negative when below.
    let altitude: Double
    /// Compass bearing, 0 = true north, clockwise.
    let azimuth: Double

    /// NOAA solar position algorithm. Good to ~0.1° for our purposes, which
    /// is far finer than building-height uncertainty.
    static func at(_ date: Date, latitude: Double, longitude: Double) -> SunPosition {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let doy = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let h = cal.dateComponents([.hour, .minute, .second], from: date)
        let utcHours = Double(h.hour ?? 0) + Double(h.minute ?? 0) / 60
            + Double(h.second ?? 0) / 3600

        let frac = 2 * .pi / 365 * (doy - 1 + (utcHours - 12) / 24)
        let eqTime = 229.18 * (0.000075
            + 0.001868 * cos(frac) - 0.032077 * sin(frac)
            - 0.014615 * cos(2 * frac) - 0.040849 * sin(2 * frac))
        let decl = 0.006918
            - 0.399912 * cos(frac) + 0.070257 * sin(frac)
            - 0.006758 * cos(2 * frac) + 0.000907 * sin(2 * frac)
            - 0.002697 * cos(3 * frac) + 0.00148 * sin(3 * frac)

        let trueSolar = (utcHours * 60 + eqTime + 4 * longitude)
            .truncatingRemainder(dividingBy: 1440)
        let hourAngle = (trueSolar / 4 - 180) * .pi / 180
        let lat = latitude * .pi / 180

        var cosZen = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle)
        cosZen = min(1, max(-1, cosZen))
        let zenith = acos(cosZen)
        let altitude = 90 - zenith * 180 / .pi

        guard sin(zenith) != 0 else { return SunPosition(altitude: altitude, azimuth: 180) }
        var c = (sin(lat) * cos(zenith) - sin(decl)) / (cos(lat) * sin(zenith))
        c = min(1, max(-1, c))
        let a = acos(c) * 180 / .pi
        // NOAA as published. Getting these two branches the wrong way round
        // mirrors the sky east<->west, and the mirror is INVISIBLE at solar
        // noon (where a == 0, so both branches give due south) — which is
        // exactly where an earlier version of this was spot-checked. Verify
        // against a morning AND an afternoon bearing, never noon alone.
        let azimuth = hourAngle > 0
            ? (a + 180).truncatingRemainder(dividingBy: 360)
            : (540 - a).truncatingRemainder(dividingBy: 360)
        return SunPosition(altitude: altitude,
                           azimuth: azimuth < 0 ? azimuth + 360 : azimuth)
    }
}

// MARK: - Horizon

/// A venue's skyline: 72 bins of 5°, values in DEGREES (unpacked from the
/// tenths-of-a-degree smallints the server stores).
struct SunHorizon {
    static let bins = 72
    let blocked: [Double]

    init(packedTenths: [Int]) {
        var v = packedTenths.map { Double($0) / 10 }
        if v.count < Self.bins { v += Array(repeating: 0, count: Self.bins - v.count) }
        blocked = Array(v.prefix(Self.bins))
    }

    /// Blocked elevation in a compass direction, linearly interpolated between
    /// bins so the sun crosses a roofline smoothly rather than in 5° steps.
    func blockedElevation(azimuth: Double) -> Double {
        let a = azimuth.truncatingRemainder(dividingBy: 360)
        let pos = (a < 0 ? a + 360 : a) / 5
        let i = Int(pos) % Self.bins
        let j = (i + 1) % Self.bins
        let t = pos - Double(Int(pos))
        return blocked[i] + (blocked[j] - blocked[i]) * t
    }

    func isSunlit(_ sun: SunPosition) -> Bool {
        // A hair above the geometric horizon: the sun's disc is ~0.53° wide
        // and low-angle light is scattered to nothing anyway.
        sun.altitude > 0.5 && sun.altitude > blockedElevation(azimuth: sun.azimuth)
    }
}

// MARK: - Sun windows

/// A stretch of the day when a terrace has direct sun.
struct SunWindow: Equatable, Identifiable {
    let start: Date
    let end: Date
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// What the map needs to say about one venue right now.
struct SunState: Equatable {
    let isSunlitNow: Bool
    /// When the current state ends — sun going away, or arriving. Nil if it
    /// doesn't change again today.
    let changesAt: Date?
    let windows: [SunWindow]

    /// Total direct sun remaining today, from `now`.
    func remaining(after now: Date) -> TimeInterval {
        windows.reduce(0) { acc, w in
            guard w.end > now else { return acc }
            return acc + w.end.timeIntervalSince(max(w.start, now))
        }
    }
}

/// One day's sun positions, sampled once and shared by every venue.
///
/// WHY THIS EXISTS: a venue's sun windows come from testing ~288 instants
/// against its horizon. Doing the NOAA maths per venue meant 150 venues x 288
/// trig-heavy calls, and the view asked for it three times per render — roughly
/// 130k evaluations a frame. That is what made the map crawl once the venue
/// count went from 39 to 150.
///
/// The sun's position is effectively identical across one city: 10 km of
/// longitude is ~20 seconds of solar time and under 0.2° of azimuth, far below
/// the 5° bins the horizon is stored in. So sample the track ONCE near the map
/// centre and reuse it — 288 evaluations per screen, total.
struct SunTrack {
    let midnight: Date
    let stepMinutes: Int
    /// Parallel arrays, index = sample number. Plain arrays: this is a hot loop.
    let altitude: [Double]
    let azimuth: [Double]

    static func forDay(
        _ day: Date,
        latitude: Double,
        longitude: Double,
        calendar: Calendar = .current,
        stepMinutes: Int = 5
    ) -> SunTrack? {
        guard let midnight = calendar.dateInterval(of: .day, for: day)?.start else { return nil }
        let count = 24 * 60 / stepMinutes
        var alt = [Double](); alt.reserveCapacity(count)
        var az = [Double](); az.reserveCapacity(count)
        for m in stride(from: 0, to: 24 * 60, by: stepMinutes) {
            let t = midnight.addingTimeInterval(TimeInterval(m * 60))
            let p = SunPosition.at(t, latitude: latitude, longitude: longitude)
            alt.append(p.altitude)
            az.append(p.azimuth)
        }
        return SunTrack(midnight: midnight, stepMinutes: stepMinutes,
                        altitude: alt, azimuth: az)
    }
}

enum SunEngine {
    /// Step the day in `stepMinutes` and collect the lit stretches. Windows
    /// shorter than `minWindow` are dropped and gaps shorter than `minGap`
    /// are bridged — a chimney or a single footprint corner shouldn't read as
    /// "sun ends at 16:15, resumes 16:20".
    static func windows(
        horizon: SunHorizon,
        latitude: Double,
        longitude: Double,
        on day: Date,
        calendar: Calendar = .current,
        stepMinutes: Int = 5,
        minWindow: TimeInterval = 15 * 60,
        minGap: TimeInterval = 20 * 60
    ) -> [SunWindow] {
        guard let track = SunTrack.forDay(day, latitude: latitude, longitude: longitude,
                                          calendar: calendar, stepMinutes: stepMinutes)
        else { return [] }
        return windows(horizon: horizon, track: track,
                       minWindow: minWindow, minGap: minGap)
    }

    /// The same walk, against a pre-sampled track. This is the one the app uses.
    static func windows(
        horizon: SunHorizon,
        track: SunTrack,
        minWindow: TimeInterval = 15 * 60,
        minGap: TimeInterval = 20 * 60
    ) -> [SunWindow] {
        var raw: [(Date, Date)] = []
        var lit = false
        let step = TimeInterval(track.stepMinutes * 60)

        for i in track.altitude.indices {
            let sun = SunPosition(altitude: track.altitude[i], azimuth: track.azimuth[i])
            let nowLit = horizon.isSunlit(sun)
            if nowLit != lit || nowLit {
                let t = track.midnight.addingTimeInterval(
                    TimeInterval(i * track.stepMinutes * 60))
                if nowLit && !lit {
                    raw.append((t, t.addingTimeInterval(step)))
                } else if nowLit, !raw.isEmpty {
                    raw[raw.count - 1].1 = t.addingTimeInterval(step)
                }
            }
            lit = nowLit
        }

        // Bridge short gaps, then drop short windows.
        var merged: [(Date, Date)] = []
        for w in raw {
            if let last = merged.last, w.0.timeIntervalSince(last.1) < minGap {
                merged[merged.count - 1].1 = w.1
            } else {
                merged.append(w)
            }
        }
        return merged
            .filter { $0.1.timeIntervalSince($0.0) >= minWindow }
            .map { SunWindow(start: $0.0, end: $0.1) }
    }

    /// State from a shared track — the path the app takes for every venue.
    static func state(horizon: SunHorizon, track: SunTrack, now: Date) -> SunState {
        let ws = windows(horizon: horizon, track: track)
        if let current = ws.first(where: { $0.start <= now && now < $0.end }) {
            return SunState(isSunlitNow: true, changesAt: current.end, windows: ws)
        }
        return SunState(isSunlitNow: false,
                        changesAt: ws.first(where: { $0.start > now })?.start,
                        windows: ws)
    }

    static func state(
        horizon: SunHorizon,
        latitude: Double,
        longitude: Double,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SunState {
        let ws = windows(horizon: horizon, latitude: latitude,
                         longitude: longitude, on: now, calendar: calendar)
        if let current = ws.first(where: { $0.start <= now && now < $0.end }) {
            return SunState(isSunlitNow: true, changesAt: current.end, windows: ws)
        }
        return SunState(isSunlitNow: false,
                        changesAt: ws.first(where: { $0.start > now })?.start,
                        windows: ws)
    }
}

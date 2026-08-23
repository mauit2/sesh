//  HealthService.swift
//  Optional Apple Health bridge. Two jobs, both no-ops until the user
//  taps "Connect Apple Health":
//    • WRITE what you log — dietary energy (calories) + number of alcoholic
//      beverages — so a night shows up in Health alongside the rest of the day.
//    • READ activity over a live sesh — active energy (calories burned),
//      steps, and heart rate — for the "Sesh Vitals" panel.
//
//  HealthKit hides exactly which reads the user granted, so we treat
//  "finished the permission sheet" as connected and simply return nothing
//  when a given type has no data or wasn't allowed. Nothing here ever throws
//  into the app; every path degrades to empty.

import Foundation
import HealthKit
import Combine

/// Stable opt-in flag. New key — follows the `sesh.*` convention.
private let hkConnectedKey = "sesh.health.connected.v1"

final class HealthService: ObservableObject {
    static let shared = HealthService()

    private let store = HKHealthStore()

    /// The user opted in and finished the permission sheet. Persisted so the
    /// connection survives relaunches; drives the Settings toggle.
    @Published private(set) var isConnected: Bool = UserDefaults.standard.bool(forKey: hkConnectedKey)

    /// False on iPad/Mac and anywhere HealthKit isn't present.
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private init() {}

    // MARK: Types

    private var readTypes: Set<HKObjectType> {
        Set<HKObjectType>([
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.bodyMass),
        ])
    }
    private var writeTypes: Set<HKSampleType> {
        Set<HKSampleType>([
            HKQuantityType(.dietaryEnergyConsumed),
            HKQuantityType(.numberOfAlcoholicBeverages),
        ])
    }

    // MARK: Connect / disconnect

    /// Presents the system permission sheet. Returns true once the user has
    /// been through it (HealthKit won't tell us what they picked — that's by
    /// design). Marks us connected so writes/reads start flowing.
    @discardableResult
    func connect() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            UserDefaults.standard.set(true, forKey: hkConnectedKey)
            await MainActor.run { self.isConnected = true }
            return true
        } catch {
            return false
        }
    }

    /// Stop writing/reading. (Actual Health permissions are revoked by the
    /// user in the Health app / Settings; this just makes Sejdel stand down.)
    func disconnect() {
        UserDefaults.standard.set(false, forKey: hkConnectedKey)
        Task { @MainActor in self.isConnected = false }
    }

    // MARK: Write — one logged drink

    /// Save a drink's calories + standard-drink count to Health. Safe to call
    /// on every log: it silently no-ops when disconnected, and per-type
    /// write-denials are swallowed.
    func log(_ option: DrinkOption, at date: Date = Date()) {
        guard UserDefaults.standard.bool(forKey: hkConnectedKey), isAvailable else { return }
        let samples: [HKQuantitySample] = [
            HKQuantitySample(
                type: HKQuantityType(.dietaryEnergyConsumed),
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: max(0, option.kcal)),
                start: date, end: date
            ),
            HKQuantitySample(
                type: HKQuantityType(.numberOfAlcoholicBeverages),
                quantity: HKQuantity(unit: .count(), doubleValue: max(0, option.standardDrinks)),
                start: date, end: date
            ),
        ]
        store.save(samples) { _, _ in }
    }

    // MARK: Read — sesh vitals over a window

    /// What the body did during a sesh. Every field is optional — missing
    /// means "no data / not granted" (e.g. heart rate needs an Apple Watch),
    /// and the UI hides whatever's nil.
    struct Vitals {
        var activeKcal: Double?
        var steps: Double?
        var avgHeartRate: Double?
        var peakHeartRate: Double?

        var isEmpty: Bool {
            activeKcal == nil && steps == nil && avgHeartRate == nil && peakHeartRate == nil
        }
    }

    func vitals(from start: Date, to end: Date = Date()) async -> Vitals {
        guard UserDefaults.standard.bool(forKey: hkConnectedKey), isAvailable, end > start else {
            return Vitals()
        }
        async let energy = statSum(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end)
        async let steps = statSum(.stepCount, unit: .count(), start: start, end: end)
        async let hr = heartRate(start: start, end: end)
        let (e, s, h) = await (energy, steps, hr)
        return Vitals(activeKcal: e, steps: s, avgHeartRate: h.0, peakHeartRate: h.1)
    }

    private func statSum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKStatisticsQuery(
                quantityType: HKQuantityType(id),
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let v = stats?.sumQuantity()?.doubleValue(for: unit)
                cont.resume(returning: (v ?? 0) > 0 ? v : nil)
            }
            store.execute(q)
        }
    }

    private func heartRate(start: Date, end: Date) async -> (Double?, Double?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Double?, Double?), Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let q = HKStatisticsQuery(
                quantityType: HKQuantityType(.heartRate),
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMax]
            ) { _, stats, _ in
                cont.resume(returning: (
                    stats?.averageQuantity()?.doubleValue(for: bpm),
                    stats?.maximumQuantity()?.doubleValue(for: bpm)
                ))
            }
            store.execute(q)
        }
    }
}

import Foundation
import HealthKit
import os.log
import ReeveKit

/// Diagnostic logger for the HealthKit device tools. Visible in
/// Console.app on macOS by filtering on
/// `subsystem:dev.jdpedrie.reeve category:HealthTools`. Surfaces
/// permission-request entry / exit so you can tell whether the
/// system actually presented the sheet, since silent off-main
/// failures looked identical to "user hasn't tapped yet" from the
/// outside.
private let log = Logger(subsystem: "dev.jdpedrie.reeve", category: "HealthTools")

/// Handlers + registration for the HealthKit-backed device tools:
/// `health_today_summary`, `health_recent_workouts`,
/// `health_sleep_last_night`, `health_vitals_recent`. iOS-only — the
/// HealthKit framework isn't available on macOS in the way we'd
/// need (no Apple Watch source, no Health DB).
///
/// One shared `HKHealthStore` per process — Apple docs say one
/// instance per app is the right shape; reusing avoids reseating
/// the permission state on every call.
///
/// **Permission model.** HealthKit grants are per-type AND
/// asymmetric: a denied read returns "no data" rather than an
/// explicit denial (Apple's privacy-by-design — the app can't tell
/// whether the user said "no" or simply has no samples). We do an
/// explicit `requestAuthorization(...)` on first call for the
/// union of read types we need; subsequent calls fall through. If
/// HealthKit returns empty data we surface a hint in the
/// description text so the model can ask the user about
/// permissions rather than confidently reporting zero steps.
enum HealthTools {

    private static let store = HKHealthStore()

    /// Registers all health handlers with the shared
    /// DeviceToolRegistry. Called from the iOS app's bootstrap.
    /// No-op if HealthKit isn't available (e.g. iPad without the
    /// Health app); handlers won't be advertised in capabilities
    /// in that case.
    static func register() {
        guard HKHealthStore.isHealthDataAvailable() else {
            log.warning("HKHealthStore not available on this device; health_* handlers will NOT be registered")
            return
        }
        let r = DeviceToolRegistry.shared
        r.register(name: "health_today_summary", handler: todaySummary)
        r.register(name: "health_recent_workouts", handler: recentWorkouts)
        r.register(name: "health_sleep_last_night", handler: sleepLastNight)
        r.register(name: "health_vitals_recent", handler: vitalsRecent)
        r.register(name: "health_query", handler: healthQuery)
        log.notice("registered 5 HealthKit device-tool handlers")
    }

    // MARK: - Handlers

    private static let todaySummary: DeviceToolHandler = { _ in
        try await ensureHealthAccess()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = Date()
        // NSPredicate isn't Sendable under Swift 6 strict concurrency,
        // so each async-let helper builds its own predicate from
        // start/end rather than sharing one across actor hops.
        async let steps = sumQuantity(.stepCount, unit: .count(), start: start, end: end)
        async let activeKcal = sumQuantity(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end)
        async let exerciseMin = sumQuantity(.appleExerciseTime, unit: .minute(), start: start, end: end)
        async let standHours = sumCategory(.appleStandHour, value: HKCategoryValueAppleStandHour.stood.rawValue, start: start, end: end)
        async let distanceM = sumQuantity(.distanceWalkingRunning, unit: .meter(), start: start, end: end)

        let payload = TodaySummary(
            date: start,
            steps: Int((try? await steps) ?? 0),
            activeEnergyKcal: (try? await activeKcal) ?? 0,
            exerciseMinutes: Int((try? await exerciseMin) ?? 0),
            standHours: (try? await standHours) ?? 0,
            distanceMeters: (try? await distanceM) ?? 0
        )
        return try JSONEncoder.iso8601.encode(payload)
    }

    private static let recentWorkouts: DeviceToolHandler = { inputJSON in
        let input = try decode(WorkoutsInput.self, from: inputJSON)
        try await ensureHealthAccess()

        let limit = max(1, min(input.limit ?? 50, 200))
        let workouts = try await runSampleQuery(
            type: .workoutType(),
            start: input.startDate, end: input.endDate,
            limit: limit, ascending: false
        ) { samples in (samples as? [HKWorkout]) ?? [] }

        let dtos = workouts.map(WorkoutDTO.init(from:))
        return try JSONEncoder.iso8601.encode(WorkoutsOutput(workouts: dtos))
    }

    private static let sleepLastNight: DeviceToolHandler = { _ in
        try await ensureHealthAccess()
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return try JSONEncoder.iso8601.encode(EmptySleep())
        }
        // 36h window: catches naps logged earlier in the day plus
        // the most recent overnight session even when the user is
        // calling shortly after waking.
        let end = Date()
        let start = end.addingTimeInterval(-36 * 3600)
        let samples = try await runSampleQuery(
            type: sleepType,
            start: start, end: end,
            limit: HKObjectQueryNoLimit, ascending: true
        ) { samples in (samples as? [HKCategorySample]) ?? [] }

        if samples.isEmpty {
            return try JSONEncoder.iso8601.encode(EmptySleep())
        }
        let summary = summariseSleep(samples)
        return try JSONEncoder.iso8601.encode(summary)
    }

    private static let vitalsRecent: DeviceToolHandler = { inputJSON in
        let input = try decode(VitalsInput.self, from: inputJSON)
        try await ensureHealthAccess()

        let days = max(1, min(input.days ?? 14, 90))
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end.addingTimeInterval(Double(-days) * 86400)

        async let restingHR = recentQuantitySamples(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, limit: 30)
        async let hrv = recentQuantitySamples(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, limit: 30)
        async let bodyMass = mostRecentQuantity(.bodyMass, unit: .gramUnit(with: .kilo))

        let payload = VitalsOutput(
            windowDays: days,
            restingHeartRateBpm: (try? await restingHR) ?? [],
            heartRateVariabilityMs: (try? await hrv) ?? [],
            bodyMassKg: try? await bodyMass
        )
        return try JSONEncoder.iso8601.encode(payload)
    }

    // MARK: - Generic query

    /// The catch-all reader. Resolves `data_type` against the
    /// quantity-type registry below, requests authorization for
    /// JUST that type (not the union the dedicated handlers ask
    /// for), then runs the matching query shape for the requested
    /// `aggregation`. Apple's privacy contract: a denied type is
    /// indistinguishable from an empty range — both return zero
    /// samples / nil. The model is told this in the tool description
    /// so it doesn't assert "you have no heart rate data" when the
    /// user actually has denied the permission.
    private static let healthQuery: DeviceToolHandler = { inputJSON in
        let input = try decode(QueryInput.self, from: inputJSON)
        log.notice("health_query: enter data_type=\(input.dataType, privacy: .public) aggregation=\(input.aggregation ?? "samples", privacy: .public)")
        guard HKHealthStore.isHealthDataAvailable() else {
            log.warning("health_query: HKHealthStore not available")
            throw DeviceToolError.permissionDenied("health (not available on this device)")
        }
        guard let entry = quantityRegistry[input.dataType] else {
            log.warning("health_query: unknown data_type=\(input.dataType, privacy: .public)")
            throw DeviceToolError.message(
                "unknown health data_type '\(input.dataType)' — see tool description for the supported list")
        }
        // Pre-auth status check — surfaces the per-type
        // authorization state BEFORE we issue requestAuthorization.
        // iOS's HealthKit privacy contract returns "not determined"
        // even for types the user has explicitly read-denied (so
        // the app can't tell whether the user said no vs hasn't
        // been asked yet); but a status of `.sharingDenied` here
        // is unambiguous and rare — most "no sheet appeared"
        // reports trace back to either the entitlement not being
        // signed into the build, or the request landing off-main.
        let preStatus = store.authorizationStatus(for: entry.type)
        log.notice("health_query: requesting auth for \(input.dataType, privacy: .public) (pre-status raw=\(preStatus.rawValue, privacy: .public))")
        // Per-type authorization. iOS shows the sheet only when
        // the user hasn't decided yet; subsequent calls for the
        // same type are no-ops.
        try await requestRead(type: entry.type)
        log.notice("health_query: auth request returned for \(input.dataType, privacy: .public)")

        let end = input.endDate ?? Date()
        let start = input.startDate ?? Calendar.current.date(byAdding: .day, value: -30, to: end) ?? end.addingTimeInterval(-30 * 86400)
        let mode = QueryAggregation(rawValue: input.aggregation ?? "samples") ?? .samples

        switch mode {
        case .samples:
            let limit = max(1, min(input.limit ?? 100, 500))
            let samples = try await runSampleQuery(
                type: entry.type, start: start, end: end,
                limit: limit, ascending: false
            ) { items in (items as? [HKQuantitySample]) ?? [] }
            let payload = QuerySamplesOutput(
                dataType: input.dataType,
                unit: entry.unitLabel,
                samples: samples.map { QueryQuantitySample(date: $0.endDate, value: $0.quantity.doubleValue(for: entry.unit)) }
            )
            return try JSONEncoder.iso8601.encode(payload)

        case .sum:
            let (total, count) = try await statisticsQuery(
                entry: entry, start: start, end: end, option: .cumulativeSum)
            return try JSONEncoder.iso8601.encode(QuerySumOutput(
                dataType: input.dataType, unit: entry.unitLabel,
                sum: total, sampleCount: count))

        case .average:
            let (avg, count) = try await statisticsQuery(
                entry: entry, start: start, end: end, option: .discreteAverage)
            return try JSONEncoder.iso8601.encode(QueryAverageOutput(
                dataType: input.dataType, unit: entry.unitLabel,
                average: avg, sampleCount: count))

        case .latest:
            // No date filter — caller wants the most recent
            // sample regardless of the supplied range.
            let samples = try await runSampleQuery(
                type: entry.type, start: nil, end: nil,
                limit: 1, ascending: false
            ) { items in (items as? [HKQuantitySample]) ?? [] }
            if let s = samples.first {
                return try JSONEncoder.iso8601.encode(QueryLatestOutput(
                    dataType: input.dataType, unit: entry.unitLabel,
                    date: s.endDate, value: s.quantity.doubleValue(for: entry.unit)))
            } else {
                return try JSONEncoder.iso8601.encode(QueryLatestEmpty(
                    dataType: input.dataType, unit: entry.unitLabel))
            }
        }
    }

    private static func statisticsQuery(
        entry: QuantityRegistryEntry,
        start: Date, end: Date,
        option: HKStatisticsOptions
    ) async throws -> (value: Double, count: Int) {
        try await withCheckedThrowingContinuation { cont in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: [.strictStartDate])
            let q = HKStatisticsQuery(
                quantityType: entry.type,
                quantitySamplePredicate: predicate,
                options: option
            ) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                let qty = (option == .cumulativeSum)
                    ? stats?.sumQuantity()
                    : stats?.averageQuantity()
                let value = qty?.doubleValue(for: entry.unit) ?? 0
                // sources().count isn't sample count — there's no
                // sample-count getter on HKStatistics. Best proxy:
                // run a separate sample query and count. For now
                // we surface 0 when no samples and 1+ when stats
                // returned a quantity so the model knows the bucket
                // wasn't empty.
                let count: Int = (qty != nil) ? 1 : 0
                cont.resume(returning: (value, count))
            }
            store.execute(q)
        }
    }

    /// Per-type read authorization.
    ///
    /// **Main-thread hop.** Apple's docs say
    /// `requestAuthorization` is safe from any thread, but in
    /// practice the permission sheet only surfaces reliably when
    /// the request originates from the main actor — calls
    /// dispatched off-main were silently failing for the user
    /// (60s broker timeout with no sheet shown). The dispatcher
    /// runs handlers on a detached Task; we hop to MainActor to
    /// fire the request so the system has somewhere to present
    /// the sheet from.
    ///
    /// Uses the iOS 15.4+ async `requestAuthorization` to avoid
    /// the continuation dance (and to side-step the Swift 6
    /// region-isolation analysis getting confused about
    /// MainActor-isolated continuations).
    @MainActor
    private static func requestRead(type: HKObjectType) async throws {
        try await store.requestAuthorization(toShare: [], read: [type])
    }

    // MARK: - Quantity type registry

    /// One entry per supported HK quantity type. `unitLabel` is the
    /// short string we surface to the model in the JSON output so
    /// it can phrase its answer with the right unit ("78 kg" vs
    /// "171 lb"). Kept in code (not derived from `HKUnit.unitString`)
    /// so additions are explicit + reviewable.
    private struct QuantityRegistryEntry {
        let type: HKQuantityType
        let unit: HKUnit
        let unitLabel: String
    }

    private static let quantityRegistry: [String: QuantityRegistryEntry] = {
        var out: [String: QuantityRegistryEntry] = [:]
        func add(_ name: String, _ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ label: String) {
            guard let t = HKObjectType.quantityType(forIdentifier: id) else { return }
            out[name] = QuantityRegistryEntry(type: t, unit: unit, unitLabel: label)
        }

        // Cardio / vitals
        let bpm = HKUnit.count().unitDivided(by: .minute())
        add("heartRate",                    .heartRate,                    bpm, "count/min")
        add("restingHeartRate",             .restingHeartRate,             bpm, "count/min")
        add("walkingHeartRateAverage",      .walkingHeartRateAverage,      bpm, "count/min")
        add("heartRateVariabilitySDNN",     .heartRateVariabilitySDNN,     .secondUnit(with: .milli), "ms")
        add("bloodPressureSystolic",        .bloodPressureSystolic,        HKUnit.millimeterOfMercury(), "mmHg")
        add("bloodPressureDiastolic",       .bloodPressureDiastolic,       HKUnit.millimeterOfMercury(), "mmHg")
        add("bloodGlucose",                 .bloodGlucose,                 HKUnit(from: "mg/dL"), "mg/dL")
        add("oxygenSaturation",             .oxygenSaturation,             .percent(), "%")
        add("respiratoryRate",              .respiratoryRate,              HKUnit.count().unitDivided(by: .minute()), "count/min")
        add("vo2Max",                       .vo2Max,                       HKUnit(from: "ml/(kg*min)"), "mL/(kg·min)")
        add("bodyTemperature",              .bodyTemperature,              .degreeCelsius(), "°C")

        // Body composition
        add("bodyMass",                     .bodyMass,                     .gramUnit(with: .kilo), "kg")
        add("bodyMassIndex",                .bodyMassIndex,                .count(), "")
        add("bodyFatPercentage",            .bodyFatPercentage,            .percent(), "%")
        add("leanBodyMass",                 .leanBodyMass,                 .gramUnit(with: .kilo), "kg")
        add("height",                       .height,                       .meter(), "m")
        add("waistCircumference",           .waistCircumference,           .meter(), "m")

        // Activity
        add("stepCount",                    .stepCount,                    .count(), "count")
        add("distanceWalkingRunning",       .distanceWalkingRunning,       .meter(), "m")
        add("distanceCycling",              .distanceCycling,              .meter(), "m")
        add("distanceSwimming",             .distanceSwimming,             .meter(), "m")
        add("flightsClimbed",               .flightsClimbed,               .count(), "count")
        add("activeEnergyBurned",           .activeEnergyBurned,           .kilocalorie(), "kcal")
        add("basalEnergyBurned",            .basalEnergyBurned,            .kilocalorie(), "kcal")
        add("appleExerciseTime",            .appleExerciseTime,            .minute(), "min")
        add("appleStandTime",               .appleStandTime,               .minute(), "min")

        // Gait / mobility
        add("walkingSpeed",                 .walkingSpeed,                 HKUnit.meter().unitDivided(by: .second()), "m/s")
        add("walkingStepLength",            .walkingStepLength,            .meter(), "m")
        add("walkingAsymmetryPercentage",   .walkingAsymmetryPercentage,   .percent(), "%")
        add("walkingDoubleSupportPercentage", .walkingDoubleSupportPercentage, .percent(), "%")
        add("sixMinuteWalkTestDistance",    .sixMinuteWalkTestDistance,    .meter(), "m")
        add("stairAscentSpeed",             .stairAscentSpeed,             HKUnit.meter().unitDivided(by: .second()), "m/s")
        add("stairDescentSpeed",            .stairDescentSpeed,            HKUnit.meter().unitDivided(by: .second()), "m/s")

        // Nutrition
        add("dietaryEnergyConsumed",        .dietaryEnergyConsumed,        .kilocalorie(), "kcal")
        add("dietaryWater",                 .dietaryWater,                 HKUnit.literUnit(with: .milli), "mL")
        add("dietaryCaffeine",              .dietaryCaffeine,              .gramUnit(with: .milli), "mg")
        add("dietaryProtein",               .dietaryProtein,               .gram(), "g")
        add("dietaryCarbohydrates",         .dietaryCarbohydrates,         .gram(), "g")
        add("dietaryFatTotal",              .dietaryFatTotal,              .gram(), "g")
        add("dietarySodium",                .dietarySodium,                .gramUnit(with: .milli), "mg")
        add("dietarySugar",                 .dietarySugar,                 .gram(), "g")

        // Audio exposure
        add("environmentalAudioExposure",   .environmentalAudioExposure,   HKUnit.decibelAWeightedSoundPressureLevel(), "dB(A)")
        add("headphoneAudioExposure",       .headphoneAudioExposure,       HKUnit.decibelAWeightedSoundPressureLevel(), "dB(A)")

        return out
    }()

    private enum QueryAggregation: String {
        case samples, sum, average, latest
    }

    // MARK: - Generic query wire types

    private struct QueryInput: Decodable {
        let dataType: String
        let startDate: Date?
        let endDate: Date?
        let limit: Int?
        let aggregation: String?
        enum CodingKeys: String, CodingKey {
            case dataType = "data_type"
            case startDate = "start_date"
            case endDate = "end_date"
            case limit
            case aggregation
        }
    }
    private struct QuerySamplesOutput: Encodable {
        let dataType: String
        let unit: String
        let samples: [QueryQuantitySample]
        enum CodingKeys: String, CodingKey {
            case dataType = "data_type"
            case unit, samples
        }
    }
    private struct QueryQuantitySample: Encodable {
        let date: Date
        let value: Double
    }
    private struct QuerySumOutput: Encodable {
        let dataType: String
        let unit: String
        let sum: Double
        let sampleCount: Int
        enum CodingKeys: String, CodingKey {
            case dataType = "data_type"
            case unit, sum
            case sampleCount = "sample_count"
        }
    }
    private struct QueryAverageOutput: Encodable {
        let dataType: String
        let unit: String
        let average: Double
        let sampleCount: Int
        enum CodingKeys: String, CodingKey {
            case dataType = "data_type"
            case unit, average
            case sampleCount = "sample_count"
        }
    }
    private struct QueryLatestOutput: Encodable {
        let dataType: String
        let unit: String
        let date: Date
        let value: Double
        enum CodingKeys: String, CodingKey {
            case dataType = "data_type"
            case unit, date, value
        }
    }
    private struct QueryLatestEmpty: Encodable {
        let dataType: String
        let unit: String
        let date: Date? = nil
        let value: Double? = nil
        enum CodingKeys: String, CodingKey {
            case dataType = "data_type"
            case unit, date, value
        }
    }

    // MARK: - Permission

    /// Request authorization for the read types every handler in
    /// this file needs. HealthKit's auth API is per-type so we ask
    /// for the union up front; subsequent calls are no-ops when
    /// the user has already chosen. Apple's privacy contract means
    /// even a denial returns "success" here — the actual read
    /// returns empty data instead. We surface no error in that
    /// case so the model gets data-or-nothing on every call.
    @MainActor
    private static func ensureHealthAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw DeviceToolError.permissionDenied("health (not available on this device)")
        }
        // Hop to MainActor — see requestRead's comment. The async
        // `requestAuthorization` is iOS 15.4+; the project's
        // deployment target is 26.0 so it's always available here.
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// The union of types every handler in this file reads. Kept
    /// at file scope so the authorization sheet asks once for the
    /// full set rather than incrementally as the model fires
    /// different tools.
    private static var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        let qty: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .appleExerciseTime,
            .distanceWalkingRunning, .restingHeartRate,
            .heartRateVariabilitySDNN, .bodyMass,
        ]
        for id in qty {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        if let stand = HKObjectType.categoryType(forIdentifier: .appleStandHour) {
            set.insert(stand)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            set.insert(sleep)
        }
        set.insert(HKObjectType.workoutType())
        return set
    }

    // MARK: - Quantity helpers

    private static func sumQuantity(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date, end: Date
    ) async throws -> Double {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return 0 }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: [.strictStartDate])
            let q = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                let v = stats?.sumQuantity()?.doubleValue(for: unit) ?? 0
                cont.resume(returning: v)
            }
            store.execute(q)
        }
    }

    private static func sumCategory(
        _ id: HKCategoryTypeIdentifier,
        value: Int,
        start: Date, end: Date
    ) async throws -> Int {
        guard let type = HKObjectType.categoryType(forIdentifier: id) else { return 0 }
        let samples = try await runSampleQuery(
            type: type, start: start, end: end,
            limit: HKObjectQueryNoLimit, ascending: nil
        ) { samples in (samples as? [HKCategorySample]) ?? [] }
        return samples.filter { $0.value == value }.count
    }

    private static func recentQuantitySamples(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date, end: Date,
        limit: Int
    ) async throws -> [QuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return [] }
        let samples = try await runSampleQuery(
            type: type, start: start, end: end,
            limit: limit, ascending: false
        ) { samples in (samples as? [HKQuantitySample]) ?? [] }
        return samples.map {
            QuantitySample(date: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
    }

    private static func mostRecentQuantity(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        // No date filter — caller wants the literal most recent sample.
        let samples = try await runSampleQuery(
            type: type, start: nil, end: nil,
            limit: 1, ascending: false
        ) { samples in (samples as? [HKQuantitySample]) ?? [] }
        return samples.first?.quantity.doubleValue(for: unit)
    }

    /// Generic HKSampleQuery runner. Builds the predicate + sort
    /// descriptors inline so the NSPredicate (not Sendable under
    /// Swift 6) never crosses an actor boundary — every HealthKit
    /// query goes through here for that reason.
    private static func runSampleQuery<T: Sendable>(
        type: HKSampleType,
        start: Date?, end: Date?,
        limit: Int,
        ascending: Bool?,
        transform: @Sendable @escaping ([HKSample]?) -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let predicate: NSPredicate? = {
                guard let start, let end else { return nil }
                return HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            }()
            let sort: [NSSortDescriptor]? = ascending.map {
                [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: $0)]
            }
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: transform(samples))
            }
            store.execute(q)
        }
    }

    // MARK: - Sleep summary

    /// Reduce a list of sleep-analysis samples into a single
    /// session summary. Picks the most recent contiguous run
    /// (samples separated by ≤60 min are part of the same
    /// session) so naps earlier in the window don't blur the
    /// "last night" answer. Per-stage totals come from HKCategory
    /// values; legacy `.asleep` (pre-watchOS 9) collapses into
    /// the generic asleep bucket.
    private static func summariseSleep(_ samples: [HKCategorySample]) -> SleepSummary {
        let sorted = samples.sorted { $0.startDate < $1.startDate }
        guard let last = sorted.last else { return SleepSummary() }
        var sessionStart = last.startDate
        var sessionEnd = last.endDate
        var session: [HKCategorySample] = [last]
        for s in sorted.reversed().dropFirst() {
            if sessionStart.timeIntervalSince(s.endDate) <= 60 * 60 {
                sessionStart = min(sessionStart, s.startDate)
                sessionEnd = max(sessionEnd, s.endDate)
                session.append(s)
            } else {
                break
            }
        }
        var inBed: TimeInterval = 0
        var asleep: TimeInterval = 0
        var awake: TimeInterval = 0
        var rem: TimeInterval = 0
        var core: TimeInterval = 0
        var deep: TimeInterval = 0
        for s in session {
            let dur = s.endDate.timeIntervalSince(s.startDate)
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .inBed: inBed += dur
            case .asleepUnspecified, .asleep: asleep += dur
            case .awake: awake += dur
            case .asleepREM: rem += dur; asleep += dur
            case .asleepCore: core += dur; asleep += dur
            case .asleepDeep: deep += dur; asleep += dur
            default: break
            }
        }
        return SleepSummary(
            bedtime: sessionStart,
            wakeTime: sessionEnd,
            timeInBedMinutes: Int((inBed > 0 ? inBed : sessionEnd.timeIntervalSince(sessionStart)) / 60),
            timeAsleepMinutes: Int(asleep / 60),
            stages: SleepStages(
                remMinutes: Int(rem / 60),
                coreMinutes: Int(core / 60),
                deepMinutes: Int(deep / 60),
                awakeMinutes: Int(awake / 60)
            )
        )
    }

    // MARK: - Wire types

    private struct TodaySummary: Encodable {
        let date: Date
        let steps: Int
        let activeEnergyKcal: Double
        let exerciseMinutes: Int
        let standHours: Int
        let distanceMeters: Double
        enum CodingKeys: String, CodingKey {
            case date
            case steps
            case activeEnergyKcal = "active_energy_kcal"
            case exerciseMinutes = "exercise_minutes"
            case standHours = "stand_hours"
            case distanceMeters = "distance_meters"
        }
    }

    private struct WorkoutsInput: Decodable {
        let startDate: Date
        let endDate: Date
        let limit: Int?
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date"
            case endDate = "end_date"
            case limit
        }
    }
    private struct WorkoutsOutput: Encodable {
        let workouts: [WorkoutDTO]
    }
    private struct WorkoutDTO: Encodable {
        let id: String
        let activity: String
        let start: Date
        let end: Date
        let durationMinutes: Int
        let activeEnergyKcal: Double?
        let distanceMeters: Double?

        init(from w: HKWorkout) {
            self.id = w.uuid.uuidString
            self.activity = workoutActivityLabel(w.workoutActivityType)
            self.start = w.startDate
            self.end = w.endDate
            self.durationMinutes = Int(w.duration / 60)
            if let stats = w.statistics(for: HKQuantityType(.activeEnergyBurned)),
               let q = stats.sumQuantity() {
                self.activeEnergyKcal = q.doubleValue(for: .kilocalorie())
            } else {
                self.activeEnergyKcal = nil
            }
            if let stats = w.statistics(for: HKQuantityType(.distanceWalkingRunning)),
               let q = stats.sumQuantity() {
                self.distanceMeters = q.doubleValue(for: .meter())
            } else {
                self.distanceMeters = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, activity, start, end
            case durationMinutes = "duration_minutes"
            case activeEnergyKcal = "active_energy_kcal"
            case distanceMeters = "distance_meters"
        }
    }

    private struct VitalsInput: Decodable {
        let days: Int?
    }
    private struct VitalsOutput: Encodable {
        let windowDays: Int
        let restingHeartRateBpm: [QuantitySample]
        let heartRateVariabilityMs: [QuantitySample]
        let bodyMassKg: Double?
        enum CodingKeys: String, CodingKey {
            case windowDays = "window_days"
            case restingHeartRateBpm = "resting_heart_rate_bpm"
            case heartRateVariabilityMs = "heart_rate_variability_ms"
            case bodyMassKg = "body_mass_kg"
        }
    }
    private struct QuantitySample: Encodable {
        let date: Date
        let value: Double
    }

    private struct EmptySleep: Encodable {
        let sleep: SleepSummary? = nil
    }
    private struct SleepSummary: Encodable {
        var bedtime: Date? = nil
        var wakeTime: Date? = nil
        var timeInBedMinutes: Int = 0
        var timeAsleepMinutes: Int = 0
        var stages: SleepStages = SleepStages()
        enum CodingKeys: String, CodingKey {
            case bedtime
            case wakeTime = "wake_time"
            case timeInBedMinutes = "time_in_bed_minutes"
            case timeAsleepMinutes = "time_asleep_minutes"
            case stages
        }
    }
    private struct SleepStages: Encodable {
        var remMinutes: Int = 0
        var coreMinutes: Int = 0
        var deepMinutes: Int = 0
        var awakeMinutes: Int = 0
        enum CodingKeys: String, CodingKey {
            case remMinutes = "rem_minutes"
            case coreMinutes = "core_minutes"
            case deepMinutes = "deep_minutes"
            case awakeMinutes = "awake_minutes"
        }
    }
}

/// Map a `HKWorkoutActivityType` to a short kebab-case label the
/// model can read without us having to ship the full Apple enum
/// list. Falls back to "other" for activity types we haven't
/// named — better than dumping the raw enum int, which the model
/// would happily quote back to the user.
private func workoutActivityLabel(_ t: HKWorkoutActivityType) -> String {
    switch t {
    case .running:                  return "running"
    case .walking:                  return "walking"
    case .cycling:                  return "cycling"
    case .hiking:                   return "hiking"
    case .swimming:                 return "swimming"
    case .yoga:                     return "yoga"
    case .functionalStrengthTraining: return "strength-training"
    case .traditionalStrengthTraining: return "strength-training"
    case .highIntensityIntervalTraining: return "hiit"
    case .pilates:                  return "pilates"
    case .rowing:                   return "rowing"
    case .elliptical:               return "elliptical"
    case .stairs, .stairClimbing:   return "stairs"
    case .coreTraining:             return "core-training"
    case .flexibility:              return "flexibility"
    case .mixedCardio:              return "mixed-cardio"
    case .dance, .cardioDance, .socialDance: return "dance"
    case .soccer:                   return "soccer"
    case .basketball:               return "basketball"
    case .tennis:                   return "tennis"
    case .golf:                     return "golf"
    case .climbing:                 return "climbing"
    case .surfingSports:            return "surfing"
    case .skatingSports:            return "skating"
    case .snowSports, .crossCountrySkiing, .downhillSkiing, .snowboarding:
                                    return "snow-sports"
    case .other:                    return "other"
    default:                        return "other"
    }
}

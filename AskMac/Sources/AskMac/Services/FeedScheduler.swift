import Foundation
import OSLog

private let logger = Logger(subsystem: "com.kevinhill.askmac", category: "FeedScheduler")

// MARK: - FeedScheduler

/// Schedules feed scripts using cron expressions.
/// Each feed script gets a looping Task that sleeps until the next cron fire time,
/// calls the provided callback, then loops for the next fire.
final class FeedScheduler: @unchecked Sendable {
    typealias FireCallback = @Sendable (ScriptManifest, URL) -> Void

    private var tasks: [String: Task<Void, Never>] = [:]  // keyed by scriptID
    private let lock = NSLock()

    // MARK: - Public API

    func schedule(manifest: ScriptManifest, scriptDir: URL, settings: AppSettings, onFire: @escaping FireCallback) {
        cancel(scriptID: manifest.id)

        let task = Task {
            while !Task.isCancelled {
                // Resolve effective schedule: iOS override → manifest schedule → hourly default
                let cronExpr = settings.feedScheduleOverride(for: manifest.id)
                    ?? manifest.schedule
                    ?? "0 * * * *"

                guard let next = CronExpression.nextFireDate(from: cronExpr) else {
                    logger.error("\(manifest.id): invalid cron '\(cronExpr)' — skipping")
                    // Wait 1 hour then retry
                    try? await Task.sleep(for: .seconds(3600))
                    continue
                }

                let delay = next.timeIntervalSinceNow
                logger.debug("\(manifest.id): next run at \(next) (in \(Int(delay))s)")
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                onFire(manifest, scriptDir)
            }
        }

        lock.lock()
        tasks[manifest.id] = task
        lock.unlock()
    }

    func task(for scriptID: String) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[scriptID]
    }

    func cancel(scriptID: String) {
        lock.lock()
        tasks.removeValue(forKey: scriptID)?.cancel()
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        lock.unlock()
    }

}

// MARK: - Cron parser

/// Minimal 5-field cron parser: minute hour day-of-month month day-of-week
/// Supports: `*`, `*/n` (step), comma-separated values, and plain integers.
enum CronExpression {
    static func nextFireDate(from expression: String, after base: Date = Date()) -> Date? {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5 else { return nil }

        guard
            let minutes  = parseField(String(fields[0]), range: 0...59),
            let hours    = parseField(String(fields[1]), range: 0...23),
            let days     = parseField(String(fields[2]), range: 1...31),
            let months   = parseField(String(fields[3]), range: 1...12),
            let weekdays = parseField(String(fields[4]), range: 0...6)
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current

        // Start searching from the next minute after `base`
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: base)
        comps.second = 0
        guard var candidate = cal.date(from: comps) else { return nil }
        candidate = candidate.addingTimeInterval(60)  // at least one minute in the future

        // Search up to 4 years ahead to avoid infinite loops on impossible expressions
        let limit = base.addingTimeInterval(4 * 365 * 86400)

        while candidate < limit {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month   = c.month,
                  let day     = c.day,
                  let hour    = c.hour,
                  let minute  = c.minute,
                  let weekday = c.weekday   // 1=Sunday … 7=Saturday
            else { break }

            let wd = weekday - 1   // normalise to 0-6 (0=Sunday)

            if !months.contains(month) {
                // Advance to 1st of next matching month
                guard let next = nextMonth(after: candidate, matching: months, cal: cal) else { break }
                candidate = next
                continue
            }
            if !days.contains(day) || !weekdays.contains(wd) {
                // Advance to midnight of next day
                guard let next = cal.date(byAdding: .day, value: 1, to: candidate.startOfDay(cal: cal)) else { break }
                candidate = next
                continue
            }
            if !hours.contains(hour) {
                // Advance to the next matching hour
                guard let next = nextHour(after: candidate, matching: hours, cal: cal) else { break }
                candidate = next
                continue
            }
            if !minutes.contains(minute) {
                // Advance to the next matching minute
                guard let next = nextMinute(after: candidate, matching: minutes, cal: cal) else { break }
                candidate = next
                continue
            }

            return candidate
        }
        return nil
    }

    // MARK: - Field parser

    private static func parseField(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        var result = Set<Int>()

        for part in field.split(separator: ",") {
            let s = String(part)

            if s == "*" {
                result.formUnion(range)
            } else if s.hasPrefix("*/") {
                guard let step = Int(s.dropFirst(2)), step > 0 else { return nil }
                stride(from: range.lowerBound, through: range.upperBound, by: step).forEach { result.insert($0) }
            } else if s.contains("-") {
                let bounds = s.split(separator: "-")
                guard bounds.count == 2,
                      let lo = Int(bounds[0]), let hi = Int(bounds[1]),
                      range.contains(lo), range.contains(hi)
                else { return nil }
                (lo...hi).forEach { result.insert($0) }
            } else {
                guard let v = Int(s), range.contains(v) else { return nil }
                result.insert(v)
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Advance helpers

    private static func nextMonth(after date: Date, matching months: Set<Int>, cal: Calendar) -> Date? {
        var d = date
        for _ in 0..<24 {
            guard let next = cal.date(byAdding: .month, value: 1, to: d) else { return nil }
            d = next.startOfMonth(cal: cal)
            if months.contains(cal.component(.month, from: d)) { return d }
        }
        return nil
    }

    private static func nextHour(after date: Date, matching hours: Set<Int>, cal: Calendar) -> Date? {
        var d = date
        for _ in 0..<48 {
            guard let next = cal.date(byAdding: .hour, value: 1, to: d) else { return nil }
            guard let zeroed = cal.date(bySetting: .minute, value: 0, of: next) else { return nil }
            d = zeroed
            if hours.contains(cal.component(.hour, from: d)) { return d }
        }
        return nil
    }

    private static func nextMinute(after date: Date, matching minutes: Set<Int>, cal: Calendar) -> Date? {
        var d = date
        for _ in 0..<120 {
            guard let next = cal.date(byAdding: .minute, value: 1, to: d) else { return nil }
            d = next
            if minutes.contains(cal.component(.minute, from: d)) { return d }
        }
        return nil
    }
}

// MARK: - Date helpers

private extension Date {
    func startOfDay(cal: Calendar) -> Date {
        cal.startOfDay(for: self)
    }

    func startOfMonth(cal: Calendar) -> Date {
        let comps = cal.dateComponents([.year, .month], from: self)
        return cal.date(from: comps) ?? self
    }
}

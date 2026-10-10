import Foundation

/// Display text for server bucket labels. The wire format carries full
/// timestamps (`2026-10-05 00:00:00`) on every bucket; rendering those
/// verbatim clutters axes, readouts, and tables with seconds nobody
/// needs. Display text is presentation-only: raw labels stay the chart
/// identity (selection, runs, accessibility counts).
public enum BucketLabels {
    private static func make(format: String, timeZone: TimeZone, posix: Bool = false) -> DateFormatter {
        let out = DateFormatter()
        out.locale = Locale(identifier: posix ? "en_US_POSIX" : "en_US")
        out.timeZone = timeZone
        out.dateFormat = format
        return out
    }

    /// Short human label for one raw bucket label in a period's context.
    /// Intraday buckets render as clock time (`14:00`); coarser buckets
    /// as day (`5 Oct`). Anything unparseable passes through untouched so
    /// no information is ever lost. Server labels are site wall-clock,
    /// so parsing and rendering share the site timezone (no conversion).
    public static func display(_ raw: String, for period: Period, in timeZone: TimeZone) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let date = make(format: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone, posix: true).date(from: text) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
            let intraday = (clock.hour ?? 0) != 0 || (clock.minute ?? 0) != 0 || (clock.second ?? 0) != 0
            switch period {
            case .realtime, .day:
                return make(format: "HH:mm", timeZone: timeZone).string(from: date)
            default:
                if intraday {
                    return make(format: "HH:mm", timeZone: timeZone).string(from: date)
                }
                return make(format: "d MMM", timeZone: timeZone).string(from: date)
            }
        }
        if let date = make(format: "yyyy-MM-dd", timeZone: timeZone, posix: true).date(from: text) {
            return make(format: "d MMM", timeZone: timeZone).string(from: date)
        }
        return raw
    }

    /// Clock label for realtime minute offsets (`-14` → site clock time
    /// at request time). Display-only; identity stays on raw values.
    public static func clockLabel(minutesAgo: Int, today: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(byAdding: .minute, value: minutesAgo, to: today) ?? today
        return make(format: "HH:mm", timeZone: timeZone).string(from: date)
    }
}

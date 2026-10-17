import AnalyticsCore
import SwiftUI

/// Shared period formatting plus native calendar sheets for picking a
/// specific day or an inclusive custom range. Day mode is a native graphical
/// date picker; range mode is a native multi-date picker whose minimum and
/// maximum form the range. Both commit explicitly with Done.
public enum PeriodLabel {
    /// Short site-local day text (`5 Oct`, with year when not this year).
    public static func shortDay(_ date: Date, in timeZone: TimeZone, today: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: date)
        let todayYear = calendar.component(.year, from: today)
        let format = year == todayYear ? "d MMM" : "d MMM yyyy"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Pill text for the working model: Today/Yesterday keep their names,
    /// any other anchored day shows its date, custom ranges show both ends.
    public static func name(period: Period, periodDate: Date?, timeZone: TimeZone, today: Date = Date()) -> String {
        switch period {
        case .realtime: return "Realtime"
        case .day:
            guard let date = periodDate else { return "Today" }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let todayStart = calendar.startOfDay(for: today)
            if calendar.isDate(date, inSameDayAs: todayStart) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
               calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
            return shortDay(date, in: timeZone, today: today)
        case .days7: return "Last 7 days"
        case .days28: return "Last 28 days"
        case .days30: return "Last 30 days"
        case .days91: return "Last 91 days"
        case .month: return "Month to date"
        case .year: return "Year to date"
        case .months6: return "Last 6 months"
        case .months12: return "Last 12 months"
        case .all: return "All time"
        case .custom(let from, let to):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if calendar.isDate(from, inSameDayAs: to) {
                return shortDay(from, in: timeZone, today: today)
            }
            return "\(shortDay(from, in: timeZone, today: today)) – \(shortDay(to, in: timeZone, today: today))"
        }
    }

    /// Initial day selection: the anchored day, else today in site time.
    public static func initialDay(period: Period, periodDate: Date?, timeZone: TimeZone, today: Date = Date()) -> Date {
        if period == .day, let date = periodDate { return date }
        if case .custom(let from, _) = period { return from }
        return SiteDateRules.startOfDay(today, in: timeZone)
    }

    /// Initial custom range: current custom, else the last 7 site days.
    public static func initialRange(period: Period, timeZone: TimeZone, today: Date = Date()) -> (from: Date, to: Date) {
        if case .custom(let from, let to) = period { return (from, to) }
        let end = SiteDateRules.startOfDay(today, in: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        return (start, end)
    }
}

/// Gregorian calendar pinned to the site timezone.
private func siteCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

/// Calendar sheet for one specific day. Commits as `.day` (nil-anchored
/// for today, dated otherwise) so the wire carries `period=day&date=…`.
public struct DayPickerSheet: View {
    @Bindable var model: QueryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    public init(model: QueryModel) {
        self.model = model
        _selection = State(initialValue: PeriodLabel.initialDay(
            period: model.period, periodDate: model.periodDate,
            timeZone: model.base.timeZone
        ))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                DatePicker(
                    "Day",
                    selection: $selection,
                    in: ...SiteDateRules.startOfDay(Date(), in: model.base.timeZone),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityIdentifier("day-picker-date")
                Button("Today") {
                    selection = SiteDateRules.startOfDay(Date(), in: model.base.timeZone)
                }
                .font(.caption)
                .accessibilityIdentifier("day-picker-today")
                Text("A single day uses the site's timezone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Pick a day")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("day-picker-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.setDay(selection)
                        dismiss()
                    }
                    .accessibilityIdentifier("day-picker-done")
                }
            }
        }
    }
}

/// Calendar sheet for an inclusive custom range. One native picker: a
/// multi-date calendar on iOS, From/To graphical pickers on macOS. The
/// earliest and latest days form the range, so the selection is always
/// ordered and Done is available whenever the range holds no future days.
public struct RangePickerSheet: View {
    @Bindable var model: QueryModel
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date

    public init(model: QueryModel) {
        self.model = model
        let initial = PeriodLabel.initialRange(period: model.period, timeZone: model.base.timeZone)
        _from = State(initialValue: initial.from)
        _to = State(initialValue: initial.to)
    }

    private var calendar: Calendar { siteCalendar(model.base.timeZone) }

    private var todayStart: Date {
        calendar.startOfDay(for: Date())
    }

    private var hasFuture: Bool {
        to > todayStart
    }

    private var summary: String {
        PeriodLabel.name(
            period: .custom(from: from, to: to),
            periodDate: nil, timeZone: model.base.timeZone
        )
    }

#if os(iOS)
    /// Dots always mirror the effective range: deselecting a middle day
    /// snaps back, deselecting an endpoint shrinks the range, tapping
    /// outside extends it. Clearing everything keeps the last range.
    private var daySelection: Binding<Set<DateComponents>> {
        Binding(
            get: { Self.components(from: from, to: to, timeZone: model.base.timeZone) },
            set: { picked in
                let dates = picked.compactMap { calendar.date(from: $0) }.sorted()
                guard let first = dates.first, let last = dates.last else { return }
                from = calendar.startOfDay(for: first)
                to = calendar.startOfDay(for: last)
            }
        )
    }
#endif

    public var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(summary)
                    .font(.headline)
                    .accessibilityIdentifier("range-picker-summary")
#if os(iOS)
                MultiDatePicker("Range", selection: daySelection)
                    .accessibilityIdentifier("range-picker-calendar")
#else
                DatePicker("From", selection: $from, in: ...todayStart, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("range-picker-from")
                DatePicker("To", selection: $to, in: from...todayStart, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("range-picker-to")
#endif
                HStack {
                    Button("Last 7 days") { applyLast(days: 7) }
                        .accessibilityIdentifier("range-quick-7d")
                    Spacer()
                    Button("Last 30 days") { applyLast(days: 30) }
                        .accessibilityIdentifier("range-quick-30d")
                    Spacer()
                    Button("This month") { applyThisMonth() }
                        .accessibilityIdentifier("range-quick-month")
                }
                .font(.caption)
                if hasFuture {
                    Text("Ranges can't include future days.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("range-picker-error")
                } else {
                    Text("Ranges are inclusive on both ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Pick a range")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("range-picker-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.setCustomRange(from: from, to: to)
                        dismiss()
                    }
                    .disabled(hasFuture)
                    .accessibilityIdentifier("range-picker-done")
                }
            }
        }
    }

    /// Every site day in [from, to] as components the native picker matches
    /// on. The calendar and timezone ride along so site-local days never
    /// shift under a differently-zoned device.
    static func components(from: Date, to: Date, timeZone: TimeZone) -> Set<DateComponents> {
        let calendar = siteCalendar(timeZone)
        var result = Set<DateComponents>()
        var day = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while day <= end {
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.calendar = calendar
            parts.timeZone = timeZone
            result.insert(parts)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    private func applyLast(days count: Int) {
        let end = calendar.startOfDay(for: Date())
        from = calendar.date(byAdding: .day, value: -(count - 1), to: end) ?? end
        to = end
    }

    private func applyThisMonth() {
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        from = calendar.startOfDay(for: startOfMonth)
        to = calendar.startOfDay(for: now)
    }
}

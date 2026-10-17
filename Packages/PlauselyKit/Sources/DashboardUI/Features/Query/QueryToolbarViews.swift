import AnalyticsCore
import SwiftUI

/// Period/comparison/import controls. Every selection rewrites the model's
/// effective query (or surfaces a typed rejection); nothing here guesses
/// transport shapes.
public struct QueryToolbarView: View {
    @Bindable private var model: QueryModel
    @State private var showingDayPicker = false
    @State private var showingRangePicker = false

    public init(model: QueryModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    periodMenu
                    comparisonMenu
                    Toggle("Imported", isOn: importToggle)
                        .accessibilityIdentifier("import-toggle")
                }
            }
            .accessibilityIdentifier("query-toolbar")
            if model.period == .day {
                dayEditor
            }
            if case .custom = model.period {
                customRangeEditors
            }
            if case .custom = model.comparison {
                customComparisonEditors
            }
            if model.comparison == .previousPeriod {
                Toggle("Match day of week", isOn: $model.matchDayOfWeek)
                    .accessibilityIdentifier("match-weekday-toggle")
            }
            if let error = model.error {
                Text(controlErrorMessage(error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("query-error")
            }
        }
    }

    // MARK: - Period

    private var periodMenu: some View {
        Menu {
            periodButton("Realtime", period: .realtime)
            periodButton("Today", period: .day)
            Button("Yesterday") { model.setYesterday() }
            Button("Pick a day…") { showingDayPicker = true }
            Button("Pick a range…") { showingRangePicker = true }
            periodButton("Last 7 days", period: .days7)
            periodButton("Last 30 days", period: .days30)
            periodButton("Month to date", period: .month)
            periodButton("Year to date", period: .year)
            periodButton("Last 6 months", period: .months6)
            periodButton("Last 12 months", period: .months12)
            periodButton("All time", period: .all)
        } label: {
            Label(periodName, systemImage: "calendar")
        }
        .accessibilityIdentifier("period-picker")
        .sheet(isPresented: $showingDayPicker) {
            DayPickerSheet(model: model)
        }
        .sheet(isPresented: $showingRangePicker) {
            RangePickerSheet(model: model)
        }
    }

    private func periodButton(_ title: String, period: Period) -> some View {
        Button(title) { model.setPeriod(period) }
    }

    private var periodName: String {
        PeriodLabel.name(period: model.period, periodDate: model.periodDate, timeZone: model.base.timeZone)
    }

    private var dayEditor: some View {
        DatePicker(
            "Day",
            selection: Binding(
                get: { model.periodDate ?? SiteDateRules.startOfDay(Date(), in: model.base.timeZone) },
                set: { model.setDay($0) }
            ),
            in: ...SiteDateRules.startOfDay(Date(), in: model.base.timeZone),
            displayedComponents: .date
        )
        .accessibilityIdentifier("period-day")
    }

    private var customRangeEditors: some View {
        Group {
            if case .custom(let from, let to) = model.period {
                Text(PeriodLabel.name(period: model.period, periodDate: model.periodDate, timeZone: model.base.timeZone))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("period-range-label")
                DatePicker("From", selection: customBinding(from: from, to: to, isFrom: true), displayedComponents: .date)
                    .accessibilityIdentifier("period-from")
                DatePicker("To", selection: customBinding(from: from, to: to, isFrom: false), displayedComponents: .date)
                    .accessibilityIdentifier("period-to")
                Text("Ranges are inclusive on both ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func customBinding(from: Date, to: Date, isFrom: Bool) -> Binding<Date> {
        Binding(
            get: { isFrom ? from : to },
            set: { newValue in
                model.setCustomRange(from: isFrom ? newValue : from, to: isFrom ? to : newValue)
            }
        )
    }

    // MARK: - Comparison

    private var comparisonMenu: some View {
        Menu {
            Button("No comparison") { model.setComparison(.off) }
            Button("Previous period") { model.setComparison(.previousPeriod) }
            Button("Year over year") { model.setComparison(.yearOverYear) }
            Button("Custom") { model.setComparison(compareDefault()) }
        } label: {
            Label(comparisonName, systemImage: "chart.bar.xaxis")
        }
        .accessibilityIdentifier("comparison-picker")
    }

    private var comparisonName: String {
        switch model.comparison {
        case .off: return "No comparison"
        case .previousPeriod: return "Previous period"
        case .yearOverYear: return "Year over year"
        case .custom: return "Custom comparison"
        }
    }

    private func compareDefault() -> Comparison {
        let today = SiteDateRules.startOfDay(Date(), in: model.base.timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.base.timeZone
        let from = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        return .custom(from: from, to: today)
    }

    private var customComparisonEditors: some View {
        Group {
            if case .custom(let from, let to) = model.comparison {
                DatePicker("Compare from", selection: compareBinding(from: from, to: to, isFrom: true), displayedComponents: .date)
                    .accessibilityIdentifier("compare-from")
                DatePicker("Compare to", selection: compareBinding(from: from, to: to, isFrom: false), displayedComponents: .date)
                    .accessibilityIdentifier("compare-to")
            }
        }
    }

    private func compareBinding(from: Date, to: Date, isFrom: Bool) -> Binding<Date> {
        Binding(
            get: { isFrom ? from : to },
            set: { newValue in
                model.setComparison(.custom(from: isFrom ? newValue : from, to: isFrom ? to : newValue))
            }
        )
    }

    // MARK: - Imports

    private var importToggle: Binding<Bool> {
        Binding(
            get: { model.includeImported },
            set: {
                model.includeImported = $0
                model.refresh()
            }
        )
    }
}

func controlErrorMessage(_ error: QueryControlError) -> String {
    switch error {
    case .multipleGoalFilters:
        return "Only one goal filter at a time."
    case .multipleSegments:
        return "Only one segment at a time."
    case .invalidSegmentValues:
        return "A segment filter needs one numeric segment."
    case .comparisonUnsupported(let period):
        return "Comparisons are off for \(period)."
    case .emptyCustomRange:
        return "Custom range ends before it starts."
    case .emptyComparisonRange:
        return "Comparison range ends before it starts."
    case .filterInvalid(let message):
        return message
    }
}

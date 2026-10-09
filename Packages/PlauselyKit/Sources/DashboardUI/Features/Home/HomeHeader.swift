import AnalyticsCore
import SwiftUI

/// Shared pill header: site picker plus period picker.
struct HomeHeaderPills: View {
    @Bindable var selection: SiteSelectionModel
    var queryModel: QueryModel?

    var body: some View {
        HStack {
            sitePill
            Spacer(minLength: 8)
            if let queryModel {
                HomePeriodPill(model: queryModel)
            }
        }
        .task {
            await selection.loadAccounts()
        }
    }

    private var sitePill: some View {
        Menu {
            if selection.accounts.count > 1 {
                Section("Instance") {
                    ForEach(selection.accounts, id: \.id) { account in
                        Button(account.displayName) {
                            Task { await selection.selectAccount(account.id) }
                        }
                    }
                }
            }
            Section("Sites") {
                ForEach(selection.sites, id: \.domain) { site in
                    Button(site.domain) {
                        selection.selectSite(site.domain)
                    }
                }
            }
        } label: {
            Text(selection.selectedSite?.domain ?? "Select a site")
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassCapsule()
        }
        .accessibilityIdentifier("home-site")
    }
}

/// Period presets plus inline custom editors. Same titles and behavior
/// as the toolbar; the toolbar itself stays on macOS.
struct HomePeriodPill: View {
    @Bindable var model: QueryModel

    var body: some View {
        Menu {
            Button("Realtime") { model.setPeriod(.realtime) }
            Button("Today") { model.setPeriod(.day) }
            Button("Yesterday") { model.setYesterday() }
            Button("Last 7 days") { model.setPeriod(.days7) }
            Button("Last 28 days") { model.setPeriod(.days28) }
            Button("Last 30 days") { model.setPeriod(.days30) }
            Button("Last 91 days") { model.setPeriod(.days91) }
            Button("Month to date") { model.setPeriod(.month) }
            Button("Year to date") { model.setPeriod(.year) }
            Button("Last 6 months") { model.setPeriod(.months6) }
            Button("Last 12 months") { model.setPeriod(.months12) }
            Button("All time") { model.setPeriod(.all) }
            Button("Custom range") { model.setPeriod(HomePeriodPill.customDefault(for: model)) }
        } label: {
            Text(HomePeriodPill.name(for: model))
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassCapsule()
        }
        .accessibilityIdentifier("home-period")
    }

    static func name(for model: QueryModel) -> String {
        switch model.period {
        case .realtime: return "Realtime"
        case .day: return model.periodDate == nil ? "Today" : "Yesterday"
        case .days7: return "Last 7 days"
        case .days28: return "Last 28 days"
        case .days30: return "Last 30 days"
        case .days91: return "Last 91 days"
        case .month: return "Month to date"
        case .year: return "Year to date"
        case .months6: return "Last 6 months"
        case .months12: return "Last 12 months"
        case .all: return "All time"
        case .custom: return "Custom"
        }
    }

    static func customDefault(for model: QueryModel) -> Period {
        let today = SiteDateRules.startOfDay(Date(), in: model.base.timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.base.timeZone
        let from = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        return .custom(from: from, to: today)
    }
}

/// Comparison, import toggle, and custom editors for the home tabs.
/// Same titles as the toolbar so menu-driven tests keep working.
struct HomeOptionsView: View {
    @Bindable var model: QueryModel

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    comparisonMenu
                    Toggle("Imported", isOn: importToggle)
                        .accessibilityIdentifier("import-toggle")
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
    }

    private var comparisonMenu: some View {
        Menu {
            Button("No comparison") { model.setComparison(.off) }
            Button("Previous period") { model.setComparison(.previousPeriod) }
            Button("Year over year") { model.setComparison(.yearOverYear) }
            Button("Custom") { model.setComparison(HomeOptionsView.compareDefault(for: model)) }
        } label: {
            Text(comparisonName)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassCapsule()
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

    static func compareDefault(for model: QueryModel) -> Comparison {
        let today = SiteDateRules.startOfDay(Date(), in: model.base.timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.base.timeZone
        let from = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        return .custom(from: from, to: today)
    }

    private var importToggle: Binding<Bool> {
        Binding(
            get: { model.includeImported },
            set: {
                model.includeImported = $0
                model.refresh()
            }
        )
    }

    private var customRangeEditors: some View {
        Group {
            if case .custom(let from, let to) = model.period {
                DatePicker("From", selection: rangeBinding(from: from, to: to, isFrom: true), displayedComponents: .date)
                    .accessibilityIdentifier("period-from")
                DatePicker("To", selection: rangeBinding(from: from, to: to, isFrom: false), displayedComponents: .date)
                    .accessibilityIdentifier("period-to")
            }
        }
    }

    private func rangeBinding(from: Date, to: Date, isFrom: Bool) -> Binding<Date> {
        Binding(
            get: { isFrom ? from : to },
            set: { model.setPeriod(.custom(from: isFrom ? $0 : from, to: isFrom ? to : $0)) }
        )
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
            set: { model.setComparison(.custom(from: isFrom ? $0 : from, to: isFrom ? to : $0)) }
        )
    }
}

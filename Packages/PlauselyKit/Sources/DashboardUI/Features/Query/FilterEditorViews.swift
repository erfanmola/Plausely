import AnalyticsCore
import SwiftUI

/// Deterministic providers for UI tests and previews. Production providers
/// arrive with the client-wiring follow-on; nothing here touches the network.
public enum MockQueryProviders {
    public static var suggestions: SuggestionProvider {
        { request, _ in
            let options: [String]
            switch request.filterName {
            case "source": options = ["Google", "Direct / None", "Bing", "newsletter"]
            case "country": options = ["Germany", "Iran", "United States"]
            case "goal": options = ["Signup", "Purchase", "Visit /checkout/success"]
            case "page": options = ["/", "/pricing", "/blog"]
            case "browser": options = ["Chrome", "Safari", "Firefox"]
            default: options = []
            }
            guard !request.input.isEmpty else { return options.prefix(3).map { Suggestion(label: $0, value: $0) } }
            return options
                .filter { $0.localizedCaseInsensitiveContains(request.input) }
                .map { Suggestion(label: $0, value: $0) }
        }
    }

    public static var segments: SegmentListProvider {
        { _ in
            [
                SavedSegment(id: 7, name: "Mobile", kind: .personal, filters: FilterExpression(clauses: [
                    FilterClause(dimension: .os, op: .is_, values: [.text("iOS")])
                ])),
                SavedSegment(id: 9, name: "Search", kind: .site, filters: FilterExpression(clauses: [
                    FilterClause(dimension: .channel, op: .is_, values: [.text("Organic Search")])
                ])),
            ]
        }
    }

    /// Deterministic bootstrap interval map for UI tests and previews.
    /// Shape mirrors the dashboard's `validIntervalsByPeriod` (lists in
    /// dashboard-preference order); live maps arrive per site from the
    /// real bootstrap transport.
    public static var intervals: IntervalPolicy {
        IntervalPolicy(validByPeriod: [
            "realtime": [.minute],
            "day": [.minute],
            "7d": [.hour, .day],
            "28d": [.day, .week],
            "30d": [.day, .week],
            "91d": [.day, .week],
            "month": [.day, .week],
            "year": [.day, .week, .month],
            "6mo": [.day, .week, .month],
            "12mo": [.day, .week, .month],
            "all": [.week, .month],
            "custom": [.day, .week, .month],
        ])
    }
}

/// Active filters, locked scope, and the read-only segment list. Clause
/// construction lives in the sheet; every commit revalidates through the
/// model before it can affect the exact query.
public struct FilterEditorView: View {
    @Bindable private var model: QueryModel
    @State private var showingAdd = false

    public init(model: QueryModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if !model.locked.clauses.isEmpty {
                Section("Locked by shared link") {
                    ForEach(Array(model.locked.clauses.enumerated()), id: \.offset) { index, clause in
                        Label(clauseSummary(clause), systemImage: "lock.fill")
                            .accessibilityIdentifier("locked-chip-\(index)")
                    }
                }
            }
            Section("Filters") {
                if model.clauses.isEmpty {
                    Text("No filters")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("no-filters")
                } else {                    ForEach(Array(model.clauses.enumerated()), id: \.offset) { index, clause in
                        HStack {
                            Text(clauseSummary(clause))
                                .accessibilityIdentifier("filter-chip-\(index)")
                            Spacer()
                            Button("Remove", role: .destructive) { model.removeClause(at: index) }
                                .accessibilityIdentifier("filter-remove-\(index)")
                        }
                    }
                    Button("Clear all") { model.clearUserFilters() }
                        .accessibilityIdentifier("filter-clear")
                }
                Button("Add filter") { showingAdd = true }
                    .accessibilityIdentifier("filter-add")
                    .sheet(isPresented: $showingAdd) {
                        FilterClauseSheet(model: model)
                    }
            }
            if let error = model.error {
                Text(controlErrorMessage(error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("filter-error")
            }
            if model.showsSegments {
                SegmentListView(model: model)
            }
        }
    }
}

/// Read-only segment list: apply expands the segment's stored filters into
/// the query (single-segment rule); Remove detaches them again. No
/// create/edit/delete surface exists here by design (phase 08 scope).
public struct SegmentListView: View {
    @Bindable private var model: QueryModel

    public init(model: QueryModel) {
        self.model = model
    }

    public var body: some View {
        Section("Segments") {
            switch model.segmentsState {
            case .unconfigured:
                EmptyView()
            case .loading:
                ProgressView("Loading segments…")
                    .accessibilityIdentifier("segments-loading")
            case .loaded(let segments):
                if segments.isEmpty {
                    Label("No saved segments", systemImage: "bookmark")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("segments-empty")
                }
                ForEach(segments, id: \.id) { segment in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(segment.name)
                            Text(segment.kind == .personal ? "Personal" : "Site")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.appliedSegmentID == segment.id {
                            Text("Applied")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("segment-applied-\(segment.id)")
                            Button("Remove") { model.clearSegment() }
                                .accessibilityIdentifier("segment-clear")
                        } else {
                            Button("Apply") { _ = model.applySegment(segment) }
                                .accessibilityIdentifier("segment-apply-\(segment.id)")
                        }
                    }
                }
            case .failed(let error):
                Text(error.message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("segments-error")
                Button("Retry") { Task { await model.loadSegments() } }
                    .accessibilityIdentifier("segments-retry")
            }
        }
        .task { await model.loadSegments() }
    }
}

/// One clause builder: dimension, restricted operators, property key where
/// required, one or more values with suggestions, then a validating commit.
public struct FilterClauseSheet: View {
    @Bindable private var model: QueryModel
    @Environment(\.dismiss) private var dismiss
    @State private var dimension: FilterDimension = .source
    @State private var op: FilterOperator = .is_
    @State private var propertyKey = ""
    @State private var draft = ""
    @State private var values: [String] = []
    @State private var localError: String?
    @State private var suggestions: [Suggestion] = []

    public init(model: QueryModel) {
        self.model = model
    }

    private var sheetDimensions: [FilterDimension] {
        FilterDimension.allCases.filter { $0 != .segment }
    }

    private var allowedOperators: [FilterOperator] {
        switch dimension {
        case .screen, .country, .region, .city:
            return [.is_, .isNot]
        default:
            return [.is_, .isNot, .contains, .containsNot]
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Picker("Dimension", selection: $dimension) {
                    ForEach(sheetDimensions, id: \.self) { Text(dimensionName($0)).tag($0) }
                }
                .accessibilityIdentifier("clause-dimension")
                .onChange(of: dimension) { _, _ in
                    if !allowedOperators.contains(op) { op = .is_ }
                    values.removeAll()
                    suggestions.removeAll()
                }
                Picker("Operator", selection: $op) {
                    ForEach(allowedOperators, id: \.self) { Text(operatorName($0)).tag($0) }
                }
                .accessibilityIdentifier("clause-operator")
                if dimension == .props {
                    TextField("Property key", text: $propertyKey)
                        .accessibilityIdentifier("clause-props-key")
                }
                Section("Values") {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .accessibilityIdentifier("clause-value-\(value)")
                    }
                    .onDelete { values.remove(atOffsets: $0) }
                    HStack {
                        TextField(valuePrompt, text: $draft)
                            .accessibilityIdentifier("clause-value")
                        Button("Add") { addDraft() }
                            .accessibilityIdentifier("clause-value-add")
                    }
                    if model.canSuggest, !suggestions.isEmpty {
                        ForEach(suggestions, id: \.value) { suggestion in
                            Button(suggestion.label) {
                                draft = suggestion.value
                                addDraft()
                            }
                            .accessibilityIdentifier("suggestion-\(suggestion.value)")
                        }
                    }
                }
                if let localError {
                    Text(localError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("clause-error")
                }
            }
            .task(id: draft) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, !draft.isEmpty else { return }
                suggestions = await model.suggest(dimension: dimension, propertyKey: propertyKey, input: draft)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("clause-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add filter") { commit() }
                        .accessibilityIdentifier("clause-add")
                }
            }
        }
    }

    private var valuePrompt: String {
        dimension.usesIntegerValues ? "Numeric ID" : "Value"
    }

    private func addDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if dimension.usesIntegerValues, Int(trimmed) == nil {
            localError = "This dimension needs a numeric ID."
            return
        }
        if !values.contains(trimmed) { values.append(trimmed) }
        draft = ""
        localError = nil
    }

    private func commit() {
        if dimension == .props, propertyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            localError = "Property filters need a key."
            return
        }
        guard !values.isEmpty else {
            localError = "Add at least one value."
            return
        }
        let filterValues: [FilterValue] = values.map {
            dimension.usesIntegerValues ? .number(Int($0) ?? 0) : .text($0)
        }
        let clause = FilterClause(
            dimension: dimension,
            propertyKey: dimension == .props ? propertyKey : nil,
            op: op,
            values: filterValues
        )
        if model.addClause(clause) {
            dismiss()
        } else if let rejection = model.error {
            localError = controlErrorMessage(rejection)
        }
    }
}

func dimensionName(_ dimension: FilterDimension) -> String {
    switch dimension {
    case .page: return "Page"
    case .entryPage: return "Entry page"
    case .exitPage: return "Exit page"
    case .source: return "Source"
    case .channel: return "Channel"
    case .referrer: return "Referrer"
    case .country: return "Country"
    case .region: return "Region"
    case .city: return "City"
    case .screen: return "Screen size"
    case .browser: return "Browser"
    case .browserVersion: return "Browser version"
    case .os: return "Operating system"
    case .osVersion: return "OS version"
    case .utmMedium: return "UTM medium"
    case .utmSource: return "UTM source"
    case .utmCampaign: return "UTM campaign"
    case .utmTerm: return "UTM term"
    case .utmContent: return "UTM content"
    case .goal: return "Goal"
    case .props: return "Property"
    case .hostname: return "Hostname"
    case .segment: return "Segment"
    case .name: return "Event name"
    }
}

func operatorName(_ op: FilterOperator) -> String {
    switch op {
    case .is_: return "is"
    case .isNot: return "is not"
    case .contains: return "contains"
    case .containsNot: return "does not contain"
    case .hasNotDone: return "has not completed"
    }
}

func clauseSummary(_ clause: FilterClause) -> String {
    let dimension = clause.dimension == .props
        ? "Property \(clause.propertyKey ?? "")"
        : dimensionName(clause.dimension)
    let values = clause.values.map { value in
        switch value {
        case .text(let text): return text
        case .number(let number): return String(number)
        }
    }.joined(separator: ", ")
    return "\(dimension) \(operatorName(clause.op)) \(values)"
}

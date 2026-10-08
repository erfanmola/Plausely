import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@Suite("goals and properties (07)")
@MainActor
struct GoalsPropsTests {
    @Test("conversions carry uniques, totals, and server rates")
    func conversionContracts() {
        #expect(ReportDefinition.conversions.columns == [.visitors, .events, .conversionRate])
        #expect(ReportDefinition.conversions.filterDimension == .goal)
        #expect(ReportDefinition.conversions.drilldown(
            BreakdownRow(name: "Signup", metrics: [.visitors: .count(1)])
        ) == nil)
        #expect(ReportDefinition.conversions.filterClause(for: "Signup") == FilterClause(
            dimension: .goal, op: .is_, values: [.text("Signup")]
        ))
        #expect(ReportDefinition.conversions.idPrefix == "breakdown-conversions")
        #expect(breakdownDefinition(for: .conversions).title == "Goal conversions")
        #expect(!ReportDefinition.conversions.supportsSearch)
    }

    @Test("property values carry their key and filter by key")
    func propContracts() {
        let definition = ReportDefinition.customPropValues(key: "plan")
        #expect(definition.columns == [.visitors, .events, .percentage, .conversionRate])
        #expect(definition.filterDimension == .props)
        #expect(definition.title == "plan")
        #expect(definition.filterClause(for: "Monthly") == FilterClause(
            dimension: .props, propertyKey: "plan", op: .is_, values: [.text("Monthly")]
        ))
        #expect(definition.drilldown(
            BreakdownRow(name: "Monthly", metrics: [.visitors: .count(1)])
        ) == nil)
        #expect(definition.idPrefix == "breakdown-custom-prop-values-plan")
        let resolved = breakdownDefinition(for: .customPropValues(key: "plan"))
        #expect(resolved.title == "plan")
        #expect(resolved.columns == definition.columns)
    }

    @Test("mock goal and property sets mirror the live shapes")
    func mockGoalPropDatasets() {
        let goals = MockBreakdownProviders.dataset(for: .conversions)
        #expect(goals.map(\.name) == ["Signup", "Visit /checkout/success", "Purchase"])
        #expect(goals.allSatisfy { $0.metrics[.events] != nil && $0.metrics[.conversionRate] != nil })

        let props = MockBreakdownProviders.dataset(for: .customPropValues(key: "plan"))
        #expect(props.map(\.name) == ["Monthly", "Yearly", "(none)"])
        #expect(props.allSatisfy { $0.metrics[.percentage] != nil })
    }
}

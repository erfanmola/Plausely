import Testing
@testable import AnalyticsCore
import Foundation

@Suite("filter contracts")
struct FilterTests {
    @Test("wire keys follow the dashboard prefix rules")
    func wireKeys() throws {
        let page = FilterExpression(clauses: [FilterClause(dimension: .page, op: .is_, values: [.text("/")])])
        #expect(try page.serialized() == #"[["is","event:page",["/"]]]"#)
        let source = FilterExpression(clauses: [FilterClause(dimension: .source, op: .is_, values: [.text("Google")])])
        #expect(try source.serialized() == #"[["is","visit:source",["Google"]]]"#)
        let segment = FilterExpression(clauses: [FilterClause(dimension: .segment, op: .is_, values: [.number(3)])])
        #expect(try segment.serialized() == #"[["is","segment",[3]]]"#)
        let props = FilterExpression(clauses: [FilterClause(dimension: .props, propertyKey: "plan", op: .is_, values: [.text("growth")])])
        #expect(try props.serialized() == #"[["is","event:props:plan",["growth"]]]"#)
    }

    @Test("contains is rejected for screen and locations")
    func containsRestrictions() {
        for dimension: FilterDimension in [.screen, .country, .region, .city] {
            let expr = FilterExpression(clauses: [FilterClause(dimension: dimension, op: .contains, values: [.text("x")])])
            #expect(throws: FilterValidationError.unsupportedOperator(.contains, dimension)) {
                try expr.serialized()
            }
        }
        let ok = FilterExpression(clauses: [FilterClause(dimension: .source, op: .contains, values: [.text("goo")])])
        #expect(throws: Never.self) { try ok.serialized() }
    }

    @Test("goal is-not becomes the has_not_done wrapper")
    func goalExclusion() throws {
        let expr = FilterExpression(clauses: [FilterClause(dimension: .goal, op: .isNot, values: [.text("Signup")])])
        #expect(try expr.serialized() == #"[["has_not_done",["is","event:goal",["Signup"]]]]"#)
        let bad = FilterExpression(clauses: [FilterClause(dimension: .source, op: .hasNotDone, values: [.text("x")])])
        #expect(throws: FilterValidationError.goalExclusionOnlyForGoal) {
            try bad.serialized()
        }
    }

    @Test("segment and geo IDs stay integers; text is rejected")
    func integerIDs() throws {
        let expr = FilterExpression(clauses: [FilterClause(dimension: .segment, op: .is_, values: [.number(7)])])
        #expect(try expr.serialized() == #"[["is","segment",[7]]]"#)
        let bad = FilterExpression(clauses: [FilterClause(dimension: .segment, op: .is_, values: [.text("7")])])
        #expect(throws: FilterValidationError.wrongValueType(.segment)) {
            try bad.serialized()
        }
    }

    @Test("empty clauses and missing prop keys are rejected")
    func invalidShapes() {
        let empty = FilterExpression(clauses: [FilterClause(dimension: .page, op: .is_, values: [])])
        #expect(throws: FilterValidationError.emptyValues(.page)) { try empty.serialized() }
        let noKey = FilterExpression(clauses: [FilterClause(dimension: .props, op: .is_, values: [.text("x")])])
        #expect(throws: FilterValidationError.missingPropertyKey) { try noKey.serialized() }
    }

    @Test("reserved characters and unicode survive structured encoding once")
    func unicodeRoundtrip() throws {
        let tricky = "/café?q=a&b=\"c\" 🎉"
        let expr = FilterExpression(clauses: [FilterClause(dimension: .page, op: .is_, values: [.text(tricky)])])
        let serialized = try expr.serialized()
        #expect(serialized.contains("caf"))
        let decoded = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [[Any]]
        #expect((decoded?.first?[2] as? [String])?.first == tricky)
    }

    @Test("empty expression serializes to an empty filter set")
    func emptyExpression() throws {
        #expect(try FilterExpression.empty.serialized() == "[]")
    }
}

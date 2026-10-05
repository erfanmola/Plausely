import Foundation

/// Display-only formatting. Rounding and units apply at render time; the
/// underlying `MetricValue` is never mutated by formatting.
public struct MetricFormatter: Sendable {
    private let numbers: NumberFormatter
    private let decimals: NumberFormatter

    public init(locale: Locale = .current) {
        let numbers = NumberFormatter()
        numbers.locale = locale
        numbers.numberStyle = .decimal
        numbers.maximumFractionDigits = 0
        self.numbers = numbers
        let decimals = NumberFormatter()
        decimals.locale = locale
        decimals.numberStyle = .decimal
        decimals.maximumFractionDigits = 2
        decimals.minimumFractionDigits = 0
        self.decimals = decimals
    }

    public func string(for value: MetricValue, as metric: MetricID) -> String {
        switch (value, MetricID.descriptor(for: metric).unit) {
        case (.unavailable, _):
            return "–"
        case (.count(let amount), .percent):
            return "\(numbers.string(from: NSNumber(value: Int(amount))) ?? "\(amount)")%"
        case (.count(let amount), .seconds):
            return duration(seconds: amount)
        case (.count(let amount), _):
            return numbers.string(from: NSNumber(value: Int(amount))) ?? "\(amount)"
        case (.decimal(let amount), .percent):
            return "\(decimals.string(from: amount as NSNumber) ?? "\(amount)")%"
        case (.decimal(let amount), .seconds):
            return duration(seconds: NSDecimalNumber(decimal: amount).int64Value)
        case (.decimal(let amount), _):
            return decimals.string(from: amount as NSNumber) ?? "\(amount)"
        }
    }

    /// Accessible label that spells out unavailable reasons.
    public func accessibleLabel(for value: MetricValue, as metric: MetricID) -> String {
        if case .unavailable(let reason) = value {
            let name = MetricID.descriptor(for: metric).displayName
            switch reason {
            case .null: return "\(name): no value reported"
            case .notDefined: return "\(name): not available for this view"
            case .notSupported: return "\(name): not supported"
            case .noData: return "\(name): no data"
            case .nonAdditive: return "\(name): cannot be combined"
            }
        }
        return "\(MetricID.descriptor(for: metric).displayName): \(string(for: value, as: metric))"
    }

    private func duration(seconds total: Int64) -> String {
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let rest = total % 60
        if minutes < 60 { return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

import Foundation

/// One point in the dotted same-time-of-day estimate for today's chart.
public struct TodayEstimatePoint: Equatable, Identifiable, Sendable {
    public let id: Int
    public let minute: Double
    public let value: Double

    public init(id: Int, minute: Double, value: Double) {
        self.id = id
        self.minute = minute
        self.value = value
    }
}

/// Builds an hourly-shape continuation from the current value and the
/// server-provided previous-period graph. Missing future buckets terminate
/// the estimate instead of being bridged or filled with invented values.
public enum TodayEstimate {
    public static func points(for series: TimeSeries, currentMinute: Double) -> [TodayEstimatePoint] {
        guard let comparisonLabels = series.comparisonLabels,
              let comparisonPlot = series.comparisonPlot
        else { return [] }

        let actual = zip(series.labels, series.plot).compactMap { label, rawValue -> (minute: Double, value: Double)? in
            guard let minute = minuteOfDay(label), minute <= currentMinute,
                  let rawValue, let value = doubleValue(rawValue) else { return nil }
            return (minute, value)
        }
        guard let anchor = actual.last else { return [] }

        let comparison: [(minute: Double, value: Double?)] = zip(comparisonLabels, comparisonPlot).compactMap { label, rawValue in
            guard let minute = minuteOfDay(label) else { return nil }
            return (minute, rawValue.flatMap(doubleValue))
        }.sorted { $0.minute < $1.minute }
        guard let comparisonAnchor = comparison.last(where: { $0.minute <= anchor.minute })?.value else { return [] }
        let offset = anchor.value - comparisonAnchor

        var future: [(minute: Double, value: Double)] = []
        for point in comparison where point.minute > currentMinute {
            guard let value = point.value else { break }
            future.append((point.minute, value + offset))
        }
        guard !future.isEmpty else { return [] }

        return [
            TodayEstimatePoint(id: -2, minute: anchor.minute, value: anchor.value),
            TodayEstimatePoint(id: -1, minute: currentMinute, value: anchor.value),
        ] + future.enumerated().map { index, point in
            TodayEstimatePoint(id: index, minute: point.minute, value: point.value)
        }
    }

    private static func minuteOfDay(_ label: String) -> Double? {
        let time = label.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? label
        let components = time.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]), let minute = Int(components[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return Double(hour * 60 + minute)
    }

    private static func doubleValue(_ value: MetricValue) -> Double? {
        switch value {
        case .count(let number): Double(number)
        case .decimal(let number): NSDecimalNumber(decimal: number).doubleValue
        case .unavailable: nil
        }
    }
}

import AnalyticsCore
import SwiftUI

/// Decorative SF Symbols for metrics and report families. All artwork is
/// hidden from VoiceOver (values and names already carry the meaning);
/// symbols are visual warmth only and never color-only meaning.
func metricSymbolName(for metric: MetricID) -> String {
    switch metric {
    case .visitors: return "person.2.fill"
    case .visits: return "person.fill"
    case .pageviews: return "doc.text.fill"
    case .viewsPerVisit: return "doc.on.doc.fill"
    case .bounceRate: return "arrow.uturn.backward"
    case .visitDuration: return "clock.fill"
    case .events: return "bolt.fill"
    case .conversions: return "flag.checkered"
    case .conversionRate, .groupConversionRate: return "percent"
    case .timeOnPage: return "timer"
    case .scrollDepth: return "arrow.down.to.line"
    case .percentage: return "chart.pie.fill"
    case .entrances: return "arrow.right.to.line"
    case .exits: return "arrow.left.to.line"
    case .exitRate: return "chart.pie"
    case .samplePercent: return "percent"
    case .impressions: return "eye.fill"
    case .ctr: return "percent"
    case .position: return "list.number"
    }
}

/// Family glyph for breakdown rows and hub lists.
func reportSymbolName(for kind: ReportKind) -> String {
    switch kind {
    case .channels: return "antenna.radiowaves.left.and.right"
    case .sources: return "tray.full.fill"
    case .referrerDrilldown: return "link"
    case .utmMediums, .utmSources, .utmCampaigns, .utmContents, .utmTerms:
        return "tag.fill"
    case .pages: return "doc.fill"
    case .entryPages: return "arrow.right.to.line"
    case .exitPages: return "arrow.left.to.line"
    case .countries: return "globe"
    case .regions: return "map.fill"
    case .cities: return "building.2.fill"
    case .browsers: return "globe.desk.fill"
    case .browserVersions: return "globe.desk"
    case .operatingSystems, .operatingSystemVersions: return "desktopcomputer"
    case .screenSizes: return "macwindow"
    case .conversions: return "flag.checkered"
    case .customPropValues: return "slider.horizontal.3"
    case .suggestions: return "magnifyingglass"
    case .searchTerms: return "magnifyingglass"
    }
}

/// Change sentiment for one metric's delta: growth is good except where
/// lower is better (bounce/exit rates, search position). Arrows and signs
/// always carry the direction too — color is never the only signal.
enum ChangeSentiment {
    case positive, negative, neutral

    static func of(_ change: Int?, for metric: MetricID) -> ChangeSentiment {
        guard let change, change != 0 else { return .neutral }
        let inverted = switch metric {
        case .bounceRate, .exitRate, .position: true
        default: false
        }
        let good = inverted ? change < 0 : change > 0
        return good ? .positive : .negative
    }
}

/// Change direction color: green for improvement, red for decline,
/// secondary for flat or uncomputable. Arrows and signs always carry the
/// direction too — color is never the only signal (MET-04).
func changeDirectionColor(_ change: Int?, for metric: MetricID) -> Color {
    switch ChangeSentiment.of(change, for: metric) {
    case .positive: return .green
    case .negative: return .red
    case .neutral: return .secondary
    }
}
/// Small tinted tile for a metric glyph. Decorative; always hidden from
/// VoiceOver by the caller.
struct MetricTile: View {
    let metric: MetricID

    var body: some View {
        Image(systemName: metricSymbolName(for: metric))
            .font(.body)
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.gradient)
            )
    }
}

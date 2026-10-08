import AnalyticsCore
import SwiftUI
import UniformTypeIdentifiers

/// Canned export payload for UI tests and previews: a valid empty ZIP
/// (end-of-central-directory only). Production bytes arrive with client
/// wiring; nothing here touches the network.
public enum MockExportProviders {
    public static var payload: Data {
        Data([
            0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
    }
}

/// FileDocument wrapper for the server ZIP. Read support exists only to
/// satisfy the protocol; the app never imports archives.
struct ZipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let data: Data
    let filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = configuration.file.filename ?? "export.zip"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}

/// Current-query export (EXPORT-01): downloads the server ZIP, then hands
/// it to the native share sheet (iOS) or save panel (macOS) through
/// `fileExporter`. Server caps (300 rows, 100 pages/exit) are stated, never
/// padded. Cancellation and failures surface inline, never as success.
public struct ExportButton: View {
    public typealias Exporter = @Sendable (DashboardQuery) async throws -> (filename: String, data: Data)

    private let query: DashboardQuery?
    private let export: Exporter?
    @State private var document: ZipDocument?
    @State private var showingExporter = false
    @State private var busy = false
    @State private var message: String?

    public init(query: DashboardQuery?, export: Exporter? = nil) {
        self.query = query
        self.export = export
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(busy ? "Preparing export…" : "Export reports (ZIP)") {
                Task { await run() }
            }
            .disabled(busy || query == nil || export == nil)
            .accessibilityIdentifier("export-run")
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("export-error")
            } else {
                Text("Server caps each report at 300 rows (100 for pages).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("export-caps")
            }
        }
        .accessibilityIdentifier("export-section")
        .fileExporter(
            isPresented: $showingExporter,
            document: document,
            contentType: .zip,
            defaultFilename: document?.filename ?? "export.zip"
        ) { _ in }
    }

    private func run() async {
        guard let query, let export else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let result = try await export(query)
            document = ZipDocument(data: result.data, filename: result.filename)
            showingExporter = true
        } catch is CancellationError {
            message = "Export was cancelled."
        } catch {
            message = "Couldn't prepare the export. Try again."
        }
    }
}

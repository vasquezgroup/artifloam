import SwiftUI
import AppKit
import MacStewardCore

struct TrashRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct TrashReviewSheet: View {
    let urls: [URL]
    var allowApplications = false
    var allowLeftovers = false
    var duplicateGroups: [DuplicateGroup] = []
    let completed: ([TrashOutcome]) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var m: StewardModel
    @State private var candidates = [TrashCandidate]()
    @State private var outcomes: [TrashOutcome]?
    @State private var outcomeByPath = [String: TrashOutcome]()
    @State private var checking = true
    @State private var error: String?
    @State private var busy = false
    private var cloudWarning: Bool { candidates.contains { $0.cloud != .local } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(outcomes == nil ? "Review before deleting" : "Results", systemImage: "trash").stewardFont(.title2, weight: .semibold)
            Text("Deletes them permanently. They can't be put back, so check the list first.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cloudWarning { Label("Deleting cloud-backed files can also remove them from the cloud and your other devices. This does not mean ‘remove local download’.", systemImage: "icloud").stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if candidates.contains(where: \.isDirectory) { Text("Selected folders include everything inside them, including files not shown in a partial map.").stewardFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if allowApplications { Text("Only the application bundle is deleted. Documents, subscriptions and support data are kept. Running apps must be quit by you first.").stewardFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if checking { StewardProgressBar(title: String(localized: "Checking \(urls.count) items…")).frame(maxWidth: 320) }
            ScrollView {
                // Lazy, and results by path: thousands of rows (all duplicate copies) stay responsive.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent.displaySafe).stewardFont(.body, weight: .medium)
                            Text(item.url.path.displaySafe).stewardFont(.caption, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
                            if let result = outcomeByPath[item.url.path] { Text(result.error ?? String(localized: "Deleted")).stewardFont(.caption).foregroundStyle(result.error == nil ? Color.mint : .orange) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            if let error { Text(error).stewardFont(.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(outcomes == nil ? "Cancel" : "Done") { dismiss() }.disabled(busy)
                Spacer()
                if outcomes == nil {
                    Button(busy ? String(localized: "Deleting…") : String(localized: "Delete \(candidates.count) permanently"), role: .destructive) { move() }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(busy || checking || candidates.isEmpty || error != nil)
                }
            }
        }.padding(26).frame(width: 550).interactiveDismissDisabled(busy)
        // The safety review reads every item from disk, so it runs off the main thread; the sheet opens at once.
        .task {
            let urls = urls, applications = allowApplications, leftovers = allowLeftovers
            let reviewed = await Task.detached(priority: .userInitiated) { Result { try ReviewedTrash.review(urls, allowApplications: applications, allowLeftovers: leftovers) } }.value
            switch reviewed {
            case .success(let items): candidates = items
            case .failure(let failure): error = failure.localizedDescription
            }
            checking = false
        }
    }
    private func move() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        if candidates.contains(where: { candidate in running.contains { $0.path == candidate.url.path || $0.path.hasPrefix(candidate.url.path + "/") } }) {
            error = String(localized: "A selected item contains a running app. Quit it yourself, then open a fresh review."); return
        }
        // The move itself runs on the removal stage over the page, with live progress, Stop and a result.
        m.startRemoval(candidates, allowApplications: allowApplications, allowLeftovers: allowLeftovers, duplicateGroups: duplicateGroups, completed: completed)
        dismiss()
    }
}

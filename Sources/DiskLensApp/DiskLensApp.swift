import AppKit
import DiskLensCore
import SwiftUI

struct DiskLensApp: App {
    @State private var model = AppModel()

    init() {
        // Lets the app come to the front when launched straight from the binary (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("DiskLens") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
                .task {
                    // Never scans on its own: first launch shows the welcome (recommending a full scan),
                    // later launches show saved results with a nudge when they're old.
                    await UISnapshots.capture(model)
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Now") { Task { await model.scan() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
                Button("Quick Clean…") { Task { await model.quickClean() } }
                    .keyboardShortcut("k")
                    .disabled(model.isBusy)
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                brand
                List(AppSection.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(badge(for: section))
                        .tag(section)
                        .help(sectionHelp(section))
                        .handCursor()
                }
                .listStyle(.sidebar)
                driveFooter
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            switch model.section {
            case .overview: OverviewView()
            case .cleanup: CleanupView()
            case .explore: ExploreView()
            case .history: HistoryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ScanControls() }
        }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.dismissPlan() } })) {
            CleanupSheet().environment(model).interactiveDismissDisabled(model.plan?.phase == .running)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }

    private func sectionHelp(_ section: AppSection) -> String {
        switch section {
        case .overview: "Drive usage, insights and categories"
        case .cleanup: "Everything that can be cleaned, with what depends on it. Safe total shown on the right."
        case .explore: "Browse and search folders by size"
        case .history: "Free space over time, before/after comparisons and the cleanup log"
        }
    }

    private func badge(for section: AppSection) -> Text? {
        guard section == .cleanup, !model.findings.isEmpty else { return nil }
        return Text(ByteFormat.string(model.reclaimable(.safe)))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("DiskLens").font(.headline)
                Text("Local · private · safe").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
    }

    @ViewBuilder private var driveFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = model.latest {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.volumeName).font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(ByteFormat.string(s.free)) free").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Theme.brand).frame(width: geo.size.width * s.usedFraction)
                        }
                    }
                    .frame(height: 6)
                }
                .help("\(ByteFormat.string(s.used)) used, \(ByteFormat.string(s.free)) free of \(ByteFormat.string(s.capacity))")
            }
            if !model.hasFullDiskAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Limited access", systemImage: "lock.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.review)
                    Text("Grant Full Disk Access to measure the Trash, iPhone backups and Mail.")
                        .font(.caption2).foregroundStyle(.secondary)
                        // Not fixedSize: measured at minimum width it became very tall and forced the
                        // whole window's layout taller than the window, so short windows couldn't scroll to the end.
                        .lineLimit(4)
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(SoftButtonStyle(tint: Theme.review))
                        .help("Opens System Settings → Privacy & Security → Full Disk Access. Turn on DiskLens there, then come back.")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.review.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

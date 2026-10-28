import DiskLensCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.needsFirstScan && !model.isScanning {
                    welcome
                } else if let snapshot = model.latest {
                    if model.fullScanIsOld { oldScanBanner }
                    hero(snapshot)
                    tiles(snapshot)
                    if !model.insights.isEmpty { insights }
                    if !snapshot.categories.isEmpty { categories(snapshot) }
                } else {
                    empty
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .navigationTitle("Overview")
    }

    // MARK: Hero

    private func hero(_ s: Snapshot) -> some View {
        HStack(alignment: .center, spacing: 32) {
            RingGauge(fraction: s.usedFraction, free: ByteFormat.string(s.free), total: ByteFormat.string(s.capacity))
                .help("\(ByteFormat.string(s.free)) free of \(ByteFormat.string(s.capacity)) (\(Int((s.usedFraction * 100).rounded()))% used)")
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.volumeName).font(.system(size: 30, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Chip(text: "\(ByteFormat.string(s.used)) used", symbol: "internaldrive", tint: Theme.brandStart,
                             help: "\(ByteFormat.string(s.used)) of \(ByteFormat.string(s.capacity)) in use, including macOS itself")
                        if let last = model.lastFullScan {
                            Chip(text: "Scanned \(last.date.friendly)", symbol: "clock", tint: .secondary,
                                 help: "When the last full scan finished")
                            if let d = last.duration { Chip(text: "took \(d.durationText)", symbol: "timer", tint: .secondary,
                                                            help: "How long the last full scan took") }
                        }
                        Chip(text: model.hasFullDiskAccess ? "Full Disk Access" : "Limited access",
                             symbol: model.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.fill",
                             tint: model.hasFullDiskAccess ? Theme.safe : Theme.review,
                             help: model.hasFullDiskAccess ? "DiskLens can measure every folder, including the Trash, Mail and iPhone backups."
                                                           : "macOS hides some folders (Trash, Mail, iPhone backups) until you grant Full Disk Access in System Settings → Privacy & Security.")
                    }
                }
                StorageBar(snapshot: s)
                StorageLegend(snapshot: s)
                HStack(spacing: 10) {
                    ScanControls(large: true, showStatus: false)
                    if model.isQuickScanning { ScanProgress(message: model.progress) }
                }
            }
        }
        .premiumCard(padding: 26)
    }

    private func tiles(_ s: Snapshot) -> some View {
        let first = model.snapshots.count > 1 ? model.snapshots.first : nil
        let sinceFirst = first.map { s.free - $0.free }
        let hasFindings = !model.findings.isEmpty
        return Grid(horizontalSpacing: 14) {
            GridRow {
                StatTile(title: "Safe to clean", value: hasFindings ? ByteFormat.string(model.reclaimable(.safe)) : "—",
                         note: hasFindings ? "\(model.findings(in: .safe).count) items that can't break anything" : "run a scan",
                         symbol: Tier.safe.symbol, tint: Theme.safe,
                         help: "Show the Safe items in Clean Up") { model.showCleanup(.safe) }
                StatTile(title: "Review first", value: hasFindings ? ByteFormat.string(model.reclaimable(.review)) : "—",
                         note: "your call: \(model.findings(in: .review).prefix(2).map(\.title).joined(separator: ", "))",
                         symbol: Tier.review.symbol, tint: Theme.review,
                         help: "Show the Review first items in Clean Up") { model.showCleanup(.review) }
                StatTile(title: "Quick Clean", value: hasFindings ? ByteFormat.string(model.quickCleanEstimate) : "—",
                         note: "caches, logs and leftovers. You confirm first", symbol: "bolt.fill", tint: Theme.brandEnd,
                         help: "Run a Quick Scan and review what Quick Clean would remove") { Task { await model.quickClean() } }
                StatTile(title: "Since first scan", value: sinceFirst.map { "\($0 >= 0 ? "+" : "−")\(ByteFormat.string(abs($0)))" } ?? "—",
                         note: first.map { "free space vs \($0.date.friendly)" } ?? "shows after your next scan", symbol: "chart.line.uptrend.xyaxis",
                         tint: (sinceFirst ?? 0) >= 0 ? Theme.safe : Theme.review,
                         help: "See free space over time in History") { model.section = .history }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Insights

    private var insights: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Insights", subtitle: "Worked out on this Mac from your scans. Nothing leaves your computer.", symbol: "lightbulb.max.fill")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(model.insights) { insight in
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: insight.symbol, color: insight.tint, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(insight.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text(insight.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let label = insight.actionLabel {
                                Button("\(label) →") { model.perform(insight) }.buttonStyle(.textLink).font(.callout.weight(.medium)).padding(.top, 2)
                                    .help(insightHelp(insight))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .premiumCard(padding: 16)
                }
            }
        }
    }

    // MARK: Categories

    private func categories(_ s: Snapshot) -> some View {
        let prev = model.previous.flatMap { $0.categories.isEmpty ? nil : $0 }
        let largest = max(1, (s.categories.map(\.bytes) + (prev?.categories.map(\.bytes) ?? [])).max() ?? 1)
        return Card {
            SectionHeader(title: "Where the space goes",
                          subtitle: prev.map { "Grey bar = scan from \($0.date.friendly)" } ?? "Click Explore to drill into any category.",
                          symbol: "chart.bar.fill")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                ForEach(s.categories) { c in
                    let style = CategoryStyle.of(c.name)
                    let before = prev?.category(named: c.name)?.bytes
                    GridRow {
                        HStack(spacing: 10) {
                            IconTile(symbol: style.symbol, color: style.color, size: 28)
                            Text(c.name).font(.callout.weight(.medium))
                        }
                        .frame(width: 210, alignment: .leading)
                        GeometryReader { geo in
                            VStack(alignment: .leading, spacing: 3) {
                                if let before {
                                    Capsule().fill(Palette.previous).frame(width: max(3, geo.size.width * CGFloat(before) / CGFloat(largest)), height: 6)
                                }
                                Capsule().fill(style.color.gradient)
                                    .frame(width: max(3, geo.size.width * CGFloat(c.bytes) / CGFloat(largest)), height: before == nil ? 12 : 8)
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .frame(height: 22)
                        .help("\(c.name): \(ByteFormat.string(c.bytes))\(before.map { " (was \(ByteFormat.string($0)))" } ?? "")")
                        Text(ByteFormat.string(c.bytes)).monospacedDigit().font(.callout.weight(.semibold)).frame(width: 74, alignment: .trailing)
                        Group { if let before { DeltaText(bytes: c.bytes - before) } else { Text("") } }
                            .font(.caption).frame(width: 78, alignment: .trailing)
                        Button("Explore") { model.explore(c) }
                            .buttonStyle(.textLink).font(.callout)
                            .disabled(c.paths.isEmpty || c.name == "Other")
                            .help("Browse the folders in \(c.name) by size")
                    }
                }
            }
        }
    }

    private func insightHelp(_ insight: Insight) -> String {
        switch insight.action {
        case .finding: "Open this item in Clean Up with its details"
        case .section(.history): "Open History"
        case .fullDiskAccess: "Open System Settings → Privacy & Security → Full Disk Access"
        default: ""
        }
    }

    private var oldScanBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark").font(.title2).foregroundStyle(Theme.review)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your last full scan was \(model.lastFullScan.map { $0.date.formatted(.relative(presentation: .named)) } ?? "a while ago")").font(.headline)
                Text("Things change: new projects, app updates, downloads. Run a full scan to see everything as it is now.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.scan() } } label: { Label("Scan Now", systemImage: "magnifyingglass") }
                .buttonStyle(GradientButtonStyle()).help("Run a full scan from scratch")
        }
        .premiumCard(padding: 16)
    }

    /// First launch: recommend a full scan, like an antivirus' first run.
    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104)
            VStack(spacing: 8) {
                Text("Welcome to DiskLens").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Start with a full scan. DiskLens measures \(model.volumeName) from scratch and learns what's on this Mac. After that, Quick Scan can check caches and leftovers in seconds.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
            }
            HStack(alignment: .top, spacing: 14) {
                welcomePoint("magnifyingglass", "Full scan", "Measures every folder and checks apps, projects, simulators, Docker, caches and large files. 1–3 minutes.")
                welcomePoint("lock.shield.fill", "Read-only", "Scanning never changes anything. Nothing leaves your Mac, and there's no AI or network.")
                welcomePoint("checkmark.seal.fill", "You decide", "Cleaning always shows a review first, and files go to the Trash so you can put them back.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 820)
            VStack(spacing: 10) {
                Button { Task { await model.scan() } } label: { Label("Start Full Scan (recommended)", systemImage: "magnifyingglass") }
                    .buttonStyle(GradientButtonStyle(large: true))
                    .help("Measure the whole drive from scratch. Read-only.")
                Button("Just do a Quick Clean") { Task { await model.quickClean() } }
                    .buttonStyle(.textLink)
                    .help("Skip the full scan and only look at caches, logs and leftovers")
                if !model.hasFullDiskAccess {
                    Button("Optional: grant Full Disk Access first, so the scan can see Mail, the Trash and iPhone backups") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.textLink).font(.caption)
                        .help("Opens System Settings → Privacy & Security → Full Disk Access. Add DiskLens there.")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .premiumCard(padding: 36)
    }

    private func welcomePoint(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconTile(symbol: symbol, color: Theme.brandStart, size: 34)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .help(text)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("See what's filling your Mac").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("DiskLens measures your drive, explains what each item is for and what depends on it, and moves things to the Trash only after you confirm.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            ScanControls(large: true)
        }
        .frame(maxWidth: .infinity, minHeight: 460)
    }
}

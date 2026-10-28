import DiskLensCore
import SwiftUI

enum Palette {
    static let measured = Theme.brandStart
    static let hidden = Color(light: 0xC9C7BF, dark: 0x4A4A46)
    static let system = Color(light: 0x8F8D86, dark: 0x6B6A65)
    static let trash = Color(light: 0xEB6834, dark: 0xD95926)
    static let free = Color(light: 0x0CA30C, dark: 0x2DBE4B)
    static let previous = Color.secondary.opacity(0.35)
}

extension Tier {
    var color: Color {
        switch self {
        case .safe: Theme.safe
        case .review: Theme.review
        case .keep: Theme.keep
        }
    }
}

extension Text {
    /// Renders inline markdown such as `code` from rule text.
    init(markdown: String) {
        if let attributed = try? AttributedString(markdown: markdown) { self.init(attributed) } else { self.init(verbatim: markdown) }
    }
}

extension Tier {
    var explanation: String {
        switch self {
        case .safe: "Safe: removing this can't break any app. It's re-created automatically or never used again."
        case .review: "Review first: usually fine to remove, but it depends on how you work. Check the details."
        case .keep: "Leave alone: managed by an app or holds your data. Listed so you know why it's big."
        }
    }
}

struct TierBadge: View {
    let tier: Tier

    var body: some View {
        Chip(text: tier.label, symbol: tier.symbol, tint: tier.color, help: tier.explanation)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }.premiumCard()
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.brand) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var note: String? = nil
    var symbol: String = "circle"
    var tint: Color = Theme.brandStart
    var noteColor: Color = .secondary
    var help: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { tile(showsChevron: true) }
                .buttonStyle(PressableCardStyle())
                .help(help ?? "")
        } else {
            tile(showsChevron: false).help(help ?? "")
        }
    }

    private func tile(showsChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, color: tint, size: 26)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            Text(note ?? " ").font(.caption).foregroundStyle(noteColor).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .premiumCard(padding: 16)
    }
}

/// A whole card that acts as a button: lifts slightly on hover, hand cursor.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLift(pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverLift<Content: View>: View {
        let pressed: Bool
        @ViewBuilder var content: Content
        @State private var hovering = false

        var body: some View {
            content
                .scaleEffect(pressed ? 0.985 : hovering ? 1.01 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
                .handCursor()
        }
    }
}

/// The drive as one bar: each category in its own color, then hidden, system and free space.
struct StorageBar: View {
    let snapshot: Snapshot
    var height: CGFloat = 22

    struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let color: Color
    }

    var segments: [Segment] {
        var list = snapshot.categories.filter { $0.bytes > 0 }.map {
            Segment(id: $0.name, bytes: $0.bytes, color: CategoryStyle.of($0.name).color)
        }
        if list.isEmpty {
            list = [Segment(id: "Your files & apps", bytes: max(0, snapshot.measured - (snapshot.trash ?? 0)), color: Palette.measured)]
        }
        list += [
            Segment(id: "Hidden (needs Full Disk Access)", bytes: snapshot.hidden, color: Palette.hidden),
            Segment(id: "macOS system", bytes: snapshot.system, color: Palette.system),
            Segment(id: "Free", bytes: snapshot.free, color: Palette.free),
        ].filter { $0.bytes > 0 }
        return list
    }

    var body: some View {
        GeometryReader { geo in
            let parts = segments
            let total = max(1, parts.reduce(0) { $0 + $1.bytes })
            let width = geo.size.width - CGFloat(parts.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(parts) { s in
                    Rectangle().fill(s.color)
                        .frame(width: max(2, width * CGFloat(s.bytes) / CGFloat(total)))
                        .help("\(s.id): \(ByteFormat.string(s.bytes))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .frame(height: height)
    }
}

struct StorageLegend: View {
    let snapshot: Snapshot

    var body: some View {
        let parts = StorageBar(snapshot: snapshot).segments
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(parts) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 10, height: 10)
                    Text(s.id).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(ByteFormat.string(s.bytes)).monospacedDigit().layoutPriority(1)
                }
                .font(.caption)
                .help("\(s.id): \(ByteFormat.string(s.bytes))")
            }
        }
    }
}

/// Dependencies and context of a finding, as label/value pairs.
struct FactGrid: View {
    let facts: [Fact]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(facts, id: \.self) { fact in
                GridRow(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Circle().fill(color(fact.kind)).frame(width: 6, height: 6)
                        Text(fact.label).foregroundStyle(.secondary)
                    }
                    .gridColumnAlignment(.leading)
                    Text(markdown: fact.value).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func color(_ kind: Fact.Kind) -> Color {
        switch kind {
        case .good: Theme.safe
        case .warning: Theme.review
        case .info: .secondary.opacity(0.6)
        }
    }
}

struct DeltaText: View {
    let bytes: Int64
    /// For free space, growth is good; for usage, shrinking is good.
    var growthIsGood = false

    var body: some View {
        if abs(bytes) < 50_000_000 {
            Text("no change").foregroundStyle(.secondary)
        } else {
            let good = growthIsGood ? bytes > 0 : bytes < 0
            Text("\(bytes > 0 ? "▲" : "▼") \(ByteFormat.string(abs(bytes)))")
                .foregroundStyle(good ? Theme.safe : Color.secondary)
                .fontWeight(.semibold)
        }
    }
}

struct ScanProgress: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message.isEmpty ? "Scanning…" : message + "…").foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct PathActions: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        if path.hasPrefix("/") {
            Button { model.reveal(path) } label: { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle()).help("Show \((path as NSString).lastPathComponent) in Finder")
            Button { model.copyPath(path) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle()).help("Copy the full path")
        }
    }
}

/// Last-scan status plus the two scan buttons, shown in the toolbar on every page.
struct ScanControls: View {
    @Environment(AppModel.self) private var model
    var large = false
    var showStatus = true

    var body: some View {
        HStack(spacing: 10) {
            if model.isScanning {
                ScanProgress(message: model.progress).frame(maxWidth: 260, alignment: .trailing).padding(.leading, 8)
            } else if showStatus, let last = model.lastFullScan {
                VStack(alignment: .leading, spacing: 1) {
                    (Text("Last scan: ").foregroundStyle(.secondary) + Text(last.date.friendly).fontWeight(.medium))
                    if let d = last.duration {
                        (Text("Scan duration: ").foregroundStyle(.secondary) + Text(d.durationText).fontWeight(.medium))
                    }
                }
                .font(.caption).monospacedDigit()
                .padding(.leading, 8)
                .help("Your last full scan. Results are saved, so DiskLens opens instantly. Scan again any time to refresh them.")
            }
            Button { Task { await model.quickClean() } } label: {
                Label("Quick Clean", systemImage: "bolt.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(SoftButtonStyle(tint: Theme.brandEnd, large: large))
            .disabled(model.isBusy)
            .help(model.lastFullScan == nil
                  ? "Quick Scan for caches, logs and leftovers no app depends on. Tip: run a full scan first so DiskLens learns where to look. You confirm before anything is cleaned."
                  : "Quick Scan (about 15 s) for caches, logs and leftovers no app depends on, in the places your last full scan found. You confirm before anything is cleaned.")

            Button { Task { await model.scan() } } label: {
                Label(model.isScanning ? "Scanning…" : "Scan Now", systemImage: "magnifyingglass").labelStyle(.titleAndIcon)
            }
            .buttonStyle(GradientButtonStyle(large: large))
            .disabled(model.isBusy)
            .keyboardShortcut("r")
            .help("Full scan: measures the whole drive from scratch and checks everything (1–3 minutes, read-only). ⌘R")
        }
        // In the toolbar, keep the buttons clear of the rounded container edge on both sides.
        .padding(.trailing, large ? 0 : 6)
        .padding(.vertical, large ? 0 : 3)
    }
}

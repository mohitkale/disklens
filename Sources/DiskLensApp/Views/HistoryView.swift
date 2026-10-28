import Charts
import DiskLensCore
import SwiftUI

/// Free space over time, a before/after comparison of any two scans, and the cleanup log.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var fromID: Date?
    @State private var toID: Date?
    // Demo screenshots show the tooltip on the first (left-edge) point.
    @State private var hoverDate: Date? = DemoData.isEnabled ? DemoData.snapshots.first?.date : nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.snapshots.isEmpty {
                    ContentUnavailableView("No scans yet", systemImage: "clock", description: Text("Each scan is saved here so you can compare before and after."))
                        .frame(minHeight: 360)
                } else {
                    trend
                    timeline
                    if model.snapshots.count >= 2 { comparison }
                    logList
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .navigationTitle("History")
    }

    private func label(_ s: Snapshot) -> String {
        s.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var hovered: Snapshot? {
        guard let hoverDate else { return nil }
        return model.snapshots.min { abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate)) }
    }

    /// Free and used space as lines over time; hover to read any scan.
    private var trend: some View {
        let snaps = model.snapshots
        return Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Trend", subtitle: "Free and used space over time. Hover the chart to read any scan.", symbol: "chart.xyaxis.line")
                Spacer()
                if let first = snaps.first, let last = snaps.last, first.id != last.id {
                    let delta = last.free - first.free
                    Chip(text: "\(delta >= 0 ? "+" : "−")\(ByteFormat.string(abs(delta))) free since \(first.date.friendly)",
                         symbol: delta >= 0 ? "arrow.up.right" : "arrow.down.right", tint: delta >= 0 ? Theme.safe : Theme.review,
                         help: "Change in free space between your first and latest scan")
                }
            }
            Chart {
                ForEach(snaps) { s in
                    AreaMark(x: .value("Date", s.date), y: .value("GB", ByteFormat.gb(s.free)), series: .value("Series", "Free area"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.safe.opacity(0.28), Theme.safe.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", s.date), y: .value("GB", ByteFormat.gb(s.free)), series: .value("Series", "Free"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(by: .value("Series", "Free"))
                    LineMark(x: .value("Date", s.date), y: .value("GB", ByteFormat.gb(s.used)), series: .value("Series", "Used"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(by: .value("Series", "Used"))
                    PointMark(x: .value("Date", s.date), y: .value("GB", ByteFormat.gb(s.free)))
                        .symbolSize(hovered?.id == s.id ? 110 : 45)
                        .foregroundStyle(Theme.safe)
                    PointMark(x: .value("Date", s.date), y: .value("GB", ByteFormat.gb(s.used)))
                        .symbolSize(hovered?.id == s.id ? 110 : 45)
                        .foregroundStyle(Theme.brandStart)
                }
                if let h = hovered {
                    RuleMark(x: .value("Date", h.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    // Anchored halfway between the two lines and kept inside the plot,
                    // so it never covers the legend, title or the lines' points.
                    PointMark(x: .value("Date", h.date), y: .value("GB", (ByteFormat.gb(h.free) + ByteFormat.gb(h.used)) / 2))
                        .symbolSize(0)
                        .annotation(position: .overlay, alignment: .center, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.date.friendly).font(.caption.weight(.semibold))
                                if let label = h.label { Text(label).font(.caption2).foregroundStyle(.secondary) }
                                HStack(spacing: 10) {
                                    Label(ByteFormat.string(h.free) + " free", systemImage: "circle.fill").foregroundStyle(Theme.safe)
                                    Label(ByteFormat.string(h.used) + " used", systemImage: "circle.fill").foregroundStyle(Theme.brandStart)
                                }
                                .font(.caption2).labelStyle(.titleAndIcon)
                            }
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                            .fixedSize()
                        }
                }
            }
            .chartForegroundStyleScale(["Free": Theme.safe, "Used": Theme.brandStart])
            .chartYScale(domain: 0...max(1, ByteFormat.gb(snaps.first?.capacity ?? 500_000_000_000)))
            .chartYAxisLabel("GB")
            .chartXSelection(value: $hoverDate)
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 260)
        }
    }

    private var timeline: some View {
        Card {
            SectionHeader(title: "Free space over time", subtitle: "One bar per saved scan.", symbol: "chart.bar.xaxis")
            Chart(model.snapshots) { s in
                BarMark(x: .value("Scan", label(s)), y: .value("Free (GB)", ByteFormat.gb(s.free)), width: .fixed(56))
                    .foregroundStyle(Theme.brand)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        Text(ByteFormat.string(s.free)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            .chartXScale(domain: model.snapshots.map(label))
            .chartYAxisLabel("GB free")
            .frame(height: 220)
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.snapshots) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(s)).font(.caption.weight(.semibold))
                        Text(s.label ?? "Scan").font(.caption2).foregroundStyle(.secondary)
                    }
                    .contextMenu { Button("Delete This Scan", role: .destructive) { model.deleteSnapshot(s) } }
                }
            }
        }
    }

    private var comparison: some View {
        let snaps = model.snapshots
        let from = snaps.first { $0.id == fromID } ?? snaps[0]
        let to = snaps.first { $0.id == toID } ?? snaps[snaps.count - 1]
        let comparable = !from.categories.isEmpty && !to.categories.isEmpty
        let names = !comparable ? [] : Array(Set(from.categories.map(\.name) + to.categories.map(\.name)))
            .sorted { (to.category(named: $0)?.bytes ?? 0) > (to.category(named: $1)?.bytes ?? 0) }
        let rows: [(String, Int64, Int64, Bool)] = [
            ("Free space", from.free, to.free, true),
            ("Used", from.used, to.used, false),
            ("Hidden (needs Full Disk Access)", from.hidden, to.hidden, false),
            ("macOS system", from.system, to.system, false),
        ] + names.map { ($0, from.category(named: $0)?.bytes ?? 0, to.category(named: $0)?.bytes ?? 0, false) }

        return Card {
            SectionHeader(title: "Before and after", subtitle: "Compare any two scans.", symbol: "arrow.left.arrow.right")
            HStack {
                Picker("Before", selection: Binding(get: { from.id }, set: { fromID = $0 })) {
                    ForEach(snaps) { Text("\(label($0))\($0.label.map { " · \($0)" } ?? "")").tag($0.id) }
                }
                Picker("After", selection: Binding(get: { to.id }, set: { toID = $0 })) {
                    ForEach(snaps) { Text("\(label($0))\($0.label.map { " · \($0)" } ?? "")").tag($0.id) }
                }
            }
            .frame(maxWidth: 640)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Before").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("After").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("Change").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                Divider()
                ForEach(rows, id: \.0) { name, before, after, growthIsGood in
                    GridRow {
                        Text(name).fontWeight(growthIsGood ? .semibold : .regular)
                        Text(ByteFormat.string(before)).monospacedDigit()
                        Text(ByteFormat.string(after)).monospacedDigit()
                        DeltaText(bytes: after - before, growthIsGood: growthIsGood)
                    }
                    .font(.callout)
                }
            }
            if !comparable {
                Text("One of these scans only has drive totals, so categories aren't compared. Pick two DiskLens scans to compare categories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var logList: some View {
        Card {
            SectionHeader(title: "Cleanup log", subtitle: model.log.isEmpty ? "Nothing cleaned with DiskLens yet." : "Everything DiskLens has cleaned, newest first.", symbol: "list.bullet.rectangle")
            ForEach(model.log) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: entry.outcome == .failed ? "xmark.octagon.fill" : entry.outcome == .trashed ? "trash.fill" : "checkmark.circle.fill")
                        .foregroundStyle(entry.outcome == .failed ? .red : entry.outcome == .trashed ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormat.string(entry.bytes)).monospacedDigit()
                        Text(entry.outcome == .trashed ? "in Trash" : entry.outcome == .freed ? "freed" : "failed").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }
}

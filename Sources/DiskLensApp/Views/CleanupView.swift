import DiskLensCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.findings.isEmpty {
                        emptyState
                    } else {
                        summary
                        controls
                        let shown = model.findings(in: model.cleanupFilter)
                        if shown.isEmpty {
                            Text("Nothing in this group.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                        }
                        ForEach(shown) { finding in
                            FindingCard(finding: finding).id(finding.id)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.focusedFindingID, initial: true) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .background(PageBackground())
        .safeAreaInset(edge: .bottom) { if !model.findings.isEmpty { selectionBar } }
        .navigationTitle("Clean Up")
    }

    private var summary: some View {
        let totals = Tier.allCases.map { ($0, model.findings(in: $0).reduce(0) { $0 + model.bytes($1) }) }
        let sum = max(1, totals.reduce(0) { $0 + $1.1 })
        return Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "What can be cleaned",
                              subtitle: "Click a group to see only those items.",
                              symbol: "sparkles")
                Spacer()
                if let date = model.findingsDate {
                    Chip(text: "Results from \(date.friendly)", symbol: "clock", tint: model.findingsAreStale ? Theme.review : .secondary,
                         help: "These results come from your last full scan. Scan Now to refresh them.")
                }
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(totals.filter { $0.1 > 0 }, id: \.0) { tier, bytes in
                        Button { model.cleanupFilter = model.cleanupFilter == tier ? nil : tier } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tier.color.opacity(tier == .keep ? 0.35 : 0.9).gradient)
                                .overlay(Text("\(tier.label) · \(ByteFormat.string(bytes))").font(.caption.weight(.bold))
                                    .foregroundStyle(tier == .keep ? Color.primary : .white).lineLimit(1).padding(.horizontal, 4))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(model.cleanupFilter == tier ? 0.5 : 0), lineWidth: 2))
                        }
                        .buttonStyle(PressableCardStyle())
                        .frame(width: max(110, (geo.size.width - 6) * CGFloat(bytes) / CGFloat(sum)))
                        .help("\(tier.explanation)\n\nClick to show only these.")
                    }
                }
            }
            .frame(height: 34)
            if model.findingsAreStale {
                Label("These results are more than a day old. Scan again before cleaning so the sizes are current.", systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(Theme.review)
            }
        }
    }

    private var controls: some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            Picker("Show", selection: $model.cleanupFilter) {
                Text("All · \(model.findings.count)").tag(Tier?.none)
                ForEach(Tier.allCases, id: \.self) { tier in
                    Text("\(tier.label) · \(model.findings(in: tier).count)").tag(Tier?.some(tier))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
            .help("Show all findings, or only one group")
            .handCursor()
            Spacer()
            selectAll
        }
    }

    private var selectAll: some View {
        let state = model.filterSelection
        let count = model.selectableInFilter.count
        let groupName = model.cleanupFilter.map { "\($0.label)" } ?? "all"
        return Button { model.toggleSelectAllInFilter() } label: {
            HStack(spacing: 7) {
                Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
                    .font(.system(size: 16)).foregroundStyle(state == .none ? Color.secondary : Theme.brandStart)
                Text(count == 0 ? "Nothing to select here" : "Select all \(groupName == "all" ? "" : groupName + " ")(\(count))")
                    .font(.callout.weight(.medium))
            }
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(count == 0)
        .help(model.cleanupFilter == .keep ? "Leave-alone items can't be cleaned." : "Select or clear every cleanable item shown below. Nothing is cleaned until you review and confirm.")
    }

    private var selectionBar: some View {
        let selected = model.selectedFindings
        let permanent = selected.filter { !$0.isReversible }.count
        return HStack(spacing: 14) {
            IconTile(symbol: "checklist", color: selected.isEmpty ? .secondary : Theme.brandStart, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                if selected.isEmpty {
                    Text("Nothing selected").font(.headline)
                    Text("Tick the items you want to clean, or use Select all.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(selected.count) selected · \(ByteFormat.string(model.selectedBytes))").font(.headline).monospacedDigit()
                    Text([selected.count - permanent > 0 ? "\(selected.count - permanent) move to the Trash" : nil,
                          permanent > 0 ? "\(permanent) can't be undone" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(permanent > 0 ? Theme.review : .secondary)
                }
            }
            Spacer()
            Button("Clear Selection") { model.selectTiers(nil) }
                .buttonStyle(SoftButtonStyle(tint: .secondary))
                .disabled(selected.isEmpty)
                .help("Untick everything")
            Button { model.reviewSelected() } label: { Label("Review Selected…", systemImage: "list.bullet.clipboard") }
                .buttonStyle(GradientButtonStyle(large: true))
                .disabled(selected.isEmpty)
                .help("Opens a review of exactly what will happen. Nothing is cleaned until you press Clean there.")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            IconTile(symbol: "sparkles", color: Theme.brandStart, size: 64)
            Text("Scan to find things to clean").font(.title2.weight(.semibold))
            Text("Or use Quick Clean for caches, logs and leftovers that are always safe to remove.").foregroundStyle(.secondary)
            ScanControls(large: true, showStatus: false)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

struct FindingCard: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    @State private var showItems = false
    @State private var showDetails = false

    private var result: ExecutionResult? { model.completed[finding.id] }
    private var isChecked: Bool { model.selectedFindingIDs.contains(finding.id) }
    private var focused: Bool { model.focusedFindingID == finding.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(markdown: finding.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !finding.facts.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    FactGrid(facts: finding.facts).padding(.top, 6)
                } label: {
                    Label("What depends on this, and how to get it back", systemImage: "info.circle").font(.callout.weight(.medium))
                        .handCursor()
                }
            }
            if let kept = finding.kept {
                Label { Text("Keeps ").fontWeight(.semibold) + Text(kept) } icon: { Image(systemName: "lock.shield.fill").foregroundStyle(Theme.safe) }
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let note = finding.afterNote {
                Label { Text(markdown: note) } icon: { Image(systemName: "lightbulb") }.font(.callout).foregroundStyle(.secondary)
            }
            if let cmd = finding.action.commandLine {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if !finding.items.isEmpty { items }
            if let result { ResultBanner(result: result) } else { footer }
        }
        .premiumCard()
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(isChecked ? Theme.brandStart : focused ? Theme.brandEnd : .clear, lineWidth: 2))
        .opacity(result != nil ? 0.7 : 1)
        .onAppear { if focused { showDetails = true; showItems = true } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.isSelectable(finding) || isChecked {
                Toggle("", isOn: Binding(get: { isChecked }, set: { _ in model.toggleFinding(finding) }))
                    .labelsHidden().toggleStyle(.checkbox).controlSize(.large)
                    .handCursor()
                    .help("Include in the cleanup you'll review")
            }
            IconTile(symbol: finding.symbol, color: finding.tier.color, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(finding.title).font(.headline)
                HStack(spacing: 6) {
                    TierBadge(tier: finding.tier)
                    switch finding.action {
                    case .trash: Chip(text: "Undo from Trash", symbol: "arrow.uturn.backward", tint: Theme.safe,
                                      help: "Items are moved to the Trash. You can put them back until you empty the Trash.")
                    case .command: Chip(text: "Can't be undone", symbol: "exclamationmark.triangle", tint: Theme.review,
                                        help: "Removed by the owning tool, not via the Trash. See How to get it back in the details.")
                    default: EmptyView()
                    }
                    if finding.quickClean { Chip(text: "Quick Clean", symbol: "bolt.fill", tint: Theme.brandEnd,
                                                 help: "Included in Quick Clean: nothing depends on it.") }
                    if let used = finding.facts.first(where: { $0.label == "Last used" || $0.label == "Last opened" }) {
                        Chip(text: "\(used.label.lowercased()) \(used.value)", symbol: "clock", tint: .secondary,
                             help: "From Spotlight and file dates on this Mac")
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let none = finding.action == .trash && !finding.items.isEmpty && model.selectedItems(finding).isEmpty
                Text(ByteFormat.string(none ? finding.bytes : finding.action == .trash && !finding.items.isEmpty ? model.bytes(finding) : finding.bytes))
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(none ? .secondary : .primary)
                if finding.action == .trash, !finding.items.isEmpty {
                    Text(none ? "nothing preselected" : "\(model.selectedItems(finding).count) of \(finding.items.count) selected")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var items: some View {
        DisclosureGroup(isExpanded: $showItems) {
            VStack(alignment: .leading, spacing: 0) {
                if finding.action == .trash {
                    HStack {
                        Button("Select all") { model.setAll(true, in: finding) }.help("Tick every item in this list")
                        Button("Select none") { model.setAll(false, in: finding) }.help("Untick every item in this list")
                        Spacer()
                    }
                    .buttonStyle(.textLink).font(.caption).padding(.bottom, 6)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                    GridRow {
                        Text("")
                        Text("Item")
                        Text("Used by")
                        Text("Last used")
                        Text("Size").gridColumnAlignment(.trailing)
                        Text("")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    ForEach(finding.items) { item in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow(alignment: .center) {
                            if finding.action == .trash {
                                Toggle("", isOn: Binding(get: { model.isSelected(item, in: finding) },
                                                         set: { model.setSelected($0, item: item, in: finding) }))
                                    .labelsHidden().toggleStyle(.checkbox).disabled(result != nil)
                                    .handCursor()
                            } else {
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                            .help(item.path)
                            Text(item.usedBy ?? "—").font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                            Text(item.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Text(item.bytes > 0 ? ByteFormat.string(item.bytes) : "—").monospacedDigit().font(.callout.weight(.medium))
                            HStack(spacing: 6) { PathActions(path: item.path) }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("\(finding.items.count) item\(finding.items.count == 1 ? "" : "s")", systemImage: "list.bullet").font(.callout.weight(.medium))
                .handCursor()
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let path = finding.revealPath {
                Button { model.reveal(path) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(SoftButtonStyle(tint: .secondary))
                    .help("Open \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) in Finder")
            }
            Spacer()
            switch finding.action {
            case .trash, .command:
                Button { model.review([finding]) } label: {
                    Label("Review…", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(SoftButtonStyle(tint: finding.tier.color))
                .help("Review just this item before cleaning it")
                .disabled(finding.action == .trash && model.selectedItems(finding).isEmpty)
            case let .launchApp(bundleID):
                Button("Start Docker Desktop") { model.launch(bundleID: bundleID) }.buttonStyle(SoftButtonStyle())
                    .help("Open Docker Desktop, then scan again to see what's inside its disk image")
            case .open:
                Button("Open Trash") { model.openTrash() }.buttonStyle(SoftButtonStyle())
                    .help("Open the Trash in Finder. Empty it there when you're ready.")
            case .advice:
                EmptyView()
            }
        }
    }
}

struct ResultBanner: View {
    let result: ExecutionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch result.outcome {
            case .trashed:
                Label("Moved \(result.trashed.count) item(s), \(ByteFormat.string(result.bytes)), to the Trash. Empty the Trash to free the space.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.safe)
            case .freed:
                Label(result.bytes > 50_000_000 ? "Done. \(ByteFormat.string(result.bytes)) freed so far." : "Done. Free space updates over the next minute or two.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.safe)
            case .failed:
                Label("That didn't work.", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
            }
            ForEach(result.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.danger) }
            if !result.output.isEmpty, result.outcome == .failed {
                Text(result.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

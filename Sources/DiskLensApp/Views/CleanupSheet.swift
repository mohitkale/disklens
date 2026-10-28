import DiskLensCore
import SwiftUI

/// Review → confirm → run → summary, for a batch cleanup or Quick Clean.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let plan = model.plan {
            VStack(spacing: 0) {
                header(plan)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch plan.phase {
                        case .scanning:
                            scanning
                        case .review, .running:
                            if plan.entries.isEmpty {
                                nothingToDo
                            } else {
                                ForEach(plan.entries) { PlanRow(entry: $0, phase: plan.phase) }
                            }
                            ForEach(plan.advice) { a in
                                Label { Text("\(a.title): \(ByteFormat.string(a.bytes)). ").fontWeight(.medium) + Text(markdown: a.detail) }
                                    icon: { Image(systemName: a.symbol).foregroundStyle(Theme.brandStart) }
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.brandStart.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            }
                        case .finished:
                            summary(plan)
                        }
                    }
                    .padding(20)
                }
                Divider()
                footer(plan)
            }
            .frame(width: 760, height: 620)
            .background(PageBackground())
        }
    }

    private func header(_ plan: CleanupPlan) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: plan.kind == .quick ? "bolt.fill" : "checklist", color: plan.kind == .quick ? Theme.brandEnd : Theme.brandStart, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(plan)).font(.title2.weight(.bold))
                Text(subtitle(plan)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if plan.phase == .review || plan.phase == .running {
                VStack(alignment: .trailing, spacing: 0) {
                    let pending = plan.entries.filter(\.included).reduce(0) { $0 + $1.bytes }
                    Text(ByteFormat.string(plan.stillChecking ? pending : plan.includedBytes))
                        .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(plan.stillChecking ? "checking…" : "ready to clean").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    private func title(_ plan: CleanupPlan) -> String {
        switch plan.phase {
        case .scanning: "Quick Scan"
        case .review: plan.kind == .quick ? "Quick Clean: review" : "Review before cleaning"
        case .running: "Cleaning…"
        case .finished: "Done"
        }
    }

    private func subtitle(_ plan: CleanupPlan) -> String {
        switch plan.phase {
        case .scanning:
            return "Looking for caches, logs and leftovers that no app depends on."
        case .review:
            if plan.stillChecking { return "Checking that every item is safe to remove right now…" }
            var parts: [String] = []
            if plan.trashCount > 0 { parts.append("\(plan.trashCount) move to the Trash (you can put them back)") }
            if plan.permanentCount > 0 { parts.append("\(plan.permanentCount) run a tool and can't be undone") }
            return parts.isEmpty ? "Nothing is ready to clean." : parts.joined(separator: " · ")
        case .running:
            return "Working through each item. Nothing else is touched."
        case .finished:
            return "Here's what changed."
        }
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(model.progress.isEmpty ? "Scanning…" : model.progress + "…").foregroundStyle(.secondary)
            Text("Usually under 30 seconds. Nothing is cleaned until you confirm.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var nothingToDo: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Theme.safe)
            Text("Nothing to clean right now").font(.title3.weight(.semibold))
            Text("Caches, logs and leftovers are already small.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func summary(_ plan: CleanupPlan) -> some View {
        let results = plan.results
        let trashed = results.filter { $0.1.outcome == .trashed }.reduce(0) { $0 + $1.1.bytes }
        let freed = results.filter { $0.1.outcome == .freed }.reduce(0) { $0 + $1.1.bytes }
        let failed = results.filter { $0.1.outcome == .failed }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StatTile(title: "Moved to Trash", value: ByteFormat.string(trashed), note: "freed when you empty the Trash", symbol: "trash.fill", tint: Palette.trash)
                StatTile(title: "Freed now", value: ByteFormat.string(freed), note: "by Xcode, Docker or Homebrew", symbol: "checkmark.circle.fill", tint: Theme.safe)
                StatTile(title: "Free space now", value: ByteFormat.string(DiskMeasure.freeBytes()), note: "on Macintosh HD", symbol: "internaldrive.fill", tint: Theme.brandStart)
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(results.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: pair.0.symbol, color: pair.0.tier.color, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0.title).font(.callout.weight(.semibold))
                        ResultBanner(result: pair.1)
                    }
                }
            }
            if !failed.isEmpty {
                Label("\(failed.count) item(s) didn't finish. Nothing else was affected.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.review)
            }
        }
    }

    private func footer(_ plan: CleanupPlan) -> some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            switch plan.phase {
            case .scanning:
                Spacer()
                Button("Cancel") { model.dismissPlan() }.keyboardShortcut(.cancelAction)
            case .review:
                if plan.needsAcknowledgement {
                    Toggle(isOn: Binding(get: { model.plan?.acknowledged ?? false }, set: { model.plan?.acknowledged = $0 })) {
                        Text(plan.permanentCount > 0
                             ? "I understand \(plan.permanentCount) action(s) can't be undone from the Trash"
                             : "I've reviewed the \"Review first\" items")
                            .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    .handCursor()
                    .help("Required for actions that can't be undone or items marked Review first")
                }
                Spacer()
                if plan.entries.contains(where: \.isBlocked) {
                    Button("Check Again") { model.recheckPlan() }.handCursor().help("Re-check after quitting the apps mentioned above")
                }
                Button("Cancel") { model.dismissPlan() }.keyboardShortcut(.cancelAction).handCursor().help("Close without cleaning anything")
                Button {
                    Task { await model.runPlan() }
                } label: {
                    Label(plan.included.isEmpty ? "Clean" : "Clean \(ByteFormat.string(plan.includedBytes))", systemImage: "sparkles")
                }
                .buttonStyle(GradientButtonStyle(large: true))
                .disabled(!plan.canRun)
                .keyboardShortcut(.defaultAction)
                .help(plan.canRun ? "Clean the ticked items now" : plan.stillChecking ? "Still checking that everything is safe…" : plan.needsAcknowledgement && !plan.acknowledged ? "Tick the confirmation on the left first" : "Nothing is ready to clean")
            case .running:
                ProgressView().controlSize(.small)
                Text("Cleaning…").foregroundStyle(.secondary)
                Spacer()
            case .finished:
                Button { model.openTrash() } label: { Label("Open Trash", systemImage: "trash") }
                    .buttonStyle(SoftButtonStyle(tint: .secondary))
                Spacer()
                Button("Scan Again") {
                    model.dismissPlan()
                    Task { await model.scan() }
                }
                .buttonStyle(SoftButtonStyle())
                Button("Done") { model.dismissPlan() }.buttonStyle(GradientButtonStyle(large: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

private struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let entry: PlanEntry
    let phase: CleanupPlan.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { entry.included }, set: { on in
                    if let i = model.plan?.entries.firstIndex(where: { $0.id == entry.id }) { model.plan?.entries[i].included = on }
                }))
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(!entry.isReady || phase != .review)
                .handCursor()
                .help(entry.isBlocked ? "Can't be included until the problem below is fixed" : "Include this in the cleanup")
                IconTile(symbol: entry.finding.symbol, color: entry.finding.tier.color, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.finding.title).font(.headline)
                    Text(markdown: whatHappens).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(entry.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
                status
            }
            VStack(alignment: .leading, spacing: 5) {
                if case let .blocked(problems) = entry.status {
                    ForEach(problems, id: \.self) { p in
                        Label(p, systemImage: "hand.raised.fill").foregroundStyle(Theme.danger)
                    }
                }
                if !entry.finding.isReversible {
                    Label("Can't be undone from the Trash.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.review)
                } else {
                    Label("Goes to the Trash. Put it back any time until you empty the Trash.", systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                }
                if let risk = entry.finding.risk {
                    Label { Text(markdown: risk) } icon: { Image(systemName: "info.circle") }.foregroundStyle(.secondary)
                }
                if let note = entry.finding.afterNote {
                    Label { Text(markdown: note) } icon: { Image(systemName: "lightbulb") }.foregroundStyle(.secondary)
                }
                if let kept = entry.finding.kept {
                    Label { Text("Keeps ") + Text(kept) } icon: { Image(systemName: "lock.shield") }.foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.leading, 30)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(entry.isBlocked ? Theme.danger.opacity(0.4) : Color.primary.opacity(0.08)))
        .opacity(entry.included || phase != .review ? 1 : 0.6)
    }

    private var whatHappens: String {
        switch entry.finding.action {
        case .trash: "Moves \(entry.items.count) item\(entry.items.count == 1 ? "" : "s") to the Trash"
        case .command: "Runs `\(entry.finding.action.commandLine ?? "")`"
        default: ""
        }
    }

    @ViewBuilder private var status: some View {
        switch entry.status {
        case .checking: ProgressView().controlSize(.small).help("Checking it's safe")
        case .ready: Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.safe).help("Ready")
        case .blocked: Image(systemName: "hand.raised.fill").foregroundStyle(Theme.danger).help("Not ready")
        case .running: ProgressView().controlSize(.small)
        case let .done(r): Image(systemName: r.outcome == .failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
            .foregroundStyle(r.outcome == .failed ? Theme.danger : Theme.safe)
        }
    }
}

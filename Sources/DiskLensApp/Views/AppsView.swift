import AppKit
import UniformTypeIdentifiers
import DiskLensCore
import SwiftUI

/// Uninstall apps completely, clear leftovers of removed apps, and see what runs in the background.
struct AppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.isScanningApps {
                    Card {
                        let p = model.appsProgress
                        ScanProgress(message: (p?.total ?? 0) > 0 ? "Measuring apps (\(p!.done) of \(p!.total))" : "Listing apps")
                    }
                }
                if model.appsScanned != nil {
                    Picker("Show", selection: $model.appsTab) {
                        ForEach(AppsTab.allCases) { tab in Label(title(tab), systemImage: tab.symbol).tag(tab) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 720).handCursor()
                    switch model.appsTab {
                    case .uninstall: UninstallList()
                    case .leftovers: LeftoversList()
                    case .startup: StartupList()
                    case .extensions: ExtensionsList()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .safeAreaInset(edge: .bottom) {
            if model.appsTab == .leftovers && !model.orphanItems.isEmpty { leftoversBar }
        }
        .navigationTitle("Apps")
    }

    private func title(_ tab: AppsTab) -> String {
        switch tab {
        case .uninstall: "\(tab.title) (\(model.appFootprints.count))"
        case .leftovers: "\(tab.title) (\(model.orphanItems.count))"
        case .startup: "\(tab.title) (\(model.startupItems.count))"
        case .extensions: "\(tab.title) (\(model.browserExtensions.count))"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: "square.grid.2x2.fill", color: Theme.brandStart, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Dragging an app to the Trash leaves its caches, settings and data behind. DiskLens finds them by the app's ID, shows each one, and moves only what you tick to the Trash.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.appsScanned != nil {
                    HStack(spacing: 8) {
                        let data = model.appFootprints.reduce(0) { $0 + $1.leftoverBytes }
                        Chip(text: "\(model.appFootprints.count) apps you can remove", symbol: "square.grid.2x2", tint: Theme.brandStart,
                             help: "Apps in Applications that aren't part of macOS")
                        Chip(text: "\(ByteFormat.string(data)) of app data", symbol: "externaldrive", tint: Theme.review,
                             help: "What your apps keep in your Library: caches, containers, app support")
                        let orphan = model.orphanItems.reduce(0) { $0 + $1.bytes }
                        if orphan > 0 {
                            Chip(text: "\(ByteFormat.string(orphan)) left by removed apps", symbol: "archivebox", tint: Theme.safe,
                                 help: "Library folders of apps that aren't installed any more")
                        }
                        if let date = model.appsScanned { Chip(text: "Checked \(date.friendly)", symbol: "clock", tint: .secondary) }
                    }
                }
            }
            Spacer()
            Button { Task { await model.scanApps() } } label: {
                Label(model.appsScanned == nil ? "Check Apps" : "Check Again", systemImage: "magnifyingglass")
            }
            .buttonStyle(GradientButtonStyle(large: true)).disabled(model.isScanningApps)
            .help("Measure every app and what it keeps in your Library. Read-only; about 30 seconds.")
        }
        .premiumCard()
    }

    private var leftoversBar: some View {
        let count = model.orphanSelection.count
        return HStack(spacing: 14) {
            IconTile(symbol: "archivebox", color: count == 0 ? .secondary : Theme.brandStart, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0 ? "Nothing selected" : "\(count) folder\(count == 1 ? "" : "s") · \(ByteFormat.string(model.orphanSelectedBytes))")
                    .font(.headline).monospacedDigit()
                Text("Nothing is ticked for you: check each one is from an app you really removed.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear Selection") { model.orphanSelection = [] }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).disabled(count == 0).help("Untick everything")
            Button { model.reviewOrphans() } label: { Label("Review Selected…", systemImage: "list.bullet.clipboard") }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(count == 0)
                .help("Review exactly what moves to the Trash before anything happens")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Uninstall

private struct UninstallList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $model.appSearch).textFieldStyle(.plain)
                if !model.appSearch.isEmpty {
                    Button { model.appSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(IconButtonStyle()).help("Clear search")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 360)

            VStack(spacing: 0) {
                ForEach(model.appsShown) { f in
                    AppRow(footprint: f)
                    if f.id != model.appsShown.last?.id { Divider().padding(.leading, 56) }
                }
                if model.appsShown.isEmpty {
                    Text(model.appSearch.isEmpty ? "No apps you can remove were found." : "No apps match “\(model.appSearch)”.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .premiumCard(padding: 12)
        }
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    let footprint: AppFootprint

    private var expanded: Bool { model.expandedApps.contains(footprint.id) }

    var body: some View {
        let app = footprint.app
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: FileManager.default.fileExists(atPath: app.path) ? NSWorkspace.shared.icon(forFile: app.path)
                                                                                   : NSWorkspace.shared.icon(for: .applicationBundle))
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.headline).lineLimit(1)
                        if let v = app.version { Text(v).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if app.isManaged {
                            Chip(text: "App Store", symbol: "bag", tint: .secondary,
                                 help: "Installed by the App Store or an administrator. Remove it from Launchpad; DiskLens can still clear its data.")
                        }
                    }
                    Text(usedText(app.lastUsed)).font(.caption).foregroundStyle(lastUsedOld(app.lastUsed) ? Theme.review : .secondary)
                }
                Spacer()
                sizeColumn("App", footprint.appBytes)
                sizeColumn("Data", footprint.leftoverBytes)
                    .help(footprint.leftovers.isEmpty ? "Keeps nothing in your Library" : "\(footprint.leftovers.count) folders or files in your Library")
                sizeColumn("Total", footprint.totalBytes, bold: true)
                Button {
                    if expanded { model.expandedApps.remove(footprint.id) } else { model.expandedApps.insert(footprint.id) }
                } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(IconButtonStyle()).disabled(footprint.leftovers.isEmpty)
                    .help(expanded ? "Hide its data" : "Show what it keeps in your Library")
                Button { model.reviewUninstall(footprint) } label: { Text(app.isManaged ? "Remove Data…" : "Uninstall…") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.danger))
                    .disabled(DemoData.isEnabled || (app.isManaged && footprint.leftovers.isEmpty))
                    .help(app.isManaged ? "Review its data before it moves to the Trash. Remove the app itself from Launchpad."
                                        : "Review the app and its data before anything moves to the Trash")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(footprint.leftovers) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16)
                            Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(item.path)
                            if let note = item.note { Chip(text: note, tint: .secondary) }
                            Spacer()
                            Text(ByteFormat.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            PathActions(path: item.path)
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .padding(.vertical, 8)
    }

    private func sizeColumn(_ label: String, _ bytes: Int64, bold: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(ByteFormat.string(bytes)).font(bold ? .callout.weight(.bold) : .callout).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 76, alignment: .trailing)
    }

    private func usedText(_ date: Date?) -> String {
        guard let date else { return "Never opened, as far as Spotlight knows" }
        return "Last opened " + date.formatted(.relative(presentation: .named))
    }

    private func lastUsedOld(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > 180 * 86_400
    }
}

// MARK: - Leftovers of removed apps

private struct LeftoversList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.orphanItems.isEmpty {
            Card { Label("No leftovers over 1 MB from removed apps.", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.safe) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Folders in your Library named after an app ID that no installed app uses. Some belong to helpers or command-line tools, so nothing is ticked for you.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                ForEach(model.orphanItems) { item in
                    let selected = model.orphanSelection.contains(item.path)
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { selected }, set: { on in
                            if on { model.orphanSelection.insert(item.path) } else { model.orphanSelection.remove(item.path) }
                        }))
                        .labelsHidden().toggleStyle(.checkbox).handCursor().help("Move this folder to the Trash")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.usedBy ?? item.name).font(.headline).lineLimit(1)
                            Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(item.path)
                        }
                        Spacer()
                        if let used = item.lastUsed {
                            Text("changed " + used.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(ByteFormat.string(item.bytes)).font(.callout.weight(.semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        PathActions(path: item.path)
                    }
                    .padding(.vertical, 6)
                    if item.id != model.orphanItems.last?.id { Divider() }
                }
            }
            .premiumCard(padding: 16)
        }
    }
}

// MARK: - Startup items

private struct StartupList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("Helpers that start with your Mac or keep running in the background. Ones that start for every user or as the system are listed for your information; turn those off in System Settings or in their app.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                    .buttonStyle(SoftButtonStyle(tint: Theme.brandStart))
                    .help("System Settings → General → Login Items, where macOS lets you switch background items off")
            }
            ForEach([StartupItem.Kind.userAgent, .systemAgent, .daemon], id: \.self) { kind in
                let items = model.startupItems.filter { $0.kind == kind }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: kind.rawValue, subtitle: "\(items.count) item\(items.count == 1 ? "" : "s")")
                            .padding(.bottom, 8)
                        ForEach(items) { item in
                            row(item)
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                    .premiumCard(padding: 16)
                }
            }
            if model.startupItems.isEmpty {
                Card { Label("Nothing starts with your Mac besides macOS itself.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.safe) }
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: item.owner == nil ? "gearshape" : "app", color: item.owner == nil ? .secondary : Theme.brandStart, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.owner ?? item.label).font(.headline).lineLimit(1)
                Text(item.program ?? item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(item.program ?? item.label)
            }
            Spacer()
            if item.runsAtLoad { Chip(text: "At login", symbol: "power", tint: .secondary, help: "Starts when you log in") }
            if item.keepAlive { Chip(text: "Always running", symbol: "arrow.clockwise", tint: Theme.review, help: "macOS restarts it if it quits") }
            if let program = item.program, !program.contains(".app/"), !FileManager.default.fileExists(atPath: program) {
                Chip(text: "Program missing", symbol: "exclamationmark.triangle", tint: Theme.review,
                     help: "The program it starts isn't on this Mac any more, so it does nothing. Safe to remove.")
            }
            if model.canRemove(item) {
                Button("Remove…") { model.reviewRemoveStartup(item) }
                    .buttonStyle(.textLink).font(.callout).help("Review, then move this login item to the Trash")
            }
            PathActions(path: item.path)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Browser extensions

private struct ExtensionsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browsers = Array(Set(model.browserExtensions.map(\.browser))).sorted()
        VStack(alignment: .leading, spacing: 12) {
            Text("Extensions can see the pages you visit. The ones marked “Can read every website” can read and change anything you see or type on any site, including passwords and messages. Remove the ones you don't recognise from the browser's Extensions page.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if browsers.isEmpty {
                Card { Label("No browser extensions found.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.safe) }
            }
            ForEach(browsers, id: \.self) { browser in
                let list = model.browserExtensions.filter { $0.browser == browser }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: browser, subtitle: "\(list.count) extension\(list.count == 1 ? "" : "s")").padding(.bottom, 8)
                    ForEach(list) { ext in
                        HStack(spacing: 10) {
                            IconTile(symbol: "puzzlepiece.extension", color: StartupInspector.readsAllSites(ext) ? Theme.review : .secondary, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ext.name).font(.headline).lineLimit(1)
                                Text([ext.version.map { "Version \($0)" }, ext.identifier].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if StartupInspector.readsAllSites(ext) {
                                Chip(text: "Can read every website", symbol: "eye", tint: Theme.review,
                                     help: "Has permission for all sites, so it can read and change any page you open")
                            }
                            PathActions(path: ext.path)
                        }
                        .padding(.vertical, 6)
                        if ext.id != list.last?.id { Divider() }
                    }
                }
                .premiumCard(padding: 16)
            }
        }
    }
}

import AppKit
import DiskLensCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings keys, shared by the Settings window, the menu bar extra and the low-space monitor.
enum Prefs {
    static let showMenuBar = "showMenuBar"
    static let lowSpaceAlerts = "lowSpaceAlerts"
    static let lowSpaceGB = "lowSpaceGB"
    static let lastLowSpaceAlert = "lastLowSpaceAlert"
    static let servicesLevel = "servicesLevel"

    /// Notifications and login items need a real app bundle (not `swift run`).
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}

// MARK: - Finder ▸ Services ▸ Make Private Copy (DiskLens)

/// Right-click files in Finder → Services → "Make Private Copy (DiskLens)": saves "name (clean).ext" next to each,
/// without location (and, by default, camera, serial numbers and names). The originals are never changed.
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func makePrivateCopy(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Select photos, videos, PDFs or Office files in Finder first." as NSString
            return
        }
        let level: MetadataCleaner.Level = UserDefaults.standard.string(forKey: Prefs.servicesLevel) == MetadataCleaner.Level.location.rawValue
            ? .location : .identifying
        Task { @MainActor in
            var made: [URL] = []
            var problems: [String] = []
            for url in urls {
                guard let report = await MetadataInspector.inspect(url.path) else {
                    problems.append("\(url.lastPathComponent): not a photo, video, PDF or Office file")
                    continue
                }
                let result = await MetadataCleaner.clean(report, level: level, mode: .saveCopy)
                if let out = result.output, result.ok { made.append(URL(fileURLWithPath: out)) } else { problems.append("\(url.lastPathComponent): \(result.message)") }
            }
            if !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
            if !problems.isEmpty {
                let alert = NSAlert()
                alert.messageText = made.isEmpty ? "No private copies were made" : "Some files were skipped"
                alert.informativeText = problems.prefix(8).joined(separator: "\n")
                alert.runModal()
            }
        }
    }
}

// MARK: - Low-space monitor

@MainActor
extension AppModel {
    /// Keeps the menu bar's free-space figure fresh and posts a local notification when space runs low
    /// (at most once a day). Reads one number from the file system; never scans.
    func startMonitoring() {
        guard !DemoData.isEnabled, !isMonitoring else { return }
        isMonitoring = true
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let free = DiskMeasure.freeBytes()
                self.liveFree = free
                self.checkLowSpace(free)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func checkLowSpace(_ free: Int64) {
        let d = UserDefaults.standard
        guard Prefs.isBundled, d.bool(forKey: Prefs.lowSpaceAlerts) else { return }
        let gb = d.integer(forKey: Prefs.lowSpaceGB) == 0 ? 20 : d.integer(forKey: Prefs.lowSpaceGB)
        guard free < Int64(gb) * 1_000_000_000 else { return }
        let last = d.double(forKey: Prefs.lastLowSpaceAlert)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        d.set(Date().timeIntervalSince1970, forKey: Prefs.lastLowSpaceAlert)
        let content = UNMutableNotificationContent()
        content.title = "Only \(ByteFormat.string(free)) free on \(volumeName)"
        content.body = "Open DiskLens to see what's using the space. Quick Clean shows what it would remove before anything happens."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.lowSpaceAlerts) private var lowSpaceAlerts = false
    @AppStorage(Prefs.lowSpaceGB) private var lowSpaceGB = 20
    @AppStorage(Prefs.servicesLevel) private var servicesLevel = MetadataCleaner.Level.identifying.rawValue
    @State private var openAtLogin = Prefs.isBundled && SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show free space in the menu bar", isOn: $showMenuBar)
                    .help("A small drive icon with how much space is free, plus Quick Clean and Scan Now")
                Toggle("Open DiskLens when you log in", isOn: $openAtLogin)
                    .disabled(!Prefs.isBundled)
                    .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
                    .help("Starts DiskLens quietly at login so the menu bar figure and low-space alerts work")
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Low space") {
                Toggle("Notify me when free space is low", isOn: $lowSpaceAlerts)
                    .disabled(!Prefs.isBundled)
                    .onChange(of: lowSpaceAlerts) { _, on in if on { requestNotifications() } }
                Picker("When free space drops below", selection: $lowSpaceGB) {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .disabled(!lowSpaceAlerts)
                Text("Checked once a minute while DiskLens is open (in the menu bar or a window), and at most one notification a day. Nothing is ever cleaned automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if notificationsDenied {
                    Text("Notifications are turned off for DiskLens in System Settings → Notifications.").font(.caption).foregroundStyle(Theme.review)
                }
            }
            Section("Finder service") {
                Picker("“Make Private Copy” removes", selection: $servicesLevel) {
                    Text("Location only").tag(MetadataCleaner.Level.location.rawValue)
                    Text("Location, camera, serial numbers and names").tag(MetadataCleaner.Level.identifying.rawValue)
                }
                Text("In Finder, select photos, videos, PDFs or Office files, right-click and choose Services → Make Private Copy (DiskLens). A clean copy is saved next to each; the original is not changed. If it doesn't appear, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Privacy") {
                Label("DiskLens never connects to the internet and has no accounts, analytics or AI services. Everything is read and changed on this Mac, and nothing is removed without your confirmation.",
                      systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve DiskLens in System Settings → General → Login Items." : nil
        } catch {
            loginMessage = "Couldn't change this: \(error.localizedDescription). Move DiskLens to Applications and try again."
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                notificationsDenied = !granted
                if !granted { lowSpaceAlerts = false }
            }
        }
    }
}

// MARK: - Menu bar extra

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let free = model.liveFree ?? model.latest?.free ?? DiskMeasure.freeBytes()
        let capacity = model.latest?.capacity
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(ByteFormat.string(free)) free").font(.headline).monospacedDigit()
                    Text(capacity.map { "of \(ByteFormat.string($0)) on \(model.volumeName)" } ?? model.volumeName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let capacity, capacity > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Theme.brand).frame(width: geo.size.width * CGFloat(1 - Double(free) / Double(capacity)))
                    }
                }
                .frame(height: 6)
            }
            if let last = model.lastFullScan {
                Text("Last full scan \(last.date.friendly) · \(ByteFormat.string(model.reclaimable(.safe))) safe to clean")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let grew = model.growthSinceLastScan.first {
                Text("Grew most since the last scan: \(grew.name) +\(ByteFormat.string(grew.bytes))").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button { show(); Task { await model.quickClean() } } label: { Label("Quick Clean…", systemImage: "bolt.fill") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.brandEnd)).disabled(model.isBusy)
                    .help("Quick Scan, then review what it would clean. Nothing happens until you confirm.")
                Button { show(); Task { await model.scan() } } label: { Label("Scan Now", systemImage: "magnifyingglass") }
                    .buttonStyle(GradientButtonStyle()).disabled(model.isBusy)
            }
            Divider()
            HStack {
                Button("Open DiskLens") { show() }.buttonStyle(.textLink)
                Spacer()
                Button("Settings…") { NSApp.activate(); openSettings() }.buttonStyle(.textLink)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.textLink)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func show() {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) { openWindow(id: "main") }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let free = model.liveFree ?? model.latest?.free ?? 0
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
            Text(ByteFormat.string(free)).monospacedDigit()
        }
    }
}

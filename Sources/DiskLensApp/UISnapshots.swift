import AppKit

/// Debug aid: with DISKLENS_SNAPSHOT_DIR set, renders each section of the app's own
/// window to a PNG after the first scan (no Screen Recording permission needed).
@MainActor
enum UISnapshots {
    static var directory: String? { ProcessInfo.processInfo.environment["DISKLENS_SNAPSHOT_DIR"] }

    static func capture(_ model: AppModel) async {
        guard let directory, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        window.setContentSize(NSSize(width: 1320, height: 1400))
        func shot(_ name: String, _ target: NSWindow = window) {
            guard let image = windowImage(CGWindowID(target.windowNumber)) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        }
        // First run: capture the welcome screen, then do the recommended full scan.
        if model.needsFirstScan {
            try? await Task.sleep(for: .seconds(2))
            shot("welcome")
            await model.scan()
        }
        for section in AppSection.allCases {
            model.section = section
            try? await Task.sleep(for: .seconds(2))
            shot(section.rawValue)
        }

        // A finding opened from an insight shows its dependency details.
        model.showCleanup(.safe)
        model.toggleSelectAllInFilter()
        try? await Task.sleep(for: .seconds(2))
        shot("cleanup-selected")

        // Review sheets run only read-only safety checks; nothing is cleaned here.
        model.reviewSelected()
        for _ in 0..<120 where model.plan?.stillChecking ?? false { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(1))
        if let sheet = window.attachedSheet { shot("review-sheet", sheet) }
        model.dismissPlan()
        model.selectTiers(nil)
        try? await Task.sleep(for: .seconds(1))

        await model.quickClean()
        try? await Task.sleep(for: .seconds(1))
        if let sheet = window.attachedSheet { shot("quick-clean-sheet", sheet) }
        model.dismissPlan()
        model.section = .overview
        FileHandle.standardError.write(Data("snapshots written to \(directory)\n".utf8))
    }

    /// CGWindowListCreateImage is hidden from the macOS 15+ SDK but still works for an app's own windows.
    private static func windowImage(_ id: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(symbol, to: Fn.self)
        // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
        return fn(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}

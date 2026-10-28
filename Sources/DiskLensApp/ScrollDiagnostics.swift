import AppKit

/// Debug aid (DISKLENS_SCROLLTEST=1): sizes the window short, then for each section reports the
/// scroll view's height vs the window's and captures it scrolled to the very bottom.
@MainActor
enum ScrollDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DISKLENS_SCROLLTEST"] == "1" }

    static func run(_ model: AppModel) async {
        guard enabled, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        window.setContentSize(NSSize(width: 1240, height: 720))
        try? await Task.sleep(for: .seconds(1))
        func dump(_ v: NSView, _ depth: Int) {
            guard depth < 9 else { return }
            let f = v.convert(v.bounds, to: nil)
            if f.height > 900 {
                FileHandle.standardError.write(Data("{\(String(repeating: "  ", count: depth))\(type(of: v)) y=\(Int(f.minY))..\(Int(f.maxY)) fit=\(Int(v.fittingSize.height))}\n".utf8))
            }
            v.subviews.forEach { dump($0, depth + 1) }
        }
        FileHandle.standardError.write(Data("{window frame=\(window.frame.size) minSize=\(window.minSize) contentMinSize=\(window.contentMinSize)}\n".utf8))
        dump(window.contentView!, 0)
        for section in AppSection.allCases {
            model.section = section
            try? await Task.sleep(for: .seconds(2))
            let scrolls = allScrollViews(in: window.contentView!).filter { $0.frame.width > 400 }
            for (i, sv) in scrolls.enumerated() {
                let docH = sv.documentView?.frame.height ?? 0
                let inWindow = sv.convert(sv.bounds, to: nil)
                FileHandle.standardError.write(Data("[\(section.rawValue)#\(i)] window=\(Int(window.contentLayoutRect.height)) scrollFrame=\(Int(inWindow.minY))..\(Int(inWindow.maxY)) visible=\(Int(sv.contentView.bounds.height)) doc=\(Int(docH)) insets=\(sv.contentInsets)\n".utf8))
                if let doc = sv.documentView {
                    doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? max(0, docH - sv.contentView.bounds.height) : 0))
                }
            }
            try? await Task.sleep(for: .seconds(1))
            if let dir = UISnapshots.directory, let image = UISnapshots.windowImagePublic(CGWindowID(window.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/scroll-\(section.rawValue).png"))
            }
        }
        NSApp.terminate(nil)
    }

    private static func allScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(allScrollViews)
    }
}

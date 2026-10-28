import DiskLensCore
import SwiftUI

/// Drill into any category folder by size, then jump to it in Finder.
struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [FolderEntry]?
    @State private var searching = false

    private var scope: String { model.explorePath.last ?? NSHomeDirectory() }
    private var scopeName: String { model.explorePath.last.map { ($0 as NSString).lastPathComponent } ?? "your home folder" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
            searchBar
            Divider()
            if let results {
                SearchResults(entries: results, query: query, scopeName: scopeName) { self.results = nil }
            } else if let path = model.explorePath.last {
                FolderList(path: path, filter: query).id(path)
            } else {
                roots
            }
        }
        .background(PageBackground())
        .navigationTitle("Explore")
        .onChange(of: model.explorePath) { _, _ in results = nil }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.explorePath.isEmpty ? "Filter categories and folders" : "Filter \(scopeName)", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await deepSearch() } }
                if !query.isEmpty {
                    Button { query = ""; results = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(IconButtonStyle()).help("Clear the search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .help("Type to filter what's shown. Press Return to search every subfolder.")
            Button { Task { await deepSearch() } } label: {
                if searching { ProgressView().controlSize(.small) } else { Label("Search all subfolders", systemImage: "text.magnifyingglass") }
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            .help("Search names in every folder inside \(scopeName) using Spotlight (local, instant)")
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func deepSearch() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        results = await model.search(query, in: scope)
        searching = false
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { if !model.explorePath.isEmpty { model.explorePath.removeLast() } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle())
                .disabled(model.explorePath.isEmpty)
                .help("Back")
            Button("Categories") { model.explorePath = [] }.buttonStyle(.textLink).help("Back to all categories")
            ForEach(Array(model.explorePath.enumerated()), id: \.offset) { index, path in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(index == 0 ? path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : (path as NSString).lastPathComponent) {
                    model.explorePath = Array(model.explorePath.prefix(index + 1))
                }
                .buttonStyle(.textLink)
                .lineLimit(1)
                .help(path)
            }
            Spacer()
            if let path = model.explorePath.last { PathActions(path: path) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var roots: some View {
        if let snapshot = model.latest, !snapshot.categories.isEmpty {
            List {
                ForEach(snapshot.categories.filter { c in
                    c.name != "Other" && !c.paths.isEmpty && (query.isEmpty || c.name.localizedCaseInsensitiveContains(query)
                        || c.paths.contains { $0.localizedCaseInsensitiveContains(query) })
                }) { c in
                    Section("\(c.name) · \(ByteFormat.string(c.bytes))") {
                        ForEach(c.paths.filter { query.isEmpty || c.name.localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { path in
                            Button { model.explorePath = [path] } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    Spacer()
                                    if let bytes = c.pathBytes?[path] {
                                        Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .handCursor()
                            .help("Open \(path) and see what's inside, largest first")
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Nothing to explore yet", systemImage: "folder", description: Text("Run a scan first."))
        }
    }
}

private struct FolderList: View {
    @Environment(AppModel.self) private var model
    let path: String
    var filter: String = ""
    @State private var entries: [FolderEntry]? = nil

    var body: some View {
        Group {
            if let all = entries {
                let entries = filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
                if entries.isEmpty && !filter.isEmpty {
                    ContentUnavailableView("No match in this folder", systemImage: "magnifyingglass",
                                           description: Text("Press Return to search every subfolder for “\(filter)”."))
                } else if entries.isEmpty {
                    ContentUnavailableView("Empty or not readable", systemImage: "lock",
                                           description: Text("Some folders need Full Disk Access to be measured."))
                } else {
                    let largest = max(1, entries.first?.bytes ?? 1)
                    List(entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2).fill(Palette.measured.opacity(0.7))
                                        .frame(width: max(2, geo.size.width * CGFloat(entry.bytes) / CGFloat(largest)))
                                }
                                .frame(height: 5)
                            }
                            Text(ByteFormat.string(entry.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            PathActions(path: entry.path)
                            Button { model.explorePath.append(entry.path) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(IconButtonStyle())
                                .help("Open this folder")
                                .disabled(!entry.isDirectory)
                                .opacity(entry.isDirectory ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if entry.isDirectory { model.explorePath.append(entry.path) } }
                        .contextMenu {
                            Button("Show in Finder") { model.revealInParent(entry.path) }
                            Button("Copy Path") { model.copyPath(entry.path) }
                        }
                    }
                }
            } else {
                VStack { ProgressView("Measuring \((path as NSString).lastPathComponent)…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { entries = await model.entries(for: path) }
    }
}

/// Spotlight results for a name search, largest first.
private struct SearchResults: View {
    @Environment(AppModel.self) private var model
    let entries: [FolderEntry]
    let query: String
    let scopeName: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(entries.count) result\(entries.count == 1 ? "" : "s") for “\(query)” in \(scopeName)").font(.callout.weight(.medium))
                Spacer()
                Button("Back to folder") { close() }.buttonStyle(.textLink).help("Leave the search results")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if entries.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass",
                                       description: Text("Spotlight found no names containing “\(query)”. Hidden folders and app internals aren't indexed."))
            } else {
                List(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Text((entry.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(entry.bytes > 0 ? ByteFormat.string(entry.bytes) : "—").monospacedDigit().foregroundStyle(.secondary)
                        PathActions(path: entry.path)
                        if entry.isDirectory {
                            Button { model.explorePath = [entry.path] } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(IconButtonStyle()).help("Open this folder in Explore")
                        }
                    }
                    .help(entry.path)
                }
            }
        }
    }
}

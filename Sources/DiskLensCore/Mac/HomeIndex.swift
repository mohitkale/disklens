#if os(macOS)
import Foundation

/// One pass over the home folder that collects what several rules need: node_modules folders,
/// Gradle files and very large files. Skips ~/Library, the Trash, hidden folders, app bundles and
/// photo libraries, which other rules handle.
public struct HomeIndex: Sendable {
    public let nodeModules: [String]
    public let gradleFiles: [String]
    public let largeFiles: [String]

    public static let largeFileThreshold = "+1G"

    public static func build(home: String = NSHomeDirectory()) async -> HomeIndex {
        let r = await Shell.run("/usr/bin/find", [
            home, "-xdev",
            "(", "-path", home + "/Library", "-o", "-path", home + "/.Trash", "-o", "-name", ".*",
            "-o", "-name", "*.app", "-o", "-name", "*.photoslibrary", "-o", "-name", "*.musiclibrary", ")", "-prune",
            "-o", "(", "-name", "node_modules", "-type", "d", "-prune", "-print", ")",
            "-o", "(", "-type", "f", "(", "-name", "build.gradle", "-o", "-name", "build.gradle.kts", "-o", "-name", "gradle.properties", ")", "-print", ")",
            "-o", "(", "-type", "f", "-size", largeFileThreshold, "-print", ")",
        ], timeout: 600, captureStderr: false)

        var modules: [String] = [], gradle: [String] = [], large: [String] = []
        for line in r.out.split(separator: "\n").map(String.init) {
            let name = (line as NSString).lastPathComponent
            if name == "node_modules" { modules.append(line) }
            else if name == "build.gradle" || name == "build.gradle.kts" || name == "gradle.properties" { gradle.append(line) }
            else { large.append(line) }
        }
        return HomeIndex(nodeModules: modules, gradleFiles: gradle, largeFiles: large)
    }
}
#endif

#if os(macOS)
import Foundation
import ImageIO
import Vision

/// A screenshot or photo whose text looks sensitive.
public struct SensitiveFinding: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case card = "Card number", code = "Verification code", password = "Password or PIN", id = "ID number",
             bank = "Bank account (IBAN)", seed = "Crypto recovery phrase", qr = "QR code", email = "Email address"

        public var symbol: String {
            switch self {
            case .card: "creditcard"
            case .code: "number.square"
            case .password: "key"
            case .id: "person.text.rectangle"
            case .bank: "building.columns"
            case .seed: "bitcoinsign.circle"
            case .qr: "qrcode"
            case .email: "at"
            }
        }
        /// High-risk kinds are worth deleting or locking away; others are worth a look.
        public var isHighRisk: Bool { self != .qr && self != .email }
    }

    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let kinds: [Kind]
    /// Masked examples, e.g. "•••• •••• •••• 4242".
    public let samples: [String]
    public let date: Date?
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: Int64, kinds: [Kind], samples: [String], date: Date?) {
        self.path = path
        self.bytes = bytes
        self.kinds = kinds
        self.samples = samples
        self.date = date
    }
}

public enum SensitiveScanner {
    /// Screenshots in `folders`: by typical name, or by the "Screenshot" comment macOS and iOS write
    /// into the image header. Skips code projects and libraries, which are full of unrelated images.
    public static func screenshots(in folders: [String], limit: Int = 4_000) -> [String] {
        var out: [String] = []
        let types: Set<String> = ["png", "jpg", "jpeg", "heic"]
        let skip: Set<String> = ["node_modules", "Pods", "DerivedData", "build", "dist", "vendor", "target", "venv", "site-packages"]
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL, out.count < limit {
                let name = url.lastPathComponent
                if skip.contains(name) || name.hasSuffix(".photoslibrary") || name.hasSuffix(".app") || name.hasSuffix(".xcassets") {
                    walker.skipDescendants(); continue
                }
                let ext = url.pathExtension.lowercased()
                guard types.contains(ext) else { continue }
                if isScreenshot(url.path, ext: ext) { out.append(url.path) }
            }
        }
        return out
    }

    static func isScreenshot(_ path: String, ext: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot") || name.hasPrefix("simulator screenshot") { return true }
        // Screenshots are PNG (Mac, iPhone) or HEIC/JPEG when converted; the header says so either way.
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return (exif?[kCGImagePropertyExifUserComment] as? String)?.lowercased() == "screenshot"
    }

    public static func scan(_ paths: [String], progress: @escaping @Sendable (Int, Int) -> Void) async -> [SensitiveFinding] {
        var results: [SensitiveFinding] = []
        await withTaskGroup(of: SensitiveFinding?.self) { group in
            var it = paths.makeIterator()
            var done = 0
            for _ in 0..<4 { if let p = it.next() { group.addTask { inspect(p) } } }
            while let r = await group.next() {
                done += 1
                if done % 10 == 0 || done == paths.count { progress(done, paths.count) }
                if let r { results.append(r) }
                if let p = it.next() { group.addTask { inspect(p) } }
            }
        }
        return results.sorted { ($0.kinds.contains(where: \.isHighRisk) ? 0 : 1, $0.path) < ($1.kinds.contains(where: \.isHighRisk) ? 0 : 1, $1.path) }
    }

    /// Reads the image's text on this Mac (Vision) and checks it with the detectors below.
    public static func inspect(_ path: String) -> SensitiveFinding? {
        guard let image = MediaLibrary.thumbnail(path, maxPixels: 2400) else { return nil }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        let codes = VNDetectBarcodesRequest()
        codes.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([text, codes])
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        var (kinds, samples) = detect(in: lines)
        if !(codes.results ?? []).isEmpty { kinds.insert(.qr) }
        guard !kinds.isEmpty else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return SensitiveFinding(path: path, bytes: Int64(attrs?[.size] as? Int ?? 0),
                                kinds: SensitiveFinding.Kind.allCases.filter(kinds.contains), samples: Array(samples.prefix(3)),
                                date: attrs?[.creationDate] as? Date)
    }

    // MARK: Detectors (pure, testable)

    public static func detect(in lines: [String]) -> (Set<SensitiveFinding.Kind>, [String]) {
        var kinds = Set<SensitiveFinding.Kind>()
        var samples: [String] = []
        let all = lines.joined(separator: "\n")
        let lower = all.lowercased()

        // Card numbers: 13–19 digits (spaces/dashes allowed) that pass the Luhn check.
        for m in matches(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, in: all) {
            let digits = m.filter(\.isNumber)
            if (13...19).contains(digits.count), luhn(digits) {
                kinds.insert(.card)
                samples.append("•••• " + digits.suffix(4))
            }
        }
        // One-time codes: 4–8 digits near words like OTP / code / verification.
        if lower.range(of: #"\b(otp|one[- ]time|verification code|security code|login code|your code|code is|passcode)\b"#, options: .regularExpression) != nil,
           !matches(#"(?<!\d)\d{4,8}(?!\d)"#, in: all).isEmpty {
            kinds.insert(.code)
            samples.append("one-time code")
        }
        // Passwords / PINs shown in plain text.
        if lower.range(of: #"\b(password|passwd|pwd|pin|passphrase)\s*[:=]\s*\S+"#, options: .regularExpression) != nil {
            kinds.insert(.password)
            samples.append("password: ••••••")
        }
        // ID numbers: US SSN, Indian Aadhaar (12 digits in 4-4-4) and PAN.
        if !matches(#"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#, in: all).isEmpty
            || (!matches(#"(?<!\d)\d{4} \d{4} \d{4}(?!\d)"#, in: all).isEmpty && lower.contains("aadhaar"))
            || !matches(#"\b[A-Z]{5}[0-9]{4}[A-Z]\b"#, in: all).isEmpty && lower.contains("permanent account") {
            kinds.insert(.id)
            samples.append("ID number")
        }
        // IBAN.
        if !matches(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#, in: all).isEmpty && lower.contains("iban") {
            kinds.insert(.bank)
            samples.append("IBAN")
        }
        // Crypto recovery phrase: "seed/recovery/secret phrase" plus 12+ short lowercase words.
        if lower.range(of: #"\b(seed phrase|recovery phrase|secret recovery|mnemonic|backup phrase)\b"#, options: .regularExpression) != nil,
           lower.split(whereSeparator: { !$0.isLetter }).filter({ (3...8).contains($0.count) }).count >= 12 {
            kinds.insert(.seed)
            samples.append("recovery phrase")
        }
        if !matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: all).isEmpty { kinds.insert(.email) }
        return (kinds, Array(NSOrderedSet(array: samples).array as! [String]))
    }

    public static func luhn(_ digits: String) -> Bool {
        let nums = digits.compactMap(\.wholeNumberValue)
        guard nums.count >= 13, Set(nums).count > 1 else { return false }   // rejects 0000… and 1111…
        var sum = 0
        for (i, d) in nums.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
}
#endif

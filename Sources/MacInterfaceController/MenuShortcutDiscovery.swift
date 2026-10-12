import Foundation

struct MenuShortcutDiscovery {
    var domains: Set<String> = []
    var excludedDomains: Set<String> = []
    var warnings: [String] = []

    /// Inspect local preference files before asking CFPreferences for a domain.
    /// This avoids opening protected messaging/home domains on every scan.
    static func scan(directory: URL, hostIdentifier: String? = nil,
                     deniedFiles: DeniedPreferenceFiles? = nil,
                     read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Self {
        var result = Self()
        guard FileManager.default.fileExists(atPath: directory.path) else { return result }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files where file.pathExtension == "plist" {
            var domain = file.deletingPathExtension().lastPathComponent
            if let hostIdentifier {
                let suffix = "." + hostIdentifier.lowercased()
                guard domain.lowercased().hasSuffix(suffix) else { continue }
                domain.removeLast(suffix.count)
            }
            guard !domain.hasPrefix("."), !["NSGlobalDomain", "com.apple.dock", "com.apple.symbolichotkeys"].contains(domain) else { continue }
            if deniedFiles?.contains(file) == true {
                result.excludedDomains.insert(domain)
                result.warnings.append("\(domain): 접근이 제한된 설정 파일입니다. 권한 변경 후 앱을 다시 실행해 주세요.")
                continue
            }
            do {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                    result.excludedDomains.insert(domain)
                result.warnings.append("\(domain): 일반 설정 파일이 아니어서 검사에서 제외했습니다.")
                    continue
                }
                let data = try read(file)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    result.excludedDomains.insert(domain)
                result.warnings.append("\(domain): 설정 파일 형식을 확인하지 못했습니다.")
                    continue
                }
                if plist["NSUserKeyEquivalents"] != nil { result.domains.insert(domain) }
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == CocoaError.fileReadNoPermission.rawValue {
                    deniedFiles?.insert(file)
                }
                result.excludedDomains.insert(domain)
                result.warnings.append("\(domain): 로컬 설정 파일을 읽지 못했습니다.")
            }
        }
        return result
    }
}

/// Remember actual permission denials for this process, so background checks do
/// not retry protected files every minute. A relaunch retries changed permissions.
final class DeniedPreferenceFiles: @unchecked Sendable {
    static let shared = DeniedPreferenceFiles()
    private let lock = NSLock()
    private var files: Set<URL> = []
    func contains(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return files.contains(url) }
    func insert(_ url: URL) { lock.lock(); defer { lock.unlock() }; files.insert(url) }
}

import ReaperFS
import ReaperRules

/// `cachedir.signature`: the directory holds a `CACHEDIR.TAG` that starts with the standard
/// signature (https://bford.info/cachedir/).
struct CacheDirSignature: Check {

    private static let signature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    let name = "cachedir.signature"

    func evaluate(_ entry: EntryContext, arguments: [String: ScalarValue], fileSystem: any FileSystem) -> Facts? {
        let tag = entry.path.appending("CACHEDIR.TAG")
        guard let bytes = try? fileSystem.readFile(at: tag, maxBytes: Self.signature.count), bytes == Self.signature else {
            return nil
        }
        return [:]
    }
}

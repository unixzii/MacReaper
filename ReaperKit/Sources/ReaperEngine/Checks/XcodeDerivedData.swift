import Foundation
import ReaperFS
import ReaperRules
import System

/// `xcode.derived-data`: reads the `info.plist` Xcode keeps in each DerivedData folder to find
/// the workspace it belongs to.
///
/// Facts:
/// - `workspacePath`: the `WorkspacePath` recorded in the plist.
/// - `workspaceExists`: something still exists at that path.
struct XcodeDerivedData: Check {

    private static let maxBytes = 1024 * 1024

    let spec = CheckSpec(name: "xcode.derived-data", facts: ["workspacePath": .string, "workspaceExists": .boolean])

    func evaluate(_ entry: EntryContext, arguments: [String: ScalarValue], fileSystem: any FileSystem) -> Facts? {
        guard let bytes = try? fileSystem.readFile(at: entry.path.appending("info.plist"), maxBytes: Self.maxBytes),
              let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any],
              let workspace = plist["WorkspacePath"] as? String, !workspace.isEmpty else {
            return nil
        }
        return [
            "workspacePath": .string(workspace),
            "workspaceExists": .boolean(fileSystem.exists(at: FilePath(workspace))),
        ]
    }
}

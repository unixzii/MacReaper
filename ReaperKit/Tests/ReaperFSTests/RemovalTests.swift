import Darwin
import Foundation
import ReaperFS
import ReaperFSTesting
import System
import Testing

@Suite("Removal")
struct RemovalTests {

    let fileSystem = DarwinFileSystem()

    @Test("Identity matches what a listing reports")
    func identityMatchesListing() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("file")
            Directory("folder") {}
            Symlink("link", to: "folder")
        }.materialize(at: temporary.path)

        for entry in try fileSystem.listDirectory(at: temporary.path).entries {
            let found = try fileSystem.identity(at: temporary.path.appending(entry.name))
            #expect(found.identity == entry.identity)
            #expect(found.kind == entry.kind)
        }
        #expect(throws: FSError.notFound) {
            try fileSystem.identity(at: temporary.path.appending("missing"))
        }
    }

    @Test("Emptying deletes files and symlinks, not what they point to, and leaves subdirectories")
    func emptyingLeavesSubdirectories() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            Directory("target") {
                File("a")
                File("b")
                Symlink("outside", to: "../outside")
                Symlink("outside-file", to: "../keep")
                Directory("debug") {
                    File("c")
                }
            }
            Directory("outside") {
                File("kept")
            }
            File("keep")
        }.materialize(at: temporary.path)
        let target = temporary.path.appending("target")

        let emptied = try fileSystem.emptyDirectory(at: target)

        #expect(emptied.removed == 4)
        #expect(emptied.failures.isEmpty)
        #expect(emptied.subdirectories == [target.appending("debug")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.string) == ["debug"])
        #expect(fileSystem.exists(at: temporary.path.appending("outside/kept")))
        #expect(fileSystem.exists(at: temporary.path.appending("keep")))
    }

    @Test("Read-only and unreadable folders the user owns are deleted")
    func readOnlyFolders() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            Directory("readonly") {
                File("file")
            }
            Directory("locked", failure: .permissionDenied) {
                File("file")
            }
        }.materialize(at: temporary.path)
        let readOnly = temporary.path.appending("readonly")
        #expect(chmod(readOnly.string, 0o555) == 0)
        #expect(chmod(temporary.path.string, 0o555) == 0)
        defer { chmod(temporary.path.string, 0o755) }

        for name in ["readonly", "locked"] {
            let directory = temporary.path.appending(name)
            let emptied = try fileSystem.emptyDirectory(at: directory)
            #expect(emptied.removed == 1)
            #expect(emptied.failures.isEmpty)
            try fileSystem.removeDirectory(at: directory)
            #expect(!fileSystem.exists(at: directory))
        }
    }

    @Test("An entry that cannot be deleted is reported, and the rest are deleted")
    func immutableFile() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("locked")
            File("other")
        }.materialize(at: temporary.path)
        let locked = temporary.path.appending("locked")
        #expect(chflags(locked.string, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.string, 0) }

        let emptied = try fileSystem.emptyDirectory(at: temporary.path)

        #expect(emptied.removed == 1)
        #expect(emptied.failures == [RemovalFailure(path: locked, error: .permissionDenied)])
        #expect(throws: FSError.permissionDenied) {
            try fileSystem.removeFile(at: locked)
        }
        #expect(throws: FSError.io(errno: ENOTEMPTY)) {
            try fileSystem.removeDirectory(at: temporary.path)
        }
    }
}

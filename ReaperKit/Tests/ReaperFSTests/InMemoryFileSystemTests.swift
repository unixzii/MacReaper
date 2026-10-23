import Darwin
import ReaperFS
import ReaperFSTesting
import System
import Testing

@Suite("InMemoryFileSystem")
struct InMemoryFileSystemTests {

    @Test("The tree is mounted at its root, with intermediate directories created")
    func mountsTreeAtRoot() throws {
        let fileSystem = InMemoryFileSystem(root: "/Users/test") {
            File("Library/Caches/Homebrew/a.tar.gz")
            Directory("Library") {
                File("note")
            }
        }

        #expect(try names(fileSystem, "/Users") == ["test"])
        #expect(try names(fileSystem, "/Users/test/Library") == ["Caches", "note"])
        #expect(try names(fileSystem, "/Users/test/Library/Caches/Homebrew") == ["a.tar.gz"])
    }

    @Test("Shuffled listings are stable for a seed and differ between seeds")
    func shuffledListings() throws {
        let tree = Tree {
            for index in 0..<20 {
                File("file-\(index)")
            }
        }
        func listing(seed: UInt64) throws -> [String] {
            try names(InMemoryFileSystem(order: .shuffled(seed: seed), tree: tree), "/")
        }

        #expect(try listing(seed: 1) == listing(seed: 1))
        #expect(try listing(seed: 1) != listing(seed: 2))
        #expect(try Set(listing(seed: 1)) == Set(names(InMemoryFileSystem(tree: tree), "/")))
    }

    @Test("Devices are inherited by everything below a directory")
    func devices() throws {
        let fileSystem = InMemoryFileSystem {
            Directory("external", device: 7) {
                File("nested/file")
            }
            File("local")
        }

        let root = try fileSystem.listDirectory(at: "/").entries
        let nested = try fileSystem.listDirectory(at: "/external/nested").entries

        #expect(root.first { $0.name == "local" }?.identity.device == 1)
        #expect(root.first { $0.name == "external" }?.identity.device == 7)
        #expect(nested.first?.identity.device == 7)
    }

    @Test("Hard links share one identity and count each other")
    func hardLinks() throws {
        let fileSystem = InMemoryFileSystem {
            File("original", contents: "data")
            HardLink("copy", to: "original")
        }

        let entries = try fileSystem.listDirectory(at: "/").entries

        #expect(Set(entries.map(\.identity)).count == 1)
        #expect(entries.allSatisfy { $0.linkCount == 2 })
    }

    @Test("Symlinks are followed in the middle of a path only")
    func symlinks() throws {
        let fileSystem = InMemoryFileSystem {
            File("real/file", contents: "data")
            Symlink("link", to: "real")
            Symlink("absolute", to: "/real/file")
            Symlink("loop", to: "loop")
        }

        #expect(try fileSystem.readFile(at: "/link/file", maxBytes: 10) == Array("data".utf8))
        #expect(throws: FSError.notADirectory) { try fileSystem.listDirectory(at: "/link") }
        #expect(try fileSystem.resolvingSymlinks("/link/file") == "/real/file")
        #expect(try fileSystem.resolvingSymlinks("/absolute") == "/real/file")
        #expect(throws: FSError.symlink) { try fileSystem.resolvingSymlinks("/loop") }
        #expect(fileSystem.exists(at: "/loop"))
    }

    @Test("Failures and dataless placeholders")
    func failures() throws {
        let fileSystem = InMemoryFileSystem {
            Directory("locked", failure: .permissionDenied) {
                File("secret")
            }
            Directory("broken", failure: .io(errno: EIO))
            Directory("icloud", flags: UInt32(SF_DATALESS))
            File("placeholder", flags: UInt32(SF_DATALESS))
        }

        #expect(throws: FSError.permissionDenied) { try fileSystem.listDirectory(at: "/locked") }
        #expect(!fileSystem.exists(at: "/locked/secret"))
        #expect(throws: FSError.io(errno: EIO)) { try fileSystem.listDirectory(at: "/broken") }
        #expect(throws: FSError.dataless) { try fileSystem.listDirectory(at: "/icloud") }
        #expect(throws: FSError.dataless) { try fileSystem.readFile(at: "/placeholder", maxBytes: 1) }
        #expect(try fileSystem.listDirectory(at: "/").entries.first { $0.name == "icloud" }?.isDataless == true)
    }

    private func names(_ fileSystem: InMemoryFileSystem, _ path: FilePath) throws -> [String] {
        try fileSystem.listDirectory(at: path).entries.map(\.name)
    }
}

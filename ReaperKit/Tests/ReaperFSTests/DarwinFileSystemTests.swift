import Darwin
import Foundation
import ReaperFS
import ReaperFSTesting
import System
import Testing

@Suite("DarwinFileSystem")
struct DarwinFileSystemTests {

    let fileSystem = DarwinFileSystem()

    @Test("Listed attributes match lstat(2)")
    func listedAttributesMatchLstat() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("data.bin", contents: String(repeating: "x", count: 10_000))
            File("empty")
            HardLink("data-link", to: "data.bin")
            Directory("folder") {
                File("inner")
            }
            Symlink("link", to: "folder")
        }.materialize(at: temporary.path)

        let listing = try fileSystem.listDirectory(at: temporary.path)

        #expect(listing.failures.isEmpty)
        #expect(Set(listing.entries.map(\.name)) == ["data.bin", "empty", "data-link", "folder", "link"])
        for entry in listing.entries {
            let info = try lstatInfo(temporary.path.appending(entry.name))
            #expect(entry.identity == FileIdentity(device: info.st_dev, fileID: info.st_ino))
            #expect(entry.modified == Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
            #expect(entry.flags == info.st_flags)
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                #expect(entry.kind == .file)
                #expect(entry.linkCount == UInt32(info.st_nlink))
                #expect(entry.allocatedSize == UInt64(info.st_blocks) * 512)
            case S_IFDIR:
                #expect(entry.kind == .directory)
            case S_IFLNK:
                #expect(entry.kind == .symlink)
            default:
                Issue.record("Unexpected file type for \(entry.name)")
            }
        }
        #expect(listing.entries.first { $0.name == "data.bin" }?.linkCount == 2)
    }

    @Test("Large directories need several getattrlistbulk calls")
    func largeDirectory() throws {
        let temporary = try TemporaryDirectory()
        let names = (0..<3_000).map { "file-\($0)-" + String(repeating: "n", count: 60) }
        try Tree {
            for name in names {
                File(name)
            }
        }.materialize(at: temporary.path)

        let listing = try fileSystem.listDirectory(at: temporary.path)

        #expect(listing.entries.count == names.count)
        #expect(Set(listing.entries.map(\.name)) == Set(names))
    }

    @Test("Names keep their exact bytes")
    func namesKeepTheirBytes() throws {
        let temporary = try TemporaryDirectory()
        let decomposed = "Cafe\u{301}.txt"
        try Tree {
            File(decomposed)
        }.materialize(at: temporary.path)

        let name = try #require(fileSystem.listDirectory(at: temporary.path).entries.first?.name)

        #expect(name.utf8.elementsEqual(decomposed.utf8))
    }

    @Test("Final symlinks are not followed")
    func finalSymlinksAreNotFollowed() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("folder/file", contents: "contents")
            Symlink("folder-link", to: "folder")
            Symlink("file-link", to: "folder/file")
            Symlink("dangling", to: "nowhere")
        }.materialize(at: temporary.path)

        #expect(throws: FSError.notADirectory) {
            try fileSystem.listDirectory(at: temporary.path.appending("folder-link"))
        }
        #expect(throws: FSError.symlink) {
            try fileSystem.readFile(at: temporary.path.appending("file-link"), maxBytes: 100)
        }
        #expect(fileSystem.exists(at: temporary.path.appending("dangling")))
        #expect(try fileSystem.listDirectory(at: temporary.path.appending("folder-link/../folder")).entries.map(\.name) == ["file"])
    }

    @Test("readFile stops at maxBytes")
    func readFileStopsAtMaxBytes() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("digits", contents: "0123456789")
        }.materialize(at: temporary.path)
        let path = temporary.path.appending("digits")

        #expect(try fileSystem.readFile(at: path, maxBytes: 4) == Array("0123".utf8))
        #expect(try fileSystem.readFile(at: path, maxBytes: 100) == Array("0123456789".utf8))
        #expect(try fileSystem.readFile(at: path, maxBytes: 0).isEmpty)
    }

    @Test("Errors map to FSError")
    func errors() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("file")
            Directory("locked", failure: .permissionDenied) {
                File("secret")
            }
        }.materialize(at: temporary.path)

        #expect(throws: FSError.notFound) {
            try fileSystem.listDirectory(at: temporary.path.appending("missing"))
        }
        #expect(throws: FSError.notADirectory) {
            try fileSystem.listDirectory(at: temporary.path.appending("file"))
        }
        #expect(throws: FSError.permissionDenied) {
            try fileSystem.listDirectory(at: temporary.path.appending("locked"))
        }
        #expect(throws: FSError.permissionDenied) {
            try fileSystem.readFile(at: temporary.path.appending("locked/secret"), maxBytes: 1)
        }
        #expect(!fileSystem.exists(at: temporary.path.appending("missing")))
    }
}

@Suite("DarwinFileSystem shared blocks")
struct SharedBlocksTests {

    @Test("Clones share their blocks; copies and hard links do not")
    func sharedBlocks() throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("original", contents: String(repeating: "o", count: 50_000))
            Clone("clone", of: "original")
            File("copy", contents: String(repeating: "o", count: 50_000))
            HardLink("link", to: "copy")
            Directory("folder")
        }.materialize(at: temporary.path)

        let entries = try DarwinFileSystem().listDirectory(at: temporary.path, options: .sharedBlocks).entries
        let shares = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.sharesBlocks) })

        let expected: [String: Bool?] = ["original": true, "clone": true, "copy": false, "link": false, "folder": nil]
        #expect(shares == expected)
        #expect(try DarwinFileSystem().listDirectory(at: temporary.path).entries.allSatisfy { $0.sharesBlocks == nil })
    }
}

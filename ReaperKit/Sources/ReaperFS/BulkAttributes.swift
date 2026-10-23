import Darwin
import Foundation

/// The attributes requested from getattrlistbulk(2), and the parser for the records it returns.
enum BulkAttributes {
    static let commonAttributes: attrgroup_t = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)
        | attrgroup_t(ATTR_CMN_ERROR)

    static let fileAttributes: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT)
        | attrgroup_t(ATTR_FILE_ALLOCSIZE)

    /// The attribute list for a listing, and the options to pass along with it.
    static func makeRequest(_ options: ListingOptions) -> (attrlist, UInt64) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = commonAttributes
        request.fileattr = fileAttributes
        guard options.contains(.privateSize) else {
            return (request, 0)
        }
        // With FSOPT_ATTR_CMN_EXTENDED, the fork attribute group holds extended common attributes.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        return (request, UInt64(FSOPT_ATTR_CMN_EXTENDED))
    }

    enum Record {
        case entry(EntryAttributes)
        case failure(EntryFailure)
    }

    /// Parses one record.
    ///
    /// A record starts with its length and the set of attributes actually returned. The error
    /// comes next, then the common attributes in bit order, then the file attributes, then the
    /// extended common attributes. An attribute is present only if its bit is set in the
    /// returned set; for example, directories carry no file attributes.
    static func parse(_ record: UnsafeRawBufferPointer) -> Record {
        var reader = RecordReader(record)
        _ = reader.read(UInt32.self)
        let returned = reader.read(attribute_set_t.self)

        func has(_ attribute: Int32, in group: attrgroup_t) -> Bool {
            group & attrgroup_t(attribute) != 0
        }

        var error: UInt32 = 0
        if has(ATTR_CMN_ERROR, in: returned.commonattr) {
            error = reader.read(UInt32.self)
        }
        var name = ""
        if has(ATTR_CMN_NAME, in: returned.commonattr) {
            name = reader.readName()
        }
        if error != 0 {
            return .failure(EntryFailure(name: name, error: FSError(errno: Int32(error))))
        }

        var device: dev_t = 0
        if has(ATTR_CMN_DEVID, in: returned.commonattr) {
            device = reader.read(dev_t.self)
        }
        var kind = EntryKind.other
        if has(ATTR_CMN_OBJTYPE, in: returned.commonattr) {
            kind = EntryKind(objectType: reader.read(fsobj_type_t.self))
        }
        var modified = Date(timeIntervalSince1970: 0)
        if has(ATTR_CMN_MODTIME, in: returned.commonattr) {
            let time = reader.read(timespec.self)
            modified = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        }
        var flags: UInt32 = 0
        if has(ATTR_CMN_FLAGS, in: returned.commonattr) {
            flags = reader.read(UInt32.self)
        }
        var fileID: UInt64 = 0
        if has(ATTR_CMN_FILEID, in: returned.commonattr) {
            fileID = reader.read(UInt64.self)
        }
        // Symlinks and other non-directories carry file attributes too; keep them for files only.
        var linkCount: UInt32 = 1
        if has(ATTR_FILE_LINKCOUNT, in: returned.fileattr) {
            let value = reader.read(UInt32.self)
            if kind == .file { linkCount = value }
        }
        var allocatedSize: UInt64 = 0
        if has(ATTR_FILE_ALLOCSIZE, in: returned.fileattr) {
            let value = UInt64(reader.read(off_t.self))
            if kind == .file { allocatedSize = value }
        }
        var privateSize: UInt64?
        if has(ATTR_CMNEXT_PRIVATESIZE, in: returned.forkattr) {
            let value = UInt64(reader.read(off_t.self))
            if kind == .file { privateSize = value }
        }

        return .entry(EntryAttributes(
            name: name,
            kind: kind,
            identity: FileIdentity(device: device, fileID: fileID),
            modified: modified,
            flags: flags,
            linkCount: linkCount,
            allocatedSize: allocatedSize,
            privateSize: privateSize
        ))
    }
}

/// Reads packed attributes front to back. Fields are not necessarily aligned for their type.
private struct RecordReader {

    let bytes: UnsafeRawBufferPointer
    var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func read<T>(_: T.Type) -> T {
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
        return value
    }

    /// Reads an `attrreference_t` and the NUL-terminated name it points to. The reference's
    /// offset is relative to the reference itself.
    mutating func readName() -> String {
        let referenceOffset = offset
        let reference = read(attrreference_t.self)
        let start = referenceOffset + Int(reference.attr_dataoffset)
        let length = max(Int(reference.attr_length) - 1, 0)
        guard start >= 0, start + length <= bytes.count else {
            return ""
        }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<start + length]), as: UTF8.self)
    }
}

private extension EntryKind {

    init(objectType: fsobj_type_t) {
        switch objectType {
        case VDIR.rawValue: self = .directory
        case VREG.rawValue: self = .file
        case VLNK.rawValue: self = .symlink
        default: self = .other
        }
    }
}

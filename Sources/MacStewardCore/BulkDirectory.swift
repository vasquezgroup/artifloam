import Darwin
import Foundation

/// One directory entry as `getattrlistbulk` reports it: one system call per batch of entries instead of a stat per file.
/// Symlinks are reported as links, never followed. Byte values match `stat`: `allocated` is `st_blocks * 512`
/// (the same as `totalFileAllocatedSize`) and `logical` is `st_size`.
struct BulkEntry {
    let name: String
    let type: UInt32
    let device: dev_t
    let fileID: UInt64
    let flags: UInt32
    let allocated: UInt64
    let logical: UInt64
    var isDirectory: Bool { type == VDIR.rawValue }
    var isSymlink: Bool { type == VLNK.rawValue }
    var isRegular: Bool { type == VREG.rawValue }
    /// FileManager leaves out AppleDouble files ("._name") that are not folders; listings here do the same,
    /// so sizes and maps match what the Foundation-based code measured.
    var hiddenByFoundation: Bool { !isDirectory && name.hasPrefix("._") }
}

/// Lists the directory open at `fd`. `complete` is false when reading stopped part-way; the entries read so far are returned.
/// Entries the filesystem could not describe fully are completed with `fstatat`, or left out when even that fails.
func bulkEntries(_ fd: Int32) -> (entries: [BulkEntry], complete: Bool) {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
    request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE) | attrgroup_t(ATTR_FILE_DATALENGTH)
    let size = 64 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buffer.deallocate() }
    var entries = [BulkEntry]()
    while true {
        let count = getattrlistbulk(fd, &request, buffer, size, 0)
        if count == 0 { return (entries, true) }
        if count < 0 { return (entries, false) }
        var entry = buffer
        for _ in 0..<count {
            let length = Int(entry.loadUnaligned(as: UInt32.self))
            defer { entry += length }
            var field = entry + 4
            let returned = field.loadUnaligned(as: attribute_set_t.self); field += MemoryLayout<attribute_set_t>.size
            func has(_ bit: Int32) -> Bool { returned.commonattr & attrgroup_t(bit) != 0 }
            func hasFile(_ bit: Int32) -> Bool { returned.fileattr & attrgroup_t(bit) != 0 }
            var failed = false
            if has(ATTR_CMN_ERROR) { failed = field.loadUnaligned(as: UInt32.self) != 0; field += 4 }
            guard has(ATTR_CMN_NAME) else { continue }
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            field += MemoryLayout<attrreference_t>.size
            var device: dev_t?, type: UInt32?, flags: UInt32?, fileID: UInt64?, allocated: UInt64?, logical: UInt64?
            if has(ATTR_CMN_DEVID) { device = field.loadUnaligned(as: dev_t.self); field += MemoryLayout<dev_t>.size }
            if has(ATTR_CMN_OBJTYPE) { type = field.loadUnaligned(as: fsobj_type_t.self); field += MemoryLayout<fsobj_type_t>.size }
            if has(ATTR_CMN_FLAGS) { flags = field.loadUnaligned(as: UInt32.self); field += 4 }
            if has(ATTR_CMN_FILEID) { fileID = field.loadUnaligned(as: UInt64.self); field += 8 }
            if hasFile(ATTR_FILE_ALLOCSIZE) { allocated = UInt64(max(0, field.loadUnaligned(as: off_t.self))); field += 8 }
            if hasFile(ATTR_FILE_DATALENGTH) { logical = UInt64(max(0, field.loadUnaligned(as: off_t.self))); field += 8 }
            let regular = type == VREG.rawValue
            if failed || device == nil || type == nil || type == VNON.rawValue || flags == nil || fileID == nil || (regular && (allocated == nil || logical == nil)) {
                // The filesystem left something out: ask for this one entry the classic way.
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let mode = info.st_mode & S_IFMT
                let vtype = mode == S_IFDIR ? VDIR : mode == S_IFREG ? VREG : mode == S_IFLNK ? VLNK : VBAD
                entries.append(BulkEntry(name: name, type: vtype.rawValue, device: info.st_dev, fileID: info.st_ino, flags: info.st_flags,
                                         allocated: UInt64(max(0, info.st_blocks)) * 512, logical: UInt64(max(0, info.st_size))))
                continue
            }
            entries.append(BulkEntry(name: name, type: type!, device: device!, fileID: fileID!, flags: flags!, allocated: allocated ?? 0, logical: logical ?? 0))
        }
    }
}

/// Allocated bytes of every non-directory, non-symlink item below `url`, like summing `totalFileAllocatedSize`
/// over a directory enumeration. Symlinks are never followed; folders that cannot be read count what was read.
func directoryBytes(_ url: URL) -> UInt64 {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { return 0 }
    return directoryBytes(fd: fd)
}
/// Takes ownership of `fd`.
func directoryBytes(fd: Int32) -> UInt64 {
    defer { close(fd) }
    var bytes: UInt64 = 0
    for entry in bulkEntries(fd).entries where !entry.hiddenByFoundation {
        if Task.isCancelled { break }
        if entry.isDirectory {
            let child = openat(fd, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if child >= 0 { bytes += directoryBytes(fd: child) }
        } else if !entry.isSymlink { bytes += entry.allocated }
    }
    return bytes
}

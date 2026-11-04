import Foundation
import Darwin

/// Capability gate only. This does not establish directory identity by itself.
/// Callers still require the continuously held directory descriptor, fresh-path
/// agreement, unchanged access metadata, and complete payload verification.
enum FilesystemPublicationCapabilities {
    static func allowsDirectoryInodeCanonicalization(descriptor: Int32) -> Bool {
        var entry = stat()
        guard descriptor >= 0, fstat(descriptor, &entry) == 0,
              entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { return false }
        let name = withUnsafeBytes(of: filesystem.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard name == "smbfs" else { return false }
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES)
        var buffer = VolumeCapabilitiesBuffer()
        guard fgetattrlist(descriptor, &request, &buffer, MemoryLayout<VolumeCapabilitiesBuffer>.size, 0) == 0,
              buffer.length == MemoryLayout<VolumeCapabilitiesBuffer>.size else { return false }
        return allowsDirectoryInodeCanonicalization(fileSystemName: name,
            formatCapabilities: buffer.values.capabilities.0, formatValid: buffer.values.valid.0)
    }

    /// The public valid bit must explicitly say the persistence result is known.
    /// An unavailable result must never be interpreted as lack of persistence.
    static func allowsDirectoryInodeCanonicalization(fileSystemName: String,
                                                     formatCapabilities: UInt32,
                                                     formatValid: UInt32) -> Bool {
        let persistentIDs = UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS)
        return fileSystemName == "smbfs" && formatValid & persistentIDs != 0 &&
            formatCapabilities & persistentIDs == 0
    }

    private struct VolumeCapabilitiesBuffer {
        var length: UInt32 = 0
        var values = vol_capabilities_attr_t()
    }
}

import Foundation
import MachO

/// A loaded Mach-O image in the running process: its name, debug UUID, and load
/// address. This is the producer counterpart to the backend's `MachoReader` — the
/// UUID matches the crashing image to its uploaded dSYM, and `imageAddr` lets the
/// backend compute the static address llvm-symbolizer expects.
/// Matches the backend ingest `debugMeta.images[]` contract (Jackson camelCase:
/// `type`, `debugId`, `imageAddr`, `codeFile`).
public struct AllStakBinaryImage: Codable, Sendable, Equatable {
    /// Image kind — "macho" for Apple platforms.
    public let type: String
    /// Debug identifier (Mach-O LC_UUID), uppercase-hyphenated to match the dSYM.
    public let debugId: String
    /// Image load address at runtime, hex (e.g. "0x102000000").
    public let imageAddr: String
    /// On-disk path of the image.
    public let codeFile: String

    init(debugId: String, imageAddr: String, codeFile: String) {
        self.type = "macho"
        self.debugId = debugId
        self.imageAddr = imageAddr
        self.codeFile = codeFile
    }
}

/// Reads the running process's loaded images (via dyld) and their debug UUIDs.
public enum BinaryImageProvider {

    /// All currently-loaded images that carry a debug UUID.
    public static func current() -> [AllStakBinaryImage] {
        var images: [AllStakBinaryImage] = []
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let headerPtr = _dyld_get_image_header(i),
                  let namePtr = _dyld_get_image_name(i) else { continue }
            guard let uuid = uuid(fromHeader: headerPtr) else { continue }
            let loadAddr = UInt(bitPattern: headerPtr)
            images.append(AllStakBinaryImage(
                debugId: uuid,
                imageAddr: "0x" + String(loadAddr, radix: 16),
                codeFile: String(cString: namePtr)
            ))
        }
        return images
    }

    /// The image containing a given runtime instruction address (for per-frame mapping).
    public static func image(forAddress address: UInt) -> AllStakBinaryImage? {
        // Best-effort: the image with the greatest load address <= the instruction
        // address. dyld doesn't expose per-image sizes cheaply, so this is a close
        // approximation that the backend refines using the dSYM's segments.
        var best: (addr: UInt, image: AllStakBinaryImage)?
        for image in current() {
            let load = UInt(image.imageAddr.dropFirst(2), radix: 16) ?? 0
            if load <= address, best == nil || load > best!.addr {
                best = (load, image)
            }
        }
        return best?.image
    }

    /// Walk the Mach-O load commands to find LC_UUID. 64-bit images only.
    private static func uuid(fromHeader header: UnsafePointer<mach_header>) -> String? {
        let raw = UnsafeRawPointer(header)
        let header64 = raw.assumingMemoryBound(to: mach_header_64.self)
        let magic = header64.pointee.magic
        guard magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else { return nil }

        var cursor = raw.advanced(by: MemoryLayout<mach_header_64>.size)
        let ncmds = Int(header64.pointee.ncmds)
        for _ in 0..<ncmds {
            let lc = cursor.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == LC_UUID {
                let uuidCmd = cursor.assumingMemoryBound(to: uuid_command.self).pointee
                return UUID(uuid: uuidCmd.uuid).uuidString
            }
            guard lc.cmdsize >= UInt32(MemoryLayout<load_command>.size) else { return nil }
            cursor = cursor.advanced(by: Int(lc.cmdsize))
        }
        return nil
    }
}

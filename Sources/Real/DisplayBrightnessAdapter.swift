import CoreGraphics
import Darwin
import Foundation
import MachO

/// Optional, narrowly versioned bridge to Apple's private DisplayServices image.
///
/// ABI evidence: inspected Apple's installed arm64 machine code on macOS 26.6.2
/// (25G83), image UUID 0AE066F1-6087-3373-9CD4-8AED1AE7ECD4. GetBrightness takes
/// the display ID in w0 and an output pointer in x1, obtains NSNumber.floatValue,
/// stores s0 through that pointer, and returns 0 or 1000 in x0. SetBrightness takes
/// the display ID in w0 and a Float in s0, calls NSNumber.initWithFloat:, and
/// returns 0 or 1000. No third-party declaration or implementation is used.
///
/// These are PRIVATE, unsupported Apple APIs. A different architecture or image
/// UUID is deliberately unsupported until its ABI is independently revalidated.
/// Symbol presence alone is never treated as proof of a compatible signature.
/// No brightness writes occur while loading or reading this adapter.
@MainActor
enum DisplayBrightnessAdapter {
    private typealias ReadFunction = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias WriteFunction = @convention(c) (UInt32, Float) -> Int32
    private static let inspectedImageUUID = "0ae066f1608733739cd48aed1ae7ecd4"
    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private final class Library {
        let handle: UnsafeMutableRawPointer
        let get: ReadFunction
        let set: WriteFunction
        init(handle: UnsafeMutableRawPointer, get: ReadFunction, set: WriteFunction) {
            self.handle = handle
            self.get = get
            self.set = set
        }
        deinit { dlclose(handle) }
    }
    private static let library: Library? = load()

    static func read(displayID: CGDirectDisplayID) -> Double? {
        guard displayID != kCGNullDirectDisplay, CGDisplayIsOnline(displayID) != 0,
              let library else { return nil }
        var result = Float.nan
        guard library.get(displayID, &result) == 0,
              result.isFinite, (0...1).contains(result) else { return nil }
        return Double(result)
    }

    /// The caller must invoke this only for an explicit user brightness action.
    /// Readback confirms the requested scalar; unsupported/error cases return false.
    static func write(displayID: CGDirectDisplayID, value: Double) -> Bool {
        guard value.isFinite, (0...1).contains(value),
              displayID != kCGNullDirectDisplay, CGDisplayIsOnline(displayID) != 0,
              let library, read(displayID: displayID) != nil else { return false }
        guard library.set(displayID, Float(value)) == 0,
              let actual = read(displayID: displayID) else { return false }
        return abs(actual - value) <= 0.02
    }

    private static func load() -> Library? {
#if os(macOS) && arch(arm64)
        guard let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness"),
              imageUUID(containing: getSymbol) == inspectedImageUUID,
              imageUUID(containing: setSymbol) == inspectedImageUUID else {
            dlclose(handle)
            return nil
        }
        return Library(handle: handle,
                       get: unsafeBitCast(getSymbol, to: ReadFunction.self),
                       set: unsafeBitCast(setSymbol, to: WriteFunction.self))
#else
        return nil
#endif
    }

    /// Reads only the Mach-O header/load commands of the image already identified
    /// by dladdr. All command offsets and sizes are bounded before dereferencing.
    private static func imageUUID(containing symbol: UnsafeMutableRawPointer) -> String? {
        var info = Dl_info()
        guard dladdr(symbol, &info) != 0, let base = info.dli_fbase,
              let name = info.dli_fname,
              String(cString: name).contains("/DisplayServices.framework/") else { return nil }
        let pointer = UnsafeRawPointer(base)
        let header = pointer.load(as: mach_header_64.self)
        guard header.magic == MH_MAGIC_64, header.cputype == CPU_TYPE_ARM64,
              header.ncmds > 0, header.ncmds <= 4096,
              header.sizeofcmds >= MemoryLayout<load_command>.size,
              header.sizeofcmds <= 1_048_576 else { return nil }
        let commandStart = MemoryLayout<mach_header_64>.size
        let commandEnd = commandStart + Int(header.sizeofcmds)
        var offset = commandStart
        for _ in 0..<header.ncmds {
            guard offset <= commandEnd - MemoryLayout<load_command>.size else { return nil }
            let command = pointer.advanced(by: offset).load(as: load_command.self)
            let size = Int(command.cmdsize)
            guard size >= MemoryLayout<load_command>.size, size <= commandEnd - offset else { return nil }
            if command.cmd == LC_UUID {
                guard size >= MemoryLayout<uuid_command>.size else { return nil }
                var command = pointer.advanced(by: offset).load(as: uuid_command.self)
                return withUnsafeBytes(of: &command.uuid) { bytes in
                    bytes.map { String(format: "%02x", $0) }.joined()
                }
            }
            offset += size
        }
        return nil
    }
}

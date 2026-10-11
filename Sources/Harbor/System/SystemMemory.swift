import Darwin
import Foundation

enum Pressure: Int, Equatable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct MemorySnapshot: Equatable {
    var physical: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// Activity Monitor's "App Memory": anonymous pages minus purgeable.
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File-backed pages plus purgeable: macOS drops these when it needs room.
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Pressure = .normal

    var used: UInt64 { app + wired + compressed }
    /// Swap counts as "heavy" once it passes half of physical RAM.
    var swapIsHeavy: Bool { swapUsed > physical / 2 }
}

enum SystemMemory {
    private static let host = mach_host_self()

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        return UInt64(size)
    }()

    static func read() -> MemorySnapshot {
        var snap = MemorySnapshot()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let p = pageSize
            let anon = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            snap.app = (anon > purgeable ? anon - purgeable : 0) * p
            snap.wired = UInt64(stats.wire_count) * p
            snap.compressed = UInt64(stats.compressor_page_count) * p
            snap.cached = (UInt64(stats.external_page_count) + purgeable) * p
            let accounted = snap.app + snap.wired + snap.compressed + snap.cached
            snap.free = snap.physical > accounted ? snap.physical - accounted : 0
        }
        let (total, used) = swap()
        snap.swapTotal = total
        snap.swapUsed = used
        snap.pressure = pressureLevel()
        return snap
    }

    static func swap() -> (total: UInt64, used: UInt64) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return (0, 0) }
        return (xsw.xsu_total, xsw.xsu_used)
    }

    static func pressureLevel() -> Pressure {
        guard let v = LibProc.sysctlInt("kern.memorystatus_vm_pressure_level") else { return .normal }
        return Pressure(rawValue: v) ?? (v >= 4 ? .critical : v >= 2 ? .warning : .normal)
    }
}

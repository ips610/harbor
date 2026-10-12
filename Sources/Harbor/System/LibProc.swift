import Darwin
import Foundation

/// Thin wrappers over libproc and sysctl. Everything here is an in-process
/// system call: harbor never spawns `ps`, `lsof`, `top` or `netstat`.
enum LibProc {
    static let myUID = getuid()

    /// Every pid on the system (zombies included).
    static func allPids() -> [pid_t] {
        var capacity = 4096
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let n = pids.withUnsafeMutableBytes { buf in
                proc_listallpids(buf.baseAddress, Int32(buf.count))
            }
            if n <= 0 { return [] }
            if Int(n) < capacity {
                pids.removeLast(capacity - Int(n))
                return pids
            }
            capacity *= 2
        }
    }

    /// Short BSD info works for every process, whoever owns it, and for zombies.
    static func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) > 0 ? info : nil
    }

    /// Full BSD info (start time etc.). Only readable for the user's own processes.
    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) > 0 ? info : nil
    }

    /// kinfo_proc via sysctl(KERN_PROC_PID). On current macOS proc_pidinfo
    /// answers ESRCH for zombies, but this still reports them (p_stat SZOMB).
    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &len, nil, 0) == 0, len > 0 else { return nil }
        return kp
    }

    /// The user a process runs as.
    static func owner(_ pid: pid_t) -> uid_t? { kinfo(pid)?.kp_eproc.e_ucred.cr_uid }

    /// (uid, parent) if `pid` is a zombie that proc_pidinfo can't see.
    static func zombieViaSysctl(_ pid: pid_t) -> (uid: uid_t, ppid: pid_t)? {
        guard let kp = kinfo(pid), Int32(kp.kp_proc.p_stat) == SZOMB else { return nil }
        return (kp.kp_eproc.e_ucred.cr_uid, kp.kp_eproc.e_ppid)
    }

    static func startDate(_ pid: pid_t) -> Date? {
        guard let b = bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: Double(b.pbi_start_tvsec) + Double(b.pbi_start_tvusec) / 1_000_000)
    }

    /// A cheap identity for pid-reuse checks: the start time when we can read it
    /// (own processes), else the executable path. "" when neither is known, so
    /// an unknown-then-unknown pid matches and isn't refused by mistake.
    static func identity(_ pid: pid_t) -> String {
        if let b = bsdInfo(pid) { return "t\(b.pbi_start_tvsec).\(b.pbi_start_tvusec)" }
        return path(pid).map { "p" + $0 } ?? ""
    }

    /// Executable path. Readable for any process.
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let r = proc_name(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Resource usage (memory footprint, CPU time). Own processes only.
    static func usage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let r: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info : nil
    }

    /// Current working directory. Own processes only.
    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        let s = cString(info.pvi_cdir.vip_path)
        return s.isEmpty ? nil : s
    }

    /// argv of a process via sysctl KERN_PROCARGS2. Own processes only.
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < Int(argc) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// How a process was started, from the same sysctl: the path that was exec'd, its argv,
    /// and the environment it was given ("NAME=value" strings). Own processes only.
    static func launch(_ pid: pid_t) -> (exec: String, arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        return launch(in: Array(buf[..<size]))
    }

    /// The same, from the bytes the kernel hands out: argc, the exec path, padding, argc
    /// strings of argv, then the environment's strings up to the first empty one.
    static func launch(in buf: [UInt8]) -> (exec: String, arguments: [String], environment: [String])? {
        guard buf.count > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = 4
        func next() -> String? {
            guard i < buf.count else { return nil }
            let start = i
            while i < buf.count && buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        guard let exec = next(), !exec.isEmpty else { return nil }
        while i < buf.count && buf[i] == 0 { i += 1 }   // padding
        var arguments: [String] = [], environment: [String] = []
        while arguments.count < Int(argc), let argument = next() { arguments.append(argument) }
        guard arguments.count == Int(argc) else { return nil }
        while let entry = next(), !entry.isEmpty { environment.append(entry) }
        return (exec, arguments, environment)
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let end = raw.firstIndex(of: 0) ?? raw.count
            return String(decoding: raw[..<end], as: UTF8.self)
        }
    }

    // MARK: - Listening TCP sockets

    struct RawListener {
        let pid: pid_t
        let port: UInt16
        let address: String
        let scope: AddressScope
        let socketID: UInt64
    }

    /// Listening TCP sockets held by `pid`, read from its file-descriptor table.
    static func listeners(pid: pid_t, fds: inout [proc_fdinfo]) -> [RawListener] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var count = 0
        while true {
            let bytes = fds.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if bytes <= 0 { return [] }
            count = Int(bytes) / stride
            if count < fds.count || fds.count >= 65536 { break }
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fds.count * 2)
        }
        var out: [RawListener] = []
        var si = socket_fdinfo()
        let siSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        let socketType = UInt32(PROX_FDTYPE_SOCKET)
        for i in 0..<count {
            let fd = fds[i]
            guard fd.proc_fdtype == socketType else { continue }
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) > 0 else { continue }
            guard Int(si.psi.soi_kind) == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            // insi_lport holds the port in network byte order.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let (address, scope) = describe(family: si.psi.soi_family, ini: ini)
            out.append(RawListener(pid: pid, port: port, address: address, scope: scope, socketID: si.psi.soi_so))
        }
        return out
    }

    private static func describe(family: Int32, ini: in_sockinfo) -> (String, AddressScope) {
        if family == AF_INET6 {
            var a6 = ini.insi_laddr.ina_6
            let b = withUnsafeBytes(of: a6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return ("all interfaces", .all) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return ("::1", .loopback) }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                // IPv4-mapped address
                let v4 = "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
                if v4 == "0.0.0.0" { return ("all interfaces", .all) }
                return (v4, b[12] == 127 ? .loopback : .specific)
            }
            return (ntop(AF_INET6, &a6), .specific)
        } else {
            var a4 = ini.insi_laddr.ina_46.i46a_addr4
            if a4.s_addr == 0 { return ("all interfaces", .all) }
            let first = withUnsafeBytes(of: a4) { $0[0] }
            return (ntop(AF_INET, &a4), first == 127 ? .loopback : .specific)
        }
    }

    private static func ntop(_ family: Int32, _ addr: UnsafeRawPointer) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, addr, &buf, socklen_t(buf.count)) != nil else { return "?" }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: - sysctl helpers

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: - Time

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// rusage CPU times are in Mach absolute-time ticks on Apple silicon.
    static func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        if timebase.numer == timebase.denom { return ticks }
        return ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
            + (ticks % UInt64(timebase.denom)) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func monotonicNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}

enum AddressScope: Int, Hashable {
    case loopback, all, specific
}

// MARK: - Responsible process (XPC services → owning app)

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

extension LibProc {
    /// The app macOS holds responsible for `pid` (e.g. Safari for a WebContent
    /// XPC service, Docker for its virtual machine). Nil if unknown.
    static func responsiblePid(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    /// The outermost `.app` bundle containing `path`, unless that bundle is
    /// buried inside a framework (Python.app inside Python.framework is a
    /// command-line tool, not an app).
    static func appBundle(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        if bundle.contains(".framework/") { return nil }
        return bundle
    }

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/usr/lib/"]

    /// Part of macOS itself: harbor never offers to quit these.
    static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return true }
        // Mail, Safari, Terminal… live under /System/Applications but are ordinary apps.
        if path.contains("/System/Applications/") { return false }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }
}

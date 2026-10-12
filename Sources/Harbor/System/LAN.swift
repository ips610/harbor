import Foundation
import SystemConfiguration

/// This Mac's address on the local network, for "open it on your phone".
enum LAN {
    /// The interface of the default route (en0, en1…), from SystemConfiguration.
    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "harbor" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return global["PrimaryInterface"] as? String
    }

    private static func isPrivate(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") { return true }
        let parts = ip.split(separator: ".")
        return parts.count == 4 && parts[0] == "172" && (16...31).contains(Int(parts[1]) ?? 0)
    }

    /// The network this Mac is on: the default route's interface, this Mac's address on it,
    /// the router, and the router's hardware address once macOS has it. Sharing on the
    /// network is tied to it. Two networks often have the same router address (192.168.1.1 at
    /// home and in the café), so the hardware address is what tells them apart.
    struct Network: Equatable {
        let interface: String
        let address: String
        let router: String?
        var routerHardware: String? = nil
    }

    static func current() -> Network? {
        guard let store = SCDynamicStoreCreate(nil, "harbor" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String, let address = ipv4(on: interface) else { return nil }
        let service = (global["PrimaryService"] as? String).flatMap {
            SCDynamicStoreCopyValue(store, "State:/Network/Service/\($0)/IPv4" as CFString) as? [String: Any]
        }
        return Network(interface: interface, address: address, router: global["Router"] as? String,
                       routerHardware: service?["ARPResolvedHardwareAddress"] as? String)
    }

    /// An IPv4 address other devices can use: up, running, not loopback, not
    /// link-local; the default route's interface first, private ranges first.
    static func ipv4() -> String? { ipv4(on: nil) }

    private static func ipv4(on only: String?) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        let primary = primaryInterface()
        var found: [(rank: (Int, Int), ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            cursor = item.pointee.ifa_next
            let flags = Int32(item.pointee.ifa_flags)
            guard let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { continue }
            let ip = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if ip.hasPrefix("169.254.") { continue }
            let name = String(cString: item.pointee.ifa_name)
            if let only, name != only { continue }
            found.append(((name == primary ? 0 : 1, isPrivate(ip) ? 0 : 1), ip))
        }
        return found.min { $0.rank < $1.rank }?.ip
    }

    /// The Bonjour name, e.g. "Ishpuneets-MacBook-Pro.local".
    static func bonjourName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    // MARK: Application firewall (read only, never changed)

    private static let lock = NSLock()
    private static var firewall: (on: Bool, at: Date)?

    /// Cached for five minutes; refreshed in the background, so callers never wait.
    static var firewallOn: Bool {
        lock.lock()
        let cached = firewall
        lock.unlock()
        if cached == nil || Date().timeIntervalSince(cached!.at) > 300 {
            DispatchQueue.global(qos: .utility).async { refreshFirewall() }
        }
        return cached?.on ?? false
    }

    private static func refreshFirewall() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        p.arguments = ["--getglobalstate"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        p.waitUntilExit()
        let on = out.contains("enabled") || out.contains("state = 1") || out.contains("state = 2")
        lock.lock()
        firewall = (on && !out.contains("disabled"), Date())
        lock.unlock()
    }
}

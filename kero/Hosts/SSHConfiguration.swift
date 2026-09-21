import Darwin
import Foundation

nonisolated enum SSHConfiguration {
    private static let defaultAlgorithms: [String: String] = {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null", "localhost"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }()
    /// OpenSSH resolves its own config syntax (Include, Host and Match). Only
    /// configuration is read; all network I/O uses Kero's native Rust engine.
    static func resolve(destination: String, port: UInt16?, depth: Int = 0) throws -> [String: Any] {
        guard depth < 8, !destination.isEmpty, !destination.hasPrefix("-") else {
            throw DaemonWire.Failure("Invalid SSH destination or jump chain")
        }
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + (port.map { ["-p", String($0)] } ?? []) + [destination]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Match exec can run an arbitrary helper. Keep config resolution
        // cancellable and bounded even if that helper holds stdout open.
        let handle = out.fileHandleForReading
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            process.terminate()
            throw DaemonWire.Failure("Cannot read SSH configuration")
        }
        defer { try? handle.close() }
        let deadline = Date().addingTimeInterval(10)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16384)
        var eof = false
        while true {
            if Task.isCancelled || Date() >= deadline || data.count > 1024 * 1024 {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw DaemonWire.Failure(
                    Task.isCancelled
                        ? "SSH configuration cancelled"
                        : "SSH configuration exceeded its time or output limit")
            }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                eof = true
            } else if errno != EAGAIN && errno != EINTR {
                if process.isRunning { process.terminate() }
                throw DaemonWire.Failure("Cannot read SSH configuration")
            }
            if eof && !process.isRunning { break }
            if count <= 0 { usleep(5000) }
        }
        guard process.terminationStatus == 0 else {
            throw DaemonWire.Failure("Cannot resolve SSH configuration for \(destination)")
        }
        var fields: [String: [String]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0]), default: []].append(String(pair[1])) }
        }
        func value(_ key: String) -> String? { fields[key]?.first }
        for field in [
            "proxycommand", "knownhostscommand", "remotecommand", "certificatefile", "localforward",
            "remoteforward", "dynamicforward",
        ] {
            if let setting = value(field), setting != "none", !setting.isEmpty {
                throw DaemonWire.Failure(
                    "SSH option \(field) is not supported by Kero; use ProxyJump or remove it from this host configuration."
                )
            }
        }
        if let setting = value("identityagent"), !["SSH_AUTH_SOCK", "none"].contains(setting) {
            throw DaemonWire.Failure("Custom IdentityAgent sockets are not supported")
        }
        if let alias = value("hostkeyalias"), alias != "none" {
            throw DaemonWire.Failure("HostKeyAlias is not supported")
        }
        if let paths = value("userknownhostsfile") {
            let files = paths.split(separator: " ").map {
                ($0.description as NSString).expandingTildeInPath
            }
            let supported = [
                NSHomeDirectory() + "/.ssh/known_hosts", NSHomeDirectory() + "/.ssh/known_hosts2",
            ]
            if files.contains(where: { !supported.contains($0) }) {
                throw DaemonWire.Failure("Custom UserKnownHostsFile is not supported")
            }
        }
        for flag in ["forwardx11", "gssapiauthentication", "batchmode"] where value(flag) == "yes" {
            throw DaemonWire.Failure("SSH option \(flag) is not supported")
        }
        let host = value("hostname") ?? destination
        let user = value("user") ?? NSUserName()
        let identities = (fields["identityfile"] ?? []).filter { $0 != "none" }.map {
            ($0 as NSString).expandingTildeInPath.replacingOccurrences(of: "%h", with: host)
                .replacingOccurrences(of: "%r", with: user).replacingOccurrences(
                    of: "%d", with: NSHomeDirectory())
        }
        var spec: [String: Any] = [
            "host": host, "port": UInt16(value("port") ?? "22") ?? 22, "user": user,
            "auth_mode": value("identitiesonly") == "yes" || value("identityagent") == "none"
                ? "public-key" : "auto", "identity_files": identities, "verify_host_keys": true,
            "connect_timeout_s": UInt32(value("connecttimeout") ?? "10") ?? 10,
            "keepalive_interval_s": UInt32(value("serveraliveinterval") ?? "15") ?? 15,
            "keepalive_count_max": UInt32(value("serveralivecountmax") ?? "3") ?? 3,
            "agent_forward": value("forwardagent") == "yes",
        ]
        var algorithms: [String: [String]] = [:]
        for (field, key) in [
            ("kexalgorithms", "kex"), ("ciphers", "cipher"), ("macs", "mac"),
            ("hostkeyalgorithms", "host_key"),
        ] {
            if let list = value(field), list != defaultAlgorithms[field] {
                algorithms[key] = list.split(separator: ",").map(String.init)
            }
        }
        if value("compression") == "yes" { algorithms["compression"] = ["zlib@openssh.com", "none"] }
        spec["algorithms"] = algorithms
        if value("pubkeyauthentication") == "no" {
            spec["auth_mode"] =
                value("passwordauthentication") == "no" ? "keyboard-interactive" : "password"
        }
        if let jumps = value("proxyjump"), jumps != "none" {
            var chain: [String: Any]?
            for jump in jumps.split(separator: ",") {
                var hop = String(jump)
                var hopPort: UInt16?
                if let colon = hop.lastIndex(of: ":"), let number = UInt16(hop[hop.index(after: colon)...]),
                    !hop.contains("]")
                {
                    hopPort = number
                    hop = String(hop[..<colon])
                }
                var resolved = try resolve(destination: hop, port: hopPort, depth: depth + 1)
                if let chain { resolved["jump"] = chain }
                chain = resolved
            }
            spec["jump"] = chain
        }
        return spec
    }
}

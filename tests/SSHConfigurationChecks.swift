import Foundation

struct DaemonWire {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@main struct SSHConfigurationChecks {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-ssh-config-\(UUID().uuidString)", isDirectory: true)
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try Data("""
        Host custom-known-hosts
          HostName 127.0.0.1
          User deploy
          UserKnownHostsFile /tmp/kero-first ~/.ssh/kero-second

        Host token-known-hosts
          HostName fixture.example
          User deploy
          UserKnownHostsFile ~/.ssh/known_%h
        """.utf8).write(to: sshDirectory.appendingPathComponent("config"))
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        do {
            let spec = try SSHConfiguration.resolve(
                destination: "custom-known-hosts", port: nil, configPath: sshDirectory.path + "/config")
            let files = spec["known_hosts_files"] as? [String]
            precondition(
                files == ["/tmp/kero-first", NSHomeDirectory() + "/.ssh/kero-second"],
                "expected resolved custom known_hosts files, got \(String(describing: files))")
        }

        do {
            let spec = try SSHConfiguration.resolve(
                destination: "token-known-hosts", port: nil, configPath: sshDirectory.path + "/config")
            let files = spec["known_hosts_files"] as? [String]
            precondition(
                files == [NSHomeDirectory() + "/.ssh/known_fixture.example"],
                "expected host token expansion, got \(String(describing: files))")
        }

        print("PASS: ssh_config custom UserKnownHostsFile resolution")
    }
}

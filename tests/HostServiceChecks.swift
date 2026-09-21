import Foundation

@main struct HostServiceChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("pass the explicitly connected host socket") }
        let service=HostService(hostID:UUID(),socketPath:CommandLine.arguments[1])
        let root="/tmp/kero-host-service-\(UUID().uuidString)"
        let path=root+"/same-name.txt"
        try FileManager.default.createDirectory(atPath:root,withIntermediateDirectories:false)
        try Data("LOCAL_UNCHANGED".utf8).write(to:URL(fileURLWithPath:path))
        defer {try? FileManager.default.removeItem(atPath:root)}
        _=try service.request("create_directory",path:root)
        defer {_=try? service.request("remove",path:root,fields:["recursive":true]);service.invalidate()}
        _=try service.request("create_file",path:path)
        let empty=try service.read(path)
        let saved=try service.write(path,data:Data("remote 中文\n".utf8),expected:empty.sha256)
        let reread=try service.read(path);precondition(reread.sha256 == saved)
        let local=try Data(contentsOf:URL(fileURLWithPath:path));precondition(local == Data("LOCAL_UNCHANGED".utf8))
        do {_=try service.write(path,data:Data("stale".utf8),expected:empty.sha256);fatalError("stale save accepted")}catch{}
        for args in [["init"],["add","same-name.txt"],["-c","user.name=Kero Test","-c","user.email=kero-test@localhost","commit","-m","fixture"],["checkout","-b","verified-branch"]] {
            let result=service.git(args,in:root);precondition(result.status == 0,result.stderr)
        }
        precondition(service.git(["branch","--show-current"],in:root).stdout == "verified-branch\n")
        _=try service.write(path,data:Data("edited remote\n".utf8),expected:saved)
        precondition(service.git(["diff","--","same-name.txt"],in:root).stdout.contains("+edited remote"))
        _=try service.request("rename",path:path,fields:["destination":root+"/renamed.txt"])
        let entries=try service.directory(root);precondition(entries.contains{$0.name == "renamed.txt"})
        let detached=HostService(hostID:UUID(),socketPath:CommandLine.arguments[1]);detached.invalidate()
        do {_=try detached.read(root+"/renamed.txt");fatalError("collapsed host reconnected")}catch{}
        print("HostService: remote CRUD, conflict protection, Git status/commit/branch/diff, local path isolation, and invalidated capability passed")
    }
}

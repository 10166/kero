import AppKit
import Combine

/// Only visible directories are read. Each refresh captures a host capability;
/// collapse cancels that capability, including its directory watch.
@MainActor
final class FileTreeModel: nonisolated ObservableObject {
    struct Item: Identifiable, Equatable, Sendable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        var isDraft = false
    }
    struct Draft: Equatable { let parentDir: String; let isDirectory: Bool }
    @Published private(set) var rootPath = ""
    @Published private(set) var items: [Item] = []
    @Published private(set) var renamingPath: String?
    @Published private(set) var draft: Draft?
    @Published private(set) var error: String?
    private var hostID = HostGroups.localID
    private var expanded: Set<String> = []
    private var generation = 0
    private var refreshTask: Task<Void,Never>?
    private var watcher: HostService.Watch?
    private var watchedPaths: Set<String> = []
    private var serviceIdentity: ObjectIdentifier?
    private var watchTask: Task<Void,Never>?
    deinit { watcher?.cancel();watchTask?.cancel();refreshTask?.cancel() }
    var onCreated: ((String)->Void)?
    var onRenamed: ((String,String)->Void)?
    var rootName: String { (rootPath as NSString).lastPathComponent }
    func isExpanded(_ item:Item)->Bool { expanded.contains(item.path) }
    func sync(root:String,hostID:UUID = HostGroups.localID) {
        let identity = ObjectIdentifier(HostGroups.shared.service(hostID))
        if root != rootPath || hostID != self.hostID || serviceIdentity != identity {
            serviceIdentity = identity
            generation += 1; refreshTask?.cancel(); refreshTask=nil
            watcher?.cancel(); watcher=nil; watchedPaths=[]; watchTask?.cancel(); watchTask=nil
            rootPath=root; self.hostID=hostID; expanded=[]; items=[]; draft=nil; renamingPath=nil
        }
        guard !root.isEmpty,HostGroups.shared.isExpanded(hostID) else { items=[]; watcher?.cancel(); return }
        rebuild()
    }
    func toggle(_ item:Item) { guard item.isDirectory else{return}; if !expanded.insert(item.path).inserted {expanded.remove(item.path)}; rebuild() }
    func beginRename(_ item:Item){renamingPath=item.path}
    func cancelRename(){renamingPath=nil}
    func beginNewFile(in directory:String){draft=Draft(parentDir:directory,isDirectory:false)}
    func beginNewFolder(in directory:String){draft=Draft(parentDir:directory,isDirectory:true)}
    func cancelDraft(){draft=nil}
    private func valid(_ name:String)->String? {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,!name.contains("/"),name != ".",name != ".." else{return nil};return name
    }
    @discardableResult func rename(_ item:Item,to name:String)->String? {
        renamingPath=nil; guard let name=valid(name),name != item.name else{return nil}
        let destination=((item.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        mutate("rename",path:item.path,fields:["destination":destination]) { [weak self] in
            guard let self else{return}
            self.expanded=Set(self.expanded.map{$0 == item.path ? destination : $0.hasPrefix(item.path+"/") ? destination+String($0.dropFirst(item.path.count)) : $0})
            self.onRenamed?(item.path,destination)
        }; return nil
    }
    @discardableResult func commitDraft(name:String)->String? {
        guard let draft else{return nil};self.draft=nil
        guard let name=valid(name) else{return nil}
        let path=(draft.parentDir as NSString).appendingPathComponent(name)
        mutate(draft.isDirectory ? "create_directory":"create_file",path:path) { [weak self] in
            self?.expanded.insert(draft.parentDir); if !draft.isDirectory {self?.onCreated?(path)}
        };return nil
    }
    func moveToTrash(_ item:Item) {
        if hostID == HostGroups.localID {
            let generation = generation
            Task { [weak self] in
                let failure = await Task.detached { () -> String? in
                    do { try FileManager.default.trashItem(at: URL(fileURLWithPath:item.path), resultingItemURL:nil); return nil }
                    catch { return error.localizedDescription }
                }.value
                guard let self, self.generation == generation else { return }
                if let failure { let alert=NSAlert(); alert.messageText="Could not move item to Trash"; alert.informativeText=failure; alert.runModal() }
                self.rebuild()
            }
            return
        }
        // Remote machines need not have a desktop Trash service. Explicitly
        // describe permanent deletion before issuing the single mutation.
        let alert=NSAlert();alert.messageText="Delete “\(item.name)”?";alert.informativeText="This permanently removes the item on this host.";alert.addButton(withTitle:"Delete");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        mutate("remove",path:item.path,fields:["recursive":item.isDirectory]){}
    }
    private func mutate(_ action:String,path:String,fields:[String:Any]=[:],completion:@escaping()->Void) {
        guard HostGroups.shared.isExpanded(hostID) else{return}
        let service=HostGroups.shared.service(hostID), generation=generation
        // Serialize JSON before crossing actor boundaries.
        guard let data=try? JSONSerialization.data(withJSONObject:fields) else{return}
        Task { [weak self] in
            let failure=await Task.detached { ()->String? in
                do { _=try service.request(action,path:path,fields:(try JSONSerialization.jsonObject(with:data)) as! [String:Any]);return nil }
                catch{return error.localizedDescription}
            }.value
            guard let self,self.generation==generation else{return}
            if let failure {self.error=failure;let alert=NSAlert();alert.messageText="File operation failed";alert.informativeText=failure;alert.runModal()}
            else {completion()}; self.rebuild()
        }
    }
    func refresh() { rebuild() }
    private func rebuild() {
        guard !rootPath.isEmpty,refreshTask==nil,HostGroups.shared.isExpanded(hostID) else{return}
        let service=HostGroups.shared.service(hostID),root=rootPath,expanded=expanded,generation=generation
        let paths=expanded.union([root])
        if paths != watchedPaths {
            watchedPaths=paths;watcher?.cancel();let token=HostService.Watch();watcher=token
            watchTask=Task.detached { [weak self] in
                try? service.watch(Array(paths),token:token) {
                    Task { @MainActor [weak self] in
                        guard let self,self.generation==generation else{return};self.rebuild()
                    }
                }
            }
        }
        refreshTask=Task { [weak self] in
            let result=await Task.detached { Result { ()throws->[Item] in
                var result:[Item]=[]
                func append(_ path:String,_ depth:Int)throws {
                    guard depth<32,result.count<50_000 else{return}
                    let entries=try service.directory(path).filter{$0.name != ".git"}.sorted { a,b in a.is_dir != b.is_dir ? a.is_dir : a.name.localizedStandardCompare(b.name) == .orderedAscending }
                    for entry in entries {
                        let child=(path as NSString).appendingPathComponent(entry.name)
                        result.append(Item(name:entry.name,path:child,isDirectory:entry.is_dir,depth:depth))
                        if entry.is_dir,expanded.contains(child){try append(child,depth+1)}
                    }
                }
                try append(root,0);return result
            }}.value
            guard let self,self.generation==generation else{return};self.refreshTask=nil
            switch result {case .success(let items):if self.items != items{self.items=items};self.error=nil
            case .failure(let error):self.error=error.localizedDescription}
        }
    }
}

import Foundation

struct RemoteProjectSelection: Equatable, Sendable {
    let hostID: UUID
    let projectID: UUID
    var selectedTabID: UUID?
}

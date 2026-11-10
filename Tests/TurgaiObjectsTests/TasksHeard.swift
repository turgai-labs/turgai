import DistributedCluster
import TurgaiDomain

@testable import TurgaiObjects

/// What a listener following a space's tasks was told, in order.
actor TasksHeard {
    private(set) var notices: [TasksNotice] = []

    func add(_ notice: TasksNotice) {
        notices.append(notice)
    }
}

/// A listener following `space`'s tasks on `node`, once the node finds it there, with what it's
/// told: kept for as long as the test holds it.
func listening(to space: SpaceID, on node: ClusterSystem) async throws -> (TasksListener, TasksHeard) {
    let heard = TasksHeard()
    let listener = await TasksListener(actorSystem: node, following: space) { await heard.add($0) }
    for _ in 0..<50 {
        if await node.receptionist.lookup(.tasks(in: space)).contains(listener) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    return (listener, heard)
}

import DistributedCluster
import TurgaiCalls
import TurgaiDomain

@testable import TurgaiObjects

/// What a listener following a space's tasks was told, in order.
actor TasksHeard {
    private(set) var notices: [TasksNotice] = []

    func add(_ notice: TasksNotice) {
        notices.append(notice)
    }

    /// The notices once `count` have come, or as they are after two seconds: they're pulled a
    /// moment after they're told.
    func notices(_ count: Int) async -> [TasksNotice] {
        for _ in 0..<100 where notices.count < count { try? await Task.sleep(for: .milliseconds(20)) }
        return notices
    }
}

/// `space`'s tasks on `node`, followed from now on as `scope`, one of its people's, with what's
/// heard of them: until the returned task is cancelled.
func listening(to space: SpaceID, as scope: CallScope, on node: ClusterSystem) async throws
    -> (Task<Void, Never>, TasksHeard)
{
    let heard = TasksHeard()
    return try await CallChain.$current.withValue(.start(scope, in: nil)) {
        let changes = try await SpaceTasks.identified(by: space, on: node).subscription()
        let following = Task {
            for await notice in changes { await heard.add(notice) }
        }
        return (following, heard)
    }
}

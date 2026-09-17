import Foundation

enum ToolArgumentType: String, Sendable, CaseIterable {
    case string
    case number
    case boolean
    case array
    case object
}

enum WorkflowStepKind: String, Sendable {
    case fetch
    case execute
    case think
}

enum WorkflowPermission: String, Sendable {
    case inherit
    case allowed
    case denied
}

enum ScriptSource: String, Sendable {
    case source
    case file
}

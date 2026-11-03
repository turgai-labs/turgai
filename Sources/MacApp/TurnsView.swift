import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// One of the agent's turns, step by step: what the message it answered made it do, and how it
/// ended. Shown from the reply it made.
struct TurnStepsView: View {
    let turn: TurnRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.message.isEmpty ? "Turn" : turn.message)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if turn.steps.isEmpty {
                        Text("No tool calls").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                        StepRow(step: step, startedAt: turn.startedAt)
                    }
                    if case .failed(let reason, _) = turn.outcome {
                        Text(reason).font(.callout).foregroundStyle(Color.turgaiAccent).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .frame(maxHeight: 520)
    }

    private var summary: String {
        let steps = turn.steps.filter { if case .toolCalled = $0.kind { true } else { false } }.count
        let calls = steps == 1 ? "1 call" : "\(steps) calls"
        switch turn.outcome {
        case .running: return "\(calls) · running"
        case .replied(_, let at): return "\(calls) · \(duration(from: turn.startedAt, to: at))"
        case .failed(_, let at): return "\(calls) · failed after \(duration(from: turn.startedAt, to: at))"
        case .cancelled(let at): return "\(calls) · cancelled after \(duration(from: turn.startedAt, to: at))"
        case .interrupted(let at): return "\(calls) · interrupted after \(duration(from: turn.startedAt, to: at))"
        }
    }
}

private struct StepRow: View {
    let step: TurnStep
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("+\(duration(from: startedAt, to: step.at))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
                .textSelection(.enabled)
                .lineLimit(12)
        }
    }

    private var title: String {
        switch step.kind {
        case .toolCalled(let name, _): name
        case .toolFinished(let name, _, let failure?): "\(name) failed (\(failure))"
        case .toolFinished(let name, _, nil): "\(name) answered"
        case .noticed: "Turgai told the model"
        }
    }

    private var detail: String {
        switch step.kind {
        case .toolCalled(_, let arguments): arguments
        case .toolFinished(_, let output, _): output
        case .noticed(let words): words
        }
    }

    private var icon: String {
        switch step.kind {
        case .toolCalled: "arrow.right.circle"
        case .toolFinished(_, _, .some): "exclamationmark.triangle"
        case .toolFinished(_, _, nil): "checkmark.circle"
        case .noticed: "info.circle"
        }
    }

    private var tint: Color {
        if case .toolFinished(_, _, .some) = step.kind { return .turgaiAccent }
        return .secondary
    }
}

/// A short duration, such as `850 ms`, `4.2 s` or `3 min 5 s`.
private func duration(from start: Date, to end: Date) -> String {
    let seconds = max(end.timeIntervalSince(start), 0)
    if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
    if seconds < 60 { return String(format: "%.1f s", seconds) }
    return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
}

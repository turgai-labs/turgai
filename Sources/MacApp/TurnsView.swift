import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The agent's turns, step by step: what each message made it do, live as it happens.
struct TurnsView: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        Group {
            if store.turns.isEmpty {
                ContentUnavailableView(
                    "No turns yet", systemImage: "list.bullet.rectangle",
                    description: Text("Send a message, and what the agent does shows up here."))
            } else {
                List(store.turns.reversed()) { turn in
                    TurnRow(turn: turn)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

private struct TurnRow: View {
    let turn: TurnRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if turn.steps.isEmpty {
                    Text("No tool calls").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                    StepRow(step: step, startedAt: turn.startedAt)
                }
                if case .replied(let text, _) = turn.outcome {
                    Text(text).font(.callout).textSelection(.enabled)
                }
                if case .failed(let reason, _) = turn.outcome {
                    Text(reason).font(.callout).foregroundStyle(Color.turgaiAccent).textSelection(.enabled)
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.message.isEmpty ? "Turn" : turn.message)
                    .lineLimit(2)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var summary: String {
        let steps = turn.steps.filter { if case .toolCalled = $0.kind { true } else { false } }.count
        let calls = steps == 1 ? "1 call" : "\(steps) calls"
        switch turn.outcome {
        case .running: return "\(calls) · running"
        case .replied(_, let at): return "\(calls) · \(duration(from: turn.startedAt, to: at))"
        case .failed(_, let at): return "\(calls) · failed after \(duration(from: turn.startedAt, to: at))"
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
        }
    }

    private var detail: String {
        switch step.kind {
        case .toolCalled(_, let arguments): arguments
        case .toolFinished(_, let output, _): output
        }
    }

    private var icon: String {
        switch step.kind {
        case .toolCalled: "arrow.right.circle"
        case .toolFinished(_, _, .some): "exclamationmark.triangle"
        case .toolFinished(_, _, nil): "checkmark.circle"
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

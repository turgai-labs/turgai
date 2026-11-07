import SwiftUI
import TurgaiModels

/// One of the agent's turns, step by step: what the message it answered made it do, and how it
/// ended. Shown from the reply it made.
struct TurnStepsView: View {
    let turn: TurnRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.heading)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(turn.summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if turn.steps.isEmpty {
                        Text("No tool calls").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                        StepRow(step: step, startedAt: turn.startedAt)
                    }
                    if let failure = turn.failure {
                        Text(failure).font(.callout).foregroundStyle(Color.turgaiAccent).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .frame(maxHeight: 520)
    }
}

private struct StepRow: View {
    let step: TurnStep
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: step.symbol).foregroundStyle(step.failed ? Color.turgaiAccent : .secondary)
                Text(step.title).font(.callout.weight(.medium))
                Spacer()
                Text(step.offset(from: startedAt))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(step.detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(step.failed ? Color.turgaiAccent : .primary)
                .textSelection(.enabled)
                .lineLimit(12)
        }
    }
}

import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The shown space's tasks under its conversations, while it has some: their heading, which folds
/// them away, and each task, its info opening beside it as it's clicked, its menu changing it.
struct TasksSection: View {
    let store: StoreOf<TasksFeature>

    var body: some View {
        if !store.rows.isEmpty {
            TasksHeading(collapsed: store.collapsed) {
                withAnimation(.smooth(duration: 0.25)) { _ = store.send(.headingTapped) }
            }
            .padding(.top, 32)
            .transition(.opacity)
            if !store.collapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.rows) { (row: TasksFeature.Row) in
                        TaskLine(task: row) { store.send(.rowTapped(row.id)) }
                            .popover(isPresented: showing(row.id), arrowEdge: .trailing) {
                                TaskInfo(task: row) { store.send(.picked($0)) }
                            }
                            .contextMenu {
                                ForEach(row.commands) { (command: TasksFeature.Command) in
                                    TaskMenuButton(command: command) { store.send(.picked(command)) }
                                }
                            }
                            .transition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Whether the info of the task `id` is open; closed, it says so.
    private func showing(_ id: TaskListing.ID) -> Binding<Bool> {
        Binding(get: { store.shown == id }, set: { if !$0 { store.send(.infoDismissed) } })
    }
}

/// What a task is, as its info shows it: its name over what it does; when it's due and where it's
/// from; and what can be done to it.
private struct TaskInfo: View {
    let task: TasksFeature.Row
    let pick: (TasksFeature.Command) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title.replacingOccurrences(of: "-", with: " ")).font(.headline)
                if let does = task.does {
                    Text(does).foregroundStyle(Color.turgaiMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Due").foregroundStyle(Color.turgaiMuted)
                    TaskDue(when: task.when, paused: task.paused)
                }
                GridRow {
                    Text("From").foregroundStyle(Color.turgaiMuted)
                    TaskOwner(owner: task.owner)
                }
            }
            .font(.callout)
            if !task.commands.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    ForEach(task.commands) { (command: TasksFeature.Command) in
                        TaskMenuButton(command: command) { pick(command) }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }
}

/// When a task is due, in full: its date, with the day and time, or what its schedule says; and that
/// it's paused, when it is.
private struct TaskDue: View {
    let when: TaskListing.When
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch when {
            case .once(let date):
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
            case .repeating(let schedule):
                Text(schedule)
            }
            if paused {
                Text("Paused").foregroundStyle(Color.turgaiMuted)
            }
        }
    }
}

/// Where a task is from: a chat's schedule or reminder, or its object's code.
private struct TaskOwner: View {
    let owner: TasksFeature.Owner

    var body: some View {
        switch owner {
        case .schedule: Text("A chat's schedule")
        case .reminder: Text("A chat's reminder")
        case .object: Text("Its object's code")
        }
    }
}

/// A task's menu item, as its menu words it.
private struct TaskMenuButton: View {
    let command: TasksFeature.Command
    let pick: () -> Void

    var body: some View {
        switch command {
        case .pause: Button("Pause", action: pick)
        case .resume: Button("Resume", action: pick)
        case .cancelSchedule, .cancelReminder: Button("Cancel", role: .destructive, action: pick)
        }
    }
}

/// Tasks, labelling the shown space's tasks under its conversations, and folding them away: its
/// arrow, at the end, shows while it's pointed at, or while they're folded, as a Mac sidebar's does.
private struct TasksHeading: View {
    let collapsed: Bool
    let toggle: () -> Void
    @State private var pointedAt = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                SectionLabel(title: "Tasks")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.turgaiMuted)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(pointedAt || collapsed ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .onHover { pointedAt = $0 }
        .buttonStyle(.plain)
        .help(collapsed ? "Show tasks" : "Hide tasks")
        .accessibilityLabel(collapsed ? "Show tasks" : "Hide tasks")
    }
}

/// A task, one item: what it's for, its handle as words, over when it's due; clicked, its info
/// opens.
private struct TaskLine: View {
    let task: TasksFeature.Row
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title.replacingOccurrences(of: "-", with: " ")).font(.body).lineLimit(1)
                    .foregroundStyle(Color.turgaiInk)
                HStack(spacing: 4) {
                    if task.paused { Text("Paused ·") }
                    TaskWhen(when: task.when)
                }
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(Color.turgaiMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// When a task is due: its date, with the day and time, or what its schedule says.
private struct TaskWhen: View {
    let when: TaskListing.When

    var body: some View {
        switch when {
        case .once(let date):
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        case .repeating(let schedule):
            Text(schedule)
        }
    }
}

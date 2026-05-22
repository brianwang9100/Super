import Core
import Foundation
import GRDBQuery
import SwiftUI

/// The Todo mini-applet. Backed by `todo.sqlite` and three repositories
/// constructed at app boot. Conforms to `MiniApplet` so the shell can
/// register, sidebar, and render it like any other backdrop applet.
public struct TodoApplet: MiniApplet {
    public static let appletID: String = TodoModule.appletID
    public var appletID: String { Self.appletID }
    public var displayName: String { "Todo" }
    public var accentColor: Color { Color(red: 0.30, green: 0.45, blue: 0.78) }
    public var systemPrompt: String { AppletSystemPrompt.load(from: .module) }

    private let dependencies: TodoDependencies

    /// The single view model backing the task surface. Held here, not
    /// rebuilt per `rootView()` call, so the open draft / active filter /
    /// toast survive re-renders of the backdrop (`AppShell.body` re-runs
    /// `rootView()` every frame of the chat overlay animation). Matches
    /// `BibleApplet`'s registry-lifetime view model.
    private let viewModel: TodoScreenViewModel

    @MainActor
    public init(dependencies: TodoDependencies) {
        self.dependencies = dependencies
        self.viewModel = TodoScreenViewModel(
            taskRepository: dependencies.taskRepository,
            labelRepository: dependencies.labelRepository,
            joinRepository: dependencies.joinRepository,
            clock: dependencies.clock,
            ids: dependencies.ids,
            calendar: dependencies.calendar
        )
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(TodoIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        // The `@Query`s in `TodoScreen` read their `DatabaseContext` from the
        // environment; provide a read/write context over `todo.sqlite` here
        // so the applet is self-contained and the shell stays applet-agnostic.
        AnyView(
            TodoScreen(viewModel: viewModel)
                .databaseContext(.readWrite { dependencies.database.queue })
        )
    }
}

/// Dependency bundle handed to `TodoApplet`, constructed once at app boot.
public struct TodoDependencies: Sendable {
    public let database: TodoDatabase
    public let taskRepository: any TaskRepository
    public let labelRepository: any LabelRepository
    public let joinRepository: any TaskLabelRepository
    public let clock: any Clock
    public let ids: any IDGenerator
    public let calendar: Calendar

    public init(
        database: TodoDatabase,
        taskRepository: any TaskRepository,
        labelRepository: any LabelRepository,
        joinRepository: any TaskLabelRepository,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator(),
        calendar: Calendar = .current
    ) {
        self.database = database
        self.taskRepository = taskRepository
        self.labelRepository = labelRepository
        self.joinRepository = joinRepository
        self.clock = clock
        self.ids = ids
        self.calendar = calendar
    }

    /// Convenience: open `todo.sqlite` under `directory` and build the
    /// repositories. Used by the app's composition root.
    public static func live(in directory: URL) throws -> TodoDependencies {
        let database = try TodoDatabase.open(in: directory)
        return TodoDependencies(
            database: database,
            taskRepository: GRDBTaskRepository(database: database),
            labelRepository: GRDBLabelRepository(database: database),
            joinRepository: GRDBTaskLabelRepository(database: database)
        )
    }
}

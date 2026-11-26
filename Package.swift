// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Turgai",
    platforms: [
        .macOS("26.4"),
        // The iPhone app, which arranges itself around a foldable's fold (`ArrangementView`).
        .iOS("27.1"),
    ],
    products: [
        .library(name: "TurgaiModels", targets: ["TurgaiModels"]),
        .library(name: "TurgaiDomain", targets: ["TurgaiDomain"]),
        .library(name: "TurgaiHail", targets: ["TurgaiHail"]),
        .library(name: "TurgaiApplication", targets: ["TurgaiApplication"]),
        .library(name: "TurgaiTelegram", targets: ["TurgaiTelegram"]),
        .executable(name: "Turgai", targets: ["Turgai"]),
        .executable(name: "TurgaiWasmRunner", targets: ["TurgaiWasmRunner"]),
        .executable(name: "TurgaiSite", targets: ["TurgaiSite"]),
        .library(name: "MacApp", targets: ["MacApp"]),
        .library(name: "PhoneApp", targets: ["PhoneApp"]),
    ],
    traits: [
        .trait(name: "Llama", description: "Local GGUF models run by llama.cpp, which builds only for Apple platforms.")
    ],
    dependencies: [
        .package(
            url: "https://github.com/akbashev/hail.git", branch: "turgai-integration",
            traits: [.trait(name: "Llama", condition: .when(traits: ["Llama"]))]),
        .package(
            url: "https://github.com/akbashev/discoverable-distributed-actors.git", branch: "turgai-integration",
            traits: ["ClusterSystem"]),
        .package(url: "https://github.com/akbashev/cluster-durable-workflows.git", branch: "turgai-integration"),
        .package(url: "https://github.com/turgai-labs/cluster-running-actors.git", branch: "main"),
        // Objects are Swift actors, checked as Swift checks them and run by Doppel.
        .package(url: "https://github.com/turgai-labs/doppel.git", branch: "main"),
        .package(url: "https://github.com/turgai-labs/mosaic.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
        .package(
            // A response that says it reached its token limit, and the schema of a type that holds
            // itself, until upstream has them.
            url: "https://github.com/akbashev/AnyLanguageModel.git",
            branch: "turgai-integration",
            traits: ["AsyncHTTPClient", .trait(name: "Llama", condition: .when(traits: ["Llama"]))]
        ),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            from: "1.1.5"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            from: "1.21.0"
        ),
        // Not merged upstream yet: stable virtual actor references, and our
        // swift-distributed-actors fixes joined on one branch.
        .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "stable-references"),
        // Every call says who made it and who it's for.
        .package(url: "https://github.com/turgai-labs/cluster-attributed-calls.git", branch: "main"),
        .package(
            url: "https://github.com/turgai-labs/swift-distributed-actors.git", branch: "turgai-integration"
        ),
        .package(
            url: "https://github.com/akbashev/cluster-event-sourcing.git",
            branch: "turgai-integration"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.12.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-auth.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/akbashev/postgres-event-store.git",
            branch: "turgai-integration"
        ),
        .package(
            url: "https://github.com/vapor/postgres-nio.git",
            from: "1.27.0"
        ),
        .package(
            url: "https://github.com/turgai-labs/sqlite-event-store.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/vapor/sqlite-nio.git",
            from: "1.13.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            from: "2.25.0"
        ),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.16.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/elementary-swift/elementary.git", from: "0.9.0"),
        .package(url: "https://github.com/elementary-swift/elementary-htmx.git", from: "0.7.0"),
        .package(url: "https://github.com/hummingbird-community/hummingbird-elementary.git", from: "0.6.0"),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        ),
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        .package(url: "https://github.com/pointfreeco/swift-parsing", from: "0.14.1"),
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture.git",
            from: "1.26.0",
            traits: ["ComposableArchitecture2Deprecations"]
        ),
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            from: "0.3.1"
        ),
        // `swift package generate-documentation`: only for building the docs.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
    ],
    targets: [
        .target(name: "TurgaiModels", dependencies: [.product(name: "Mosaic", package: "mosaic")]),
        .target(name: "TurgaiDomain"),
        .target(
            name: "TurgaiCalls",
            dependencies: [
                "TurgaiDomain",
                .product(name: "AttributedCalls", package: "cluster-attributed-calls"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
            ]
        ),
        // What's due once or again and again, for whoever sets it: each kept by its durable
        // workflow, which tells its owner when it's due. It knows nothing of who sets it.
        .target(
            name: "TurgaiTimers",
            dependencies: [
                .product(name: "AttributedCalls", package: "cluster-attributed-calls"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
            ]
        ),
        .target(
            name: "TurgaiPeople",
            dependencies: [
                "TurgaiCalls",
                "TurgaiDomain",
                "TurgaiMemory",
                "TurgaiPersistence",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Hail", package: "hail"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
            ]
        ),
        .target(
            name: "TurgaiSpaces",
            dependencies: [
                "TurgaiTimers",
                .product(name: "AttributedCalls", package: "cluster-attributed-calls"),
                .product(name: "RunningActors", package: "cluster-running-actors"),
                "TurgaiAgents",
                "TurgaiTelegram",
                "TurgaiObjects",
                "TurgaiConversations",
                "TurgaiCalls",
                "TurgaiDomain",
                "TurgaiHail",
                "TurgaiMemory",
                "TurgaiPeople",
                "TurgaiPersistence",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
            ]
        ),
        .target(
            name: "TurgaiConversations",
            dependencies: [
                "TurgaiCalls",
                "TurgaiDomain",
                "TurgaiHail",
                "TurgaiMemory",
                "TurgaiPeople",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                "TurgaiPersistence",
            ]
        ),
        .target(
            name: "TurgaiAgents",
            dependencies: [
                "TurgaiDomain",
                "TurgaiPersistence",
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            ]
        ),
        .target(
            name: "TurgaiBrand",
            resources: [
                .copy("Resources/Public")
            ]
        ),
        .target(
            name: "TurgaiWeb",
            dependencies: [
                "TurgaiTimers",
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                "TurgaiAgents",
                "TurgaiCalls",
                "TurgaiConversations",
                "TurgaiSpaces",
                "TurgaiPeople",
                "TurgaiBrand",
                "TurgaiApplication",
                "TurgaiMemory",
                "TurgaiModels",
                "TurgaiObjects",
                "TurgaiHail",
                "TurgaiPersistence",
                "TurgaiTelegram",
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "Mosaic", package: "mosaic"),
                .product(name: "MosaicHTML", package: "mosaic"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Elementary", package: "elementary"),
                .product(name: "ElementaryHTMX4", package: "elementary-htmx"),
                .product(name: "ElementaryHTMX4WS", package: "elementary-htmx"),
                .product(name: "HummingbirdElementary", package: "hummingbird-elementary"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "TurgaiSite",
            dependencies: [
                "TurgaiBrand",
                .product(name: "Elementary", package: "elementary"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "TurgaiObjects",
            dependencies: [
                "TurgaiTimers",
                .product(name: "RunningActors", package: "cluster-running-actors"),
                .product(name: "AttributedCalls", package: "cluster-attributed-calls"),
                "TurgaiCalls",
                "TurgaiDomain",
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Parsing", package: "swift-parsing"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                // A refusal, as what code's tool calls and an object's own doing come back with.
                .product(name: "ScopedEffect", package: "hail"),
                .product(name: "Doppel", package: "doppel"),
                .product(name: "DoppelRuntime", package: "doppel"),
                // What a website shows, and how a browser shows it.
                .product(name: "Mosaic", package: "mosaic"),
                .product(name: "MosaicHTML", package: "mosaic"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                // The runtime's macros, expanded in-process before a script is checked and run.
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "TurgaiModelEval",
            dependencies: [
                "TurgaiAgents",
                "TurgaiCalls",
                "TurgaiConversations",
                "TurgaiSpaces",
                "TurgaiApplication",
                "TurgaiHail",
                "TurgaiPersistence",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "Mosaic", package: "mosaic"),
            ]
        ),
        .target(
            name: "TurgaiMemory",
            dependencies: ["TurgaiDomain"]
        ),
        .target(
            name: "TurgaiHail",
            dependencies: [
                "TurgaiCalls",
                "TurgaiDomain",
                .product(name: "Hail", package: "hail"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .target(
            name: "TurgaiApplication",
            dependencies: [
                .product(name: "RunningActors", package: "cluster-running-actors"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                "TurgaiAgents",
                "TurgaiConversations",
                "TurgaiCalls",
                "TurgaiDomain",
                "TurgaiMemory",
                "TurgaiHail",
                "TurgaiObjects",
                "TurgaiPeople",
                "TurgaiSpaces",
                "TurgaiPersistence",
                "TurgaiTelegram",
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TurgaiTelegram",
            dependencies: [
                "TurgaiDomain",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .target(
            name: "TurgaiServer",
            dependencies: [
                "TurgaiTimers",
                .product(name: "RunningActors", package: "cluster-running-actors"),
                "TurgaiAgents",
                "TurgaiCalls",
                "TurgaiConversations",
                "TurgaiPeople",
                "TurgaiSpaces",
                "TurgaiApplication",
                "TurgaiHail",
                "TurgaiTelegram",
                "TurgaiWeb",
                "TurgaiObjects",
                "TurgaiPersistence",
                .product(name: "Hail", package: "hail"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "PostgresEventStore", package: "postgres-event-store"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "SQLiteEventStore", package: "sqlite-event-store"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "Turgai",
            dependencies: [
                "TurgaiObjects",
                "TurgaiPersistence",
                "TurgaiServer",
                "TurgaiWeb",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .target(
            // What the apps show and do, talking only to a server, wherever it runs: the Mac app
            // and the iPhone app each draw it their own way.
            name: "TurgaiClient",
            dependencies: [
                "TurgaiModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Mosaic", package: "mosaic"),
                .product(name: "MosaicSwiftUI", package: "mosaic"),
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .target(
            name: "MacApp",
            dependencies: [
                "TurgaiClient",
                "TurgaiApplication",
                "TurgaiModels",
                "TurgaiObjects",
                "TurgaiPersistence",
                "TurgaiServer",
                "TurgaiWeb",
                .product(name: "HailAgentRuntime", package: "hail"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "Mosaic", package: "mosaic"),
                .product(name: "MosaicSwiftUI", package: "mosaic"),
            ]
        ),
        .target(
            // Turgai on an iPhone: what `TurgaiClient` does, drawn for a phone, folded or not.
            name: "PhoneApp",
            dependencies: [
                "TurgaiClient",
                "TurgaiModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Mosaic", package: "mosaic"),
            ]
        ),
        .executableTarget(
            name: "TurgaiWasmRunner",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
            ]
        ),
        .testTarget(
            name: "TurgaiDomainTests",
            dependencies: ["TurgaiDomain"]
        ),
        .testTarget(
            name: "TurgaiModelsTests",
            dependencies: ["TurgaiModels", .product(name: "Mosaic", package: "mosaic")]
        ),
        .testTarget(
            name: "TurgaiMemoryTests",
            dependencies: ["TurgaiDomain", "TurgaiMemory"]
        ),
        .testTarget(
            name: "TurgaiHailTests",
            dependencies: ["TurgaiDomain", "TurgaiHail", "TurgaiApplication", "TurgaiSpaces", "TurgaiTelegram"]
        ),
        .testTarget(
            name: "TurgaiApplicationTests",
            dependencies: [
                "TurgaiAgents", "TurgaiCalls", "TurgaiConversations", "TurgaiDomain", "TurgaiHail", "TurgaiApplication",
                "TurgaiPeople", "TurgaiPersistence", "TurgaiSpaces", "TurgaiWeb",
            ]
        ),
        .testTarget(
            name: "TurgaiObjectsTests",
            dependencies: [
                "TurgaiTimers",
                "TurgaiCalls",
                .product(name: "AttributedCalls", package: "cluster-attributed-calls"),
                "TurgaiSpaces",
                "TurgaiObjects",
                .product(name: "Doppel", package: "doppel"),
                .product(name: "Mosaic", package: "mosaic"),
                "TurgaiApplication",
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
            ]
        ),
        // The Swift module Turgai gives an object's code compiles, for every object written so far.
        .testTarget(
            name: "ObjectModuleTests",
            dependencies: [
                "TurgaiObjects",
                .product(name: "DoppelCompilerCheck", package: "doppel"),
            ],
            resources: [.copy("Corpus")]
        ),
        .testTarget(
            name: "PhoneAppTests",
            dependencies: [
                "PhoneApp",
                "TurgaiClient",
                "TurgaiModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "MacAppTests",
            dependencies: [
                "MacApp",
                "TurgaiClient",
                "TurgaiModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "TurgaiTelegramTests",
            dependencies: ["TurgaiDomain", "TurgaiTelegram"]
        ),
        .testTarget(
            name: "TurgaiDeliveryTests",
            dependencies: ["TurgaiApplication"]
        ),
        .target(
            name: "TurgaiPersistence",
            dependencies: [
                "TurgaiDomain",
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "PostgresEventStore", package: "postgres-event-store"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "TurgaiPersistenceTests",
            dependencies: [
                "TurgaiDomain",
                "TurgaiPersistence",
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// Every async function runs on its caller's executor unless it says otherwise, as Swift 6.2's
// approachable concurrency has it: what an actor owns stays on that actor.
for target in package.targets where target.type != .binary {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
}

// What's slow to type-check, said where it slows the app's build: tests, whose expectations are
// macros each, aren't held to it.
for target in package.targets where target.type != .binary && target.type != .test {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .unsafeFlags([
                "-Xfrontend", "-warn-long-function-bodies=100",
                "-Xfrontend", "-warn-long-expression-type-checking=100",
            ])
        ]
}

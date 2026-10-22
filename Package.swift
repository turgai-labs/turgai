// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Turgai",
    platforms: [
        .macOS("26.4")
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
    ],
    dependencies: [
        .package(url: "https://github.com/akbashev/hail.git", branch: "turgai-integration"),
        .package(
            url: "https://github.com/akbashev/discoverable-distributed-actors.git", branch: "turgai-integration",
            traits: ["ClusterSystem"]),
        .package(url: "https://github.com/akbashev/cluster-durable-workflows.git", branch: "turgai-integration"),
        // Objects are Swift actors, checked as Swift checks them and run by Doppel.
        .package(url: "https://github.com/turgai-labs/doppel.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel.git",
            branch: "main",
            traits: ["AsyncHTTPClient", "Llama"]
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
            url: "https://github.com/apple/swift-nio-ssl.git",
            from: "2.25.0"
        ),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.16.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/elementary-swift/elementary.git", from: "0.7.0"),
        .package(url: "https://github.com/elementary-swift/elementary-htmx.git", from: "0.1.0"),
        .package(url: "https://github.com/hummingbird-community/hummingbird-elementary.git", from: "0.4.2"),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        ),
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        .package(url: "https://github.com/pointfreeco/swift-parsing", from: "0.14.1"),
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture.git",
            from: "1.22.0"
        ),
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            from: "0.3.1"
        ),
    ],
    targets: [
        .target(name: "TurgaiModels"),
        .target(name: "TurgaiDomain"),
        .target(
            name: "TurgaiBrand",
            resources: [
                .copy("Resources/Public")
            ]
        ),
        .target(
            name: "TurgaiWeb",
            dependencies: [
                "TurgaiBrand",
                "TurgaiApplication",
                "TurgaiModels",
                "TurgaiHail",
                "TurgaiPersistence",
                "TurgaiTelegram",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Elementary", package: "elementary"),
                .product(name: "ElementaryHTMX", package: "elementary-htmx"),
                .product(name: "ElementaryHTMXWS", package: "elementary-htmx"),
                .product(name: "HummingbirdElementary", package: "hummingbird-elementary"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Markdown", package: "swift-markdown"),
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
                "TurgaiDomain",
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Parsing", package: "swift-parsing"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Doppel", package: "doppel"),
                .product(name: "DoppelRuntime", package: "doppel"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                // The runtime's macros, expanded in-process before a script is checked and run.
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Elementary", package: "elementary"),
            ]
        ),
        .executableTarget(
            name: "TurgaiModelEval",
            dependencies: [
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
            ]
        ),
        .target(
            name: "TurgaiMemory",
            dependencies: []
        ),
        .target(
            name: "TurgaiHail",
            dependencies: [
                "TurgaiDomain",
                .product(name: "Hail", package: "hail"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            ]
        ),
        .target(
            name: "TurgaiApplication",
            dependencies: [
                "TurgaiDomain",
                "TurgaiMemory",
                "TurgaiHail",
                "TurgaiObjects",
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
            ]
        ),
        .target(
            name: "TurgaiTelegram",
            dependencies: [
                "TurgaiDomain",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "TurgaiServer",
            dependencies: [
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
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "Turgai",
            dependencies: [
                "TurgaiServer",
                "TurgaiWeb",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .target(
            name: "MacApp",
            dependencies: [
                "TurgaiModels",
                "TurgaiObjects",
                "TurgaiServer",
                "TurgaiWeb",
                .product(name: "HailAgentRuntime", package: "hail"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            ],
            resources: [
                .process("Resources/Assets.xcassets")
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
            dependencies: ["TurgaiModels"]
        ),
        .testTarget(
            name: "TurgaiMemoryTests",
            dependencies: ["TurgaiMemory"]
        ),
        .testTarget(
            name: "TurgaiHailTests",
            dependencies: ["TurgaiDomain", "TurgaiHail", "TurgaiApplication"]
        ),
        .testTarget(
            name: "TurgaiApplicationTests",
            dependencies: ["TurgaiDomain", "TurgaiHail", "TurgaiApplication", "TurgaiWeb"]
        ),
        .testTarget(
            name: "TurgaiObjectsTests",
            dependencies: [
                "TurgaiObjects",
                .product(name: "Doppel", package: "doppel"),
                "TurgaiApplication",
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DiscoverableActors", package: "discoverable-distributed-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
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
            name: "MacAppTests",
            dependencies: [
                "MacApp",
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
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
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

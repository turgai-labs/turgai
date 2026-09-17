// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Turgai",
    platforms: [
        .macOS("26.4")
    ],
    products: [
        .library(name: "TurgaiDomain", targets: ["TurgaiDomain"]),
        .library(name: "TurgaiHail", targets: ["TurgaiHail"]),
        .library(name: "TurgaiApplication", targets: ["TurgaiApplication"]),
        .library(name: "TurgaiTelegram", targets: ["TurgaiTelegram"]),
        .executable(name: "Turgai", targets: ["Turgai"]),
        .executable(name: "TurgaiWasmRunner", targets: ["TurgaiWasmRunner"]),
    ],
    dependencies: [
        .package(path: "../hail"),
        .package(path: "../cluster-durable-workflows"),
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel.git",
            from: "0.9.0",
            traits: ["AsyncHTTPClient"]
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
        .package(
            url: "https://github.com/akbashev/cluster-virtual-actors.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/apple/swift-distributed-actors.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/akbashev/cluster-event-sourcing.git",
            branch: "main"
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
            branch: "main"
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
        .package(url: "https://github.com/elementary-swift/elementary.git", from: "0.7.0"),
        .package(url: "https://github.com/hummingbird-community/hummingbird-elementary.git", from: "0.4.2"),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        ),
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            from: "0.3.1"
        ),
    ],
    targets: [
        .target(name: "TurgaiDomain"),
        .target(
            name: "TurgaiWeb",
            dependencies: [
                "TurgaiApplication",
                "TurgaiHail",
                "TurgaiPersistence",
                "TurgaiTelegram",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Elementary", package: "elementary"),
                .product(name: "HummingbirdElementary", package: "hummingbird-elementary"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            resources: [
                .copy("Resources/Public")
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
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
            ]
        ),
        .target(
            name: "TurgaiTelegram",
            dependencies: [
                "TurgaiDomain",
                "TurgaiApplication",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "Turgai",
            dependencies: [
                "TurgaiApplication",
                "TurgaiHail",
                "TurgaiTelegram",
                "TurgaiWeb",
                "TurgaiPersistence",
                .product(name: "Hail", package: "hail"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
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
            name: "TurgaiTelegramTests",
            dependencies: ["TurgaiDomain", "TurgaiTelegram"]
        ),
        .testTarget(
            name: "TurgaiDeliveryTests",
            dependencies: ["Turgai"]
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

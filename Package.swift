// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Norby",
    platforms: [
        .macOS("26.4")
    ],
    products: [
        .library(name: "NorbyDomain", targets: ["NorbyDomain"]),
        .library(name: "NorbyHail", targets: ["NorbyHail"]),
        .library(name: "NorbyApplication", targets: ["NorbyApplication"]),
        .library(name: "NorbyTelegram", targets: ["NorbyTelegram"]),
        .executable(name: "Norby", targets: ["Norby"])
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
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        )
    ],
    targets: [
        .target(name: "NorbyDomain"),
        .target(
            name: "NorbyMemory",
            dependencies: []
        ),
        .target(
            name: "NorbyHail",
            dependencies: [
                "NorbyDomain",
                .product(name: "Hail", package: "hail"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors")
            ]
        ),
        .target(
            name: "NorbyApplication",
            dependencies: [
                "NorbyDomain",
                "NorbyMemory",
                "NorbyHail",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Hail", package: "hail"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows")
            ]
        ),
        .target(
            name: "NorbyTelegram",
            dependencies: [
                "NorbyDomain",
                "NorbyApplication",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "Norby",
            dependencies: [
                "NorbyApplication",
                "NorbyHail",
                "NorbyTelegram",
                "NorbyPersistence",
                .product(name: "Hail", package: "hail"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "DurableWorkflows", package: "cluster-durable-workflows"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "NorbyDomainTests",
            dependencies: ["NorbyDomain"]
        ),
        .testTarget(
            name: "NorbyMemoryTests",
            dependencies: ["NorbyMemory"]
        ),
        .testTarget(
            name: "NorbyHailTests",
            dependencies: ["NorbyDomain", "NorbyHail", "NorbyApplication"]
        ),
        .testTarget(
            name: "NorbyApplicationTests",
            dependencies: ["NorbyDomain", "NorbyHail", "NorbyApplication"]
        ),
        .testTarget(
            name: "NorbyTelegramTests",
            dependencies: ["NorbyDomain", "NorbyTelegram"]
        ),
        .testTarget(
            name: "NorbyDeliveryTests",
            dependencies: ["Norby"]
        ),
        .target(
            name: "NorbyPersistence",
            dependencies: [
                "NorbyDomain",
                .product(name: "EventSourcing", package: "cluster-event-sourcing")
            ]
        ),
        .testTarget(
            name: "NorbyPersistenceTests",
            dependencies: [
                "NorbyDomain",
                "NorbyPersistence",
                .product(name: "EventSourcing", package: "cluster-event-sourcing")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

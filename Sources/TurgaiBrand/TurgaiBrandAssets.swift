import Foundation

public enum TurgaiBrandAssets {
    public static var publicRoot: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Public")
    }

    public static var stylesheet: URL {
        publicRoot.appendingPathComponent("turgai.css")
    }

    public static var skylark: URL {
        publicRoot.appendingPathComponent("skylark.svg")
    }
}

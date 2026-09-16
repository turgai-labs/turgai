import Foundation

/// Static dashboard assets packaged with the TurgaiWeb target.
public enum TurgaiWebAssets {
    public static var publicRoot: String {
        Bundle.module.resourceURL!.appendingPathComponent("Public").path
    }
}

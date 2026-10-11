import Foundation
import TurgaiBrand

/// Static dashboard assets shared with the public website.
public enum TurgaiWebAssets {
    public static var publicRoot: String {
        TurgaiBrandAssets.publicRoot.path
    }
}

import AppKit
import DiscoverableActors
import DistributedCluster
import Foundation
import IOKit.ps

/// This Mac: its clipboard, battery, and how hard it's working.
@Discoverable
public distributed actor Mac {
    public typealias ActorSystem = ClusterSystem

    public init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        let id = self.id
        let object = try DiscoverableObject.resolve(id: id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    /// The computer's name, such as "Ada's MacBook Pro".
    public distributed var name: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// The text on the clipboard, or null when it holds no text.
    public distributed var clipboard: String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// The battery, or null on a Mac without one.
    public distributed var battery: Battery? {
        Battery.current()
    }

    /// How hot the Mac is running. Above nominal, the system slows work down.
    public distributed var thermalState: ThermalState {
        ThermalState(ProcessInfo.processInfo.thermalState)
    }

    /// Put text on the clipboard, replacing what's there.
    /// - Parameter text: The text to copy.
    public distributed func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A Mac's battery.
@Describable
public struct Battery: Codable, Sendable, Equatable {
    /// Charge, from 0 to 100.
    public var level: Int
    /// Whether it's charging now.
    public var isCharging: Bool
    /// Whether the Mac is connected to power.
    public var isOnPower: Bool

    /// The internal battery's current state, or `nil` without one.
    static func current() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return Battery(
                level: current * 100 / maximum,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }
}

/// How hot a Mac is running.
@Describable
public enum ThermalState: String, Codable, Sendable, CaseIterable {
    /// Normal.
    case nominal
    /// Slightly elevated.
    case fair
    /// High; the system reduces performance.
    case serious
    /// Very high; the system reduces performance significantly.
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        self =
            switch state {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .critical
            }
    }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Mac: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}

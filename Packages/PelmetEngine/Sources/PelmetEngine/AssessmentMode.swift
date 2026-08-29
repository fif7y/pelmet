// AssessmentMode.swift
// Swift face of the MenuBarClientCore shim. The engine's hide/show primitive.

import Foundation
import PelmetCore
import PelmetEngineObjC

/// One active hide state. Process-bound: dropping the instance (or the app
/// crashing) restores the menu bar — macOS invalidates the assertion itself.
public final class AssessmentAssertion {
    private let handle: AnyObject

    fileprivate init(handle: AnyObject) {
        self.handle = handle
    }

    public func invalidate() {
        pelmet_invalidateAssertion(handle)
    }
}

public enum AssessmentMode {
    /// Whether MenuBarClientCore resolved on this OS build. Re-check on app
    /// activation; a 27.x update can remove the private API.
    public static var isAvailable: Bool {
        pelmet_assessmentModeAvailable()
    }

    /// Probe-only: the runtime method surface of the private classes.
    public static var apiDescription: String {
        pelmet_describeAssessmentClasses()
    }

    /// Activates an assertion that keeps only `systemItems` and `bundleIDs`
    /// visible; every other item is hidden and the bar reflows.
    public static func activate(
        allowing systemItems: [SystemItem] = SystemItem.allCases,
        bundleIDs: [String],
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AssessmentAssertion? {
        activate(rawSystemItems: systemItems.map(\.rawValue), bundleIDs: bundleIDs, completion: completion)
    }

    /// Probe-only variant: raw MBSystemItemIdentifier values, including ones
    /// beyond the 9 documented cases — used to test whether the enum extends
    /// to the collateral extras (Now Playing etc.).
    public static func activate(
        rawSystemItems: [Int],
        bundleIDs: [String],
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AssessmentAssertion? {
        let config = pelmet_makeConfiguration(
            rawSystemItems.map { NSNumber(value: $0) },
            bundleIDs
        )
        guard let config else { return nil }
        guard let handle = pelmet_activateAssertion(config, { completion($0) }) else {
            return nil
        }
        return AssessmentAssertion(handle: handle as AnyObject)
    }
}

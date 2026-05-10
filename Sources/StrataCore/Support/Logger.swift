import Foundation
import OSLog

/// Strata's internal log facility. We use Apple's unified logging so that
/// migration events show up in Console.app, persist across launches, and
/// can be correlated with system events.
///
/// Callers should not log into this facility directly — Strata's own
/// operations and safety layer emit structured events that downstream
/// tooling (StrataInspect) can consume.
package enum StrataLog {
    /// The OSLog subsystem identifier. Tests can filter on this when
    /// verifying that the expected log lines were emitted.
    package static let subsystem = "dev.strata.migrations"

    package static let plan      = Logger(subsystem: subsystem, category: "plan")
    package static let stage     = Logger(subsystem: subsystem, category: "stage")
    package static let operation = Logger(subsystem: subsystem, category: "operation")
    package static let safety    = Logger(subsystem: subsystem, category: "safety")
    package static let inspect   = Logger(subsystem: subsystem, category: "inspect")
}

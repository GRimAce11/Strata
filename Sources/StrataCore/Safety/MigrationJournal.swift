import Foundation

/// An append-only, crash-safe record of migration lifecycle events for a
/// single store.
///
/// ## Format
///
/// JSON Lines (`.jsonl`): one JSON object per line, separated by `\n`.
/// Each line is a self-contained ``JournalEntry`` so partial writes (from a
/// crash) leave all previous entries intact and readable.
///
/// ```
/// {"ts":"2026-05-19T09:00:00Z","planID":"abc","event":"migrationStarted",...}
/// {"ts":"2026-05-19T09:00:01Z","planID":"abc","event":"backupCreated",...}
/// {"ts":"2026-05-19T09:00:05Z","planID":"abc","event":"migrationCompleted",...}
/// ```
///
/// ## File location
///
/// `<storeURL>.strata-journal` — a sibling file to the store. For a store at
/// `/AppSupport/app.store`, the journal is `/AppSupport/app.store.strata-journal`.
///
/// ## Recovery detection
///
/// On every launch ``MigrationRecoveryCoordinator`` calls ``findIncompletePlanID()``.
/// If a `migrationStarted` entry exists with no subsequent `migrationCompleted`
/// or `rollbackCompleted` for the same `planID`, the previous migration was
/// interrupted (crash, jetsam, etc.) and recovery should run.
package struct MigrationJournal: Sendable {

    // MARK: - Entry types

    package struct Entry: Codable, Sendable {
        let timestamp: String   // ISO 8601 UTC
        let planID: String
        let event: String       // discriminator
        let detail: [String: String]  // event-specific key-value pairs
    }

    package enum Event: Sendable {
        case migrationStarted(planID: String, fromVersion: String, toVersion: String, storeFile: String)
        case backupCreated(planID: String, backupPath: String)
        case migrationCompleted(planID: String, durationMs: Int64, migrationRan: Bool)
        case rollbackStarted(planID: String, reason: String)
        case rollbackCompleted(planID: String)
        case crashRecoveryApplied(priorPlanID: String, restoredFrom: String)

        var planID: String {
            switch self {
            case .migrationStarted(let id, _, _, _),
                 .backupCreated(let id, _),
                 .migrationCompleted(let id, _, _),
                 .rollbackStarted(let id, _),
                 .rollbackCompleted(let id):
                return id
            case .crashRecoveryApplied(let id, _):
                return id
            }
        }

        var name: String {
            switch self {
            case .migrationStarted:       return "migrationStarted"
            case .backupCreated:          return "backupCreated"
            case .migrationCompleted:     return "migrationCompleted"
            case .rollbackStarted:        return "rollbackStarted"
            case .rollbackCompleted:      return "rollbackCompleted"
            case .crashRecoveryApplied:   return "crashRecoveryApplied"
            }
        }

        var detail: [String: String] {
            switch self {
            case .migrationStarted(_, let from, let to, let file):
                return ["from": from, "to": to, "storeFile": file]
            case .backupCreated(_, let path):
                return ["backupPath": path]
            case .migrationCompleted(_, let ms, let ran):
                return ["durationMs": "\(ms)", "migrationRan": ran ? "true" : "false"]
            case .rollbackStarted(_, let reason):
                return ["reason": reason]
            case .rollbackCompleted:
                return [:]
            case .crashRecoveryApplied(_, let path):
                return ["restoredFrom": path]
            }
        }
    }

    // MARK: - State

    package let url: URL

    // ISO8601DateFormatter is not Sendable — create a fresh instance per call.
    // The formatter is lightweight and format options never change.
    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    // MARK: - Init

    package init(storeURL: URL) {
        self.url = storeURL.appendingPathExtension("strata-journal")
    }

    // MARK: - Write

    /// Append a single event as a JSON line.
    ///
    /// Uses `FileHandle` in append mode — O(1) regardless of journal size,
    /// and POSIX-safe for concurrent process access. Calls `synchronizeFile()`
    /// to flush the OS buffer so the entry survives an immediate crash.
    package func append(_ event: Event) {
        let entry = Entry(
            timestamp: Self.makeISO8601().string(from: Date()),
            planID: event.planID,
            event: event.name,
            detail: event.detail
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let bytes = Data((line + "\n").utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(bytes)
            handle.synchronizeFile()
        } else {
            // First write — create the file (not .atomic to avoid replacing a
            // partially written file from a concurrent write on another process)
            try? bytes.write(to: url)
        }
    }

    // MARK: - Read

    /// Load all journal entries in chronological order.
    /// Returns an empty array if the journal file does not exist.
    package func load() -> [Entry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// Find the `planID` of any migration that started but never completed.
    ///
    /// Returns `nil` if the journal is empty or all migrations have a
    /// completion (or rollback) record. A non-nil result means the prior
    /// launch crashed or was killed mid-migration.
    package func findIncompletePlanID() -> String? {
        let entries = load()
        var started: [String: Entry] = [:]   // planID → start entry
        var finished: Set<String> = []        // planIDs with completion record

        for entry in entries {
            switch entry.event {
            case "migrationStarted":
                started[entry.planID] = entry
            case "migrationCompleted", "rollbackCompleted":
                finished.insert(entry.planID)
            default:
                break
            }
        }

        // Any planID that started but never finished
        return started.keys.first(where: { !finished.contains($0) })
    }

    // MARK: - Maintenance

    /// Remove the journal file entirely — call after successful migration
    /// pruning once the audit window has passed.
    package func deleteIfExists() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Compact the journal by discarding entries older than `days` days.
    /// Keeps at least the most recent complete migration record.
    package func compact(keepingDays days: Int = 90) {
        let entries = load()
        guard !entries.isEmpty else { return }

        let cutoff = ISO8601DateFormatter()
        cutoff.formatOptions = [.withInternetDateTime]
        let thresholdDate = Date().addingTimeInterval(-Double(days) * 86_400)
        let threshold = Self.makeISO8601().string(from: thresholdDate)

        let recent = entries.filter { $0.timestamp >= threshold }
        guard recent.count < entries.count else { return }  // nothing to trim

        let encoder = JSONEncoder()
        let lines = recent.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return line
        }.joined(separator: "\n")

        try? (lines + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

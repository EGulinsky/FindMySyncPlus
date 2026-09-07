import Foundation

/// One run, as Home Assistant sees it.
///
/// Every field here is state the app already holds and already puts on screen — the key
/// statuses, `LogStore.needsFullDiskAccess`, the fatal-error message, and the counts the
/// plan and result lines print every run. Publishing them is reading properties that
/// exist; the only work was carrying `RunMetrics` far enough to reach the transport.
///
/// **This is what makes skipping repeated locations legible.** Availability answers *is
/// the app alive*. It does not answer *did it look at my tracker and decide nothing had
/// changed*, and without these counts those two look identical from Home Assistant.
///
/// It also discharges what #14's close-out comment promised: that reporter would have
/// seen `LocalStorage key: missing` in Home Assistant rather than filing a log line
/// nobody could act on.
struct SyncStatusReport {
    let version: String
    let runSeconds: Double
    let discovered: Int
    let located: Int
    let tracked: Int
    let published: Int
    let skippedUnchanged: Int
    let noLocation: Int
    let unassigned: Int
    let sleptDuringRun: Bool
    /// Whether this run actually relaunched Find My.
    ///
    /// Half of the freshness question. The cache advances because we launch Find My, so
    /// "did the cache move" only means something beside "did we ask it to".
    let findMyLaunched: Bool
    /// When Apple last wrote the newest cache we read.
    ///
    /// Published raw rather than turned into a freshness verdict: mtime answers "a write
    /// happened", never "a position arrived" — a write four seconds after the previous one
    /// carrying an identical digest has been measured. Beside `find_my_launched` and
    /// `skipped_unchanged` it separates the three cases a support thread would otherwise
    /// be opened to distinguish: we asked and it wrote and nothing was new, we asked and
    /// it never wrote, or we never asked.
    let cacheWritten: Date?
    let keys: String
    let fullDiskAccess: Bool
    let lastError: String?

    /// The attribute payload, exactly as published.
    ///
    /// **People template against these, so a rename after shipping is a breaking
    /// change.** The set is settled: three separate reasons a device did not publish
    /// coexist — `no_location`, `unassigned` and `skipped_unchanged` — and a single
    /// `skipped` would not say which.
    ///
    /// Per-device staleness deliberately stays on each device's own attributes. A
    /// per-device map here would recreate exactly the churn this release removes.
    var attributes: [String: Any] {
        [
            "version": version,
            // Raw, like `gps_accuracy`. Rounding to hundredths was tried and bought
            // nothing: Foundation serializes any Double that is not exactly representable
            // at full precision, so `5.11` went on the wire as `5.1100000000000003`
            // anyway — the same shape `gps_accuracy` has shipped with all along.
            "run_seconds": runSeconds,
            "discovered": discovered,
            "located": located,
            "tracked": tracked,
            "published": published,
            "skipped_unchanged": skippedUnchanged,
            "no_location": noLocation,
            "unassigned": unassigned,
            // What survives of the sleep work. The scheduler no longer stops on
            // `willSleep`, but a run that overlapped a sleep looks broken and is not:
            // `run_seconds: 961` on its own is a support thread, and with this beside
            // it the question answers itself.
            "slept_during_run": sleptDuringRun,
            "find_my_launched": findMyLaunched,
            // Built here rather than held as a static: `ISO8601DateFormatter` is not
            // `Sendable`, and this runs once per sync.
            "cache_written": cacheWritten.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "keys": keys,
            "full_disk_access": fullDiskAccess,
            // `NSNull` rather than an omitted key: an attribute that disappears when
            // things are healthy makes every template that reads it need a guard.
            "last_error": lastError ?? NSNull()
        ]
    }

    /// `fmip ok, fmf missing` — one line naming every key's state.
    ///
    /// Ordered fixed rather than by status so the string is stable run to run, and
    /// `localstorage` and `fmf` are reported even when Friends is switched off: "you
    /// have no key for this" and "you have this switched off" are different answers,
    /// and folding them together is what made #14 unanswerable.
    static func keysDescription(fmip: KeyStatus, fmf: KeyStatus, localStorage: KeyStatus) -> String {
        [("fmip", fmip), ("fmf", fmf), ("localstorage", localStorage)]
            .map { "\($0.0) \(describe($0.1))" }
            .joined(separator: ", ")
    }

    /// Deliberately four words, not two. `present` means a key is stored but has never
    /// decrypted anything, and reporting it as `ok` would send a user looking anywhere
    /// but at the key that is actually wrong.
    private static func describe(_ status: KeyStatus) -> String {
        switch status {
        case .notPresent: return "missing"
        case .present:    return "present"
        case .valid:      return "ok"
        case .invalid:    return "invalid"
        }
    }
}

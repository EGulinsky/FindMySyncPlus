import Foundation

// The decisions MQTT publishing makes, separated from the connection that acts on them.
//
// All `nonisolated static` and pure: no socket, no state, no main actor. That is the
// point — `post()` and the delegate callbacks need a live broker and so cannot be reached
// by a test at all, which would leave the rules that decide whether an entity goes quiet,
// or whether a Find My relaunch fires, with no coverage anywhere.
//
// Split out of MQTTClient.swift when that file crossed the 1000-line lint error
// threshold, following `MQTTDiscoveryPayloads`.
extension MQTTClient {

    /// Whether this entity's payload is identical to the one already retained.
    ///
    /// Pure, because `post()` needs a live socket and so cannot be reached by a test at
    /// all — the rule that decides whether an entity goes quiet must be assertable
    /// somewhere. The failure mode being guarded is the reason: always-publish fails
    /// loudly, with bad data someone notices, while suppression fails silently, with an
    /// entity that stops updating and is discovered when it is needed.
    ///
    /// No previous payload always publishes, so the first run after a launch or a
    /// reconnect sends everything.
    nonisolated static func shouldSkipPublish(enabled: Bool,
                                              previous: String?,
                                              current: String) -> Bool {
        guard enabled, let previous else { return false }
        return previous == current
    }

    /// The stored client id, or a fresh one when nothing is stored yet.
    ///
    /// Pure so it can be asserted on directly: the test target is hosted by the app
    /// bundle and shares the user's real UserDefaults, so a test must never build a
    /// `SettingsStore` to check that the id is stable. The caller writes the result
    /// back when it differs from what it passed in.
    ///
    /// **What a stable id does and does not buy.** CocoaMQTT defaults `cleanSession`
    /// to true and we never override it, so no session is resumed either way, and the
    /// last will is registered per connection, so availability works regardless. What
    /// it buys is one identity on the broker instead of one per launch.
    nonisolated static func resolveClientId(stored: String) -> String {
        stored.isEmpty ? "FindMySyncPlus-\(UUID().uuidString.prefix(8))" : stored
    }

    enum InboundOutcome: Equatable {
        case refresh
        case ignoredTopic
        case droppedRetained
    }

    /// A broker replays a retained message to every new subscriber, and we resubscribe on
    /// every reconnect — so one `retain: true` press would become a Find My relaunch on
    /// every reconnect, indefinitely, with nothing on screen to explain it. Reconnects are
    /// routine at boot and after a network blip, so it would present as the app launching
    /// Find My at random. The trigger would live on the broker rather than in our state,
    /// which makes it the worst kind of bug to receive a report about.
    nonisolated static func inboundOutcome(topic: String,
                                           retained: Bool,
                                           refreshTopic: String) -> InboundOutcome {
        guard topic == refreshTopic else { return .ignoredTopic }
        return retained ? .droppedRetained : .refresh
    }

    enum RefreshButtonAction: Equatable {
        case publish
        case clear
        case none
    }

    /// Clearing is conditional on having published it, so a user who has never switched
    /// the trigger on never pays for a tombstone they do not need — the alternative was
    /// an extra retained publish every session for everyone.
    nonisolated static func refreshButtonAction(enabled: Bool,
                                                wasPublished: Bool) -> RefreshButtonAction {
        if enabled { return .publish }
        return wasPublished ? .clear : .none
    }

    /// A payload as the exact string that goes on the wire.
    ///
    /// `sortedKeys` so two serializations of equal content are byte-identical —
    /// without it, comparing this run's payload against the last one would depend on
    /// dictionary ordering rather than on whether anything changed.
    nonisolated static func jsonString(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}

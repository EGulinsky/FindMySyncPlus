import Foundation
import CocoaMQTT

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

    /// The last will: retained `offline` on the availability topic.
    ///
    /// **Quitting deliberately does not send a clean DISCONNECT.** It used to publish
    /// `offline` and then close, and the frame never reached the broker — the socket went
    /// down in the same turn, and neither a runloop spin nor a blocking sleep could flush
    /// it. The will is the mechanism MQTT provides for exactly this, so quitting now takes
    /// the same path as a crash or a pulled cable: one behaviour, no race.
    ///
    /// Extracted so the shape can be asserted without a socket. It is the only thing
    /// standing between a quit and a retained `online` that never clears, and the demo
    /// broker implements no wills, so nothing else can check it.
    nonisolated static func willMessage(prefix: String) -> CocoaMQTTMessage {
        CocoaMQTTMessage(topic: availabilityTopic(prefix: prefix),
                         string: availabilityOffline,
                         qos: .qos1,
                         retained: true)
    }

    /// What happened to one device's attributes this cycle.
    ///
    /// Three outcomes rather than a `Bool`, because a skip and a failure are opposite
    /// things that both mean "nothing went out": one is the feature working, the other
    /// is an entity silently going dark.
    enum AttributePublishOutcome {
        case published
        /// Split by reason: "nothing changed" and "it moved less than you asked me to care
        /// about" are different answers to "why did my entity go quiet", and only the
        /// second is a decision the app made.
        case skippedIdentical
        case skippedWithinThreshold
        case failed
    }

    /// The parts of a publish cycle that are the same for every device in it.
    struct AttributeCycle {
        let prefix: String
        let iso: ISO8601DateFormatter
        let skipRepeats: Bool
        let minimumMovementMetres: Double
    }

    // MARK: - Suppressing a position that has not meaningfully moved

    /// What the last publish for one entity looked like.
    ///
    /// The position is held apart from the rest because the two are compared differently:
    /// everything else has to match exactly, while the position only has to be close.
    struct PublishedState {
        let signature: String
        let latitude: Double
        let longitude: Double
    }

    enum SuppressionDecision: Equatable {
        case publish
        /// Same coordinates to the last decimal.
        case identical
        /// Moved, but no further than the threshold. Carries the distance, because a user
        /// debugging silence needs to know how far it decided was near enough.
        case withinThreshold(Double)
    }

    /// Attributes deliberately left out of the exact comparison.
    ///
    /// **Position**, because it is compared by distance instead — comparing it exactly is
    /// what made suppression useless: three stationary runs on a live account moved every
    /// actively-located device by between 0.01 mm and 1.4 m, all of it far inside the 3 m
    /// accuracy those devices reported.
    ///
    /// **Time**, because `last_update` and `location_timestamp` change whenever Apple
    /// rewrites a record — so leaving them in would mean any recomputed fix publishes,
    /// whatever the threshold, and the feature would do nothing for exactly the devices it
    /// is meant to quiet.
    ///
    /// The row reads "Skip repeated locations", and a repeated location is the same place
    /// again — so the position decides, and a fresh observation of an unchanged position is
    /// a repeat. The accepted consequence is that a skipped entity's timestamps stop
    /// advancing in Home Assistant; app-level freshness lives on the status entity and the
    /// Connected sensor.
    nonisolated static let volatileAttributeKeys: Set<String> = [
        "latitude", "longitude", "gps_accuracy", "altitude", "vertical_accuracy",
        "speed", "course", "last_update", "location_timestamp"
    ]

    /// The payload minus everything that moves on its own, as a comparable string.
    nonisolated static func signature(of attrs: [String: Any]) -> String? {
        jsonString(attrs.filter { !volatileAttributeKeys.contains($0.key) })
    }

    /// Metres between two coordinates.
    ///
    /// Equirectangular rather than haversine: at the distances that decide this — under a
    /// few metres — the two agree far beyond the precision of the inputs, and this one can
    /// be read at a glance. A degree of latitude is ~111,320 m everywhere; a degree of
    /// longitude shrinks by the cosine of the latitude, which is the only correction needed.
    nonisolated static func metresBetween(_ fromLat: Double, _ fromLon: Double,
                                          _ toLat: Double, _ toLon: Double) -> Double {
        let metresPerDegreeLatitude = 111_320.0
        let northing = (toLat - fromLat) * metresPerDegreeLatitude
        let meanLatitude = ((fromLat + toLat) / 2) * .pi / 180
        let easting = (toLon - fromLon) * metresPerDegreeLatitude * cos(meanLatitude)
        return (northing * northing + easting * easting).squareRoot()
    }

    /// Whether this entity's update can be held back.
    ///
    /// **The toggle owns on and off; the threshold only ever widens.** A threshold of 0 is
    /// the strictest setting rather than an escape hatch — identical coordinates only —
    /// because a zero that meant "publish everything" would let a stale tracker republish
    /// forever, which is the thing suppression exists to stop.
    ///
    /// The comparison is `<=`, not `<`. With `<`, a threshold of 0 would never suppress
    /// anything, since two identical positions are 0 m apart: the feature would look
    /// enabled and do nothing.
    ///
    /// No previous state always publishes, so the first run after a launch or a reconnect
    /// sends everything.
    nonisolated static func suppressionDecision(enabled: Bool,
                                                previous: PublishedState?,
                                                current: PublishedState,
                                                thresholdMetres: Double) -> SuppressionDecision {
        guard enabled, let previous else { return .publish }

        // Any real attribute change — battery, charging, separation — publishes however
        // wide the threshold. Only the position is allowed to be approximately equal.
        guard previous.signature == current.signature else { return .publish }

        let moved = metresBetween(previous.latitude, previous.longitude,
                                  current.latitude, current.longitude)
        if moved == 0 { return .identical }
        return moved <= thresholdMetres ? .withinThreshold(moved) : .publish
    }
}

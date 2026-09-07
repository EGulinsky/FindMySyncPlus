import Testing
import Foundation
import CocoaMQTT
@testable import FindMySyncPlus

/// The 1.5b pieces: a stable client id, availability, the status entity, and skipping
/// a position Find My has already reported.
///
/// Nothing here builds a `SettingsStore`. The test target is hosted by the app bundle
/// and shares the user's real UserDefaults, so constructing one would write over their
/// configuration — which is why each rule below is reachable as a pure function.
@Suite("Sync status, availability and suppression")
@MainActor
struct SyncStatusAndAvailabilityTests {

    private static let prefix = "findmysyncplus/"
    private static let devId = "findmy_wallet"

    // MARK: - Stable client id

    @Test("a stored client id is reused rather than replaced")
    func storedClientIdIsReused() {
        #expect(MQTTClient.resolveClientId(stored: "FindMySyncPlus-abc12345")
                == "FindMySyncPlus-abc12345")
    }

    /// The defect this fixes: a fresh identity every launch, so the broker saw a new
    /// client each time and a broker retaining client state accumulated a dead entry
    /// per launch.
    @Test("an empty stored id yields a new one, and two of them differ")
    func emptyClientIdIsGenerated() {
        let first = MQTTClient.resolveClientId(stored: "")
        let second = MQTTClient.resolveClientId(stored: "")

        #expect(first.hasPrefix("FindMySyncPlus-"))
        #expect(first != second, "each install must get its own id, or two Macs fight over one session")
        #expect(MQTTClient.resolveClientId(stored: first) == first,
                "once stored, it must never change again")
    }

    // MARK: - Availability

    /// `availability` is a leaf and `status/` is a namespace. Upstream PR #50 puts
    /// availability at `<prefix>status`, which works alone and breaks the moment the
    /// status entity arrives — that topic would hold "online" while
    /// `<prefix>status/state` held a timestamp.
    @Test("availability and status occupy separate topics")
    func topicsDoNotCollide() {
        #expect(MQTTClient.availabilityTopic(prefix: Self.prefix) == "findmysyncplus/availability")
        #expect(MQTTClient.statusStateTopic(prefix: Self.prefix) == "findmysyncplus/status/state")
        #expect(MQTTClient.statusAttributesTopic(prefix: Self.prefix)
                == "findmysyncplus/status/attributes")
    }

    /// Without this a tracker holds its last known position forever once the Mac goes
    /// away, with nothing to say the app stopped.
    @Test("every discovery payload references the one availability topic")
    func discoveryPayloadsCarryAvailability() throws {
        let tracker = MQTTClient.discoveryPayload(devId: Self.devId,
                                                  displayName: "Wallet",
                                                  topicPrefix: Self.prefix)
        let battery = MQTTClient.batterySensorPayload(devId: Self.devId,
                                                      displayName: "Wallet",
                                                      topicPrefix: Self.prefix)
        let status = MQTTClient.statusPayload(topicPrefix: Self.prefix)

        for payload in [tracker, battery, status] {
            #expect(payload["availability_topic"] as? String == "findmysyncplus/availability")
        }
    }

    @Test("the availability payloads are HA's own defaults, so no extra keys are needed")
    func availabilityPayloadsMatchHomeAssistantDefaults() {
        #expect(MQTTClient.availabilityOnline == "online")
        #expect(MQTTClient.availabilityOffline == "offline")

        let tracker = MQTTClient.discoveryPayload(devId: Self.devId,
                                                  displayName: "Wallet",
                                                  topicPrefix: Self.prefix)
        #expect(tracker["payload_available"] == nil)
        #expect(tracker["payload_not_available"] == nil)
    }

    // MARK: - Status entity

    /// A singleton, not a devId — which is why retired-alias cleanup never sweeps it.
    @Test("the status entity is a singleton sensor with a timestamp state")
    func statusPayloadShape() {
        let payload = MQTTClient.statusPayload(topicPrefix: Self.prefix)

        #expect(MQTTClient.statusDiscoveryTopic()
                == "homeassistant/sensor/findmysyncplus_status/config")
        #expect(payload["unique_id"] as? String == "findmysyncplus_status")
        #expect(payload["default_entity_id"] as? String == "sensor.findmysyncplus_status")
        #expect(payload["device_class"] as? String == "timestamp")
        #expect(payload["state_topic"] as? String == "findmysyncplus/status/state")
        #expect(payload["json_attributes_topic"] as? String == "findmysyncplus/status/attributes")
        // `object_id` was removed from HA in Core 2026.4 and must not come back here.
        #expect(payload["object_id"] == nil)
    }

    /// Retiring an alias works from an explicit list rather than sweeping the prefix,
    /// so the status entity is safe without an exemption. Asserted because the discovered
    /// button in the refresh-trigger spec *did* need one.
    @Test("retirement never sweeps the status entity")
    func retirementLeavesStatusAlone() {
        let tombstones = MQTTClient.tombstonesToPublish(
            retired: ["findmy_old", MQTTClient.statusDevId],
            liveDevIds: [MQTTClient.statusDevId]
        )
        #expect(tombstones == ["findmy_old"])
    }

    private static func report(skippedUnchanged: Int = 9,
                               sleptDuringRun: Bool = false,
                               lastError: String? = nil) -> SyncStatusReport {
        SyncStatusReport(version: "1.5b", transport: "mqtt", runSeconds: 5.0341,
                         discovered: 13, located: 12, tracked: 11, published: 2,
                         skippedUnchanged: skippedUnchanged, noLocation: 2, unassigned: 1,
                         sleptDuringRun: sleptDuringRun,
                         keys: "fmip ok, fmf missing, localstorage missing",
                         fullDiskAccess: true, lastError: lastError)
    }

    /// **People template against these**, so a rename after shipping is a breaking
    /// change. The set is asserted whole rather than key by key: a key quietly added or
    /// dropped is exactly what this must catch.
    @Test("the attribute set is exactly the published contract")
    func attributeKeysAreSettled() {
        let keys = Set(Self.report().attributes.keys)

        #expect(keys == [
            "version", "transport", "run_seconds", "discovered", "located", "tracked",
            "published", "skipped_unchanged", "no_location", "unassigned",
            "slept_during_run", "keys", "full_disk_access", "last_error"
        ])
    }

    /// Three separate reasons a device did not publish coexist. A single `skipped`
    /// would not say which, and the other two already have their own keys.
    @Test("the three not-published reasons stay separate")
    func notPublishedReasonsAreDistinct() {
        let attrs = Self.report().attributes

        #expect(attrs["skipped_unchanged"] as? Int == 9)
        #expect(attrs["no_location"] as? Int == 2)
        #expect(attrs["unassigned"] as? Int == 1)
        #expect(attrs["skipped"] == nil, "the ambiguous name must not appear")
    }

    /// Microsecond noise on the run duration would change the payload every run and
    /// make an uneventful sync look eventful.
    @Test("run_seconds is rounded to hundredths")
    func runSecondsIsRounded() {
        #expect(Self.report().attributes["run_seconds"] as? Double == 5.03)
    }

    /// A run of 961 seconds looks broken on its own and is not. The scheduler no longer
    /// stops on sleep, so this is what is left of the sleep work.
    @Test("a sleep inside the run is reported, not acted on")
    func sleepIsReported() {
        #expect(Self.report(sleptDuringRun: true).attributes["slept_during_run"] as? Bool == true)
        #expect(Self.report().attributes["slept_during_run"] as? Bool == false)
    }

    /// An attribute that vanishes when things are healthy makes every template that
    /// reads it need a guard.
    @Test("last_error is present as null when there is no error")
    func lastErrorIsAlwaysPresent() {
        #expect(Self.report().attributes["last_error"] is NSNull)
        #expect(Self.report(lastError: "Full Disk Access required").attributes["last_error"] as? String
                == "Full Disk Access required")
    }

    /// `present` means stored but never used to decrypt anything. Reporting it as `ok`
    /// would send a user looking anywhere but at the key that is wrong.
    @Test("each key state gets its own word")
    func keyStatesAreDistinguished() {
        #expect(SyncStatusReport.keysDescription(fmip: .valid, fmf: .notPresent,
                                                 localStorage: .notPresent)
                == "fmip ok, fmf missing, localstorage missing")
        #expect(SyncStatusReport.keysDescription(fmip: .present, fmf: .invalid,
                                                 localStorage: .valid)
                == "fmip present, fmf invalid, localstorage ok")
    }

    // MARK: - Skipping repeated locations

    @Test("nothing is skipped while the setting is off")
    func skippingIsOptIn() {
        #expect(MQTTClient.shouldSkipPublish(enabled: false, previous: "{}", current: "{}") == false)
    }

    @Test("an identical payload is skipped and a changed one is not")
    func skipsOnlyIdenticalPayloads() {
        #expect(MQTTClient.shouldSkipPublish(enabled: true, previous: "{\"a\":1}",
                                             current: "{\"a\":1}"))
        #expect(MQTTClient.shouldSkipPublish(enabled: true, previous: "{\"a\":1}",
                                             current: "{\"a\":2}") == false)
    }

    /// The first run after a launch or a reconnect must send everything: retained
    /// discovery is republished then, and a config with no state behind it is an empty
    /// entity.
    @Test("with no previous payload, everything publishes")
    func firstRunAlwaysPublishes() {
        #expect(MQTTClient.shouldSkipPublish(enabled: true, previous: nil,
                                             current: "{\"a\":1}") == false)
    }

    /// Key order must not decide whether an entity goes quiet.
    @Test("equal payloads serialize byte-identically whatever the insertion order")
    func serializationIsOrderStable() throws {
        let first = try #require(MQTTClient.jsonString(["b": 2, "a": 1]))
        let second = try #require(MQTTClient.jsonString(["a": 1, "b": 2]))
        #expect(first == second)
    }

    // MARK: - last_update carries the fix time

    private static func point(timestamp: Date?) -> DevicePoint {
        DevicePoint(id: "AAAA", name: "Wallet", latitude: 51.5, longitude: -0.12,
                    accuracy: 12, battery: nil,
                    richAttributes: RichLocationAttributes(
                        verticalAccuracy: nil, altitude: nil, speed: nil, course: nil,
                        timestamp: timestamp, motionActivityState: nil, locationLabel: nil))
    }

    /// `last_update` was `Date()`, so Home Assistant saw an attribute change every
    /// cycle and a 43-hour-old position was presented as having just arrived. It is
    /// also the only reason the payload was unstable, so nothing could be compared
    /// against the previous run.
    @Test("last_update is the fix time, not the publish time")
    func lastUpdateIsTheFixTime() throws {
        let iso = ISO8601DateFormatter()
        let fixedAt = Date(timeIntervalSince1970: 1_756_000_000)
        let attrs = MQTTClient().buildAttributes(for: Self.point(timestamp: fixedAt), iso: iso)

        #expect(attrs["last_update"] as? String == iso.string(from: fixedAt))
        #expect(attrs["last_update"] as? String == attrs["location_timestamp"] as? String)
    }

    /// Two builds of an unchanged record must be byte-identical, or suppression could
    /// never fire.
    @Test("an unchanged record builds the same payload twice")
    func unchangedRecordIsStable() throws {
        let iso = ISO8601DateFormatter()
        let point = Self.point(timestamp: Date(timeIntervalSince1970: 1_756_000_000))
        let client = MQTTClient()

        let first = try #require(MQTTClient.jsonString(client.buildAttributes(for: point, iso: iso)))
        let second = try #require(MQTTClient.jsonString(client.buildAttributes(for: point, iso: iso)))
        #expect(first == second)
    }

    /// The safe direction: a record Apple gives no timestamp for keeps the publish time
    /// and so never matches itself. It publishes every cycle rather than going quiet on
    /// a record we cannot reason about.
    @Test("a record with no fix time never suppresses itself")
    func recordWithoutTimestampKeepsPublishing() throws {
        let iso = ISO8601DateFormatter()
        let point = Self.point(timestamp: nil)
        let client = MQTTClient()
        let firstRun = Date(timeIntervalSince1970: 1_756_000_000)

        let first = try #require(MQTTClient.jsonString(
            client.buildAttributes(for: point, iso: iso, now: firstRun)))
        #expect(first.contains("last_update"),
                "the field must stay present for anyone templating on it")
        #expect(!first.contains("location_timestamp"),
                "no fix time means no location_timestamp — a fabricated one would claim a reading")

        // One sync interval later, the same unchanged record still publishes.
        let later = try #require(MQTTClient.jsonString(
            client.buildAttributes(for: point, iso: iso,
                                   now: firstRun.addingTimeInterval(300))))
        #expect(MQTTClient.shouldSkipPublish(enabled: true, previous: first, current: later) == false)
    }
}

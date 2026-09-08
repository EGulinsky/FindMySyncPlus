import Foundation
import CocoaMQTT

enum MQTTConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}

@MainActor
final class MQTTClient: NSObject, ObservableObject, TransportClient {
    @Published private(set) var connectionState: MQTTConnectionState = .disconnected

    private var client: CocoaMQTT?
    private var reconnectTask: Task<Void, Never>?
    private(set) var reconnectAttempts = 0
    private var publishedDiscoveryIds: Set<String> = []
    /// Separate from `publishedDiscoveryIds` on purpose — see
    /// `publishBatterySensorIfNeeded`.
    private var publishedBatterySensorIds: Set<String> = []

    private weak var logger: LogStore?
    private weak var settings: SettingsStore?
    private var intentionalDisconnect = false

    /// Identity of the client this object currently owns. CocoaMQTT's delegate
    /// callbacks arrive asynchronously and are then hopped to the main actor, so a
    /// client we have already torn down can report state long after it stopped being
    /// the active connection. Compared as a token because `CocoaMQTT` is not `Sendable`.
    private var activeClientToken: ObjectIdentifier?

    /// The availability topic this connection registered its will against.
    ///
    /// Held rather than recomputed so the `online` publish, the will and the `offline`
    /// on quit all name the same topic even if the user edits `mqttTopicPrefix`
    /// mid-session — otherwise a retained `online` would be stranded under the old
    /// prefix with nothing left to clear it.
    private var availabilityTopicInUse: String?

    /// Set once the status entity's discovery config has gone out this session, the
    /// same per-session gate the trackers use.
    private var publishedStatusDiscovery = false

    /// Set once this session has settled the refresh button — published when the trigger
    /// is on, cleared when it is off. Both directions run once, so flipping the setting
    /// cannot leave a button behind that presses into nothing.
    private var settledRefreshButton = false

    /// Called when a refresh is asked for over MQTT. Set by `AppModel`, which owns the
    /// decision about whether a run may start; this object only decides that a genuine,
    /// non-retained request arrived on the right topic.
    var onRefreshRequested: (@MainActor () -> Void)?

    /// Last published attributes payload per devId, for suppressing repeats.
    ///
    /// Cleared on reconnect beside `publishedDiscoveryIds`: retained discovery is
    /// republished then, and a suppression map that survived would leave an entity
    /// with a fresh config and no state behind it.
    private var lastPublishedAttributes: [String: String] = [:]

    /// When the in-flight attempt started, so a stalled one is replaced rather than
    /// leaving the client wedged in `.connecting`.
    private var connectingSince: Date?
    nonisolated static let connectingTimeout: TimeInterval = 15

    /// Sized so the whole retry chain (0.25 + 0.5 + 1 + 2 + 4 + 8 + 16 ≈ 32s) finishes
    /// inside one scheduler interval — the minimum is 60s. The sync run is then the
    /// outer retry loop, and the two never overlap: a pre-flight firing while a retry
    /// is queued would cancel it and restart the schedule, so it could never end.
    nonisolated static let maxReconnectAttempts = 7

    func bind(logger: LogStore, settings: SettingsStore) {
        self.logger = logger
        self.settings = settings
    }

    #if DEBUG
    /// Seeds the retry counter so backoff behavior can be tested without opening a
    /// socket. Mirrors `CacheDecryptor.loadKeyForTesting`.
    func setReconnectAttemptsForTesting(_ value: Int) { reconnectAttempts = value }
    #endif

    // MARK: - Connection lifecycle

    /// - Parameter resetBackoff: `true` for a connection the app asks for (startup,
    ///   pre-flight, the connection test), which starts a fresh retry schedule. `false`
    ///   for a scheduled reconnect, which must keep advancing the existing one.
    func connect(settings: SettingsStore, resetBackoff: Bool = true) {
        disconnect(resetBackoff: resetBackoff)
        intentionalDisconnect = false
        guard !settings.mqttHost.isEmpty else {
            logger?.warn("MQTT: host not configured")
            return
        }

        // Generated once and persisted, so the broker sees one identity for this
        // install rather than one per launch.
        let clientId = Self.resolveClientId(stored: settings.mqttClientId)
        if settings.mqttClientId != clientId {
            settings.mqttClientId = clientId
            logger?.info("MQTT: client id assigned for this install")
        }
        let mqtt = CocoaMQTT(
            clientID: clientId,
            host: settings.mqttHost,
            port: UInt16(settings.mqttPort)
        )
        if !settings.mqttUsername.isEmpty {
            mqtt.username = settings.mqttUsername
            if !settings.mqttPassword.isEmpty {
                mqtt.password = settings.mqttPassword
            }
        }
        mqtt.keepAlive = 60
        mqtt.autoReconnect = false
        // The last will, registered per connection: the broker publishes it if this
        // Mac disappears without a clean DISCONNECT, so every entity referencing the
        // topic goes unavailable instead of holding its last position forever.
        let availabilityTopic = Self.availabilityTopic(prefix: settings.mqttTopicPrefix)
        availabilityTopicInUse = availabilityTopic
        mqtt.willMessage = CocoaMQTTMessage(topic: availabilityTopic,
                                            string: Self.availabilityOffline,
                                            qos: .qos1,
                                            retained: true)
        if settings.mqttUseTLS {
            mqtt.enableSSL = true
            mqtt.allowUntrustCACertificate = true
        }
        mqtt.delegate = self
        client = mqtt
        activeClientToken = ObjectIdentifier(mqtt)

        connectionState = .connecting
        connectingSince = Date()
        logger?.info("MQTT connecting to \(settings.mqttHost):\(settings.mqttPort)")
        _ = mqtt.connect()
    }

    func disconnect(resetBackoff: Bool = true) {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        // Only a fresh, externally requested connection restarts the schedule. A retry
        // tears the client down too, and resetting here would pin every attempt at the
        // first delay — an endless fast loop that never backs off or gives up.
        if resetBackoff { reconnectAttempts = 0 }
        client?.disconnect()
        client = nil
        activeClientToken = nil
        connectionState = .disconnected
        connectingSince = nil
        publishedDiscoveryIds.removeAll()
        publishedBatterySensorIds.removeAll()
        publishedStatusDiscovery = false
        lastPublishedAttributes.removeAll()
    }

    // MARK: - Availability

    /// Publish the app-level availability state, retained.
    ///
    /// Retained on purpose: a subscriber that connects later must learn the current
    /// state rather than wait for the next transition.
    private func publishAvailability(_ state: String) {
        guard let client, let topic = availabilityTopicInUse else { return }
        client.send(CocoaMQTTMessage(topic: topic, string: state, qos: .qos1, retained: true))
    }

    /// Say `offline` and disconnect, for an app that is quitting.
    ///
    /// **The will alone is not enough.** The broker publishes a will only when the
    /// connection drops *without* a DISCONNECT packet; a clean quit sends one, the
    /// will is discarded, and the retained `online` stands forever. Availability
    /// would then cover a crash or a pulled cable and miss the ordinary case of
    /// quitting the app.
    ///
    /// **The trigger is termination, not `stop()`.** The scheduler stopping is not
    /// the app going away — publishing `offline` from there would say the app is gone
    /// while it is sitting on screen.
    func publishOfflineForTermination() {
        guard connectionState == .connected, client != nil else { return }
        publishAvailability(Self.availabilityOffline)
        logger?.info("MQTT: published offline before quitting")
        // The publish is queued on the socket's own queue, and the process is about to
        // exit. `disconnect()` queues DISCONNECT behind it, so the ordering is right;
        // what is missing is time for either to reach the wire. A short bounded spin
        // is the whole remedy — without it the retained `online` can survive a clean
        // quit, which is the exact case this method exists for.
        disconnect()
        RunLoop.current.run(until: Date().addingTimeInterval(Self.terminationFlushSeconds))
    }

    /// Long enough for a queued PUBLISH and DISCONNECT to leave the socket, short
    /// enough that quitting still feels immediate.
    nonisolated static let terminationFlushSeconds: TimeInterval = 0.3

    func ensureConnected(settings: SettingsStore) async -> Bool {
        if connectionState == .connected { return true }

        // Don't restart an attempt that is already in flight: `connect()` begins by
        // tearing the current client down, which surfaces as an unexpected disconnect.
        let stalled = connectingSince.map { Date().timeIntervalSince($0) > Self.connectingTimeout } ?? true
        if connectionState != .connecting || stalled {
            connect(settings: settings)
        }
        // Wait up to 5 seconds for connection
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if connectionState == .connected { return true }
        }
        return connectionState == .connected
    }

    // MARK: - Connection test

    func testConnection(settings: SettingsStore) async -> (Bool, String) {
        let wasConnected = connectionState == .connected
        if !wasConnected {
            connect(settings: settings)
        }
        // Wait up to 5 seconds
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if connectionState == .connected {
                if !wasConnected {
                    disconnect()
                }
                return (true, "Connected successfully to \(settings.mqttHost):\(settings.mqttPort)")
            }
        }
        let msg = "Connection failed to \(settings.mqttHost):\(settings.mqttPort)"
        if !wasConnected {
            disconnect()
        }
        return (false, msg)
    }

    // MARK: - Publishing

    func post(_ devices: [DevicePoint],
              aliasByUUID: [String: String],
              settings: SettingsStore,
              logger: LogStore,
              dryRun: Bool = false) async -> PostSummary {

        if dryRun {
            for d in devices {
                let uuid = d.id.normalized()
                if let alias = aliasByUUID[uuid] {
                    let devId = DeviceAlias.entityID(for: alias)
                    logger.info("[DRY] Would publish MQTT for dev_id=\(devId)")
                } else {
                    logger.warn("[DRY] Skipping \(uuid): no alias mapping found")
                }
            }
            return PostSummary(successCount: 0, authRejectedCount: 0, transientCount: 0)
        }

        guard connectionState == .connected, let client else {
            logger.warn("MQTT: not connected, skipping publish")
            return PostSummary(successCount: 0, authRejectedCount: 0,
                               transientCount: devices.count)
        }

        var successCount = 0
        var transientCount = 0
        var skippedUnchangedCount = 0
        let prefix = settings.mqttTopicPrefix
        let iso = ISO8601DateFormatter()
        let cycle = AttributeCycle(prefix: prefix, iso: iso,
                                   skipRepeats: settings.skipRepeatedLocations)

        drainRetiredDevIds(client: client, aliasByUUID: aliasByUUID,
                           settings: settings, logger: logger, prefix: prefix)

        for d in devices {
            let uuid = d.id.normalized()
            guard let alias = aliasByUUID[uuid] else {
                transientCount += 1
                logger.warn("MQTT: no alias for UUID \(uuid)")
                continue
            }

            let devId = DeviceAlias.entityID(for: alias)

            // Publish HA auto-discovery config (once per session). The
            // `device` block groups all FindMySync+ entities under a single
            // device card in HA's Devices & Services view. No `state_topic`
            // on purpose — HA derives tracker state from latitude/longitude
            // in json_attributes_topic (device_tracker.mqtt + source_type=gps);
            // publishing state messages on every sync caused home → not_home
            // → home flapping that reset zone-duration counters (commit 4c28f0d).
            if !publishedDiscoveryIds.contains(devId) {
                let configTopic = Self.discoveryTopic(forDevId: devId)
                let configPayload = Self.discoveryPayload(
                    devId: devId,
                    displayName: d.name.isEmpty ? alias : d.name,
                    topicPrefix: prefix
                )
                publishJSON(client: client, topic: configTopic, payload: configPayload, retain: true)
                publishedDiscoveryIds.insert(devId)
                logger.info("MQTT discovery published for \(devId) as device_tracker.\(haSlug(devId))")
            }

            publishBatterySensorIfNeeded(client: client, device: d, devId: devId,
                                         displayName: d.name.isEmpty ? alias : d.name,
                                         prefix: prefix)

            switch publishAttributes(client: client, device: d, devId: devId,
                                     cycle: cycle, logger: logger) {
            case .published:      successCount += 1
            case .skippedUnchanged: skippedUnchangedCount += 1
            case .failed:         transientCount += 1
            }
        }

        // Never silent: with skipping on, "working as intended" and "broken" look
        // identical from the outside, and this line plus `skipped_unchanged` on the
        // status entity are the two things that tell them apart.
        if skippedUnchangedCount > 0 {
            logger.info("MQTT: \(skippedUnchangedCount) entit\(skippedUnchangedCount == 1 ? "y" : "ies") "
                        + "unchanged since the last publish, not republished")
        }

        return PostSummary(successCount: successCount,
                           authRejectedCount: 0,
                           transientCount: transientCount,
                           skippedUnchangedCount: skippedUnchangedCount)
    }

    /// What happened to one device's attributes this cycle.
    ///
    /// Three outcomes rather than a `Bool`, because a skip and a failure are opposite
    /// things that both mean "nothing went out": one is the feature working, the other
    /// is an entity silently going dark.
    enum AttributePublishOutcome {
        case published
        case skippedUnchanged
        case failed
    }

    /// Build and publish one device's attributes, skipping a payload identical to the
    /// one already retained on the broker.
    ///
    /// The comparison is the whole payload rather than a coordinate check, and that is
    /// only sound because `last_update` now carries the fix time instead of `Date()` —
    /// see `buildAttributes`. A record Apple gives no timestamp for keeps the publish
    /// time and so never matches itself, which is the safe direction: it publishes,
    /// loudly, rather than going quiet on a record we cannot reason about.
    /// The parts of a publish cycle that are the same for every device in it.
    struct AttributeCycle {
        let prefix: String
        let iso: ISO8601DateFormatter
        let skipRepeats: Bool
    }

    private func publishAttributes(client: MQTTPublishing,
                                   device: DevicePoint,
                                   devId: String,
                                   cycle: AttributeCycle,
                                   logger: LogStore) -> AttributePublishOutcome {
        let (prefix, iso, skipRepeats) = (cycle.prefix, cycle.iso, cycle.skipRepeats)
        guard let json = Self.jsonString(buildAttributes(for: device, iso: iso)) else {
            logger.warn("[\(devId)] MQTT: attributes could not be serialized; not published")
            return .failed
        }

        if Self.shouldSkipPublish(enabled: skipRepeats,
                                  previous: lastPublishedAttributes[devId],
                                  current: json) {
            logger.debug("[\(devId)] unchanged since the last publish — skipped")
            return .skippedUnchanged
        }

        client.send(CocoaMQTTMessage(topic: Self.attributesTopic(forDevId: devId, prefix: prefix),
                                     string: json, qos: .qos1, retained: true))
        lastPublishedAttributes[devId] = json
        logger.info("[\(devId)] MQTT published")
        return .published
    }

    // MARK: - Refresh trigger

    /// Subscribe to the one topic this app listens on, if the user has turned it on.
    ///
    /// Called from the connect ack, inside the `activeClientToken` guard: a subscribe
    /// from a client we have already replaced is the same bug class the token exists for.
    /// Re-established on every reconnect, like discovery re-publication.
    private func subscribeToRefreshTopic() {
        guard let settings, settings.enableRefreshTrigger, let client else { return }
        let topic = Self.refreshSyncTopic(prefix: settings.mqttTopicPrefix)
        client.subscribe(topic, qos: .qos1)
    }

    /// Apply a change to the trigger setting now, rather than at the next connection.
    ///
    /// Both halves of this feature used to live in the connect ack alone, so switching
    /// the setting on did nothing at all — no subscription, no button, and nothing in the
    /// log — until the app reconnected or restarted. The user's next move is to go and
    /// look for the button in Home Assistant, so the gap presented as the feature being
    /// broken. Renaming an alias already applies at the moment of the action; this brings
    /// the trigger into line with it.
    func applyRefreshTriggerSetting(enabled: Bool, prefix: String) {
        guard connectionState == .connected, let client else {
            logger?.info("MQTT: not connected — sync requests will be set up on the next connection")
            return
        }

        let topic = Self.refreshSyncTopic(prefix: prefix)
        if enabled {
            client.subscribe(topic, qos: .qos1)
        } else {
            client.unsubscribe(topic)
            logger?.info("MQTT unsubscribed from \(topic)")
        }

        // Settle the button again against the new value: this is a deliberate second pass
        // in one session, which the per-session latch would otherwise block.
        settledRefreshButton = false
        settleRefreshButton(client: client, enabled: enabled, prefix: prefix)
    }

    /// Decide what an inbound message means.
    ///
    /// Pure so the retained-message guard can be asserted on: it is the difference
    /// between a working feature and the app relaunching Find My at apparently random
    /// moments, and a delegate callback cannot be reached by a test.
    private func handleInbound(topic: String, retained: Bool) {
        guard let settings else { return }
        let refreshTopic = Self.refreshSyncTopic(prefix: settings.mqttTopicPrefix)

        switch Self.inboundOutcome(topic: topic, retained: retained, refreshTopic: refreshTopic) {
        case .ignoredTopic:
            logger?.debug("MQTT: ignoring a message on \(topic)")
        case .droppedRetained:
            // Never silent: this line is the only thing that could ever explain the
            // symptom, and a silently ignored trigger is the same class of failure as a
            // silently fired one.
            logger?.warn("MQTT: dropped a retained message on \(topic). A retained press "
                         + "would fire on every reconnect — republish it with retain off.")
        case .refresh:
            logger?.info("MQTT: refresh and sync requested on \(topic)")
            onRefreshRequested?()
        }
    }

    /// Publish the refresh button's discovery config, or clear it, once per session.
    ///
    /// Both directions, because a button left behind after the setting is switched off
    /// presses into a topic nobody is listening on — which looks like the feature is
    /// broken rather than off.
    func settleRefreshButton(client: MQTTPublishing, enabled: Bool, prefix: String) {
        guard !settledRefreshButton, let settings else { return }
        settledRefreshButton = true

        switch Self.refreshButtonAction(enabled: enabled,
                                        wasPublished: settings.refreshButtonPublished) {
        case .publish:
            publishJSON(client: client,
                        topic: Self.refreshButtonTopic(),
                        payload: Self.refreshButtonPayload(topicPrefix: prefix),
                        retain: true)
            settings.refreshButtonPublished = true
            logger?.info("MQTT discovery published for button.\(Self.refreshButtonId)")
        case .clear:
            send(client, empty: Self.refreshButtonTopic())
            settings.refreshButtonPublished = false
            logger?.info("MQTT: removed button.\(Self.refreshButtonId) — "
                         + "Home Assistant requests are switched off")
        case .none:
            break
        }
    }

    // MARK: - Status entity

    /// Publish the sync status entity: its discovery config once per session, then its
    /// state and attributes.
    ///
    /// **Every sync, not hourly.** It is one entity against ~25, so payload cost is not
    /// the constraint, and an hourly heartbeat cannot tell you the app died 50 minutes
    /// ago.
    ///
    /// - Parameter lastSuccessfulSync: `nil` when this run published nothing, which
    ///   leaves the previous timestamp standing rather than advancing it — the state is
    ///   "last successful sync", and a failed run is precisely when a user must be able
    ///   to see how long ago the last good one was.
    func publishStatus(_ report: SyncStatusReport,
                       lastSuccessfulSync: Date?,
                       prefix: String,
                       refreshTriggerEnabled: Bool,
                       iso: ISO8601DateFormatter) {
        guard connectionState == .connected, let client else {
            logger?.debug("MQTT: not connected; status entity not published this run")
            return
        }

        // Rides here because this is the one place per run that is known to have a live
        // connection and runs after the trackers, so the app-level entities land together.
        settleRefreshButton(client: client, enabled: refreshTriggerEnabled, prefix: prefix)

        if !publishedStatusDiscovery {
            publishJSON(client: client,
                        topic: Self.statusDiscoveryTopic(),
                        payload: Self.statusPayload(topicPrefix: prefix),
                        retain: true)
            publishedStatusDiscovery = true
            logger?.info("MQTT discovery published for sensor.\(Self.statusDevId)")
        }

        if let lastSuccessfulSync {
            client.send(CocoaMQTTMessage(topic: Self.statusStateTopic(prefix: prefix),
                                         string: iso.string(from: lastSuccessfulSync),
                                         qos: .qos1, retained: true))
        }
        publishJSON(client: client,
                    topic: Self.statusAttributesTopic(prefix: prefix),
                    payload: report.attributes,
                    retain: true)
    }

    // MARK: - Re-registration

    /// Delete an entity's discovery config and immediately recreate it, so Home
    /// Assistant registers it afresh and applies `default_entity_id`.
    ///
    /// This is the only way to fix an entity whose ID was assigned before HA
    /// removed `object_id` in Core 2026.4. `default_entity_id` is consulted only
    /// at first registration — `entity_platform` resolves a known `unique_id` to
    /// its existing entry and keeps that entry's ID — so the registry entry has to
    /// go before a correct ID can be assigned.
    ///
    /// **Destructive by design.** Removing the discovery config removes the
    /// registry entry, taking any rename, icon or area the user set with it. Only
    /// ever call this from an explicit, confirmed user action.
    func reRegister(devId: String,
                    displayName: String,
                    settings: SettingsStore,
                    logger: LogStore) async -> Bool {
        guard connectionState == .connected, let client else {
            logger.warn("MQTT: not connected — cannot re-register \(devId)")
            return false
        }

        await performReRegister(client: client,
                                devId: devId,
                                displayName: displayName,
                                topicPrefix: settings.mqttTopicPrefix)

        guard connectionState == .connected else {
            logger.warn("MQTT: connection lost while re-registering \(devId); entity was removed but not recreated")
            return false
        }
        logger.info("MQTT: re-registered \(devId) as \(DeviceAlias.haEntityID(forDevId: devId))")
        return true
    }

    /// The publish sequence itself: clear, wait, republish.
    ///
    /// Split from the guards above so it can be asserted on with a recording
    /// publisher — the ordering *is* the behavior, and nothing else can check it.
    /// `delay` is a parameter for the same reason; production always uses 0.5s.
    func performReRegister(client: MQTTPublishing,
                           devId: String,
                           displayName: String,
                           topicPrefix: String,
                           delay: TimeInterval = 0.5) async {
        // Configs only. The retained attributes message stays, so HA restores the
        // position the moment it re-subscribes — see `clearDiscoveryConfigs`.
        clearDiscoveryConfigs(client: client, devId: devId)

        // HA has to process the removal before the new config lands. Published back
        // to back on one topic, it treats the pair as an update, the registry entry
        // survives, and the stale entity ID with it — the exact thing this fixes.
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }

        publishJSON(client: client,
                    topic: Self.discoveryTopic(forDevId: devId),
                    payload: Self.discoveryPayload(devId: devId,
                                                   displayName: displayName,
                                                   topicPrefix: topicPrefix),
                    retain: true)
        publishedDiscoveryIds.insert(devId)
    }

    // MARK: - Attribute building

    /// - Parameter now: the fallback for a record Apple gave no fix time. A parameter
    ///   only so a test can advance it: the whole point of that branch is that such a
    ///   record keeps publishing rather than matching itself, and a fixed clock is the
    ///   only way to show it.
    func buildAttributes(for device: DevicePoint,
                         iso: ISO8601DateFormatter,
                         now: Date = Date()) -> [String: Any] {
        var attrs: [String: Any] = [
            "latitude": device.latitude,
            "longitude": device.longitude,
            "gps_accuracy": device.accuracy,
            // The fix time, not the publish time.
            //
            // This was `Date()`, which meant Home Assistant saw an attribute change
            // every cycle and every entity's "last updated" always read as fresh —
            // a 43-hour-old position presented as if it had just arrived. It is also
            // the only reason the payload was unstable per cycle, so nothing could be
            // compared against the previous one.
            //
            // Falls back to now when Apple supplied no timestamp, which keeps the
            // field present for anyone templating on it and keeps such a record
            // publishing every cycle rather than silently matching itself.
            "last_update": iso.string(from: device.richAttributes?.timestamp ?? now)
        ]
        // Four attributes, split by meaning rather than by Apple's key name. A single
        // raw value would be ambiguous: `batteryLevel` is a 0–1 fraction and
        // `batteryStatus` a small ordinal, so 1 could mean 100% or the ordinal "full".
        if let level = device.battery {
            attrs["battery"] = Int((level * 100).rounded())
            attrs["battery_level_raw"] = level
        }
        if let code = device.batteryStatusCode {
            // Deliberately not normalized into a percentage. The same ordinal means
            // different things across manufacturers — observed values 0, 1, 2, 4, 5 and
            // 100 from Apple, Sitecom and World Tag hardware, on scales that cannot be
            // reconciled. Passing it through lets a user map their own.
            attrs["battery_status_raw"] = code
        }
        // Travels beside the raw ordinal, never instead of it, so a user who disagrees
        // with the threshold can template on the raw directly.
        if let low = device.isBatteryLow {
            attrs["battery_low"] = low
        }
        if let charging = device.chargingState {
            attrs["charging_state"] = charging
        }
        if let rich = device.richAttributes {
            if let alt = rich.altitude { attrs["altitude"] = alt }
            if let speed = rich.speed { attrs["speed"] = speed }
            if let course = rich.course { attrs["course"] = course }
            if let vAcc = rich.verticalAccuracy { attrs["vertical_accuracy"] = vAcc }
            if let ts = rich.timestamp {
                attrs["location_timestamp"] = iso.string(from: ts)
            }
            // Apple's own flag for whether the fix is stale, passed through rather
            // than turned into a staleness rule of ours — the threshold is the
            // user's to pick, which is what issue #17 asked for. Absent stays
            // absent: a fabricated false would claim Apple called the fix current.
            if let isOld = rich.isOld {
                attrs["is_old"] = isOld
            }
            if rich.motionActivityState != nil {
                attrs["motion_state"] = rich.motionStateDescription.lowercased()
            }
            // Names how the fix was obtained, so a crowdsourced fallback is visible
            // rather than silently substituted for a live position.
            if let type = rich.positionType {
                attrs["position_type"] = type
            }
            if let label = rich.locationLabel {
                attrs["location_label"] = label
            }
            // Apple's own accuracy judgement, passed through like `is_old` rather than
            // folded into a rule of ours. Absent stays absent.
            if let inaccurate = rich.isInaccurate {
                attrs["is_inaccurate"] = inaccurate
            }
            if let role = rich.role {
                attrs["role"] = role
            }
            if let emoji = rich.roleEmoji {
                attrs["role_emoji"] = emoji
            }
            // Home Assistant has no built-in reverse geocoding, so this is the one
            // attribute here a user would otherwise install an integration to get.
            if let address = rich.address {
                attrs["address"] = address
            }
            // A group's coordinate is sometimes its own and sometimes a piece's. Naming
            // the source is what stops it reading as a measurement of the whole pair.
            if let source = rich.positionSource {
                attrs["position_source"] = source
            }
            if let separation = rich.separationStatus {
                attrs["separation_status"] = separation
            }
            if let pieces = rich.pieces {
                attrs["pieces"] = pieces
            }
        }
        return attrs
    }

    // MARK: - Helpers

    /// Clear the retained topics of aliases that were renamed, deleted or
    /// untracked, then drop them from the retired list.
    ///
    /// Filtered against the devIds being published this cycle, so an alias renamed
    /// away and back is never cleared while it is in use.
    private func drainRetiredDevIds(client: MQTTPublishing,
                                    aliasByUUID: [String: String],
                                    settings: SettingsStore,
                                    logger: LogStore,
                                    prefix: String) {
        let liveDevIds = Set(aliasByUUID.values.map { DeviceAlias.entityID(for: $0) })
        let tombstones = publishTombstones(client: client,
                                           retired: settings.retiredDevIds,
                                           liveDevIds: liveDevIds,
                                           prefix: prefix)
        for devId in tombstones {
            logger.info("MQTT: cleared retained topics for retired \(devId)")
        }
        if !tombstones.isEmpty {
            let cleared = Set(tombstones)
            settings.retiredDevIds = settings.retiredDevIds.filter { !cleared.contains($0) }
        }
        // A retired dev_id that is live again is a decision, not a no-op — say so
        // rather than leaving it to look like nothing happened.
        let stillLive = settings.retiredDevIds.count
        if stillLive > 0 {
            logger.info("MQTT: \(stillLive) retired dev_id(s) still in use, not cleared")
        }
    }

    /// Clear retired entities now, outside a sync run.
    ///
    /// Renaming, deleting or untracking an alias is a user action, and waiting up to
    /// a full sync interval for the old entity to disappear from Home Assistant reads
    /// as a bug. The caller is responsible for connecting first; this returns nothing
    /// if there is no connection, leaving the persisted list for the next sync.
    func flushRetirements(retired: [String], liveDevIds: Set<String>, prefix: String) -> [String] {
        guard connectionState == .connected, let client else { return [] }
        return publishTombstones(client: client, retired: retired,
                                 liveDevIds: liveDevIds, prefix: prefix)
    }

    /// Clear the retained topics of every retired dev_id that is not live again,
    /// and report which ones were cleared.
    ///
    /// Takes plain values rather than a `SettingsStore`: the test target is hosted
    /// by the app bundle and shares the user's real UserDefaults, so a test must
    /// never construct one. The caller reads and writes the stored list around this.
    @discardableResult
    func publishTombstones(client: MQTTPublishing,
                           retired: [String],
                           liveDevIds: Set<String>,
                           prefix: String) -> [String] {
        let tombstones = Self.tombstonesToPublish(retired: retired, liveDevIds: liveDevIds)
        for devId in tombstones {
            clearRetainedTopics(client: client, devId: devId, prefix: prefix)
        }
        return tombstones
    }

    /// Clear every retained topic for a dev_id.
    ///
    /// A zero-length retained payload is HA's signal to drop a discovered entity,
    /// and removes the retained message from the broker. Order matters: the
    /// discovery config goes first so HA drops the entity, then the attributes
    /// topic, so the device's last latitude/longitude does not linger behind under
    /// a name the user removed.
    func clearRetainedTopics(client: MQTTPublishing, devId: String, prefix: String) {
        clearDiscoveryConfigs(client: client, devId: devId)
        // Retirement clears the attributes topic as well: the alias is gone, and
        // its last latitude/longitude must not sit on the broker under a name the
        // user deliberately removed. Re-registration deliberately does NOT do this.
        send(client, empty: Self.attributesTopic(forDevId: devId, prefix: prefix))
    }

    /// Clear only the two discovery configs, leaving the attributes topic intact.
    ///
    /// This is what re-registration wants. Emptying the discovery config is what
    /// makes HA drop the entity and its registry entry; the retained attributes
    /// message is independent, and leaving it means HA subscribes on re-creation
    /// and restores the position immediately. Clearing it too — which this used to
    /// do — left the recreated entity with no location until the next sync.
    private func clearDiscoveryConfigs(client: MQTTPublishing, devId: String) {
        send(client, empty: Self.discoveryTopic(forDevId: devId))
        send(client, empty: Self.batterySensorTopic(forDevId: devId))
        // Allow the sensor to be republished: it is gated per session, and without
        // this a re-registered device would come back without its battery sensor.
        publishedBatterySensorIds.remove(devId)
    }

    /// A zero-length retained message — HA's signal to drop a discovered entity,
    /// and what removes the retained message from the broker.
    private func send(_ client: MQTTPublishing, empty topic: String) {
        client.send(CocoaMQTTMessage(topic: topic, string: "", qos: .qos1, retained: true))
    }

    /// Publish the battery sensor's discovery config, once per session per device.
    ///
    /// Gated on its own set rather than `publishedDiscoveryIds`: tracker discovery
    /// fires on the first sync, but a device's battery can be absent then and
    /// present on a later one, and a shared set would mean the sensor never
    /// appeared for it.
    func publishBatterySensorIfNeeded(client: MQTTPublishing,
                                      device: DevicePoint,
                                      devId: String,
                                      displayName: String,
                                      prefix: String) {
        // No reading means no sensor: one published with no value shows as `unknown`
        // in HA and clutters the device card.
        guard device.battery != nil, !publishedBatterySensorIds.contains(devId) else { return }

        publishJSON(client: client,
                    topic: Self.batterySensorTopic(forDevId: devId),
                    payload: Self.batterySensorPayload(devId: devId,
                                                       displayName: displayName,
                                                       topicPrefix: prefix),
                    retain: true)
        publishedBatterySensorIds.insert(devId)
        logger?.info("MQTT battery sensor published for \(devId)")
    }

    private func publishJSON(client: MQTTPublishing, topic: String, payload: [String: Any], retain: Bool) {
        guard let json = Self.jsonString(payload) else {
            // Was a silent `return`. A payload that cannot be serialized is an entity
            // that never appears in Home Assistant, with nothing anywhere to say why.
            logger?.warn("MQTT: payload for \(topic) could not be serialized; not published")
            return
        }
        client.send(CocoaMQTTMessage(topic: topic, string: json, qos: .qos1, retained: retain))
    }

    /// Exponential from 250ms: 0.25, 0.5, 1, 2, 4, 8, 16, 32, 60…
    ///
    /// The faults this recovers from are short. macOS denies local network access with
    /// EHOSTUNREACH while it establishes a grant for a newly-signed binary — which
    /// happens on first launch after every update — and the window measured ~320ms. A
    /// 5s first retry turned that into a 5s outage plus a discarded sync run, because
    /// the pre-flight gave up at exactly the moment the backoff was due to fire.
    /// Decides whether a sync run should start a connection, or leave it to whatever is
    /// already trying.
    ///
    /// Reconnection has two possible drivers — the retry chain and the scheduler's
    /// pre-flight — and only one may own it at a time. `connect()` tears down the
    /// current client and cancels any pending retry, so a pre-flight that fires while a
    /// retry is queued silently restarts the backoff schedule. Left unguarded, the
    /// schedule resets every sync cycle and never reaches its attempt limit.
    nonisolated static func shouldStartNewConnection(state: MQTTConnectionState,
                                                     retryPending: Bool,
                                                     connectingSince: Date?,
                                                     now: Date = Date()) -> Bool {
        if state == .connected { return false }
        // A queued retry owns reconnection until its chain is exhausted.
        if retryPending { return false }
        if state == .connecting, let since = connectingSince,
           now.timeIntervalSince(since) <= connectingTimeout {
            return false        // an attempt is genuinely in flight
        }
        return true
    }

    nonisolated static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        min(0.25 * pow(2.0, Double(max(1, attempt) - 1)), 60.0)
    }

    private func scheduleReconnect(settings: SettingsStore) {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        guard reconnectAttempts <= Self.maxReconnectAttempts else {
            logger?.warn("MQTT: max reconnect attempts reached")
            // Hand ownership back: with no retry queued, the next sync run's pre-flight
            // starts a fresh schedule rather than leaving the client dead forever.
            reconnectTask = nil
            return
        }
        // Exponential from 250ms: 0.25, 0.5, 1, 2, 4, 8, 16, 32, 60…
        // The faults this recovers from are short. A measured case: the process got
        // ENETDOWN for ~320ms while the system network path reported satisfied. A raw
        // NWConnection rode it out and was ready 320ms later; CocoaMQTT treated it as
        // fatal, and a 5s first retry turned that into a 5s outage plus a discarded
        // sync run — the pre-flight gave up at the moment the backoff was due to fire.
        let delay = min(0.25 * pow(2.0, Double(reconnectAttempts - 1)), 60.0)
        connectionState = .connecting
        logger?.warn(String(format: "MQTT reconnecting (attempt %d, %.2fs)", reconnectAttempts, delay))
        let settingsRef = settings
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect(settings: settingsRef, resetBackoff: false)
        }
    }
}

// MARK: - CocoaMQTTDelegate

extension MQTTClient: CocoaMQTTDelegate {
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        let accepted = (ack == .accept)
        let ackDesc = "\(ack)"
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            guard token == self.activeClientToken else { return }
            if accepted {
                self.connectionState = .connected
                self.connectingSince = nil
                self.reconnectAttempts = 0
                self.reconnectTask?.cancel()
                self.publishedDiscoveryIds.removeAll()
                self.publishedBatterySensorIds.removeAll()
                self.publishedStatusDiscovery = false
                self.settledRefreshButton = false
                self.lastPublishedAttributes.removeAll()
                self.publishAvailability(Self.availabilityOnline)
                self.subscribeToRefreshTopic()
                self.logger?.info("MQTT connected (discovery will re-publish)")
            } else {
                self.logger?.error("MQTT connection rejected: \(ackDesc)")
                self.connectionState = .disconnected
            }
        }
    }

    nonisolated func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: (any Error)?) {
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            // A disconnect from a client we've already replaced is our own teardown
            // arriving late, not a connection failure.
            guard token == self.activeClientToken else { return }
            self.connectionState = .disconnected
            self.connectingSince = nil
            if let err {
                self.logger?.warn("MQTT disconnected: \(err.localizedDescription)")
            }
            if !self.intentionalDisconnect, let settings = self.settings {
                self.scheduleReconnect(settings: settings)
            }
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        // Read what is needed on this side: `CocoaMQTTMessage` is not Sendable, and the
        // topic and the retained flag are the whole of what the decision uses.
        let topic = message.topic
        let retained = message.retained
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            guard token == self.activeClientToken else { return }
            self.handleInbound(topic: topic, retained: retained)
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        let subscribed = success.allKeys.compactMap { $0 as? String }.sorted()
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            guard token == self.activeClientToken else { return }
            for topic in subscribed {
                self.logger?.info("MQTT subscribed to \(topic)")
            }
            // A subscription that failed means the button and any automation are dead with
            // nothing to say so.
            for topic in failed {
                self.logger?.warn("MQTT: subscription to \(topic) was refused by the broker")
            }
        }
    }
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    nonisolated func mqttDidPing(_ mqtt: CocoaMQTT) {}
    nonisolated func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}

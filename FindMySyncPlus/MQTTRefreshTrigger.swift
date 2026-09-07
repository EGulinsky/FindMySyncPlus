import Foundation
import CocoaMQTT

// The one thing Home Assistant can ask this app to do, and the button that asks it.
//
// Split out of MQTTClient.swift, which has crossed the 1000-line lint error threshold
// repeatedly — trimming comments to stay under it was buying a few lines at a time. This
// is a whole feature with one entry point from the connect ack and one from the delegate,
// so it lifts cleanly.
//
// The members it reaches lost `private` to make that possible. They stay internal to the
// app target; `private` in Swift is file-scoped, so a same-type extension in another file
// cannot see them.
extension MQTTClient {

    // MARK: - Refresh trigger

    /// Subscribe to the one topic this app listens on, if the user has turned it on.
    ///
    /// Called from the connect ack, inside the `activeClientToken` guard: a subscribe
    /// from a client we have already replaced is the same bug class the token exists for.
    /// Re-established on every reconnect, like discovery re-publication.
    func subscribeToRefreshTopic() {
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
    func handleInbound(topic: String, retained: Bool) {
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
}

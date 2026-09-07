import SwiftUI
import AppKit
import Foundation

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var app: AppModel

    @StateObject private var loginItemManager = LoginItemManager()

    /// Whether this macOS provides friend locations at all.
    private let friendsAvailability = FriendsAvailability.current

    @State private var intervalMinutes: Int = 5
    @State private var waitSecondsInt: Int = 10

    private static let minIntervalMinutes = 1
    private static let maxIntervalMinutes = 180
    // Capped at 50 rather than 100 so the dial cannot be set somewhere that hides movement
    // across a property. Measured need: recompute noise is sub-millimetre and positioning
    // wobble reaches 1.4 m, so the useful range is roughly 0.1 m to 5 m.
    private static let minMovement: Double = 0
    private static let maxMovement: Double = 50
    private static let movementStep: Double = 0.5
    private static let metresFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimum = 0
        nf.maximum = 50
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        return nf
    }()
    private static let minWaitSeconds = 1
    private static let maxWaitSeconds = 30
    private static let intFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.minimum = 0
        nf.maximumFractionDigits = 0
        return nf
    }()

    var body: some View {
        AppScroll {
            VStack(spacing: 16) {
                schedulerCard
                findMyCard
                publishingCard
                sourcesCard
                deviceManagerCard
            }
            // --- STANDARDIZED LAYOUT ---
            .padding(.horizontal, 18)
            .contentMargins(.top, 8)
            .padding(.top, 8)
            .frame(maxWidth: 610)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: onAppearPopulate)
        .onAppear {
            NotificationCenter.default.post(name: .clearToolbarItems, object: nil)
        }
        .onChange(of: intervalMinutes) { _, newMinutes in
            let clamped = max(Self.minIntervalMinutes, min(newMinutes, Self.maxIntervalMinutes))
            settings.updateIntervalSec = Double(clamped * 60)
            if clamped != newMinutes {
                intervalMinutes = clamped
            }
        }
        .onChange(of: waitSecondsInt) { _, newSeconds in
            let clamped = max(Self.minWaitSeconds, min(newSeconds, Self.maxWaitSeconds))
            settings.findMyWaitSeconds = Double(clamped)
            if clamped != newSeconds {
                waitSecondsInt = clamped
            }
        }
    }

    private var schedulerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Startup & Scheduling")
                        .font(.title3).fontWeight(.semibold)

                    InfoTip(message: "Control open at login, start syncing on app launch, and scheduler run frequency.")
                    Spacer()
                }

                SettingsToggleRow(label: "Open at Login", isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { loginItemManager.setLoginItem(enabled: $0, logger: logger) }
                ))
                SettingsToggleRow(label: "Open Main Window on Startup", isOn: $settings.openMainOnLaunch)
                SettingsToggleRow(label: "Auto-start Scheduler", isOn: $settings.autoStartSchedulerOnLaunch)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Update Interval ")
                        .font(.body)
                        + Text("(minutes)").foregroundStyle(.secondary)

                    Spacer()

                    TextField("", value: $intervalMinutes, formatter: Self.intFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)

                    Stepper("", value: $intervalMinutes, in: Self.minIntervalMinutes...Self.maxIntervalMinutes)
                        .labelsHidden()
                }
            }
        }
    }

    private var findMyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Find My Cache Refresh")
                        .font(.title3).fontWeight(.semibold)

                    InfoTip(message: "Launch, wait and terminate Find My so caches update before decryption.")
                    Spacer()
                }

                SettingsToggleRow(label: "Launch Find My before each run", isOn: $settings.autoLaunchKillFindMy)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text("Wait ")
                        .font(.body)
                     + Text("(seconds)").foregroundStyle(.secondary))
                        .foregroundStyle(settings.autoLaunchKillFindMy ? .primary : .secondary)

                    Spacer()

                    TextField("", value: $waitSecondsInt, formatter: Self.intFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.autoLaunchKillFindMy)

                    Stepper("", value: $waitSecondsInt, in: Self.minWaitSeconds...Self.maxWaitSeconds)
                        .labelsHidden()
                        .disabled(!settings.autoLaunchKillFindMy)
                }
            }
        }
    }

    /// MQTT publishes its attributes topic retained, so a skipped entity still gets its
    /// last value when Home Assistant restarts and resubscribes. REST has no retained
    /// equivalent — a REST user with this on would come back from a restart with
    /// entities unknown until something actually moved — so the row reads off there,
    /// leaving the stored preference alone for anyone who switches transport later.
    private var isMQTT: Bool { settings.transportMode == .mqtt }

    /// The threshold only widens suppression, so it means nothing until the toggle is on.
    private var movementEnabled: Bool { isMQTT && settings.skipRepeatedLocations }

    private var publishingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Home Assistant")
                        .font(.title3).fontWeight(.semibold)

                    InfoTip(message: """
                        Subscribing listens on an MQTT topic to trigger an ad-hoc Find My \
                        launch and run a single sync. Useful when combined with disabling \
                        Find My before each run to reduce system load.

                        Skip repeated locations publishes an entity update only when \
                        Find My reports a different location, rather than on every sync. \
                        Minimum movement treats near-identical locations as unchanged; at \
                        0, only exact coordinate matches are skipped. A skipped entity keeps \
                        its last timestamps, so read Sync status for freshness.
                        """)
                    Spacer()
                }

                VStack(spacing: 10) {
                    SettingsToggleRow(
                        label: "Subscribe to sync requests",
                        isOn: isMQTT ? $settings.enableRefreshTrigger : .constant(false),
                        disabled: !isMQTT,
                        qualifier: isMQTT ? nil : "MQTT only"
                    )
                    SettingsToggleRow(
                        label: "Skip repeated locations",
                        isOn: isMQTT ? $settings.skipRepeatedLocations : .constant(false),
                        disabled: !isMQTT,
                        qualifier: isMQTT ? nil : "MQTT only"
                    )
                }
                .font(.body)
                .padding(.top, 2)

                // Last, and governed by the toggle above it — the shape "Wait (seconds)"
                // already uses under "Launch Find My before each run".
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text("Minimum movement ")
                        .font(.body)
                     + Text("(metres)").foregroundStyle(.secondary))
                        .foregroundStyle(movementEnabled ? .primary : .secondary)

                    Spacer()

                    TextField("", value: $settings.minimumMovementMetres,
                              formatter: Self.metresFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!movementEnabled)

                    Stepper("", value: $settings.minimumMovementMetres,
                            in: Self.minMovement...Self.maxMovement,
                            step: Self.movementStep)
                        .labelsHidden()
                        .disabled(!movementEnabled)
                }
            }
        }
    }

    private var sourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Find My Sources")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Choose which local Find My caches to process.")
                    Spacer()
                }

                VStack(spacing: 10) {
                    SettingsToggleRow(label: "Devices", isOn: $settings.enableDevices, disabled: settings.fmipKeyStatus == .notPresent)
                    SettingsToggleRow(label: "Items", isOn: $settings.enableItems, disabled: settings.fmipKeyStatus == .notPresent)
                    // Reads off, because that is what it does. The stored preference is
                    // deliberately left alone: it can legitimately be true on a machine
                    // that was upgraded, and writing false would lose the setting for
                    // anyone who later moves to macOS 15.
                    SettingsToggleRow(
                        label: "Friends",
                        isOn: friendsAvailability.isSupported ? $settings.enableFriends : .constant(false),
                        disabled: !friendsAvailability.isSupported || settings.localStorageKeyStatus == .notPresent,
                        qualifier: friendsAvailability.isSupported ? nil : FriendsAvailability.toggleQualifier
                    )
                }
                .font(.body)
                .padding(.top, 2)

                // On macOS 14 the LocalStorage key is not needed, so its absence must
                // not prompt the user to go and import one.
                if settings.fmipKeyStatus == .notPresent
                    || (friendsAvailability.isSupported && settings.localStorageKeyStatus == .notPresent) {
                    Text("Import keys in Access settings to enable sources")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            }
        }
    }

    private var deviceManagerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Device Management")
                        .font(.title3).fontWeight(.semibold)

                    InfoTip(message: """
                        Apple rotates device UUIDs periodically. \
                        These settings control how many old UUIDs to keep \
                        per alias and whether to automatically add new UUIDs \
                        when device names match.
                        """)
                }
                SettingsToggleRow(label: "Auto-learn UUIDs", isOn: $settings.autoLearnUUIDs)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Maximum UUIDs tracked")
                    Spacer()
                    TextField("", value: $settings.maxUUIDsPerAlias, formatter: Self.intFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $settings.maxUUIDsPerAlias, in: 1...5)
                        .labelsHidden()
                }
            }
        }
    }

    private func onAppearPopulate() {
        let mins = max(1, Int(settings.updateIntervalSec / 60.0))
        intervalMinutes = mins

        let secs = max(1, Int(settings.findMyWaitSeconds.rounded()))
        waitSecondsInt = secs
    }
}

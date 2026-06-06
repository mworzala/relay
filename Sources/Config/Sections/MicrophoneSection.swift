import SwiftUI

/// Microphone priority list: drag to reorder, connection state shown, with a live
/// input-level meter you can exercise via "Test". Priority is persisted by stable
/// device UID; connected devices are merged in automatically and disconnected
/// ones stay (greyed) so their position is remembered.
struct MicrophoneSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MicrophoneCapture.self) private var mic
    @State private var testing = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 14) {
            levelMeter

            HStack {
                Text("Keep microphone ready")
                Spacer()
                Picker("", selection: $settings.micKeepAlive) {
                    ForEach(MicKeepAlive.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.micKeepAlive) { _, _ in
                    settings.save()
                    mic.applyKeepAlivePolicy()
                }
            }
            Text("Starting the mic cold takes a moment (longer for Bluetooth), which can clip your first word. Keeping it warm after you finish makes the next dictation start instantly. While warm, the microphone-in-use indicator stays on, a little battery is used, and a Bluetooth headset stays in low-quality call mode. “Always” keeps it ready the whole time Relay runs (the first dictation never clips); “Disabled” starts fresh each time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Priority order")
                .font(.headline)
            Text("Relay records from the highest-priority connected device, falling to the next when one disconnects and switching back when it returns.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.micPriority) { entry in
                    deviceRow(entry)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)
        }
        .padding()
        .navigationTitle("Microphone")
        .onAppear {
            mic.refreshDevices()
            mergeConnected()
        }
        .onChange(of: mic.connectedDevices) { _, _ in mergeConnected() }
        .onDisappear {
            if testing { mic.endCapture(); testing = false }
        }
    }

    // MARK: Subviews

    private var levelMeter: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.green.gradient)
                        .frame(width: max(2, geo.size.width * CGFloat(min(mic.level, 1))))
                        .animation(.linear(duration: 0.05), value: mic.level)
                }
            }
            .frame(height: 10)

            Button(testing ? "Stop" : "Test") {
                if testing {
                    mic.endCapture()
                    testing = false
                } else {
                    mic.beginCapture { _ in }   // no-op sink: drives the meter only
                    testing = true
                }
            }
            .fixedSize()
        }
    }

    private func deviceRow(_ entry: MicPriorityEntry) -> some View {
        let connected = isConnected(entry)
        let active = mic.activeDevice?.uid == entry.uid
        return HStack(spacing: 10) {
            Image(systemName: connected ? "mic.fill" : "mic.slash")
                .foregroundStyle(connected ? (active ? Color.green : .primary) : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .foregroundStyle(connected ? .primary : .secondary)
                Text(active ? "Active" : (connected ? "Connected" : "Disconnected"))
                    .font(.caption)
                    .foregroundStyle(active ? Color.green : .secondary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Mutations

    private func isConnected(_ entry: MicPriorityEntry) -> Bool {
        mic.connectedDevices.contains { $0.uid == entry.uid }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = settings.micPriority
        list.move(fromOffsets: source, toOffset: destination)
        settings.micPriority = list
        settings.save()
        mic.priorityDidChange()
    }

    /// Only disconnected (stale) entries can be removed; connected devices stay.
    private func delete(_ offsets: IndexSet) {
        let removable = offsets
            .map { settings.micPriority[$0] }
            .filter { !isConnected($0) }
        guard !removable.isEmpty else { return }
        settings.micPriority.removeAll { entry in removable.contains(entry) }
        settings.save()
    }

    /// Append newly-connected devices and refresh known names; persist if changed.
    private func mergeConnected() {
        var list = settings.micPriority
        var changed = false
        // Drop any stale internal-aggregate entries that slipped in previously.
        let pruned = list.filter { !CoreAudioDevices.isInternalAggregate(uid: $0.uid) }
        if pruned.count != list.count { list = pruned; changed = true }
        for device in mic.connectedDevices where !list.contains(where: { $0.uid == device.uid }) {
            list.append(MicPriorityEntry(uid: device.uid, name: device.name))
            changed = true
        }
        for index in list.indices {
            if let device = mic.connectedDevices.first(where: { $0.uid == list[index].uid }),
               device.name != list[index].name {
                list[index].name = device.name
                changed = true
            }
        }
        if changed {
            settings.micPriority = list
            settings.save()
            mic.priorityDidChange()
        }
    }
}

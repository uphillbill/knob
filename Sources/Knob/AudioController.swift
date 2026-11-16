import AppKit
import ApplicationServices
import CoreAudio
import Foundation
import KnobDSP
import ServiceManagement
import os

/// App state and policy. Decides when the tap engine runs and with which gains.
///
/// The engine only runs when it has work to do:
///   * the current output device has no volume control of its own (optical, HDMI, DisplayPort...), or
///   * at least one running app has a per-app volume other than 100% or is muted, or
///   * the device's EQ, or the EQ of a running app with EQ on, isn't Flat.
/// Otherwise audio flows untouched and Knob costs nothing.
final class AudioController: ObservableObject {
    struct AppEntry: Identifiable {
        let key: String
        var id: String { key }
        let name: String
        let icon: NSImage
        var processObjects: [AudioObjectID]
        var isPlaying: Bool
        var volume: Float      // 0...2, 1 = unchanged
        var muted: Bool
        var eqOn: Bool
        var eq: EQSettings
        /// Volume or mute differs from 100%/unmuted.
        var isAdjusted: Bool { muted || abs(volume - 1) > 0.01 }
        /// Gets its own tap when the engine runs.
        var needsTap: Bool { isAdjusted || eqOn }
    }

    /// What the EQ window is editing.
    enum EQTarget: Hashable { case device, app(String) }

    @Published private(set) var devices: [HAL.Device] = []
    @Published private(set) var currentDevice: HAL.Device?
    @Published private(set) var masterVolume: Float = 0.5
    @Published private(set) var muted = false
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var status = "Starting…"
    @Published private(set) var isOn = true
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var launchAtLogin = false
    /// EQ of the current output device.
    @Published private(set) var deviceEQ = EQSettings.flat
    @Published private(set) var userPresets: [EQPreset] = []
    @Published var eqTarget = EQTarget.device

    var allPresets: [EQPreset] { EQPreset.builtIn + userPresets }
    /// Presets in menu sections: tone fixes, music styles, then the user's own.
    var presetGroups: [[EQPreset]] {
        let builtIn = EQPreset.builtIn
        return [Array(builtIn[..<EQPreset.musicStart]), Array(builtIn[EQPreset.musicStart...]), userPresets]
            .filter { !$0.isEmpty }
    }

    /// True when Knob is the volume control for the current device.
    var softwareMode: Bool { isOn && (currentDevice.map { !$0.hasHardwareVolume } ?? false) }

    private let engine = TapEngine()
    private let keys = VolumeKeys()
    private let hud = VolumeHUD()
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: Knob.id, category: "controller")

    private var engineSignature: String?
    private var engineAppKeys: [String] = []   // app keys in tap order, after the global tap
    private var reconcileWork: DispatchWorkItem?
    private var reconcileDeadline: DispatchTime?
    /// After an EQ change, keep the engine running a little even if everything is Flat, so
    /// dragging a slider through 0 dB doesn't stop and restart it.
    private var eqKeepAliveUntil = Date.distantPast
    private var sampleRateDevice = HAL.unknown
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var pollTimer: Timer?
    private var keysActive = false
    private var infoCache: [String: (name: String, icon: NSImage)] = [:]

    // MARK: - Lifecycle

    func start() {
        migrateVolumeCurve()
        loadUserPresets()
        isOn = defaults.object(forKey: "isOn") == nil ? true : defaults.bool(forKey: "isOn")
        installListeners()
        refreshDevices()
        refreshApps()

        keys.handler = { [weak self] key, fine, isDown in
            self?.handleKey(key, fine: fine, isDown: isDown) ?? false
        }
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted { keysActive = keys.start() }
        log.info("Accessibility granted=\(self.accessibilityGranted), volume key tap active=\(self.keysActive)")

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        launchAtLogin = SMAppService.mainApp.status == .enabled

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.engineSignature = nil
            self?.scheduleReconcile(immediate: true)
        }
        scheduleReconcile(immediate: true)
    }

    func shutdown() {
        engine.stop()
    }

    private func installListeners() {
        let main = DispatchQueue.main
        var defaultDevice = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(HAL.system, &defaultDevice, main) { [weak self] _, _ in self?.refreshDevices() }
        var deviceList = HAL.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(HAL.system, &deviceList, main) { [weak self] _, _ in self?.refreshDevices() }
        var processList = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(HAL.system, &processList, main) { [weak self] _, _ in self?.refreshApps() }
    }

    private func poll() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted { accessibilityGranted = granted }
        if granted && !keysActive {
            keysActive = keys.start()
            log.debug("Volume key tap started=\(self.keysActive)")
        }
        if let peaks = engine.takePeaks() {
            log.debug("Levels: tap in peak \(peaks.input), out peak \(peaks.output), master \(self.masterVolume) gain \(self.masterGain()) muted=\(self.muted)")
        }
        refreshApps()
        if let device = currentDevice, device.hasHardwareVolume {
            let hw = HAL.hardwareVolume(device.id)
            if abs(hw - masterVolume) > 0.001 { masterVolume = hw }
        }
    }

    // MARK: - Devices

    private func refreshDevices() {
        devices = HAL.outputDevices()
        let defaultID = HAL.defaultOutputDevice()
        for d in devices {
            log.debug("Device \(d.id): \(d.name, privacy: .public) uid=\(d.uid, privacy: .private) hardwareVolume=\(d.hasHardwareVolume) default=\(d.id == defaultID)")
        }
        let newDevice = devices.first { $0.id == defaultID }
        let changed = newDevice?.uid != currentDevice?.uid || newDevice?.id != currentDevice?.id
        currentDevice = newDevice
        if changed {
            loadMasterForCurrentDevice()
            loadDeviceEQ()
            watchSampleRate(of: newDevice?.id ?? HAL.unknown)
            engineSignature = nil
        }
        scheduleReconcile(immediate: changed)
    }

    private func loadMasterForCurrentDevice() {
        guard let device = currentDevice else { return }
        if device.hasHardwareVolume {
            masterVolume = HAL.hardwareVolume(device.id)
            muted = false
        } else {
            let key = "deviceVolume.\(device.uid)"
            // Unknown device: start at unity (the level macOS sends when nothing adjusts it).
            masterVolume = defaults.object(forKey: key) == nil ? Self.unityPosition : defaults.float(forKey: key)
            muted = defaults.bool(forKey: "deviceMuted.\(device.uid)")
        }
    }

    /// A sample-rate change needs new filter coefficients and a fresh engine (which also resets
    /// the filter state), so treat it like a device change.
    private func watchSampleRate(of device: AudioObjectID) {
        var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
        if let listener = sampleRateListener, sampleRateDevice != HAL.unknown {
            AudioObjectRemovePropertyListenerBlock(sampleRateDevice, &addr, DispatchQueue.main, listener)
        }
        sampleRateListener = nil
        sampleRateDevice = device
        guard device != HAL.unknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.log.info("Sample rate changed to \(HAL.nominalSampleRate(device)) Hz")
            self.engineSignature = nil
            self.scheduleReconcile(immediate: true)
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, listener) == noErr {
            sampleRateListener = listener
        }
    }

    func select(device: HAL.Device) {
        log.info("Menu: select output \(device.name, privacy: .public)")
        HAL.setDefaultOutputDevice(device.id)   // the default-device listener does the rest
    }

    // MARK: - Apps

    private func refreshApps() {
        let ownPID = getpid()
        var groups: [String: (objects: [AudioObjectID], playing: Bool)] = [:]
        for process in HAL.audioProcesses() where process.pid != ownPID && !process.bundleID.isEmpty {
            let key = Self.groupKey(for: process.bundleID)
            var group = groups[key] ?? (objects: [], playing: false)
            group.objects.append(process.objectID)
            group.playing = group.playing || process.isRunningOutput
            groups[key] = group
        }

        var result: [AppEntry] = []
        for (key, group) in groups {
            let volumeKey = "appVolume.\(key)"
            let volume = defaults.object(forKey: volumeKey) == nil ? 1 : defaults.float(forKey: volumeKey)
            let isMuted = defaults.bool(forKey: "appMuted.\(key)")
            let eqOn = defaults.bool(forKey: "eqOn.app.\(key)")
            let adjusted = isMuted || abs(volume - 1) > 0.01
            guard group.playing || adjusted || eqOn else { continue }
            let info = appInfo(for: key)
            result.append(AppEntry(key: key, name: info.name, icon: info.icon,
                                   processObjects: group.objects.sorted(), isPlaying: group.playing,
                                   volume: volume, muted: isMuted, eqOn: eqOn,
                                   eq: EQSettings(stored: defaults.array(forKey: "eq.app.\(key)")) ?? .flat))
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let changed = result.map { "\($0.key)\($0.processObjects)\($0.isPlaying)\($0.eqOn)" }
            != apps.map { "\($0.key)\($0.processObjects)\($0.isPlaying)\($0.eqOn)" }
        if changed {
            apps = result
            scheduleReconcile(immediate: false)
        }
    }

    /// Groups helper processes under their parent app (Chrome helpers, Electron renderers, Safari's WebKit).
    static func groupKey(for bundleID: String) -> String {
        if bundleID.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        for marker in [".helper", ".Helper", ".renderer", ".Renderer", ".plugin", ".Plugin"] {
            if let range = bundleID.range(of: marker) { return String(bundleID[..<range.lowerBound]) }
        }
        return bundleID
    }

    private func appInfo(for key: String) -> (name: String, icon: NSImage) {
        if let cached = infoCache[key] { return cached }
        var name = key
        var icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.size = NSSize(width: 18, height: 18)
        infoCache[key] = (name, icon)
        return (name, icon)
    }

    func setAppVolume(_ key: String, _ value: Float) {
        guard let index = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[index].volume = max(0, min(2, value))
        defaults.set(apps[index].volume, forKey: "appVolume.\(key)")
        appSettingsChanged(key)
    }

    func toggleAppMute(_ key: String) {
        guard let index = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[index].muted.toggle()
        defaults.set(apps[index].muted, forKey: "appMuted.\(key)")
        appSettingsChanged(key)
    }

    func resetApp(_ key: String) {
        guard let index = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[index].volume = 1
        apps[index].muted = false
        defaults.removeObject(forKey: "appVolume.\(key)")
        defaults.removeObject(forKey: "appMuted.\(key)")
        appSettingsChanged(key)
    }

    private func appSettingsChanged(_ key: String) {
        if engine.isRunning && engineAppKeys.contains(key) { pushGains() }
        scheduleReconcile(immediate: false)
    }

    // MARK: - EQ

    private func loadDeviceEQ() {
        guard let device = currentDevice else { deviceEQ = .flat; return }
        deviceEQ = EQSettings(stored: defaults.array(forKey: "eq.device.\(device.uid)")) ?? .flat
    }

    func setDeviceEQ(_ settings: EQSettings) {
        guard let device = currentDevice else { return }
        deviceEQ = settings
        let key = "eq.device.\(device.uid)"
        if settings.isFlat { defaults.removeObject(forKey: key) } else { defaults.set(settings.stored, forKey: key) }
        engine.setSystemEQ(settings)
        eqChanged()
    }

    func eqSettings(for target: EQTarget) -> EQSettings {
        switch target {
        case .device: return deviceEQ
        case .app(let key): return apps.first { $0.key == key }?.eq ?? .flat
        }
    }

    func setEQ(_ settings: EQSettings, for target: EQTarget) {
        switch target {
        case .device: setDeviceEQ(settings)
        case .app(let key): setAppEQ(key, settings)
        }
    }

    /// Changing an app's EQ turns it on (the app then gets its own tap).
    func setAppEQ(_ key: String, _ settings: EQSettings) {
        guard let index = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[index].eq = settings
        let storeKey = "eq.app.\(key)"
        if settings.isFlat { defaults.removeObject(forKey: storeKey) } else { defaults.set(settings.stored, forKey: storeKey) }
        if !apps[index].eqOn && !settings.isFlat {
            setAppEQOn(key, true)
            return
        }
        if let tap = engineAppKeys.firstIndex(of: key) { engine.setAppEQ(tap: tap + 1, settings) }
        eqChanged()
    }

    func setAppEQOn(_ key: String, _ on: Bool) {
        guard let index = apps.firstIndex(where: { $0.key == key }) else { return }
        log.info("Menu: app EQ \(on ? "on" : "off", privacy: .public)")
        apps[index].eqOn = on
        if on { defaults.set(true, forKey: "eqOn.app.\(key)") } else { defaults.removeObject(forKey: "eqOn.app.\(key)") }
        eqChanged()
    }

    private func eqChanged() {
        eqKeepAliveUntil = Date().addingTimeInterval(3)
        scheduleReconcile(immediate: false)
    }

    func presetName(for settings: EQSettings) -> String? {
        allPresets.first { $0.settings.matches(settings) }?.name
    }

    private func loadUserPresets() {
        let stored = defaults.dictionary(forKey: "eq.userPresets") ?? [:]
        let builtInNames = Set(EQPreset.builtIn.map { $0.name.lowercased() })
        userPresets = stored.compactMap { name, value in
            // A saved name that later became a built-in preset is hidden (the built-in wins).
            guard !builtInNames.contains(name.lowercased()) else { return nil }
            return EQSettings(stored: value).map { EQPreset(name: name, settings: $0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Returns false if the name is empty or belongs to a built-in preset.
    @discardableResult
    func saveUserPreset(named rawName: String, _ settings: EQSettings) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !EQPreset.builtIn.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        var stored = defaults.dictionary(forKey: "eq.userPresets") ?? [:]
        stored[name] = settings.stored
        defaults.set(stored, forKey: "eq.userPresets")
        loadUserPresets()
        return true
    }

    func deleteUserPreset(named name: String) {
        var stored = defaults.dictionary(forKey: "eq.userPresets") ?? [:]
        stored[name] = nil
        if stored.isEmpty { defaults.removeObject(forKey: "eq.userPresets") } else { defaults.set(stored, forKey: "eq.userPresets") }
        loadUserPresets()
    }

    // MARK: - Master volume

    func setMaster(_ value: Float) {
        guard let device = currentDevice else { return }
        masterVolume = max(0, min(1, value))
        if softwareMode {
            defaults.set(masterVolume, forKey: "deviceVolume.\(device.uid)")
            if muted && masterVolume > 0 { setMuted(false) }
            pushGains()
            log.debug("Master \(self.masterVolume) -> gain \(self.masterGain()) engineRunning=\(self.engine.isRunning)")
        } else if device.hasHardwareVolume {
            HAL.setHardwareVolume(device.id, masterVolume)
        }
    }

    func toggleMute() {
        guard softwareMode else { return }
        setMuted(!muted)
    }

    private func setMuted(_ value: Bool) {
        guard let device = currentDevice else { return }
        muted = value
        defaults.set(value, forKey: "deviceMuted.\(device.uid)")
        pushGains()
    }

    // MARK: - Settings

    func setOn(_ value: Bool) {
        log.info("Menu: Knob on = \(value)")
        // While Knob is off, a device without volume control plays at full level. Turning Knob
        // on continues at that level instead of jumping down to the remembered setting.
        if value && !isOn, let device = currentDevice, !device.hasHardwareVolume {
            masterVolume = Self.unityPosition
            muted = false
            defaults.set(masterVolume, forKey: "deviceVolume.\(device.uid)")
            defaults.set(false, forKey: "deviceMuted.\(device.uid)")
        }
        isOn = value
        defaults.set(value, forKey: "isOn")
        engineSignature = nil
        scheduleReconcile(immediate: true)
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Open at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestAccessibility() {
        // Literal value of kAXTrustedCheckOptionPrompt; avoids SDK differences in how the constant is imported.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Volume keys

    /// Returns true to swallow the key event. Only takes over the keys when Knob owns the volume.
    private func handleKey(_ key: VolumeKeys.Key, fine: Bool, isDown: Bool) -> Bool {
        log.debug("Volume key \(String(describing: key), privacy: .public) down=\(isDown) softwareMode=\(self.softwareMode)")
        guard softwareMode, let device = currentDevice else { return false }
        guard isDown else { return true }
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        switch key {
        case .up: setMaster(masterVolume + step)
        case .down: setMaster(masterVolume - step)
        case .mute: toggleMute()
        }
        hud.show(volume: masterVolume, muted: muted, deviceName: device.name)
        return true
    }

    // MARK: - Engine policy

    /// Runs reconcile soon. A pending run that's already due sooner is kept, so a stream of
    /// changes (a slider drag) still reconciles within 0.4 s instead of waiting for it to stop.
    private func scheduleReconcile(immediate: Bool) {
        let deadline = DispatchTime.now() + (immediate ? 0.05 : 0.4)
        if let pending = reconcileDeadline, reconcileWork != nil, pending <= deadline { return }
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcileWork = nil
            self?.reconcileDeadline = nil
            self?.reconcile()
        }
        reconcileWork = work
        reconcileDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }

    private func reconcile() {
        guard isOn else { stopEngine("Off"); return }
        guard let device = currentDevice else { stopEngine("No output device"); return }

        let tapped = apps.filter { $0.needsTap && !$0.processObjects.isEmpty }
        let eqActive = !deviceEQ.isFlat || tapped.contains { $0.eqOn && !$0.eq.isFlat }
        let needed = softwareMode || tapped.contains { $0.isAdjusted } || eqActive
        guard needed || (engine.isRunning && Date() < eqKeepAliveUntil) else {
            stopEngine("Idle: \(device.name) has its own volume control")
            return
        }
        if !needed {
            // Everything is Flat right after an EQ change: check again once the slider settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.scheduleReconcile(immediate: true) }
        }

        let sampleRate = HAL.nominalSampleRate(device.id)
        let signature = device.uid + "#\(device.id)@\(sampleRate)|" + tapped
            .map { app in "\(app.key)\(app.eqOn ? "+eq" : "")=" + app.processObjects.map { String($0) }.joined(separator: ".") }
            .joined(separator: ",")
        if signature == engineSignature && engine.isRunning {
            pushGains()
            return
        }
        let adjusted = tapped

        let own = HAL.processObject(for: getpid())
        log.info("Own process object for pid \(getpid()): \(own)")
        guard own != HAL.unknown else {
            stopEngine("Not started: couldn't find Knob's own audio process (would feed back)")
            return
        }

        do {
            engineAppKeys = adjusted.map(\.key)
            try engine.start(outputDeviceUID: device.uid,
                             excludedProcesses: [own],
                             appTaps: adjusted.map(\.processObjects),
                             initialGains: currentGains(),
                             systemEQ: deviceEQ,
                             appEQ: adjusted.map { $0.eqOn ? $0.eq : nil })
            engineSignature = signature
            let appNote = adjusted.isEmpty ? "" : " · \(adjusted.count) app\(adjusted.count == 1 ? "" : "s") adjusted"
            let eqNote = eqActive ? " · EQ" : ""
            status = "Active on \(device.name)\(appNote)\(eqNote)"
        } catch {
            engine.stop()
            engineSignature = nil
            engineAppKeys = []
            status = "Engine error: \(error.localizedDescription)"
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopEngine(_ message: String) {
        if engine.isRunning { log.info("Engine stopped: \(message, privacy: .public)") }
        engine.stop()
        engineSignature = nil
        engineAppKeys = []
        status = message
    }

    /// Master slider position that plays at the device's own full level (gain 1, 0 dB).
    static let unityPosition: Float = 0.5
    /// Boost at the top of the master slider.
    static let maxBoostDB: Float = 12

    /// Master curve, slider position -> linear gain.
    /// 0...unity: cubic fade up to gain 1. unity...1: boost, linear in dB, up to +maxBoostDB.
    static func curve(_ v: Float) -> Float {
        if v <= 0 { return 0 }
        if v <= unityPosition {
            let x = v / unityPosition
            return x * x * x
        }
        let db = (min(v, 1) - unityPosition) / (1 - unityPosition) * maxBoostDB
        return powf(10, db / 20)
    }
    /// Per-app curve: 0...100% is a cubic fade to unity; 100...200% is a straight boost.
    static func appCurve(_ v: Float) -> Float { v <= 0 ? 0 : (v <= 1 ? v * v * v : v) }

    /// Version 2 moved unity from the top of the master slider to the middle. Saved device
    /// volumes from version 1 would now mean a boost of up to +12 dB, so drop them.
    private func migrateVolumeCurve() {
        guard defaults.integer(forKey: "volumeCurveVersion") < 2 else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("deviceVolume.") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(2, forKey: "volumeCurveVersion")
        log.info("Volume curve v2: cleared saved device volumes")
    }

    private func masterGain() -> Float {
        guard softwareMode else { return 1 }   // hardware handles master volume
        return muted ? 0 : Self.curve(masterVolume)
    }

    private func currentGains() -> [Float] {
        let master = masterGain()
        return [master] + engineAppKeys.map { (key: String) -> Float in
            guard let app = apps.first(where: { $0.key == key }) else { return master }
            return app.muted ? 0 : master * Self.appCurve(app.volume)
        }
    }

    private func pushGains() {
        engine.setGains(currentGains())
    }
}

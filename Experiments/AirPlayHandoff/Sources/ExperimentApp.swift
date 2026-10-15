import AppKit
import AVFoundation
import AVKit
import Foundation
@_spi(AirPlayExperiment) import Lumen

private func itemID(_ item: AVPlayerItem?) -> String {
    item.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private let handle: FileHandle

    init() throws {
        let path = ProcessInfo.processInfo.environment["LUMEN_EXPERIMENT_LOG"]
            ?? NSHomeDirectory() + "/Library/Logs/LumenAirPlayExperiment/events.jsonl"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func emit(_ event: String, player: AVPlayer? = nil, extra: [String: Any] = [:]) {
        var record = extra
        record["event"] = event
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        record["mainThread"] = Thread.isMainThread
        if let player {
            record["externalVideo"] = player.isExternalPlaybackActive
            record["item"] = itemID(player.currentItem)
            record["playerStatus"] = player.status.rawValue
            record["itemStatus"] = player.currentItem?.status.rawValue ?? -1
            record["rate"] = player.rate
            record["timeControl"] = player.timeControlStatus.rawValue
            record["muted"] = player.isMuted
            let seconds = player.currentTime().seconds
            if seconds.isFinite { record["itemSeconds"] = seconds }
        }
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        record["sequence"] = sequence
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data([10]))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

@MainActor
private final class ExperimentController: NSObject, NSApplicationDelegate, AVRoutePickerViewDelegate {
    private struct Configuration: Decodable {
        let mediaURL: String
        let audioTrackID: Int32
    }
    private var window: NSWindow?
    private var engine: ProAVPlayer?
    private var observations = [NSKeyValueObservation]()
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var log: EventLog?
    private var prepared = false
    private var stopped = false
    private let stateLabel = NSTextField(labelWithString: "Not prepared. No automatic playback.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            log = try EventLog()
            guard let path = ProcessInfo.processInfo.environment["LUMEN_EXPERIMENT_CONFIG"] else { throw NSError(domain: "ExperimentConfig", code: 1) }
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let url = URL(string: config.mediaURL), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path), config.audioTrackID >= 0 else { throw NSError(domain: "ExperimentConfig", code: 2) }
            let options = KSOptions()
            options.isLoopPlay = false
            options.registerRemoteControll = false
            options.startPlayTime = 12
            let engine = ProAVPlayer(url: url, options: options)
            self.engine = engine
            engine.isMuted = true
            engine.experimentConfigure(audioTrackID: config.audioTrackID) { [weak self] event, fields in
                guard let self else { return }
                self.log?.emit(event, player: self.engine?.experimentPlayer, extra: fields)
                self.stateLabel.stringValue = event
            }
            installObservations(player: engine.experimentPlayer)
            buildWindow(engine: engine)
            log?.emit("setup.proav", player: engine.experimentPlayer, extra: ["os": ProcessInfo.processInfo.operatingSystemVersionString, "audioStream": config.audioTrackID, "requestedSourceStart": 12])
        } catch {
            log?.emit("setup.failed", extra: ["domain": (error as NSError).domain, "code": (error as NSError).code])
            NSApplication.shared.terminate(nil)
        }
    }

    private func buildWindow(engine: ProAVPlayer) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Lumen ProAV APAC / FLAC Experiment"
        self.window = window
        let content = NSStackView()
        content.orientation = .vertical
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        if let root = window.contentView {
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        }
        let controls = NSStackView()
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 40, height: 32))
        picker.player = engine.experimentPlayer
        picker.delegate = self
        picker.setAccessibilityLabel("External video route")
        controls.addArrangedSubview(picker)
        addButton("Prepare FLAC baseline", action: #selector(prepare), to: controls)
        addButton("Play", action: #selector(play), to: controls)
        addButton("Pause", action: #selector(pause), to: controls)
        addButton("Stop", action: #selector(stop), to: controls)
        addButton("Inspect cleanup", action: #selector(inspectCleanup), to: controls)
        content.addArrangedSubview(controls)
        let routes = NSStackView()
        addButton("Mark TV selected", action: #selector(markExternal), to: routes)
        addButton("Mark local selected", action: #selector(markLocal), to: routes)
        addButton("Confirm receiver FLAC progression", action: #selector(confirmReceiver), to: routes)
        content.addArrangedSubview(routes)
        let handoff = NSStackView()
        addButton("Prepare APAC", action: #selector(prepareAPAC), to: handoff)
        addButton("Prepare FLAC", action: #selector(prepareFLAC), to: handoff)
        addButton("Commit direct", action: #selector(commit), to: handoff)
        addButton("Cancel candidate", action: #selector(cancel), to: handoff)
        content.addArrangedSubview(handoff)
        content.addArrangedSubview(stateLabel)
        content.addArrangedSubview(NSTextField(labelWithString: "Route marks record an observed picker selection; they do not change routes. Confirm actual receiver FLAC playback before codec changes."))
        if let view = engine.view {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func addButton(_ title: String, action: Selector, to row: NSStackView) {
        row.orientation = .horizontal
        row.spacing = 8
        let button = NSButton(title: title, target: self, action: action)
        button.setAccessibilityIdentifier(title)
        row.addArrangedSubview(button)
    }

    private func installObservations(player: AVPlayer) {
        let eventLog = log
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.initial, .old, .new]) { player, change in
            var fields = [String: Any]()
            if let old = change.oldValue { fields["old"] = old }
            if let new = change.newValue { fields["new"] = new }
            eventLog?.emit("video.kvo", player: player, extra: fields)
        })
        observations.append(player.observe(\.currentItem, options: [.initial, .old, .new]) { [weak self] player, _ in
            eventLog?.emit("item.kvo", player: player)
            let item = player.currentItem
            Task { @MainActor in self?.observeItem(item) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in eventLog?.emit("timeControl.kvo", player: player) })
        observations.append(player.observe(\.rate, options: [.initial, .new]) { player, _ in eventLog?.emit("rate.kvo", player: player) })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                engine.experimentObserveProgress()
                var fields: [String: Any] = ["cleanupWorkspaceExists": engine.experimentWorkspaceExists]
                if engine.currentPlaybackTime.isFinite { fields["sourceSeconds"] = engine.currentPlaybackTime }
                if time.seconds.isFinite { fields["observerItemSeconds"] = time.seconds }
                self.log?.emit("playback.tick", player: engine.experimentPlayer, extra: fields)
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem?) {
        let eventLog = log
        let player = engine?.experimentPlayer
        itemObservation = item?.observe(\.status, options: [.initial, .new]) { item, _ in
            var fields: [String: Any] = ["observedItem": itemID(item), "observedStatus": item.status.rawValue]
            if let error = item.error as NSError? { fields["errorDomain"] = error.domain; fields["errorCode"] = error.code }
            eventLog?.emit("itemStatus.kvo", player: player, extra: fields)
        }
    }

    @objc private func prepare() {
        guard !prepared, !stopped else { return }
        prepared = true
        log?.emit("baseline.prepare", player: engine?.experimentPlayer)
        engine?.experimentBeginBaseline()
    }
    @objc private func play() { if !stopped { engine?.play() } }
    @objc private func pause() { engine?.pause() }
    @objc private func markExternal() { engine?.experimentMarkSelectedRoute(external: true) }
    @objc private func markLocal() { engine?.experimentMarkSelectedRoute(external: false) }
    @objc private func confirmReceiver() { engine?.experimentConfirmReceiverProgress() }
    @objc private func prepareAPAC() { engine?.experimentPrepareCounterpart(.apac) }
    @objc private func prepareFLAC() { engine?.experimentPrepareCounterpart(.flac) }
    @objc private func commit() { engine?.experimentCommitCandidate() }
    @objc private func cancel() { engine?.experimentCancelCandidate() }
    @objc private func inspectCleanup() {
        guard let engine else { return }
        log?.emit("cleanup.inspected", player: engine.experimentPlayer, extra: ["workspaceExists": engine.experimentWorkspaceExists])
    }
    @objc private func stop() {
        guard !stopped else { return }
        stopped = true
        engine?.shutdown()
        log?.emit("stop", player: engine?.experimentPlayer)
    }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { log?.emit("picker.open", player: engine?.experimentPlayer) }
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { log?.emit("picker.closed", player: engine?.experimentPlayer) }
    func applicationWillTerminate(_ notification: Notification) {
        if let timeObserver { engine?.experimentPlayer.removeTimeObserver(timeObserver) }
        stop()
        log?.emit("terminate", player: engine?.experimentPlayer)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private struct ExperimentApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let controller = ExperimentController()
        application.delegate = controller
        withExtendedLifetime(controller) { application.run() }
    }
}

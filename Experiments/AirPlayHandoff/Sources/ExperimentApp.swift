import AppKit
import AVFoundation
import AVKit
import Foundation
import Lumen

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
        let timestamp = ProcessInfo.processInfo.systemUptime
        var record = extra
        record["event"] = event
        record["uptime"] = timestamp
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
            if seconds.isFinite { record["seconds"] = seconds }
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
    private var window: NSWindow?
    private var engine: KSAVPlayer?
    private var observations = [NSKeyValueObservation]()
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var mediaURL: URL?
    private var options = KSOptions()
    private var log: EventLog?
    private var candidateReady = false
    private let stateLabel = NSTextField(labelWithString: "Not prepared")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            log = try EventLog()
            guard let configPath = ProcessInfo.processInfo.environment["LUMEN_EXPERIMENT_CONFIG"] else {
                throw NSError(domain: "ExperimentConfig", code: 1)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            guard let config = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let rawURL = config["mediaURL"], let url = URL(string: rawURL)
            else { throw NSError(domain: "ExperimentConfig", code: 2) }
            mediaURL = url
            options.isLoopPlay = false
            options.registerRemoteControll = false
            let engine = KSAVPlayer(url: url, options: options)
            self.engine = engine
            engine.isMuted = true
            installObservations(player: engine.player)
            buildWindow(engine: engine)
            log?.emit("setup", player: engine.player, extra: ["os": ProcessInfo.processInfo.operatingSystemVersionString])
        } catch {
            log?.emit("setup.failed", extra: ["domain": (error as NSError).domain, "code": (error as NSError).code])
            NSApplication.shared.terminate(nil)
        }
    }

    private func buildWindow(engine: KSAVPlayer) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Lumen AirPlay Experiment"
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
        controls.orientation = .horizontal
        controls.spacing = 8
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 40, height: 32))
        picker.player = engine.player
        picker.delegate = self
        picker.setAccessibilityLabel("External video route")
        controls.addArrangedSubview(picker)
        addButton("Prepare", action: #selector(prepare), to: controls)
        addButton("Play", action: #selector(play), to: controls)
        addButton("Pause", action: #selector(pause), to: controls)
        addButton("Stop", action: #selector(stop), to: controls)
        addButton("Mark route action", action: #selector(mark), to: controls)
        content.addArrangedSubview(controls)
        let paths = NSStackView()
        paths.orientation = .horizontal
        paths.spacing = 8
        addButton("A remove", action: #selector(removeA), to: paths)
        addButton("A attach", action: #selector(attachA), to: paths)
        addButton("B prepare", action: #selector(prepareB), to: paths)
        addButton("B commit", action: #selector(commitB), to: paths)
        addButton("C direct", action: #selector(replaceC), to: paths)
        content.addArrangedSubview(paths)
        content.addArrangedSubview(stateLabel)
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
        let button = NSButton(title: title, target: self, action: action)
        button.setAccessibilityIdentifier(title)
        row.addArrangedSubview(button)
    }

    private func installObservations(player: AVPlayer) {
        let eventLog = log
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.initial, .old, .new]) { [weak self] player, change in
            var fields: [String: Any] = [:]
            if let old = change.oldValue { fields["old"] = old }
            if let new = change.newValue { fields["new"] = new }
            eventLog?.emit("video.kvo", player: player, extra: fields)
            Task { @MainActor in self?.refreshState() }
        })
        observations.append(player.observe(\.currentItem, options: [.initial, .old, .new]) { [weak self] player, _ in
            eventLog?.emit("item.kvo", player: player)
            let item = player.currentItem
            Task { @MainActor in self?.observeItem(item) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .old, .new]) { player, _ in
            eventLog?.emit("timeControl.kvo", player: player)
        })
        observations.append(player.observe(\.rate, options: [.initial, .old, .new]) { player, _ in
            eventLog?.emit("rate.kvo", player: player)
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { _ in
            eventLog?.emit("playback.tick", player: player)
        }
    }

    private func observeItem(_ item: AVPlayerItem?) {
        let eventLog = log
        let player = engine?.player
        itemStatusObservation = item?.observe(\.status, options: [.initial, .old, .new]) { item, _ in
            var fields: [String: Any] = ["observedItem": itemID(item), "observedStatus": item.status.rawValue]
            if let error = item.error as NSError? {
                fields["errorDomain"] = error.domain
                fields["errorCode"] = error.code
            }
            eventLog?.emit("itemStatus.kvo", player: player, extra: fields)
        }
        refreshState()
    }

    private func refreshState() {
        guard let player = engine?.player else { return }
        stateLabel.stringValue = "External video: \(player.isExternalPlaybackActive) | Item: \(itemID(player.currentItem)) | Status: \(player.currentItem?.status.rawValue ?? -1) | Candidate ready: \(candidateReady) | Muted: \(player.isMuted)"
    }

    @objc private func prepare() {
        guard let engine else { return }
        log?.emit("prepare.before", player: engine.player)
        engine.prepareToPlay()
        log?.emit("prepare.after", player: engine.player)
    }

    @objc private func play() { engine?.play(); log?.emit("play", player: engine?.player) }
    @objc private func pause() { engine?.pause(); log?.emit("pause", player: engine?.player) }
    @objc private func mark() { log?.emit("manual.routeAction", player: engine?.player) }

    @objc private func removeA() {
        guard let engine else { return }
        engine.cancelSourceSwitch()
        candidateReady = false
        log?.emit("A.remove.before", player: engine.player)
        engine.shutdown()
        log?.emit("A.remove.after.checkpoint", player: engine.player)
        refreshState()
    }

    @objc private func attachA() {
        guard let engine, let mediaURL else { return }
        log?.emit("A.attach.before", player: engine.player)
        engine.replace(url: mediaURL, options: options)
        engine.prepareToPlay()
        engine.play()
        log?.emit("A.attach.after", player: engine.player)
    }

    @objc private func prepareB() {
        guard let engine, let mediaURL else { return }
        candidateReady = false
        engine.experimentSourceSwitchReady = { [weak self] in
            guard let self else { return }
            self.candidateReady = true
            self.log?.emit("B.ready.checkpoint", player: self.engine?.player)
            self.refreshState()
        }
        log?.emit("B.prepare.before", player: engine.player)
        engine.switchSource(url: mediaURL, options: options) { [weak self] success in
            guard let self else { return }
            self.candidateReady = false
            self.log?.emit("B.complete", player: self.engine?.player, extra: ["success": success])
            self.refreshState()
        }
        log?.emit("B.prepare.after", player: engine.player)
    }

    @objc private func commitB() {
        guard let engine, candidateReady else {
            log?.emit("B.commit.notReady", player: engine?.player)
            return
        }
        log?.emit("B.commit.before", player: engine.player)
        engine.experimentCommitSourceSwitch()
        log?.emit("B.commit.after", player: engine.player)
        refreshState()
    }

    @objc private func replaceC() {
        guard let engine, let mediaURL else { return }
        engine.cancelSourceSwitch()
        candidateReady = false
        let replacement = AVPlayerItem(url: mediaURL)
        log?.emit("C.replace.before", player: engine.player, extra: ["replacementItem": itemID(replacement)])
        engine.player.replaceCurrentItem(with: replacement)
        engine.play()
        log?.emit("C.replace.after", player: engine.player)
    }

    @objc private func stop() {
        engine?.shutdown()
        log?.emit("stop", player: engine?.player)
        refreshState()
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        log?.emit("picker.open", player: engine?.player)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        log?.emit("picker.closed", player: engine?.player)
        refreshState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let timeObserver { engine?.player.removeTimeObserver(timeObserver) }
        engine?.shutdown()
        log?.emit("terminate", player: engine?.player)
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

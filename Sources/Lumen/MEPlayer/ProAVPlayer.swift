import AVFoundation
import Foundation
#if os(tvOS) || os(xrOS)
import DisplayCriteria
#endif
#if (os(tvOS) || os(iOS)) && canImport(SpatialAudioPlayback)
import SpatialAudioPlayback
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
public final class ProAVPlayer {
    public static var segmentDuration = TimeInterval(2)
    public static var minimumSegmentsBeforeReady = 2
    public static var serverFactory: () -> ProAVLocalServer = { ProAVLoopbackHTTPServer() }

    private let innerPlayer: KSAVPlayer
    private let server: ProAVLocalServer
    private let workspaceURL: URL
    private var url: URL
    private var options: KSOptions
    private var remuxItem: MEPlayerItem?
    private var session: ProAVRemuxSession?
    private var serverBaseURL: URL?
    private var startOffset = TimeInterval(0)
    private var pendingSeekCompletion: ((Bool) -> Void)?
    private var launchIndex = 0
    private var activeLaunchIndex = 0
    private var delegateProxy: ProAVLaunchDelegateProxy?
    private var pendingSourceSwitch: PendingSourceSwitch?
    private var preferredAudioTrackID: Int32?
    /// Audio tracks of this source that the library refused; they keep the FLAC path.
    private var refusedSpatialAudioTrackIDs = Set<Int32>()
    /// Whether playback resumes after an in-place restart, for the FLAC fallback or AirPlay, of a launch
    /// that was already playing.
    private var fallbackResumesPlayback: Bool?
    private var playbackTimeObserver: Any?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var externalPlaybackObservationGeneration = 0
    /// Keep the observed route across item removal, which can clear AVPlayer's active flag.
    private var externalPlaybackActive = false
    /// The AtmosOutputActivator while a launch plays APAC on tvOS or iOS; releasing it detaches it.
    private var atmosOutput: AnyObject?
    private var reportedReady = false
    private var didFail = false
    public weak var delegate: MediaPlayerDelegate?

    // Temporary SPI on the isolated experiment branch; nil for every normal player.
    private var experiment: AirPlayExperiment?

    private final class AirPlayExperiment {
        let event: (String, [String: Any]) -> Void
        var candidate: ExperimentCandidate?
        var retained = [RemuxLaunch]()
        var mapping: ProAVExperimentMapping?
        var probingBaseline = false
        var committing = false
        var blocked = false
        var selectedExternal: Bool?
        var externalFLACVerified = false
        var progressStart: Double?
        var progressItem: AVPlayerItem?
        var baselineTimeout: DispatchWorkItem?
        var confirmationTimeout: DispatchWorkItem?

        init(event: @escaping (String, [String: Any]) -> Void) { self.event = event }
    }

    private final class ExperimentCandidate {
        let launch: RemuxLaunch
        let options: KSOptions
        let spatial: Bool
        let requestedOffset: Double
        var mapping: ProAVExperimentMapping?
        var timeout: DispatchWorkItem?

        init(launch: RemuxLaunch, options: KSOptions, spatial: Bool, requestedOffset: Double) {
            self.launch = launch
            self.options = options
            self.spatial = spatial
            self.requestedOffset = requestedOffset
        }
    }

    private struct RemuxLaunch {
        let index: Int
        let directoryName: String
        let session: ProAVRemuxSession
        let item: MEPlayerItem
        let proxy: ProAVLaunchDelegateProxy
    }

    private struct PendingSourceSwitch {
        let launch: RemuxLaunch
        let url: URL
        let options: KSOptions
        let startOffset: TimeInterval
        let spatialAudio: ProAVRemuxSession.SpatialAudioPolicy
        let completion: (Bool) -> Void
        var innerSwitchStarted = false
    }

    public required init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        server = ProAVPlayer.serverFactory()
        innerPlayer = KSAVPlayer(url: url, options: options)
        ProAVPlayer.purgeWorkspaces()
        workspaceURL = ProAVPlayer.workspaceRoot.appendingPathComponent(UUID().uuidString)
        innerPlayer.delegate = self
        // The remux reads only so far ahead of this position.
        playbackTimeObserver = innerPlayer.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let experiment = self.experiment, experiment.committing, let candidate = experiment.candidate, let mapping = candidate.mapping {
                    candidate.launch.session.playbackTime = mapping.sourceOffset + self.innerPlayer.currentPlaybackTime
                } else {
                    self.session?.playbackTime = self.currentPlaybackTime
                }
            }
        }
        observeExternalPlayback()
    }

    private func observeExternalPlayback() {
        #if !os(xrOS)
        let generation = externalPlaybackObservationGeneration
        externalPlaybackObservation = innerPlayer.player.observe(\.isExternalPlaybackActive) { [weak self] player, _ in
            let isActive = player.isExternalPlaybackActive
            Task { @MainActor in
                guard let self, self.externalPlaybackObservationGeneration == generation else { return }
                self.externalPlaybackDidChange(isActive: isActive)
            }
        }
        #endif
    }

    /// Replacing an item must not turn a teardown notification into a route change. The generation
    /// also drops notifications already queued by the previous observation.
    private func updateInnerPlayerItem(_ update: () -> Void) {
        // Capture a real disconnect that may still be queued on the main actor. Once the item is
        // gone, a false property value can instead be a side effect of our own teardown.
        if innerPlayer.player.currentItem != nil {
            externalPlaybackActive = innerPlayer.isExternalPlaybackActive
        }
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        externalPlaybackObservationGeneration += 1
        update()
        // Attachment can activate AirPlay synchronously while observation is suspended. Only an
        // observed route change may clear the saved state; item removal's false value cannot.
        if innerPlayer.isExternalPlaybackActive {
            externalPlaybackActive = true
        }
        observeExternalPlayback()
    }

    private static var workspaceRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lumen-ProAV")
    }

    private static func purgeWorkspaces() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func makeLaunch(url: URL, options: KSOptions, at time: TimeInterval, audioTrackID: Int32?, spatialAudio: ProAVRemuxSession.SpatialAudioPolicy) -> RemuxLaunch {
        launchIndex += 1
        let directoryName = "launch\(launchIndex)"
        let directory = workspaceURL.appendingPathComponent(directoryName)
        let configuration = ProAVRemuxSession.Configuration(directory: directory, targetSegmentDuration: ProAVPlayer.segmentDuration, minimumSegmentsBeforeReady: ProAVPlayer.minimumSegmentsBeforeReady)
        let session = ProAVRemuxSession(configuration: configuration)
        session.preferredAudioTrackID = audioTrackID
        var spatialAudio = spatialAudio
        // An AirPlay receiver plays the stream itself, so the APAC rendition is left out.
        if experiment == nil { spatialAudio.isExternalPlaybackActive = externalPlaybackActive }
        session.experimentRecordsMuxSample = experiment != nil
        session.spatialAudioPolicy = spatialAudio
        session.playbackTime = time
        options.startPlayTime = time
        let item = MEPlayerItem(url: url, options: options, remuxSession: session)
        let proxy = ProAVLaunchDelegateProxy(target: self, launch: launchIndex)
        item.delegate = proxy
        return RemuxLaunch(index: launchIndex, directoryName: directoryName, session: session, item: item, proxy: proxy)
    }

    private func startRemux(at time: TimeInterval, spatialAudioEnabled: Bool = true) {
        let spatialAudio = ProAVRemuxSession.SpatialAudioPolicy(refusedTrackIDs: refusedSpatialAudioTrackIDs, isEnabled: spatialAudioEnabled, isExternalPlaybackActive: experiment != nil)
        let launch = makeLaunch(url: url, options: options, at: time, audioTrackID: preferredAudioTrackID, spatialAudio: spatialAudio)
        launch.session.onReady = { [weak self, weak session = launch.session, directoryName = launch.directoryName] _ in
            runOnMainThread {
                guard let self, let session, self.session === session else { return }
                self.remuxDidBecomeReady(directoryName: directoryName)
            }
        }
        launch.session.onFailure = { [weak self, weak session = launch.session] sessionError in
            runOnMainThread {
                guard let self, let session, self.session === session else { return }
                self.sessionDidFail(session, error: sessionError)
            }
        }
        session = launch.session
        remuxItem = launch.item
        delegateProxy = launch.proxy
        activeLaunchIndex = launch.index
        startOffset = time
        launch.item.prepareToPlay()
    }

    private func remuxDidBecomeReady(directoryName: String) {
        guard !didFail else { return }
        if let experiment, experiment.mapping == nil {
            guard !experiment.probingBaseline, !experiment.blocked, let session else { return }
            guard let remuxItem, experimentValidateTrack(remuxItem) else { experimentReject("baseline.trackMismatch"); return }
            experiment.probingBaseline = true
            Task { [weak self] in
                let result = await Task.detached { Result { try session.experimentReadMapping() } }.value
                guard let self, self.experiment === experiment, self.session === session, !experiment.blocked else { return }
                switch result {
                case let .success(mapping):
                    guard mapping.hasMuxedFLAC else { self.experimentReject("baseline.notFLAC"); return }
                    experiment.mapping = mapping
                    experiment.baselineTimeout?.cancel()
                    experiment.event("baseline.mapping", mapping.fields.mapValues { $0 as Any })
                    experiment.event("baseline.offset", ["requested": self.startOffset, "measured": mapping.sourceOffset])
                    self.startOffset = mapping.sourceOffset
                    self.remuxDidBecomeReady(directoryName: directoryName)
                case let .failure(error): self.experimentReject("baseline.mapping.failed", error: error)
                }
            }
            return
        }
        guard !restartForExternalPlaybackIfNeeded() else { return }
        applyDisplayCriteria()
        if let serverBaseURL {
            attach(baseURL: serverBaseURL, directoryName: directoryName)
        } else {
            server.start(rootDirectory: workspaceURL) { [weak self] result in
                runOnMainThread {
                    guard let self else { return }
                    switch result {
                    case let .success(baseURL):
                        self.serverBaseURL = baseURL
                        self.attach(baseURL: baseURL, directoryName: directoryName)
                    case let .failure(serverError):
                        self.fail(error: NSError(description: "ProAV server start failed: \(serverError.localizedDescription)"))
                    }
                }
            }
        }
    }

    private func attach(baseURL: URL, directoryName: String) {
        guard !didFail, directoryName == "launch\(activeLaunchIndex)" else { return }
        guard !restartForExternalPlaybackIfNeeded() else { return }
        let masterURL = baseURL.appendingPathComponent(directoryName).appendingPathComponent(ProAVRemuxSession.masterPlaylistName)
        updateSpatialAudioOutput()
        updateInnerPlayerItem {
            innerPlayer.replace(url: masterURL, options: options)
            innerPlayer.prepareToPlay()
        }
        _ = restartForExternalPlaybackIfNeeded()
    }

    /// Plays the activator while the active launch plays APAC on this device: APAC alone doesn't switch
    /// a receiver to Dolby Atmos, and AirPods render it flatter without it.
    private func updateSpatialAudioOutput() {
        #if (os(tvOS) || os(iOS)) && canImport(SpatialAudioPlayback)
        guard #available(tvOS 26, iOS 26, *) else { return }
        guard session?.playsSpatialAudio == true, !externalPlaybackActive else {
            atmosOutput = nil
            return
        }
        guard atmosOutput == nil else { return }
        let activator = AtmosOutputActivator()
        activator.attach(to: innerPlayer.player)
        atmosOutput = activator
        #endif
    }

    private func applyDisplayCriteria() {
        #if os(tvOS) || os(xrOS)
        guard let displayManager = UIApplication.shared.windows.first?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled,
              let signaling = session?.videoSignaling
        else {
            return
        }
        let refreshRate = remuxItem?.assetTracks.first(where: { $0.mediaType == .video && $0.isEnabled })?.nominalFrameRate ?? 0
        guard refreshRate > 0 else { return }
        displayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, videoDynamicRange: signaling.preferredDynamicRange.rawValue)
        #endif
    }

    private func sessionDidFail(_ session: ProAVRemuxSession, error: NSError) {
        if experiment != nil { experimentReject("session.failed", error: error); return }
        guard !didFail else { return }
        guard let failure = session.spatialAudioFailure else {
            fail(error: error)
            return
        }
        KSLog(level: .info, "\(error.localizedDescription); falling back to FLAC")
        if case let .refused(trackID) = failure {
            refusedSpatialAudioTrackIDs.insert(trackID)
        }
        restartInPlace(spatialAudioEnabled: false)
    }

    private func externalPlaybackDidChange(isActive: Bool) {
        externalPlaybackActive = isActive
        if let experiment {
            experiment.event("policy.route.checkpoint", ["externalVideo": isActive, "wouldRestart": session?.needsSpatialAudioRestart(isExternalPlaybackActive: isActive) ?? false])
            return
        }
        guard !didFail else { return }
        // The activator stops as AirPlay starts, ahead of the restart without APAC.
        updateSpatialAudioOutput()
        guard isActive else {
            // Keep the requested source switch. Its readiness callback also rechecks the route if
            // opening has not selected audio yet.
            if let pending = pendingSourceSwitch {
                if pending.launch.session.needsSpatialAudioRestart(isExternalPlaybackActive: false) {
                    restartPendingSourceSwitch(spatialAudio: pending.spatialAudio)
                }
                return
            }
            _ = restartForExternalPlaybackIfNeeded()
            return
        }
        if session?.playsSpatialAudio == true {
            KSLog(level: .info, "AirPlay started; playing the APAC track through FLAC")
            // Like a seek, the restart abandons a pending switch, which the layer then makes cold,
            // without APAC while AirPlay lasts.
            _ = restartForExternalPlaybackIfNeeded()
        } else if let pending = pendingSourceSwitch, pending.launch.session.needsSpatialAudioRestart(isExternalPlaybackActive: true) {
            restartPendingSourceSwitch(spatialAudio: pending.spatialAudio)
        }
    }

    @discardableResult
    private func restartForExternalPlaybackIfNeeded() -> Bool {
        if experiment != nil { return false }
        guard let session, session.needsSpatialAudioRestart(isExternalPlaybackActive: externalPlaybackActive) else { return false }
        restartInPlace(spatialAudioEnabled: session.spatialAudioPolicy.isEnabled)
        return true
    }

    /// Restarts the active launch at the current position, keeping the play or pause state.
    private func restartInPlace(spatialAudioEnabled: Bool) {
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        // The remux runs ahead of playback, so this can happen while the launch plays.
        let resumesPlayback = isReadyToPlay && seekCompletion == nil ? isPlaying : nil
        restart(at: currentPlaybackTime, completion: seekCompletion, spatialAudioEnabled: spatialAudioEnabled)
        fallbackResumesPlayback = resumesPlayback
    }

    private func fail(error: NSError) {
        if experiment != nil { experimentReject("playback.failed", error: error); return }
        abortPendingSourceSwitch()
        guard !didFail else { return }
        didFail = true
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        seekCompletion?(false)
        remuxItem?.delegate = nil
        atmosOutput = nil
        updateInnerPlayerItem { innerPlayer.shutdown() }
        remuxItem?.shutdown()
        session?.requestCleanup()
        server.stop()
        serverBaseURL = nil
        delegate?.finish(player: self, error: error)
    }

    private func restart(at time: TimeInterval, completion: ((Bool) -> Void)?, spatialAudioEnabled: Bool = true) {
        abortPendingSourceSwitch()
        let previousCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        previousCompletion?(false)
        pendingSeekCompletion = completion
        fallbackResumesPlayback = nil
        didFail = false
        remuxItem?.delegate = nil
        atmosOutput = nil
        updateInnerPlayerItem { innerPlayer.shutdown() }
        remuxItem?.shutdown()
        session?.requestCleanup()
        startRemux(at: time, spatialAudioEnabled: spatialAudioEnabled)
    }

    private func startSourceSwitch(url: URL, options: KSOptions, spatialAudio: ProAVRemuxSession.SpatialAudioPolicy, completion: @escaping (Bool) -> Void) {
        let time = currentPlaybackTime
        let launch = makeLaunch(url: url, options: options, at: time, audioTrackID: nil, spatialAudio: spatialAudio)
        pendingSourceSwitch = PendingSourceSwitch(launch: launch, url: url, options: options, startOffset: time, spatialAudio: spatialAudio, completion: completion)
        launch.session.onReady = { [weak self, weak session = launch.session] _ in
            runOnMainThread {
                guard let self, let session, self.pendingSourceSwitch?.launch.session === session else { return }
                self.pendingSourceSwitchDidBecomeReady()
            }
        }
        // One handler serves the candidate while it is pending and once it is committed, so a failure
        // that arrives during the commit still reaches the active session.
        launch.session.onFailure = { [weak self, weak session = launch.session] sessionError in
            runOnMainThread {
                guard let self, let session else { return }
                if self.pendingSourceSwitch?.launch.session === session {
                    self.pendingSourceSwitchDidFail(session)
                } else if self.session === session {
                    self.sessionDidFail(session, error: sessionError)
                }
            }
        }
        launch.item.prepareToPlay()
    }

    /// Retries a candidate whose APAC conversion failed on the FLAC path, as a cold launch would.
    private func pendingSourceSwitchDidFail(_ session: ProAVRemuxSession) {
        guard let pending = pendingSourceSwitch, let failure = session.spatialAudioFailure else {
            abortPendingSourceSwitch(restoreSpatialAudio: true)
            return
        }
        var spatialAudio = pending.spatialAudio
        spatialAudio.isEnabled = false
        if case let .refused(trackID) = failure {
            spatialAudio.refusedTrackIDs.insert(trackID)
        }
        restartPendingSourceSwitch(spatialAudio: spatialAudio)
    }

    private func restartPendingSourceSwitch(spatialAudio: ProAVRemuxSession.SpatialAudioPolicy) {
        guard let pending = pendingSourceSwitch else { return }
        pendingSourceSwitch = nil
        if pending.innerSwitchStarted {
            innerPlayer.abandonPendingSourceSwitch()
        }
        pending.launch.item.delegate = nil
        pending.launch.item.shutdown()
        pending.launch.session.requestCleanup()
        startSourceSwitch(url: pending.url, options: pending.options, spatialAudio: spatialAudio, completion: pending.completion)
    }

    private func pendingSourceSwitchDidBecomeReady() {
        guard let pending = pendingSourceSwitch else { return }
        if pending.launch.session.needsSpatialAudioRestart(isExternalPlaybackActive: externalPlaybackActive) {
            restartPendingSourceSwitch(spatialAudio: pending.spatialAudio)
            return
        }
        guard let serverBaseURL else {
            abortPendingSourceSwitch(restoreSpatialAudio: true)
            return
        }
        let masterURL = serverBaseURL.appendingPathComponent(pending.launch.directoryName).appendingPathComponent(ProAVRemuxSession.masterPlaylistName)
        pendingSourceSwitch?.innerSwitchStarted = true
        innerPlayer.switchSource(url: masterURL, options: pending.options) { [weak self] success in
            runOnMainThread {
                guard let self, self.pendingSourceSwitch?.launch.session === pending.launch.session else { return }
                if success {
                    self.commitPendingSourceSwitch()
                } else {
                    self.abortPendingSourceSwitch(restoreSpatialAudio: true)
                }
            }
        }
    }

    private func commitPendingSourceSwitch() {
        guard let pending = pendingSourceSwitch else { return }
        pendingSourceSwitch = nil
        let previousSession = session
        let previousItem = remuxItem
        let previousDynamicRange = previousSession?.videoSignaling?.preferredDynamicRange
        previousItem?.delegate = nil
        url = pending.url
        options = pending.options
        preferredAudioTrackID = nil
        refusedSpatialAudioTrackIDs = pending.spatialAudio.refusedTrackIDs
        session = pending.launch.session
        remuxItem = pending.launch.item
        delegateProxy = pending.launch.proxy
        activeLaunchIndex = pending.launch.index
        startOffset = pending.startOffset
        pending.launch.session.onReady = nil
        previousItem?.shutdown()
        previousSession?.requestCleanup()
        if session?.videoSignaling?.preferredDynamicRange != previousDynamicRange {
            applyDisplayCriteria()
        }
        updateSpatialAudioOutput()
        pending.completion(true)
    }

    private func abortPendingSourceSwitch(restoreSpatialAudio: Bool = false) {
        guard let pending = pendingSourceSwitch else { return }
        pendingSourceSwitch = nil
        if pending.innerSwitchStarted {
            innerPlayer.abandonPendingSourceSwitch()
        }
        pending.launch.item.delegate = nil
        pending.launch.item.shutdown()
        pending.launch.session.requestCleanup()
        pending.completion(false)
        // AirPlay may have ended while this candidate was pending, deferring the active restart.
        if restoreSpatialAudio, pendingSourceSwitch == nil, !externalPlaybackActive {
            _ = restartForExternalPlaybackIfNeeded()
        }
    }

    fileprivate func launchDidFail(index: Int, error: NSError?) {
        if let pending = pendingSourceSwitch, pending.launch.index == index {
            abortPendingSourceSwitch(restoreSpatialAudio: true)
            return
        }
        guard index == activeLaunchIndex else { return }
        fail(error: error ?? NSError(errorCode: .formatOpenInput))
    }
}

// SPI and implementation below exist only on this durable, unmerged experiment branch.
@_spi(AirPlayExperiment)
public enum ProAVExperimentAudio: String {
    case flac, apac
}

extension ProAVPlayer {
    @_spi(AirPlayExperiment) public var experimentPlayer: AVQueuePlayer { innerPlayer.player }
    @_spi(AirPlayExperiment) public var experimentWorkspaceExists: Bool { FileManager.default.fileExists(atPath: workspaceURL.path) }

    @_spi(AirPlayExperiment) public func experimentConfigure(audioTrackID: Int32, event: @escaping (String, [String: Any]) -> Void) {
        guard session == nil, experiment == nil else { return }
        preferredAudioTrackID = audioTrackID
        experiment = AirPlayExperiment(event: event)
    }

    @_spi(AirPlayExperiment) public func experimentBeginBaseline() {
        guard let experiment, session == nil, !experiment.blocked else { return }
        let timeout = DispatchWorkItem { [weak self] in self?.experimentReject("baseline.preparation.timeout") }
        experiment.baselineTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        prepareToPlay()
    }

    @_spi(AirPlayExperiment) public func experimentMarkSelectedRoute(external: Bool) {
        guard let experiment, !experiment.blocked else { return }
        experiment.selectedExternal = external
        experiment.progressStart = nil
        experiment.progressItem = nil
        experiment.event("operator.selectedRoute", ["external": external])
    }

    /// Called by the existing app's periodic observer. This is video-item progression, not an
    /// audio-route or Atmos detector. The operator separately confirms the receiver picture.
    @_spi(AirPlayExperiment) public func experimentObserveProgress() {
        guard let experiment, !experiment.blocked, !experiment.committing,
              experiment.selectedExternal == true, innerPlayer.isExternalPlaybackActive,
              experiment.mapping?.hasMuxedFLAC == true, session?.playsSpatialAudio == false,
              innerPlayer.player.currentItem?.status == .readyToPlay, innerPlayer.player.rate > 0 else {
            experiment?.progressStart = nil
            experiment?.progressItem = nil
            return
        }
        let time = innerPlayer.player.currentTime().seconds
        guard time.isFinite else { return }
        if experiment.progressItem !== innerPlayer.player.currentItem {
            experiment.progressItem = innerPlayer.player.currentItem
            experiment.progressStart = time
        }
        experiment.event("preflight.externalFLAC.progress", ["itemTime": time, "advance": time - (experiment.progressStart ?? time)])
    }

    @_spi(AirPlayExperiment) public func experimentConfirmReceiverProgress() {
        guard let experiment, !experiment.blocked, experiment.selectedExternal == true,
              innerPlayer.isExternalPlaybackActive, experiment.progressItem === innerPlayer.player.currentItem,
              let start = experiment.progressStart, innerPlayer.player.rate > 0,
              innerPlayer.player.currentTime().seconds - start >= 2,
              experiment.mapping?.hasMuxedFLAC == true else {
            experiment?.event("preflight.notSatisfied", [:])
            return
        }
        let item = innerPlayer.player.currentItem
        experiment.confirmationTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.experimentReject("preflight.itemMapping.timeout") }
        experiment.confirmationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        Task { [weak self] in
            guard let self else { return }
            let identity = await self.innerPlayer.experimentValidateItemTimeline(event: experiment.event)
            guard self.experiment === experiment, !experiment.blocked, self.innerPlayer.player.currentItem === item else { return }
            experiment.confirmationTimeout?.cancel()
            guard identity else { self.experimentReject("preflight.itemMappingAmbiguous"); return }
            guard experiment.selectedExternal == true, self.innerPlayer.isExternalPlaybackActive else { return }
            experiment.externalFLACVerified = true
            experiment.event("preflight.externalFLAC.operatorConfirmed", [:])
        }
    }

    @_spi(AirPlayExperiment) public func experimentPrepareCounterpart(_ audio: ProAVExperimentAudio) {
        guard let experiment, !experiment.blocked, experiment.externalFLACVerified,
              !experiment.committing, experiment.candidate == nil,
              let active = session, experiment.mapping != nil, serverBaseURL != nil else {
            experiment?.event("candidate.notPermitted", [:])
            return
        }
        let time = currentPlaybackTime
        guard time.isFinite, time >= 0 else { experimentReject("position.invalid"); return }
        let options = KSOptions()
        options.isLoopPlay = false
        options.registerRemoteControll = false
        let policy = ProAVRemuxSession.SpatialAudioPolicy(isExternalPlaybackActive: audio == .flac)
        let launch = makeLaunch(url: url, options: options, at: time, audioTrackID: preferredAudioTrackID, spatialAudio: policy)
        let candidate = ExperimentCandidate(launch: launch, options: options, spatial: audio == .apac, requestedOffset: time)
        experiment.candidate = candidate
        launch.session.onReady = { [weak self, weak candidate] _ in
            runOnMainThread {
                guard let self, let candidate, self.experiment?.candidate === candidate else { return }
                self.experimentMeasureCandidate(candidate)
            }
        }
        launch.session.onFailure = { [weak self] error in runOnMainThread { self?.experimentReject("candidate.session.failed", error: error) } }
        let timeout = DispatchWorkItem { [weak self] in self?.experimentReject("candidate.preparation.timeout") }
        candidate.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        experiment.event("candidate.prepare", ["audio": audio.rawValue, "requestedSourceOffset": time, "activeAPAC": active.playsSpatialAudio, "launch": launch.index])
        launch.item.prepareToPlay()
    }

    private func experimentMeasureCandidate(_ candidate: ExperimentCandidate) {
        guard let experiment, !experiment.blocked, candidate.mapping == nil,
              experimentValidateTrack(candidate.launch.item),
              candidate.launch.session.playsSpatialAudio == candidate.spatial else {
            experimentReject("candidate.codecOrTrackMismatch")
            return
        }
        let candidateSession = candidate.launch.session
        let spatial = candidate.spatial
        Task { [weak self] in
            let result = await Task.detached { () -> Result<ProAVExperimentMapping, Error> in
                Result {
                    var mapping = try candidateSession.experimentReadMapping()
                    if spatial {
                        let audio = try ProAVExperimentMapping.audioTiming(directory: candidateSession.configuration.directory)
                        guard audio["audioSampleEntry"] == "apac" else {
                            throw NSError(domain: "LumenExperimentMapping", code: 12)
                        }
                        mapping.fields.merge(audio) { _, value in value }
                    } else if !mapping.hasMuxedFLAC {
                        throw NSError(domain: "LumenExperimentMapping", code: 13)
                    }
                    return mapping
                }
            }.value
            guard let self, self.experiment === experiment, !experiment.blocked, experiment.candidate === candidate else { return }
            switch result {
            case let .success(mapping):
                candidate.mapping = mapping
                experiment.event("candidate.mapping", mapping.fields.mapValues { $0 as Any })
                experiment.event("candidate.ready.checkpoint", ["launch": candidate.launch.index, "audio": candidate.spatial ? "apac" : "flac", "requestedOffset": candidate.requestedOffset, "measuredOffset": mapping.sourceOffset])
            case let .failure(error): self.experimentReject("candidate.mapping.failed", error: error)
            }
        }
    }

    private func experimentValidateTrack(_ item: MEPlayerItem) -> Bool {
        guard let selected = item.assetTracks.first(where: { $0.mediaType == .audio && $0.isEnabled }),
              selected.trackID == preferredAudioTrackID,
              ProAVSpatialAudioTranscoder.converts(codecpar: selected.codecpar) else { return false }
        experiment?.event("source.selectedTrack", ["stream": selected.trackID, "codec": selected.codecName, "timebase": "\(selected.timebase.num)/\(selected.timebase.den)"])
        return true
    }

    @_spi(AirPlayExperiment) public func experimentCancelCandidate() {
        guard let experiment, !experiment.committing, let candidate = experiment.candidate else { return }
        candidate.timeout?.cancel()
        candidate.launch.session.onReady = nil
        candidate.launch.session.onFailure = nil
        candidate.launch.item.delegate = nil
        candidate.launch.item.shutdown()
        experiment.retained.append(candidate.launch)
        experiment.candidate = nil
        experiment.event("candidate.cancelled.filesRetained", ["launch": candidate.launch.index])
    }

    @_spi(AirPlayExperiment) public func experimentCommitCandidate() {
        guard let experiment, !experiment.blocked, !experiment.committing,
              let candidate = experiment.candidate, let mapping = candidate.mapping,
              let oldSession = session, let oldItem = remuxItem, let oldProxy = delegateProxy,
              let selectedExternal = experiment.selectedExternal, let base = serverBaseURL else { return }
        guard !candidate.spatial || !selectedExternal,
              selectedExternal == innerPlayer.isExternalPlaybackActive else {
            experiment.event("candidate.routeMismatch.cancelRequired", [:])
            return
        }
        let position = currentPlaybackTime
        let target = position - mapping.sourceOffset
        guard position.isFinite, target.isFinite, target >= 0 else { experimentReject("candidate.mapping.targetInvalid"); return }
        candidate.timeout?.cancel()
        experiment.committing = true
        let old = RemuxLaunch(index: activeLaunchIndex, directoryName: "launch\(activeLaunchIndex)", session: oldSession, item: oldItem, proxy: oldProxy)
        let master = base.appendingPathComponent(candidate.launch.directoryName).appendingPathComponent(ProAVRemuxSession.masterPlaylistName)
        experiment.event("candidate.commit", ["sourcePosition": position, "candidateItemTarget": target, "candidateMeasuredOffset": mapping.sourceOffset, "activeMeasuredOffset": startOffset])
        innerPlayer.experimentReplaceDirect(url: master, options: candidate.options, target: target, event: experiment.event, validateCommit: { [weak self] in
            guard let self, !experiment.blocked, let route = experiment.selectedExternal else { return false }
            return route == self.innerPlayer.isExternalPlaybackActive && (!candidate.spatial || !route)
        }) { [weak self] success in
            guard let self, self.experiment === experiment else { return }
            experiment.committing = false
            guard !experiment.blocked else { return }
            if !success { self.experimentReject("candidate.direct.failed"); return }
            self.session = candidate.launch.session
            self.remuxItem = candidate.launch.item
            self.delegateProxy = candidate.launch.proxy
            self.activeLaunchIndex = candidate.launch.index
            self.options = candidate.options
            self.startOffset = mapping.sourceOffset
            experiment.mapping = mapping
            experiment.candidate = nil
            candidate.launch.session.onReady = nil
            candidate.launch.session.onFailure = { [weak self] error in runOnMainThread { self?.experimentReject("active.session.failed", error: error) } }
            old.item.delegate = nil
            old.item.shutdown()
            experiment.retained.append(old)
            self.session?.playbackTime = self.currentPlaybackTime
            experiment.event("candidate.committed.oldFilesRetained", ["sourcePositionAfterSeek": self.currentPlaybackTime, "sourcePositionAtCommit": position, "audio": candidate.spatial ? "apac" : "flac"])
        }
    }

    private func experimentReject(_ event: String, error: Error? = nil) {
        guard let experiment, !experiment.blocked else { return }
        var fields = [String: Any]()
        if let error = error as NSError? { fields = ["errorDomain": error.domain, "errorCode": error.code] }
        experiment.event(event, fields)
        experiment.blocked = true
        experiment.baselineTimeout?.cancel()
        experiment.confirmationTimeout?.cancel()
        innerPlayer.pause()
        experimentCancelCandidate()
        experiment.event("experiment.blocked.stopRequired", [:])
    }
}

extension ProAVPlayer: MediaPlayerProtocol {
    public var view: UIView? { innerPlayer.view }
    public var playableTime: TimeInterval { startOffset + innerPlayer.playableTime }
    public var isReadyToPlay: Bool { innerPlayer.isReadyToPlay }
    public var playbackState: MediaPlaybackState { innerPlayer.playbackState }
    public var loadState: MediaLoadState { innerPlayer.loadState }
    public var isPlaying: Bool { innerPlayer.isPlaying }
    public var seekable: Bool { true }
    public var duration: TimeInterval { remuxItem?.duration ?? innerPlayer.duration }
    public var fileSize: Double { remuxItem?.fileSize ?? innerPlayer.fileSize }
    public var naturalSize: CGSize { remuxItem?.naturalSize ?? innerPlayer.naturalSize }
    public var chapters: [Chapter] { remuxItem?.chapters ?? [] }
    public var currentPlaybackTime: TimeInterval { startOffset + innerPlayer.currentPlaybackTime }
    public var dynamicInfo: DynamicInfo? { remuxItem?.dynamicInfo }
    public var subtitleDataSouce: SubtitleDataSouce? { nil }

    public var isMuted: Bool {
        get { innerPlayer.isMuted }
        set { innerPlayer.isMuted = newValue }
    }

    public var allowsExternalPlayback: Bool {
        get { innerPlayer.allowsExternalPlayback }
        set { innerPlayer.allowsExternalPlayback = newValue }
    }

    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool {
        get { innerPlayer.usesExternalPlaybackWhileExternalScreenIsActive }
        set { innerPlayer.usesExternalPlaybackWhileExternalScreenIsActive = newValue }
    }

    public var isExternalPlaybackActive: Bool { innerPlayer.isExternalPlaybackActive }

    public var playbackRate: Float {
        get { innerPlayer.playbackRate }
        set { innerPlayer.playbackRate = newValue }
    }

    public var playbackVolume: Float {
        get { innerPlayer.playbackVolume }
        set { innerPlayer.playbackVolume = newValue }
    }

    public var contentMode: UIViewContentMode {
        get { innerPlayer.contentMode }
        set { innerPlayer.contentMode = newValue }
    }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator { innerPlayer.playbackCoordinator }

    @available(tvOS 14.0, *)
    public var pipController: KSPictureInPictureController? { innerPlayer.pipController }

    public func prepareToPlay() {
        // A fresh play must not inherit the route from a previous, terminal shutdown.
        externalPlaybackActive = innerPlayer.isExternalPlaybackActive
        didFail = false
        startRemux(at: options.startPlayTime)
    }

    public func replace(url: URL, options: KSOptions) {
        shutdown()
        didFail = false
        reportedReady = false
        preferredAudioTrackID = nil
        refusedSpatialAudioTrackIDs = []
        self.url = url
        self.options = options
    }

    public func play() {
        if experiment?.blocked == true { return }
        if fallbackResumesPlayback != nil {
            fallbackResumesPlayback = true
        }
        innerPlayer.play()
    }

    public func pause() {
        if fallbackResumesPlayback != nil {
            fallbackResumesPlayback = false
        }
        innerPlayer.pause()
    }

    public func switchSource(url: URL, options: KSOptions, completion: @escaping ((Bool) -> Void)) {
        abortPendingSourceSwitch()
        guard !didFail, reportedReady, session != nil, serverBaseURL != nil else {
            completion(false)
            return
        }
        startSourceSwitch(url: url, options: options, spatialAudio: ProAVRemuxSession.SpatialAudioPolicy(), completion: completion)
    }

    public func cancelSourceSwitch() {
        abortPendingSourceSwitch(restoreSpatialAudio: true)
    }

    public func shutdown() {
        if let experiment {
            experiment.blocked = true
            experiment.baselineTimeout?.cancel()
            experiment.confirmationTimeout?.cancel()
            experiment.progressItem = nil
            experiment.candidate?.timeout?.cancel()
            if let candidate = experiment.candidate { experiment.retained.append(candidate.launch) }
            experiment.candidate = nil
        }
        abortPendingSourceSwitch()
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        seekCompletion?(false)
        remuxItem?.delegate = nil
        atmosOutput = nil
        updateInnerPlayerItem { innerPlayer.shutdown() }
        remuxItem?.shutdown()
        session?.requestCleanup()
        if let experiment {
            experiment.retained.forEach { $0.item.delegate = nil; $0.item.shutdown(); $0.session.requestCleanup() }
            experiment.retained.removeAll()
            experiment.event("cleanup.requested", [:])
        }
        remuxItem = nil
        session = nil
        server.stop()
        serverBaseURL = nil
        externalPlaybackActive = false
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        restart(at: max(time, 0), completion: completion)
    }

    public func enterBackground() {
        innerPlayer.enterBackground()
    }

    public func enterForeground() {
        innerPlayer.enterForeground()
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        await innerPlayer.thumbnailImageAtCurrentTime()
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [MediaPlayerTrack] {
        if let remuxItem {
            return remuxItem.assetTracks.filter { $0.mediaType == mediaType }
        }
        return innerPlayer.tracks(mediaType: mediaType)
    }

    public func select(track: some MediaPlayerTrack) {
        guard track.mediaType == .audio else { return }
        guard preferredAudioTrackID != track.trackID else { return }
        preferredAudioTrackID = track.trackID
        remuxItem?.assetTracks.filter { $0.mediaType == .audio }.forEach { $0.isEnabled = $0.trackID == track.trackID }
        restart(at: currentPlaybackTime, completion: nil)
    }
}

extension ProAVPlayer: MediaPlayerDelegate {
    public func readyToPlay(player _: some MediaPlayerProtocol) {
        if let experiment, experiment.committing { experiment.event("direct.item.ready", [:]); return }
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        if reportedReady {
            seekCompletion?(true)
            if let resumesPlayback = fallbackResumesPlayback {
                fallbackResumesPlayback = nil
                if resumesPlayback {
                    play()
                } else {
                    pause()
                }
            } else if options.isSeekedAutoPlay {
                play()
            }
        } else {
            reportedReady = true
            seekCompletion?(true)
            delegate?.readyToPlay(player: self)
        }
    }

    public func changeLoadState(player _: some MediaPlayerProtocol) {
        delegate?.changeLoadState(player: self)
    }

    public func changeBuffering(player _: some MediaPlayerProtocol, progress: Int) {
        delegate?.changeBuffering(player: self, progress: progress)
    }

    public func playBack(player _: some MediaPlayerProtocol, loopCount: Int) {
        delegate?.playBack(player: self, loopCount: loopCount)
    }

    public func finish(player _: some MediaPlayerProtocol, error: Error?) {
        if let error {
            fail(error: NSError(description: "ProAV playback failed: \(error.localizedDescription)"))
        } else {
            delegate?.finish(player: self, error: nil)
        }
    }
}

private final class ProAVLaunchDelegateProxy: MEPlayerDelegate {
    private weak var target: ProAVPlayer?
    private let launch: Int

    init(target: ProAVPlayer, launch: Int) {
        self.target = target
        self.launch = launch
    }

    func sourceDidChange(loadingState _: LoadingState) {}

    func sourceDidOpened() {}

    func sourceDidFailed(error: NSError?) {
        runOnMainThread { [weak self] in
            guard let self, let target = self.target else { return }
            target.launchDidFail(index: self.launch, error: error)
        }
    }

    func sourceDidFinished() {}

    func sourceDidChange(oldBitRate _: Int64, newBitrate _: Int64) {}
}

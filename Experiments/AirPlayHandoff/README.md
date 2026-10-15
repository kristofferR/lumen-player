# Temporary AirPlay handoff experiment

This isolated branch tests the existing `KSAVPlayer` and its view on one macOS sender. It is not a production fix and must not be merged into the integration or example branches.

The app reads `LUMEN_EXPERIMENT_CONFIG`, the path to a private JSON file containing `mediaURL`. The media URL and credentials are never written to its event log. Optional `LUMEN_EXPERIMENT_LOG` selects the JSONL log path. Defaults live in `~/Library/Logs/LumenAirPlayExperiment/`.

Cloud-build the XcodeGen project for arm64 macOS without signing. Download the short-lived workflow artifact, sign locally for development if required, then launch its executable with the private configuration path. Do not compile locally. Use the existing Apple TV ownership lock before playback.

Start with one existing native H.264/AAC media URL. The player starts muted. Route selection uses `AVRoutePickerView` bound to the same `AVQueuePlayer`.

- **A remove / A attach:** the existing shutdown/replace/prepare path, with an explicit nonblocking empty-item checkpoint.
- **B prepare / B commit:** the actual existing `switchSource` path, paused at the branch-only readiness callback. The main actor stays free. The existing timeout still bounds preparation; the temporary hook cancels it only once the candidate is ready so route selection can finish before manual commit.
- **C direct:** direct non-nil replacement on that same player, using the same URL.

For each path, first preserve the selected remote video route. Then deliberately disconnect/reconnect around preparation and commit. Mark the intended action before changing routes. Events include sequence, monotonic time, current-item identity, raw external-video state, status, rate and time-control state. KVO is never suspended in this harness. A false video flag or audio route alone is not proof of physical route identity; compare with the deliberately selected route and receiver behavior.

End by selecting the original local route, stopping the app, restoring any changed volume/settings and releasing only the owned device lock. Preserve raw logs outside the repository. Results cover only the actual sender OS and receiver used.

## Prepared follow-up: actual ProAV APAC / FLAC HLS

This is a preparation protocol, not an implemented follow-up harness or a playback result. The native harness above remains unchanged. Its source checkpoint is `566c70d00c2fea7a14af81d404f82c231278aab4`; raw evidence is retained outside the repository in `~/Library/Application Support/LumenAirPlayExperiment/20261015/`.

### Evidence reused

The native run used macOS 27.0.1 (26A434, arm64) and Apple TV 4K (2nd generation), tvOS 27.2 (24K5103f). Direct non-nil replacement retained external-video true through the new item's readiness, until an intentional disconnect about 62 seconds later. Removing the item produced false roughly 4.8 seconds later while Apple TV remained selected in the picker. An actual disconnect after that false produced no further false notification. These are one-sender observations, not an AVFoundation guarantee or an APAC result.

Queued preparation reached no ready checkpoint in two remote attempts and one local control; each completed false at the existing ten-second timeout. Source inspection shows insertion behind the current item followed by a wait for candidate status, then advancement only after readiness. The logs establish the timeout, not why AVFoundation withheld readiness. Do not change that timeout, force an unready queued commit, or repeat B for this follow-up. Do not repeat native A/C controls.

### Existing media and scope

Use the existing `atmos-pairs/natures-fury.TrueHD.Atmos.mkv` under the private NativePlayer fixture directory. Its stored probe reports 111.177 seconds, H.264 High video, a single TrueHD + Dolby Atmos audio stream (index 1), 48 kHz, eight channels, and source start zero. Revalidate stream identity when opening; select that same stream explicitly for both launches. No media is committed, uploaded, copied or converted in advance. Read its existing local path from private runtime configuration.

Use only the same arm64 macOS sender and existing receiver, recording their actual versions again at runtime. No iPhone target, iOS/tvOS sender claim, DTS:X expansion or receiver Atmos claim. macOS has no `AtmosOutputActivator` in the current ProAV implementation; preserve that existing platform behavior.

### Smallest harness change

Keep the same AppKit window, existing KSAVPlayer view, AVQueuePlayer and route picker. Add a ProAV mode and branch-only seams in ProAVPlayer / KSAVPlayer, rather than implementing another remux or player framework:

1. Expose the existing inner player for observation and picker binding. Initialize one ProAVPlayer with fresh options, the selected stream and a nonzero source start (12 seconds). Use its real `makeLaunch`, MEPlayerItem, ProAVRemuxSession, server, APAC converter and FLAC converter.
2. Prepare one counterpart launch while the active launch remains intact. Pass a fresh options object and explicit experiment policy: APAC allowed for a local launch; external-playback policy for FLAC so `spatialAudioWithheld` remains truthful. Never mutate the active options to prepare a candidate. Hold at session `onReady`, with the main actor free. Readiness still requires the normal video fragments and an APAC audio fragment when applicable. Log failure/refusal and stop that case; FLAC fallback must not be counted as successful APAC preparation.
3. Gate automatic route-triggered restart only in this explicitly selected experiment mode. Continue observing every raw external-video transition and record both the real policy decision and operator checkpoint. Manual prepare/commit controls make route timing observable. The existing production observation/restart behavior remains untouched outside the seam; the original finding remains open.
4. Commit through a branch-only KSAVPlayer method using `makeAsset` and one direct `replaceCurrentItem(with: nonNilCandidate)`. Maintain its asset/loader/options ownership and existing item observers. Do not call shutdown, replace(url:options:), removeAllItems or suspend KVO. This candidate is not a queued item: session-ready means HLS exists, not that the new AVPlayerItem is ready. Record its actual unknown-to-ready/failed transition after replacement, seek completion and resumption before declaring success.
5. Retain the previous item, asset/loader and remux producer until the replacement is ready and the seek succeeds. Keep the shared server running. On candidate preparation failure, abandon only the candidate. On post-replacement failure, restore the retained previous item with a direct non-nil replacement, record the failure and stop the case. After success stop the retired producer; retain its files until experiment Stop. Limit to one active and one pending producer; no automatic retry.

The source seam must be visibly restricted to this durable experiment branch. Keep production/shared, example and upstream refs fixed. Preserve the original native source and CI refs as immutable checkpoints.

### Timeline and lifetime checks

ProAV reports `startOffset + innerPlayer.currentPlaybackTime`. `makeLaunch` seeds session playback time and `options.startPlayTime` with the requested source position; MEPlayerItem seeks at source start plus that position. The generic KSAVPlayer queue commit instead seeks to the old item's raw time. Do not reuse that seek for a newly rebased remux launch.

At candidate creation record its nominal source offset S. At commit capture the active nominal source position P and calculate candidate item time `P - S`, rather than seeking to P or the old raw item time. Verify that the target lies in the candidate's available timeline. Also record source start, first source video PTS/DTS, derived mux origin, actual first fragment decode/presentation times, APAC start/priming and candidate seekable ranges. Seeking can land at a keyframe before the requested time; the nominal offset is not proof of frame continuity. Compare the observed source-to-item mapping on both launches and stop if it disagrees with the nominal mapping. Do not silently clamp a target, alter timestamps or hide a discontinuity to make the handoff pass.

APAC uses a separate audio playlist and derives packet times from the first video decode origin, with encoder priming retained before its start. FLAC is muxed with video and primes its encoder timestamps from the first decoded source audio frame. The master playlist chooses one audio representation at session creation. Switching a policy flag on a running session does not change its codec or make both representations available. Validate actual `apac` versus `fLaC` signaling/sample entries and selected stream, not merely a requested mode.

`requestCleanup()` can delete the entire launch directory as soon as remuxing has finished; it is not a reader lease. Do not request old-session cleanup during preparation or immediately before replacement. On Stop, detach playback first, stop all retained producers, request their cleanup, stop the server and verify only this experiment's workspace is removed.

### Required cloud build

After implementing and inspecting these seams, create a new manual workflow-only validation ref with exact source SHA/tree assertions and a whitelist covering only this experiment plus the reviewed ProAV/KSAV seams and necessary session/timeline diagnostics. Reuse the previous pinned XcodeGen 2.46.0 archive/hash, macos-26 / Xcode 26.6, unsigned arm64 macOS app command, SAB 1.6.2 exact revision/location, frozen generated dependency lock, platform/architecture checks and short-lived app artifact. No extra platform builds or unchanged library-suite rerun. No media, source URL or credential in CI, artifacts or logs.

Before dispatch, verify Actions OFF and refs; bounded enable/inventory/disable-all, enable only manual build.yml, dispatch the exact validation ref once, disable the file at start and turn Actions OFF first at terminal. A failed build is diagnosed before any further dispatch. No local compilation. The native app artifact cannot substitute for this changed harness build.

### Focused runtime sequence after a fresh device-use grant

1. Check sender use and TV ownership; acquire only the normal free TV lock. Capture picker, receiver state and original route/volume/settings. Start muted, using the real default loopback server. Confirm local APAC HLS readiness and progression at a nonzero source position. Prepare the FLAC counterpart while APAC continues; inspect the session-ready checkpoint and both timelines.
2. Mark the action, select Apple TV and directly commit the ready FLAC HLS launch. Observe ordered video KVO, old/new item identity, item status, seek completion, source/item times, rate, time-control, errors and receiver behavior. Confirm actual FLAC HLS external progression before interpreting route preservation. The production server binds and advertises only `127.0.0.1`; do not assume receiver fetch/proxy behavior. If external HLS fails, retain error/request evidence and stop. Do not silently expose a LAN server to bypass it.
3. While FLAC remains remote, prepare local APAC. Deliberately select the local route during preparation, mark the selection and hold at session-ready if needed. Commit APAC only after the operator-confirmed local selection. Observe whether the direct handoff introduces another false/true transition, whether local APAC progresses and whether the policy would incorrectly retain FLAC. A raw false alone does not identify the selected video route.
4. One reconnect variant: while a new APAC candidate is preparing from remote FLAC, select local, then reselect Apple TV before commit. Reject the now-inappropriate APAC candidate, prepare FLAC at the current source position and directly commit FLAC. Record the obsolete candidate's cancellation and any item/KVO gaps. Do not attach APAC to the external receiver just to finish a checkpoint.

Use bounded preparation/observation windows (30 seconds each; commit promptly after ready), with no repeated retries or endurance/listening phase. Absence of a false transition in these cases is promising evidence only for the tested macOS sender. It does not close the runtime finding or prove iOS/tvOS behavior.

Cleanup: select the original local route, stop and close the owned app, verify all its processes and remux producers are gone, verify server/workspace cleanup, restore route/volume/settings and temporary launch environment, delete private configuration, and release only the owned lock. Preserve ordered logs and short outcome evidence outside the repository. Required next device step is a fresh runtime grant and ownership check after the changed harness artifact is ready; this preparation does not acquire the TV or start playback.

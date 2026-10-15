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

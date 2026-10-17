import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var session: SessionCoordinator
    @State private var tracks: [TrackSource] = []
    @State private var spotifyURI = ""
    @State private var listenerID = ""

    var body: some View {
        List {
            if let error = session.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            nowPlaying

            if session.isLeader {
                librarySection
                calibrationSection
            }

            speakersSection

            if !session.isLeader {
                clockSection
            }

            spotifySection
        }
        .navigationTitle(session.isLeader ? "Your session" : "Joined")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Leave") { session.leave() }
            }
        }
        .onAppear {
            tracks = LocalLibrary.allTracks()
            listenerID = session.myID
        }
    }

    // MARK: Sections

    private var nowPlaying: some View {
        Section("Now playing") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.track?.title ?? "Nothing yet").font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isLeader, session.timeline != nil {
                    Button { session.pauseAll() } label: {
                        Image(systemName: "pause.circle.fill").font(.largeTitle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }

    private var statusLine: String {
        if session.timeline != nil { return "Playing in sync" }
        if session.track != nil { return "Loading on every phone…" }
        return session.isLeader ? "Pick a track below" : "Waiting for the host to pick a track"
    }

    private var librarySection: some View {
        Section {
            ForEach(tracks, id: \.self) { track in
                Button {
                    session.play(track)
                } label: {
                    Label(track.title, systemImage: "music.note")
                }
            }
            HStack {
                TextField("spotify:track:…", text: $spotifyURI)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                Button("Play") {
                    let uri = normalizedSpotifyURI(spotifyURI)
                    session.play(.spotify(uri: uri, title: "Spotify track"))
                }
                .disabled(normalizedSpotifyURI(spotifyURI).isEmpty || !session.spotifyConnected)
            }
        } header: {
            Text("Play on every phone")
        } footer: {
            Text("Local files must be on every phone with the same name. Add them in the Files app under SyncSpeaker. The click track is the easiest way to hear sync errors.")
        }
    }

    private var calibrationSection: some View {
        Section {
            Picker("Listening phone", selection: $listenerID) {
                Text("This phone").tag(session.myID)
                ForEach(session.connectedPeers, id: \.self) { Text($0).tag($0) }
            }
            Button {
                session.calibrate(listenerID: listenerID.isEmpty ? session.myID : listenerID)
            } label: {
                Label("Calibrate speakers", systemImage: "waveform.badge.mic")
            }
            .disabled(isCalibrating)

            switch session.calibration {
            case .idle: EmptyView()
            case .running(let msg): Label(msg, systemImage: "ear").foregroundStyle(.secondary)
            case .done(let msg): Label(msg, systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let msg): Label(msg, systemImage: "xmark.circle").foregroundStyle(.red)
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("Hold the listening phone where people will be. Each speaker chirps three times, and every phone adjusts its timing so the chirps arrive together.")
        }
    }

    private var isCalibrating: Bool {
        if case .running = session.calibration { return true }
        return false
    }

    private var speakersSection: some View {
        Section("Speakers") {
            VStack(alignment: .leading, spacing: 6) {
                Text("This phone · \(session.routeName)").font(.subheadline.bold())
                metricRow("Reported delay", ms(session.reportedDelayMillis))
                metricRow("Calibrated extra", ms(session.residualMillis, signed: true))
                metricRow("Timeline error", session.playerErrorMillis.map { ms($0, signed: true) } ?? "–")
                metricRow("Rate trim", session.playerRate.map { String(format: "%+.3f%%", ($0 - 1) * 100) } ?? "–")
            }

            if session.isLeader {
                ForEach(session.connectedPeers, id: \.self) { name in
                    let status = session.peerStatuses[name]
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(name) · \(status?.routeName ?? "…")").font(.subheadline.bold())
                        metricRow("Ready", status.map { $0.ready ? "yes" : "no" } ?? "–")
                        metricRow("Timeline error", status?.errorMillis.map { ms($0, signed: true) } ?? "–")
                        metricRow("Clock accuracy", status?.clockRMSMillis.map { "±" + ms($0) } ?? "syncing…")
                    }
                }
                if session.connectedPeers.isEmpty {
                    Text("No one has joined yet.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clockSection: some View {
        Section {
            metricRow("Clock accuracy", session.clockRMSMillis.map { "±" + ms($0) } ?? "syncing…")
            metricRow("Best round trip", session.clockMinRTTMillis.map { ms($0) } ?? "–")
        } header: {
            Text("Clock sync with host")
        } footer: {
            Text("Under ±2 ms is good. If the round trip is above ~30 ms, try putting both phones on the same Wi-Fi.")
        }
    }

    private var spotifySection: some View {
        Section {
            if session.spotifyConnected {
                Label("Connected to Spotify", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { session.connectSpotify() } label: {
                    Label("Connect Spotify", systemImage: "link")
                }
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Needs Spotify Premium and the Spotify app on this phone. While the app is in development, each person must also be added in the Spotify Developer Dashboard.")
        }
    }

    // MARK: Helpers

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func ms(_ value: Double, signed: Bool = false) -> String {
        String(format: signed ? "%+.1f ms" : "%.1f ms", value)
    }

    /// Accepts "spotify:track:ID" or an open.spotify.com/track/ID link.
    private func normalizedSpotifyURI(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("spotify:track:") { return t }
        if let url = URL(string: t), url.host?.contains("spotify.com") == true,
           let i = url.pathComponents.firstIndex(of: "track"), i + 1 < url.pathComponents.count {
            return "spotify:track:\(url.pathComponents[i + 1])"
        }
        return ""
    }
}

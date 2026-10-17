import SwiftUI
import MultipeerConnectivity

struct RootView: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle: HomeView()
                case .browsing: JoinView()
                case .hosting, .joined: SessionView()
                }
            }
            .animation(.default, value: session.phase)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("SyncSpeaker").font(.largeTitle.bold())
                Text("Play the same song on everyone's speakers, perfectly in time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 12) {
                Button { session.host() } label: {
                    Label("Start a session", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button { session.browse() } label: {
                    Label("Join a session", systemImage: "person.2.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(24)
    }
}

// MARK: - Join

struct JoinView: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        List {
            Section {
                if session.foundLeaders.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for nearby sessions…").foregroundStyle(.secondary)
                    }
                }
                ForEach(session.foundLeaders, id: \.self) { leader in
                    Button {
                        session.join(leader)
                    } label: {
                        Label(leader.displayName, systemImage: "hifispeaker")
                    }
                }
            } footer: {
                Text("Phones need Wi-Fi or Bluetooth turned on and to be near each other.")
            }
        }
        .navigationTitle("Join")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { session.leave() }
            }
        }
    }
}

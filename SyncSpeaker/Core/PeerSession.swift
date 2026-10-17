import Foundation
import MultipeerConnectivity
import UIKit

/// Peer-to-peer transport built on MultipeerConnectivity.
///
/// - The leader advertises; followers browse and invite the leader they pick.
/// - Clock-sync pings are answered right here, on MultipeerConnectivity's
///   delivery queue, so main-thread work can't add delay to t2/t3.
/// - Everything else is forwarded to `onMessage` on the main queue.
final class PeerSession: NSObject {
    static let serviceType = "syncspk"   // ≤15 chars; must match NSBonjourServices in Info.plist

    let localPeer: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// Called on the main queue. `receivedAt` is the local HostClock ns at arrival.
    var onMessage: ((SyncMessage, MCPeerID, Int64) -> Void)?
    var onPeersChanged: (([MCPeerID]) -> Void)?
    var onFoundLeadersChanged: (([MCPeerID]) -> Void)?

    /// Leader sets this so pings get answered immediately.
    var answersPings = false

    /// Only touched on the main queue.
    private(set) var foundLeaders: [MCPeerID] = [] {
        didSet { onFoundLeadersChanged?(foundLeaders) }
    }

    /// `deviceName` comes from the caller because `UIDevice` is main-actor only.
    init(deviceName: String) {
        let suffix = String(UUID().uuidString.prefix(4))
        localPeer = MCPeerID(displayName: "\(deviceName)-\(suffix)")
        // No encryption: these are tiny control messages and encryption adds
        // per-packet work that shows up as clock-sync jitter.
        session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .none)
        super.init()
        session.delegate = self
    }

    var connectedPeers: [MCPeerID] { session.connectedPeers }

    // MARK: Roles

    func startAdvertising() {
        stopAll()
        answersPings = true
        let adv = MCNearbyServiceAdvertiser(peer: localPeer,
                                            discoveryInfo: ["role": PeerRole.leader.rawValue],
                                            serviceType: Self.serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
    }

    func startBrowsing() {
        stopAll()
        answersPings = false
        let br = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
    }

    func join(_ leader: MCPeerID) {
        browser?.invitePeer(leader, to: session, withContext: nil, timeout: 15)
    }

    func stopAll() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        foundLeaders = []
    }

    func disconnect() {
        stopAll()
        session.disconnect()
    }

    // MARK: Sending

    func send(_ message: SyncMessage, to peers: [MCPeerID]? = nil) {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty, let data = try? MessageCodec.encode(message) else { return }
        // Unreliable for clock sync: a lost ping is just a lost sample, while
        // a retransmitted one would carry a misleading RTT.
        let mode: MCSessionSendDataMode = message.isClockSync ? .unreliable : .reliable
        do {
            try session.send(data, toPeers: targets, with: mode)
        } catch {
            print("PeerSession send failed: \(error)")
        }
    }
}

// MARK: - MCSessionDelegate

extension PeerSession: MCSessionDelegate {
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let receivedAt = HostClock.nowNanos()          // take t2 / t4 first
        guard let message = try? MessageCodec.decode(data) else { return }

        if answersPings, case let .ping(id, t1) = message {
            let t3 = HostClock.nowNanos()
            send(.pong(id: id, t1: t1, t2: receivedAt, t3: t3), to: [peerID])
            return
        }

        DispatchQueue.main.async {
            self.onMessage?(message, peerID, receivedAt)
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peers = session.connectedPeers
        DispatchQueue.main.async { self.onPeersChanged?(peers) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser (leader)

extension PeerSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // MVP: accept everyone who finds us. Add a join code here later if needed.
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Advertising failed: \(error)")
    }
}

// MARK: - Browser (follower)

extension PeerSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == PeerRole.leader.rawValue else { return }
        DispatchQueue.main.async {
            if !self.foundLeaders.contains(peerID) { self.foundLeaders.append(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.foundLeaders.removeAll { $0 == peerID } }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Browsing failed: \(error)")
    }
}

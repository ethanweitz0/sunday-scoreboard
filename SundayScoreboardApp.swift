import AVFoundation
import Combine
import SwiftUI
import UIKit

@main
struct SundayScoreboardApp: App {
    var body: some Scene {
        WindowGroup { ScoreboardScreen() }
    }
}

@MainActor
struct ScoreboardScreen: View {
    @StateObject private var game = GameSession()
    @State private var sheet: Panel?

    enum Panel: String, Identifiable {
        case setup, channels
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.049, blue: 0.09).ignoresSafeArea()
            if game.playingVideo {
                VideoSurface(player: game.player).ignoresSafeArea()
            } else {
                idleScreen
            }

            VStack {
                Spacer()
                controls
            }

            if let alert = game.scoringAlert {
                Celebration(alert: alert, isDemo: game.isDemo)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 50)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { panel in
            switch panel {
            case .setup: setup
            case .channels: ChannelPicker(channels: game.channels) { channel in
                game.play(channel)
                sheet = nil
            }
            }
        }
        .onPlayPauseCommand { game.togglePlayback() }
    }

    private var idleScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: "football.fill")
                .font(.system(size: 64))
                .foregroundStyle(.cyan)
            Text("Sunday Scoreboard")
                .font(.system(size: 90, weight: .black))
            if let snapshot = game.snapshot {
                Text("Week \(snapshot.week)  •  \(points(snapshot.ourScore)) – \(points(snapshot.opponentScore))")
                    .font(.title2.monospacedDigit())
            } else {
                Text("Connect your ESPN matchup and choose a live channel.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button("Setup") { sheet = .setup }
            Button("Channels") { sheet = .channels }
                .disabled(game.channels.isEmpty)
            if game.playingVideo {
                Button("Stop video") { game.stopVideo() }
            }
            Menu("Demo") {
                Button("Touchdown") { game.queueDemo(.demoTouchdown) }
                Button("Big fantasy gain") { game.queueDemo(.demoBigGain) }
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 4) {
                if let snapshot = game.snapshot, game.playingVideo {
                    Text("\(points(snapshot.ourScore)) – \(points(snapshot.opponentScore))")
                        .font(.headline.monospacedDigit())
                }
                Text(game.videoStatus).lineLimit(1)
                Text(game.fantasyStatus).lineLimit(2).foregroundStyle(.secondary)
            }
            .font(.caption)
            .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Setup").font(.largeTitle.bold())
                    Spacer()
                    Button("Done") { sheet = nil }
                }
                Text("Live TV").font(.title2.bold())
                TextField("Xtream server (https://…)", text: $game.server)
                TextField("Xtream username", text: $game.username)
                SecureField("Xtream password", text: $game.password)
                HStack {
                    Button("Load channels") { game.loadChannels() }
                        .disabled(game.loadingChannels)
                    Text(game.videoStatus).font(.caption).foregroundStyle(.secondary)
                }
                SecureField("Optional direct HTTPS HLS (.m3u8) URL", text: $game.directStream)
                Button("Play URL") {
                    if game.playDirect() { sheet = nil }
                }
                .disabled(game.directStream.isEmpty)

                Divider().padding(.vertical, 16)

                Text("ESPN Fantasy").font(.title2.bold())
                TextField("Season", text: $game.season)
                TextField("League ID", text: $game.leagueID)
                TextField("Team ID", text: $game.teamID)
                SecureField("SWID (private leagues only)", text: $game.swid)
                SecureField("espn_s2 (private leagues only)", text: $game.espnS2)
                HStack {
                    Button("Connect ESPN") { game.connectFantasy() }
                    Text(game.fantasyStatus).font(.caption).foregroundStyle(.secondary)
                }
                if game.monitoring {
                    Button("Stop ESPN alerts") { game.disconnectFantasy() }
                }
            }
            .padding(48)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
    }
}

@MainActor
final class GameSession: ObservableObject {
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""
    @Published var directStream = ""
    @Published var season = ""
    @Published var leagueID = ""
    @Published var teamID = ""
    @Published var swid = ""
    @Published var espnS2 = ""

    @Published private(set) var channels: [XtreamChannel] = []
    @Published private(set) var loadingChannels = false
    @Published private(set) var videoStatus = "Live TV disconnected"
    @Published private(set) var fantasyStatus = "ESPN disconnected"
    @Published private(set) var monitoring = false
    @Published private(set) var snapshot: FantasySnapshot?
    @Published private(set) var scoringAlert: ScoringAlert?
    @Published private(set) var isDemo = false
    @Published private(set) var playingVideo = false

    let player = AVPlayer()
    private var xtream: XtreamFeed?
    private var fantasyTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?
    private var pending: [(ScoringAlert, Bool)] = []
    private var playerObservation: NSKeyValueObservation?

    func loadChannels() {
        guard !loadingChannels else { return }
        guard let url = httpsURL(server), url.query == nil, url.fragment == nil,
              !username.isEmpty, !password.isEmpty else {
            videoStatus = "Enter the HTTPS Xtream server, username, and password."
            return
        }
        let feed = XtreamFeed(server: url, username: username, password: password)
        loadingChannels = true
        videoStatus = "Loading Xtream channels…"
        Task {
            defer { loadingChannels = false }
            do {
                let results = try await feed.channels()
                var seen = Set<Int>()
                channels = results.filter { seen.insert($0.id).inserted }
                xtream = feed
                videoStatus = "\(channels.count) channels ready"
            } catch {
                videoStatus = message(for: error, fallback: "Couldn’t reach the Xtream server over HTTPS.")
            }
        }
    }

    func play(_ channel: XtreamChannel) {
        guard let url = xtream?.streamURL(for: channel.id) else {
            videoStatus = "Couldn’t create the channel URL."
            return
        }
        play(url, title: channel.name)
    }

    @discardableResult
    func playDirect() -> Bool {
        guard let url = httpsURL(directStream) else {
            videoStatus = "Enter a valid HTTPS stream URL."
            return false
        }
        play(url, title: "Direct stream")
        return true
    }

    private func play(_ url: URL, title: String) {
        let item = AVPlayerItem(url: url)
        videoStatus = "Opening \(title)…"
        playerObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor [weak self, weak observed] in
                guard let self, let observed, self.player.currentItem === observed else { return }
                switch status {
                case .readyToPlay: self.videoStatus = title
                case .failed: self.videoStatus = "Can’t play \(title). Try another HTTPS HLS channel."
                case .unknown: break
                @unknown default: break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        playingVideo = true
        player.play()
    }

    func stopVideo() {
        playerObservation = nil
        player.replaceCurrentItem(with: nil)
        playingVideo = false
        videoStatus = channels.isEmpty ? "Live TV disconnected" : "\(channels.count) channels ready"
    }

    func togglePlayback() {
        guard playingVideo else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func connectFantasy() {
        guard let season = Int(season), season > 2000,
              let league = Int(leagueID), league > 0, let team = Int(teamID), team > 0 else {
            fantasyStatus = "Check the ESPN season, league ID, and team ID."
            return
        }
        let swid = swid.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = espnS2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard swid.isEmpty == secret.isEmpty,
              ![swid, secret].contains(where: { $0.rangeOfCharacter(from: .newlines) != nil || $0.contains(";") }) else {
            fantasyStatus = "Enter both ESPN cookies or leave both blank."
            return
        }
        disconnectFantasy()
        monitoring = true
        fantasyStatus = "Checking ESPN matchup…"
        let feed = ESPNFeed(season: season, leagueID: league, teamID: team, swid: swid, espnS2: secret)
        fantasyTask = Task {
            while !Task.isCancelled {
                do {
                    let next = try await feed.snapshot()
                    guard !Task.isCancelled else { return }
                    let alerts = ScoringAlert.changes(from: snapshot, to: next)
                    snapshot = next
                    fantasyStatus = "ESPN connected · Week \(next.week)"
                    pending.append(contentsOf: alerts.map { ($0, false) })
                    showPending()
                } catch {
                    guard !Task.isCancelled else { return }
                    fantasyStatus = message(for: error, fallback: "ESPN unavailable. Retrying…")
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func disconnectFantasy() {
        fantasyTask?.cancel()
        fantasyTask = nil
        monitoring = false
        snapshot = nil
        pending.removeAll { !$0.1 }
        fantasyStatus = "ESPN disconnected"
    }

    func queueDemo(_ alert: ScoringAlert) {
        guard !(isDemo && alertTask != nil), !pending.contains(where: { $0.1 }) else { return }
        pending.append((alert, true))
        showPending()
    }

    private func showPending() {
        guard alertTask == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        isDemo = next.1
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { scoringAlert = next.0 }
        alertTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeOut(duration: 0.25)) { scoringAlert = nil }
            try? await Task.sleep(nanoseconds: 300_000_000)
            alertTask = nil
            showPending()
        }
    }

    private func message(for error: Error, fallback: String) -> String {
        (error as? FeedError)?.errorDescription ?? fallback
    }
}

struct ChannelPicker: View {
    let channels: [XtreamChannel]
    let select: (XtreamChannel) -> Void
    @State private var query = ""

    private var filtered: [XtreamChannel] {
        query.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Live channels").font(.largeTitle.bold())
            TextField("Search by channel name", text: $query)
            if filtered.isEmpty {
                Text("No matching channels.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filtered) { channel in
                        Button { select(channel) } label: {
                            Text(channel.name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
        }
        .padding(42)
    }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.videoLayer.videoGravity = .resizeAspect
        view.videoLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurface, context: Context) {
        view.videoLayer.player = player
    }
}

final class PlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct Celebration: View {
    let alert: ScoringAlert
    let isDemo: Bool

    private var portrait: some View {
        AsyncImage(url: URL(string: "https://a.espncdn.com/i/headshots/nfl/players/full/\(alert.player.id).png")) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "football.fill").font(.system(size: 57))
        }
        .frame(width: 140, height: 140)
        .background(.cyan.opacity(0.22), in: Circle())
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.cyan, lineWidth: 3))
    }

    var body: some View {
        HStack(spacing: 30) {
            portrait
            VStack(alignment: .leading, spacing: 4) {
                Text(isDemo ? "DEMO  /  \(alert.title)" : alert.title)
                    .font(.headline.weight(.heavy))
                    .tracking(4)
                    .foregroundStyle(.cyan)
                Text(alert.player.name)
                    .font(.system(size: 56, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Fantasy points gained").foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(alert.gain >= 0 ? "+" : "")\(points(alert.gain))")
                    .font(.system(size: 64, weight: .black, design: .monospaced))
                    .foregroundStyle(.cyan)
                Text("\(points(alert.ourScore)) – \(points(alert.opponentScore))")
                    .font(.title3.monospacedDigit())
            }
        }
        .padding(28)
        .background(
            LinearGradient(colors: [Color(red: 0.04, green: 0.25, blue: 0.39), Color(red: 0.025, green: 0.055, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28)
        )
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.cyan.opacity(0.75), lineWidth: 2))
        .shadow(color: .black.opacity(0.65), radius: 24, y: 8)
        .accessibilityElement(children: .combine)
    }
}

private func points(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1...2)))
}

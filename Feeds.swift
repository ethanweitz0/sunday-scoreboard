import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum FeedError: LocalizedError {
    case invalidURL, response(String), missingMatchup, invalidPlaylist

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTPS address."
        case .response(let message): return message
        case .missingMatchup: return "ESPN did not return an active head-to-head matchup and lineup for this team."
        case .invalidPlaylist: return "No live channels were returned. Check the server and login."
        }
    }
}

func httpsURL(_ text: String) -> URL? {
    guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
          parts.user == nil, parts.password == nil else { return nil }
    return parts.url
}

private let feedSession = URLSession(configuration: .ephemeral)

private func requestData(_ request: URLRequest, service: String) async throws -> Data {
    let (data, response) = try await feedSession.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw FeedError.response("\(service) returned HTTP \(code). Check your access and settings.")
    }
    return data
}

struct XtreamChannel: Decodable, Identifiable {
    let stream_id: Int
    let name: String
    var id: Int { stream_id }

    enum CodingKeys: String, CodingKey { case stream_id, name }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? values.decode(Int.self, forKey: .stream_id) {
            stream_id = id
        } else if let raw = try? values.decode(String.self, forKey: .stream_id), let id = Int(raw) {
            stream_id = id
        } else {
            throw FeedError.invalidPlaylist
        }
        name = try values.decode(String.self, forKey: .name)
    }
}

struct XtreamFeed {
    let server: URL
    let username: String
    let password: String

    func channels() async throws -> [XtreamChannel] {
        let endpoint = server.appendingPathComponent("player_api.php")
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw FeedError.invalidURL
        }
        parts.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ]
        // PHP decodes a literal plus in a query as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw FeedError.invalidURL }
        let data = try await requestData(URLRequest(url: url, timeoutInterval: 25), service: "Xtream")
        guard let channels = try? JSONDecoder().decode([XtreamChannel].self, from: data),
              !channels.isEmpty else { throw FeedError.invalidPlaylist }
        return channels
    }

    func streamURL(for id: Int) -> URL? {
        guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let user = username.addingPercentEncoding(withAllowedCharacters: allowed),
              let pass = password.addingPercentEncoding(withAllowedCharacters: allowed),
              user != ".", user != "..", pass != ".", pass != ".." else { return nil }
        let base = parts.percentEncodedPath.hasSuffix("/") ? String(parts.percentEncodedPath.dropLast()) : parts.percentEncodedPath
        parts.percentEncodedPath = base + "/live/\(user)/\(pass)/\(id).m3u8"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}

struct FantasySnapshot {
    struct Player {
        let id: Int
        let name: String
        let points: Double
        let touchdowns: Double
    }

    let week: Int
    let ourScore: Double
    let opponentScore: Double
    let starters: [Player]
}

struct ScoringAlert {
    static let bigGainThreshold = 6.0

    let player: FantasySnapshot.Player
    let touchdownCount: Int
    let gain: Double
    let ourScore: Double
    let opponentScore: Double

    var title: String {
        switch touchdownCount {
        case 0: return "BIG FANTASY GAIN"
        case 1: return "TOUCHDOWN"
        default: return "\(touchdownCount) TOUCHDOWNS"
        }
    }

    static func changes(from previous: FantasySnapshot?, to next: FantasySnapshot) -> [ScoringAlert] {
        guard let previous, previous.week == next.week else { return [] }
        return next.starters.compactMap { player in
            guard let before = previous.starters.first(where: { $0.id == player.id }) else { return nil }
            let gain = player.points - before.points
            let touchdownDelta = player.touchdowns - before.touchdowns
            let touchdownCount = max(0, Int(exactly: touchdownDelta) ?? 0)
            guard touchdownCount > 0 || gain >= bigGainThreshold - 1e-9 else { return nil }
            return ScoringAlert(player: player, touchdownCount: touchdownCount, gain: gain,
                                ourScore: next.ourScore, opponentScore: next.opponentScore)
        }
    }

    static let demoTouchdown = ScoringAlert(
        player: .init(id: 4362628, name: "Ja’Marr Chase", points: 24.8, touchdowns: 1),
        touchdownCount: 1, gain: 8.4, ourScore: 92.6, opponentScore: 78.2
    )

    static let demoBigGain = ScoringAlert(
        player: .init(id: 4362628, name: "Ja’Marr Chase", points: 22.8, touchdowns: 0),
        touchdownCount: 0, gain: 6.4, ourScore: 90.6, opponentScore: 78.2
    )
}

struct ESPNFeed {
    let season: Int
    let leagueID: Int
    let teamID: Int
    let swid: String
    let espnS2: String

    func snapshot() async throws -> FantasySnapshot {
        let base = "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/\(season)/segments/0/leagues/\(leagueID)"
        let metadata = try await fetch(base, [URLQueryItem(name: "view", value: "mStatus")])
        guard let matchupPeriod = metadata.status?.currentMatchupPeriod, matchupPeriod > 0 else {
            throw FeedError.response("ESPN did not return a current matchup week. For a private league, check the cookies.")
        }
        let week = metadata.scoringPeriodId ?? matchupPeriod
        let box = try await fetch(base, [
            URLQueryItem(name: "view", value: "mBoxscore"),
            URLQueryItem(name: "matchupPeriodId", value: String(matchupPeriod)),
            URLQueryItem(name: "scoringPeriodId", value: String(week))
        ])
        guard let matchup = box.schedule?.first(where: {
            $0.matchupPeriodId == matchupPeriod && ($0.home?.teamId == teamID || $0.away?.teamId == teamID)
        }),
              let us = matchup.home?.teamId == teamID ? matchup.home : matchup.away,
              let opponent = matchup.home?.teamId == teamID ? matchup.away : matchup.home,
              let entries = (us.rosterForCurrentScoringPeriod ?? us.rosterForMatchupPeriod)?.entries
        else { throw FeedError.missingMatchup }

        let starters = entries.compactMap { entry -> FantasySnapshot.Player? in
            guard entry.lineupSlotId != 20, entry.lineupSlotId != 21,
                  let player = entry.playerPoolEntry?.player else { return nil }
            let stat = player.stats?.first {
                $0.scoringPeriodId == week && $0.statSourceId == 0 && ($0.statSplitTypeId == nil || $0.statSplitTypeId == 1)
            }
            let touchdowns = ["4", "25", "43", "63"].reduce(0.0) { count, key in
                count + (stat?.stats?[key] ?? 0)
            }
            return .init(id: player.id, name: player.fullName, points: stat?.appliedTotal ?? 0, touchdowns: touchdowns)
        }
        guard !starters.isEmpty else { throw FeedError.missingMatchup }
        return .init(week: week, ourScore: score(us, week: week),
                     opponentScore: score(opponent, week: week), starters: starters)
    }

    private func score(_ team: Team, week: Int) -> Double {
        team.totalPointsLive ?? team.pointsByScoringPeriod?[String(week)] ?? team.totalPoints ?? 0
    }

    private func fetch(_ base: String, _ query: [URLQueryItem]) async throws -> League {
        guard var parts = URLComponents(string: base) else { throw FeedError.invalidURL }
        parts.queryItems = query
        guard let url = parts.url else { throw FeedError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if !swid.isEmpty, !espnS2.isEmpty {
            request.setValue("SWID=\(swid); espn_s2=\(espnS2)", forHTTPHeaderField: "Cookie")
        }
        let data = try await requestData(request, service: "ESPN")
        guard let league = try? JSONDecoder().decode(League.self, from: data) else {
            throw FeedError.response("ESPN did not return readable league data. For a private league, check the cookies.")
        }
        return league
    }

    private struct League: Decodable {
        struct Status: Decodable { let currentMatchupPeriod: Int? }
        let scoringPeriodId: Int?
        let status: Status?
        let schedule: [Matchup]?
    }

    private struct Matchup: Decodable {
        let matchupPeriodId: Int
        let home: Team?
        let away: Team?
    }

    private struct Team: Decodable {
        struct Roster: Decodable { let entries: [Entry] }
        let teamId: Int
        let totalPointsLive: Double?
        let totalPoints: Double?
        let pointsByScoringPeriod: [String: Double]?
        let rosterForCurrentScoringPeriod: Roster?
        let rosterForMatchupPeriod: Roster?
    }

    private struct Entry: Decodable {
        struct Pool: Decodable { let player: Player? }
        let lineupSlotId: Int
        let playerPoolEntry: Pool?
    }

    private struct Player: Decodable {
        struct Stat: Decodable {
            let scoringPeriodId: Int
            let statSourceId: Int
            let statSplitTypeId: Int?
            let stats: [String: Double]?
            let appliedTotal: Double?
        }
        let id: Int
        let fullName: String
        let stats: [Stat]?
    }
}

import Testing
import Foundation
@testable import LiveChess

/// Decode-side tests for every Lichess JSON shape we consume. Fixtures
/// are pasted verbatim from the Lichess OpenAPI examples (or shrunk to
/// the fields our model touches). If Lichess changes a key, the matching
/// test fails immediately and tells us exactly which model needs an
/// update.
@Suite("Lichess JSON models")
struct LichessModelsTests {

    private let decoder = JSONDecoder()

    // MARK: - Account

    @Test
    func decodesAccountWithPerfs() throws {
        let json = """
        {
          "id": "thibault",
          "username": "thibault",
          "perfs": {
            "blitz": { "games": 2945, "rating": 1609, "rd": 60, "prog": 0, "prov": false },
            "rapid": { "games": 1234, "rating": 1742, "rd": 80, "prog": 5 }
          },
          "playTime": { "total": 0, "tv": 0 }
        }
        """.data(using: .utf8)!

        let account = try decoder.decode(LichessAccount.self, from: json)
        #expect(account.id == "thibault")
        #expect(account.username == "thibault")
        #expect(account.title == nil)
        #expect(account.rating(forPerfKey: "rapid") == 1742)
        #expect(account.perfs?["blitz"]?.isProvisional == false)
        #expect(account.perfs?["rapid"]?.isProvisional == false)  // missing prov defaults to false
    }

    // MARK: - Active games

    @Test
    func decodesNowPlaying() throws {
        let json = """
        {
          "nowPlaying": [
            {
              "gameId": "abcdefgh",
              "fullId": "abcdefgh1234",
              "color": "white",
              "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
              "hasMoved": false,
              "isMyTurn": true,
              "lastMove": null,
              "opponent": { "id": "magnus", "username": "Magnus", "rating": 2830, "title": "GM" },
              "perf": "rapid",
              "rated": true,
              "secondsLeft": 599,
              "source": "lobby",
              "speed": "rapid",
              "variant": { "key": "standard", "name": "Standard" }
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(LichessNowPlaying.self, from: json)
        #expect(envelope.nowPlaying.count == 1)
        let game = envelope.nowPlaying[0]
        #expect(game.gameId == "abcdefgh")
        #expect(game.color == .white)
        #expect(game.isMyTurn)
        #expect(game.opponent.username == "Magnus")
        #expect(game.opponent.title == "GM")
        #expect(game.variant.key == "standard")
    }

    // MARK: - Event stream

    @Test
    func decodesGameStartEvent() throws {
        let json = """
        {
          "type": "gameStart",
          "game": {
            "gameId": "abcdefgh",
            "fullId": "abcdefgh1234",
            "color": "black",
            "fen": "startpos",
            "lastMove": "",
            "source": "friend",
            "variant": { "key": "standard" },
            "speed": "rapid",
            "perf": "rapid",
            "rated": false,
            "hasMoved": false,
            "opponent": { "id": "magnus", "username": "Magnus", "rating": 2830 },
            "isMyTurn": false
          }
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessEvent.self, from: json)
        guard case let .gameStart(info) = event else {
            Issue.record("Expected .gameStart, got \(event)"); return
        }
        #expect(info.gameId == "abcdefgh")
        #expect(info.color == .black)
        #expect(info.opponent.username == "Magnus")
    }

    @Test
    func decodesGameFinishEventWithRatingDiff() throws {
        let json = """
        {
          "type": "gameFinish",
          "game": {
            "gameId": "abcdefgh",
            "fullId": "abcdefgh1234",
            "color": "white",
            "variant": { "key": "standard" },
            "speed": "rapid",
            "perf": "rapid",
            "rated": true,
            "opponent": { "id": "magnus", "username": "Magnus", "rating": 2830 },
            "winner": "white",
            "ratingDiff": 8,
            "status": "mate"
          }
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessEvent.self, from: json)
        guard case let .gameFinish(info) = event else {
            Issue.record("Expected .gameFinish, got \(event)"); return
        }
        #expect(info.ratingDiff == 8)
        #expect(info.winner == .white)
        #expect(info.status == .mate)
    }

    @Test
    func decodesChallengeEvent() throws {
        let json = """
        {
          "type": "challenge",
          "challenge": {
            "id": "ZxYWxYWj",
            "url": "https://lichess.org/ZxYWxYWj",
            "status": "created",
            "challenger": { "id": "magnus", "name": "Magnus", "title": "GM", "rating": 2830, "online": true },
            "destUser": { "id": "thibault", "name": "thibault", "rating": 1500 },
            "variant": { "key": "standard", "name": "Standard" },
            "rated": true,
            "speed": "rapid",
            "timeControl": { "type": "clock", "limit": 600, "increment": 0, "show": "10+0" },
            "color": "random",
            "perf": { "icon": "#", "name": "Rapid" }
          }
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessEvent.self, from: json)
        guard case let .challenge(challenge) = event else {
            Issue.record("Expected .challenge, got \(event)"); return
        }
        #expect(challenge.id == "ZxYWxYWj")
        #expect(challenge.challenger?.name == "Magnus")
        #expect(challenge.timeControl.limit == 600)
        #expect(challenge.timeControl.show == "10+0")
        #expect(challenge.rated)
    }

    @Test
    func decodesUnknownEventGracefully() throws {
        // Future event types must not crash the parser — we want forward
        // compatibility so a Lichess feature rollout doesn't break online
        // play across our installed base.
        let json = """
        { "type": "future_event_we_dont_know_about", "payload": { "x": 1 } }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessEvent.self, from: json)
        guard case let .unknown(type) = event else {
            Issue.record("Expected .unknown, got \(event)"); return
        }
        #expect(type == "future_event_we_dont_know_about")
    }

    // MARK: - Game stream

    @Test
    func decodesGameFullThenGameState() throws {
        let fullJSON = """
        {
          "type": "gameFull",
          "id": "abcdefgh",
          "variant": { "key": "standard", "name": "Standard", "short": "Std" },
          "clock": { "initial": 600000, "increment": 0 },
          "speed": "rapid",
          "perf": { "name": "Rapid" },
          "rated": true,
          "createdAt": 1700000000000,
          "white": { "id": "thibault", "name": "thibault", "rating": 1500 },
          "black": { "id": "magnus", "name": "Magnus", "title": "GM", "rating": 2830 },
          "initialFen": "startpos",
          "state": {
            "type": "gameState",
            "moves": "e2e4 e7e5",
            "wtime": 595000,
            "btime": 590000,
            "winc": 0,
            "binc": 0,
            "status": "started"
          }
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessGameStreamEvent.self, from: fullJSON)
        guard case let .gameFull(full) = event else {
            Issue.record("Expected .gameFull, got \(event)"); return
        }
        #expect(full.id == "abcdefgh")
        #expect(full.clock?.initial == 600000)
        #expect(full.white.name == "thibault")
        #expect(full.black.title == "GM")
        #expect(full.state.moves == "e2e4 e7e5")
        #expect(full.state.status == .started)
        #expect(full.initialFen == "startpos")

        let stateJSON = """
        {
          "type": "gameState",
          "moves": "e2e4 e7e5 g1f3 b8c6",
          "wtime": 593000,
          "btime": 588000,
          "winc": 0,
          "binc": 0,
          "status": "started",
          "wdraw": false,
          "bdraw": true
        }
        """.data(using: .utf8)!

        let stateEvent = try decoder.decode(LichessGameStreamEvent.self, from: stateJSON)
        guard case let .gameState(state) = stateEvent else {
            Issue.record("Expected .gameState"); return
        }
        #expect(state.moves.split(separator: " ").count == 4)
        #expect(state.bdraw == true)
        #expect(state.wdraw == false)
    }

    @Test
    func decodesGameOverState() throws {
        let json = """
        {
          "type": "gameState",
          "moves": "e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7",
          "wtime": 540000,
          "btime": 580000,
          "winc": 0,
          "binc": 0,
          "status": "mate",
          "winner": "white"
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessGameStreamEvent.self, from: json)
        guard case let .gameState(state) = event else {
            Issue.record("Expected .gameState"); return
        }
        #expect(state.status == .mate)
        #expect(state.status.isFinished)
        #expect(state.winner == .white)
    }

    @Test
    func decodesOpponentGoneEvent() throws {
        let json = """
        { "type": "opponentGone", "gone": true, "claimWinInSeconds": 30 }
        """.data(using: .utf8)!

        let event = try decoder.decode(LichessGameStreamEvent.self, from: json)
        guard case let .opponentGone(gone) = event else {
            Issue.record("Expected .opponentGone"); return
        }
        #expect(gone.gone)
        #expect(gone.claimWinInSeconds == 30)
    }

    // MARK: - AI created game

    @Test
    func decodesAICreatedGame() throws {
        let json = """
        {
          "id": "abcdefgh",
          "rated": false,
          "variant": { "key": "standard", "name": "Standard" },
          "speed": "rapid",
          "perf": "rapid",
          "createdAt": 1700000000000,
          "fullId": "abcdefgh1234",
          "player": "white",
          "status": "started",
          "fen": "startpos",
          "turns": 0,
          "source": "ai"
        }
        """.data(using: .utf8)!

        let game = try decoder.decode(LichessAICreatedGame.self, from: json)
        #expect(game.id == "abcdefgh")
        #expect(!game.rated)
        #expect(game.player == "white")
        #expect(game.variant.key == "standard")
    }

    // MARK: - Time control bucketing

    @Test
    func timeControlBucketsMatchLichessSpeeds() {
        // Bullet boundary: total < 180s
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 60, incrementSeconds: 0).speed == .bullet)
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 120, incrementSeconds: 1).speed == .bullet)
        // Blitz: 180–479s
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 180, incrementSeconds: 0).speed == .blitz)
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 300, incrementSeconds: 3).speed == .blitz)
        // Rapid: 480–1499s
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 600, incrementSeconds: 0).speed == .rapid)
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 600, incrementSeconds: 5).speed == .rapid)
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 900, incrementSeconds: 10).speed == .rapid)
        // Classical: ≥1500s
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 1800, incrementSeconds: 0).speed == .classical)
        #expect(LichessTimeControlSpec.realTime(limitSeconds: 1800, incrementSeconds: 20).speed == .classical)
        // Correspondence
        #expect(LichessTimeControlSpec.correspondence(daysPerTurn: 3).speed == .correspondence)
        #expect(LichessTimeControlSpec.unlimited.speed == .correspondence)
    }
}

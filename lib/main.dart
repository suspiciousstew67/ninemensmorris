import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data' as typed_data;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_client.dart';
import 'extreme_ai.dart' as extreme_ai;
import 'tablebase_loader.dart';
import 'extreme_simple_wrapper.dart';
import 'hybrid_ai.dart'; // MCTS + Tablebase hybrid AI
import 'mcts_ai.dart'; // MCTS configuration

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load endgame tablebase for perfect play
  await tablebaseLoader.load();
  
  // Initialize Zobrist hashing for AI
  extreme_ai.initZobrist();
  
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));
  runApp(const MorrisApp());
}

class MorrisApp extends StatefulWidget {
  const MorrisApp({super.key});

  @override
  State<MorrisApp> createState() => _MorrisAppState();
}

class _MorrisAppState extends State<MorrisApp> {
  bool darkMode = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Nine Men's Morris",
      debugShowCheckedModeBanner: false,
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xfff3f3f3),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff0e0e0e),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, brightness: Brightness.dark),
      ),
      home: MorrisHome(
        darkMode: darkMode,
        onThemeChanged: (value) => setState(() => darkMode = value),
      ),
    );
  }
}

enum GamePhase { placing, moving, flying, gameOver }
enum GameMode { classic, simple }
enum GameType { ai, human, network }
enum Difficulty { easy, medium, hard, extreme }
enum NetworkRole { none, host, client }

// Configuration: Enable MCTS + Tablebase Hybrid AI
// Set to true to use Monte Carlo Tree Search with Retrograde Analysis
const bool USE_MCTS_AI = true; // Change to true to enable MCTS mode

Future<T> _runCompute<T>(FutureOr<T> Function() action) async {
  // Isolates are unavailable on web; run on main isolate there to avoid runtime errors.
  if (kIsWeb) return await action();
  return Isolate.run<T>(action);
}

extension DifficultyLabel on Difficulty {
  String get label => switch (this) { Difficulty.easy => 'Easy', Difficulty.medium => 'Medium', Difficulty.hard => 'Hard', Difficulty.extreme => 'Extreme' };
  int get searchDepth => switch (this) { Difficulty.easy => 2, Difficulty.medium => 3, Difficulty.hard => 4, Difficulty.extreme => 10 };
  int get nodeLimit {
    final limit = switch (this) { Difficulty.easy => 8000, Difficulty.medium => 20000, Difficulty.hard => 60000, Difficulty.extreme => 4000000 };
    return kIsWeb ? (limit * 0.6).round() : limit;
  }
  int get timeLimitMs {
    final limit = switch (this) { Difficulty.easy => 600, Difficulty.medium => 900, Difficulty.hard => 1300, Difficulty.extreme => 9000 };
    return kIsWeb ? (limit * 0.6).round() : limit;
  }
}

extension GameModeLabel on GameMode {
  String get label => this == GameMode.classic ? 'Classic' : 'Simple';
}

extension GameTypeLabel on GameType {
  String get label => switch (this) { GameType.ai => 'vs AI', GameType.human => 'Pass & Play', GameType.network => 'Network' };
}

class Move {
  final int? from;
  final int? to;
  final int? remove;

  const Move({required this.from, required this.to, this.remove});
}

class MoveResult {
  final bool formedMill;
  final int? gameOverWinner;

  MoveResult({required this.formedMill, this.gameOverWinner});
}

class GameEngine {
  final GameMode mode;
  final List<List<int>> mills = const [
    [0, 1, 2],
    [2, 3, 4],
    [4, 5, 6],
    [6, 7, 0],
    [8, 9, 10],
    [10, 11, 12],
    [12, 13, 14],
    [14, 15, 8],
    [16, 17, 18],
    [18, 19, 20],
    [20, 21, 22],
    [22, 23, 16],
    [1, 9, 17],
    [3, 11, 19],
    [5, 13, 21],
    [7, 15, 23],
  ];

  final Map<int, List<int>> adjacencyMap = const {
    0: [1, 7],
    1: [0, 2, 9],
    2: [1, 3],
    3: [2, 4, 11],
    4: [3, 5],
    5: [4, 6, 13],
    6: [5, 7],
    7: [0, 6, 15],
    8: [9, 15],
    9: [1, 8, 10, 17],
    10: [9, 11],
    11: [3, 10, 12, 19],
    12: [11, 13],
    13: [5, 12, 14, 21],
    14: [13, 15],
    15: [7, 8, 14, 23],
    16: [17, 23],
    17: [9, 16, 18],
    18: [17, 19],
    19: [11, 18, 20],
    20: [19, 21],
    21: [13, 20, 22],
    22: [21, 23],
    23: [15, 16, 22],
  };

  late typed_data.Uint8List board; // 0 empty, 1 / 2 for players
  late typed_data.Uint8List piecesLeft;
  late typed_data.Uint8List piecesOnBoard;
  GamePhase phase = GamePhase.placing;

  final List<Offset> positions = const [
    Offset(0.05, 0.05),
    Offset(0.50, 0.05),
    Offset(0.95, 0.05),
    Offset(0.95, 0.50),
    Offset(0.95, 0.95),
    Offset(0.50, 0.95),
    Offset(0.05, 0.95),
    Offset(0.05, 0.50),
    Offset(0.20, 0.20),
    Offset(0.50, 0.20),
    Offset(0.80, 0.20),
    Offset(0.80, 0.50),
    Offset(0.80, 0.80),
    Offset(0.50, 0.80),
    Offset(0.20, 0.80),
    Offset(0.20, 0.50),
    Offset(0.30, 0.30),
    Offset(0.50, 0.30),
    Offset(0.70, 0.30),
    Offset(0.70, 0.50),
    Offset(0.70, 0.70),
    Offset(0.50, 0.70),
    Offset(0.30, 0.70),
    Offset(0.30, 0.50),
  ];

  GameEngine({required this.mode}) {
    board = typed_data.Uint8List(24);
    piecesLeft = typed_data.Uint8List.fromList(const [0, 9, 9]);
    piecesOnBoard = typed_data.Uint8List(3);
  }

  GameEngine clone() {
    final clone = GameEngine(mode: mode);
    clone.board = typed_data.Uint8List.fromList(board);
    clone.piecesLeft = typed_data.Uint8List.fromList(piecesLeft);
    clone.piecesOnBoard = typed_data.Uint8List.fromList(piecesOnBoard);
    clone.phase = phase;
    return clone;
  }

  int opponent(int player) => player == 1 ? 2 : 1;

  bool canFly(int player) {
    if (mode == GameMode.simple) return false;
    return piecesOnBoard[player] <= 3 && piecesLeft[player] == 0;
  }

  bool isPositionInMill(int pos, int player, [List<int>? state]) {
    final s = state ?? board;
    return mills.any((m) => m.contains(pos) && m.every((p) => s[p] == player));
  }

  bool isRemovable(int pos, int player, [List<int>? state]) {
    final s = state ?? board;
    if (s[pos] != player) return false;
    if (!isPositionInMill(pos, player, s)) return true;
    return !s.asMap().entries.any((e) => e.value == player && !isPositionInMill(e.key, player, s));
  }

  int? firstRemovable(int opponent) {
    for (int i = 0; i < board.length; i++) {
      if (isRemovable(i, opponent)) return i;
    }
    return null;
  }

  MoveResult applyMove(Move move, int player) {
    if (phase == GamePhase.placing) {
      if (piecesLeft[player] == 0) {
        return MoveResult(formedMill: false, gameOverWinner: null);
      }
      board[move.to!] = player;
      if (piecesLeft[player] > 0) {
        piecesLeft[player] -= 1;
      }
      piecesOnBoard[player] += 1;
    } else {
      board[move.from!] = 0;
      board[move.to!] = player;
    }

    final formedMill = isPositionInMill(move.to!, player, board);
    _updatePhase();

    final winner = checkWinner();
    return MoveResult(formedMill: formedMill, gameOverWinner: winner);
  }

  void removePiece(int pos, int player) {
    if (board[pos] == player) {
      board[pos] = 0;
      piecesOnBoard[player] -= 1;
      _updatePhase();
    }
  }

  void _updatePhase() {
    if (mode == GameMode.simple) {
      phase = GamePhase.placing;
      return;
    }
    if (piecesLeft[1] == 0 && piecesLeft[2] == 0) {
      phase = GamePhase.moving;
      if (canFly(1) || canFly(2)) {
        phase = GamePhase.flying;
      }
    } else {
      phase = GamePhase.placing;
    }
  }

  int? checkWinner() {
    if (mode == GameMode.simple) {
      for (final m in mills) {
        final first = board[m[0]];
        if (first != 0 && m.every((p) => board[p] == first)) {
          return first;
        }
      }
      return null;
    }
    for (final player in [1, 2]) {
      final opp = opponent(player);
      if (piecesLeft[opp] == 0 && piecesOnBoard[opp] < 3) return player;
      if (piecesLeft[opp] == 0 && _legalMovesFor(opp).isEmpty) return player;
    }
    return null;
  }

  List<Move> legalMoves(int player) => _legalMovesFor(player);

  List<Move> _legalMovesFor(int player) {
    final moves = <Move>[];
    if (phase == GamePhase.placing) {
      for (int i = 0; i < board.length; i++) {
        if (board[i] == 0) moves.add(Move(from: null, to: i));
      }
      return moves;
    }
    final fly = canFly(player);
    for (int from = 0; from < board.length; from++) {
      if (board[from] != player) continue;
      final targets = fly ? List<int>.generate(board.length, (i) => i) : adjacencyMap[from]!;
      for (final to in targets) {
        if (board[to] != 0) continue;
        moves.add(Move(from: from, to: to));
      }
    }
    return moves;
  }
}

// ignore: unused_element
class _LegacyMinimaxAI {
  _LegacyMinimaxAI({this.difficulty = Difficulty.hard});
  Difficulty difficulty;
  static const int _ttCapacity = 200000;
  static const int _bitTTCapacity = 400000;
  final LinkedHashMap<int, _TTEntry> _tt = LinkedHashMap();
  final LinkedHashMap<int, _BitTTEntry> _bitTT = LinkedHashMap();
  final Map<int, int> _history = {};
  final Map<int, List<int>> _killers = {};

  Future<Move?> chooseMove(GameEngine engine, {required int player}) async {
    if (difficulty == Difficulty.extreme) {
      final snapshot = _EngineSnapshot.fromEngine(engine);
      _history.clear();
      _killers.clear();
      // Run heavy search off the UI thread
      return await _runCompute<Move?>(() {
        final eng = snapshot.toEngine();
        final ai = _LegacyMinimaxAI(difficulty: difficulty);
        return ai._computeExtremeBitboard(eng, player);
      });
    }

    final clone = engine.clone();
    _tt.clear();
    final best = _iterativeDeepening(clone, player: player, timeLimitMs: difficulty.timeLimitMs, maxNodes: difficulty.nodeLimit);
    if (best.move != null) return best.move;
    final fallback = clone.legalMoves(player).firstOrNull;
    if (fallback != null) return fallback;
    return null;
  }

  _EvalResult _iterativeDeepening(GameEngine engine, {required int player, required int timeLimitMs, required int maxNodes}) {
    final start = DateTime.now();
    _EvalResult best = _EvalResult(score: -1e9, move: null);
    int nodes = 0;
    for (int depth = 1; depth <= difficulty.searchDepth; depth++) {
      final timeUp = DateTime.now().difference(start).inMilliseconds >= timeLimitMs;
      if (timeUp || nodes >= maxNodes) break;
      final result = _minimax(engine.clone(), depth: depth, maximizing: true, player: player, alpha: -1e9, beta: 1e9, nodes: nodes, maxNodes: maxNodes, deadline: start.add(Duration(milliseconds: timeLimitMs)));
      nodes = result.nodesVisited;
      if (result.move != null) best = result;
      if (DateTime.now().isAfter(start.add(Duration(milliseconds: timeLimitMs))) || nodes >= maxNodes) break;
    }
    return best;
  }

  Move? _computeExtremeBitboard(GameEngine engine, int player) {
    final helper = BitboardMorris();
    final bitState = helper.fromEngine(engine);
    _bitTT.clear();
    final result = _bitIterativeDeepening(helper, bitState, player, timeLimitMs: difficulty.timeLimitMs, maxNodes: difficulty.nodeLimit, maxDepth: difficulty.searchDepth);
    return result.move;
  }

  _EvalResult _bitIterativeDeepening(BitboardMorris helper, BitState state, int player, {required int timeLimitMs, required int maxNodes, required int maxDepth}) {
    final start = DateTime.now();
    _EvalResult best = _EvalResult(score: -1e9, move: null);
    int nodes = 0;
    for (int depth = 1; depth <= maxDepth; depth++) {
      if (DateTime.now().difference(start).inMilliseconds >= timeLimitMs || nodes >= maxNodes) break;
      final res = _bitMinimax(helper, state, depth: depth, maximizing: true, player: player, alpha: -1e9, beta: 1e9, nodes: nodes, maxNodes: maxNodes, deadline: start.add(Duration(milliseconds: timeLimitMs)));
      nodes = res.nodesVisited;
      if (res.move != null) best = res;
    }
    return best;
  }

  _EvalResult _bitMinimax(
    BitboardMorris helper,
    BitState state, {
    required int depth,
    required bool maximizing,
    required int player,
    required int nodes,
    required int maxNodes,
    required DateTime deadline,
    double alpha = -1e9,
    double beta = 1e9,
    bool inQuiescence = false,
  }) {
    final mover = maximizing ? player : helper.opponent(player);
    final hash = _bitHash(state, mover: mover, rootPlayer: player, maximizing: maximizing);
    final cached = _bitTT[hash];
    if (cached != null && cached.depth >= depth) {
      return _EvalResult(score: cached.score, move: cached.bestMove, nodesVisited: nodes);
    }

    if (DateTime.now().isAfter(deadline) || nodes >= maxNodes) {
      return _EvalResult(score: helper.evaluate(state, player), move: null, nodesVisited: nodes);
    }
    nodes++;

    final winner = helper.checkWinner(state);
    if (winner != null) {
      final score = winner == player ? 100000.0 : -100000.0;
      _cacheBitEntry(hash, _BitTTEntry(depth: depth, score: score, bestMove: null));
      return _EvalResult(score: score, nodesVisited: nodes);
    }
    if (depth == 0) {
      final score = helper.evaluate(state, player);
      _cacheBitEntry(hash, _BitTTEntry(depth: depth, score: score, bestMove: null));
      return _EvalResult(score: score, nodesVisited: nodes);
    }

    final moves = helper.legalMoves(state, mover);
    if (moves.isEmpty) {
      final score = maximizing ? -100000.0 : 100000.0;
      _cacheBitEntry(hash, _BitTTEntry(depth: depth, score: score, bestMove: null));
      return _EvalResult(score: score, nodesVisited: nodes);
    }
    moves.sort((a, b) => _bitMoveOrderScore(helper, state, b, mover, depth).compareTo(_bitMoveOrderScore(helper, state, a, mover, depth)));

    Move? bestMove;
    if (maximizing) {
      double bestScore = -1e9;
      for (final m in moves) {
        final next = helper.applyMove(state, m, player);
        final branches = helper.resolveMillRemovals(next, m, player);
        double aggregated = -1e9;
        for (final branch in branches) {
          var nextDepth = max(0, depth - 1);
          final scoreRes = _bitMinimax(helper, branch, depth: nextDepth, maximizing: false, player: player, alpha: alpha, beta: beta, nodes: nodes, maxNodes: maxNodes, deadline: deadline, inQuiescence: inQuiescence);
          nodes = scoreRes.nodesVisited;
          aggregated = max(aggregated, scoreRes.score);
          if (aggregated >= beta || nodes >= maxNodes) break;
        }
        if (aggregated > bestScore) {
          bestScore = aggregated;
          bestMove = m;
        }
        if (bestMove != null) {
          final key = _bitMoveKey(bestMove, mover);
          _history[key] = (_history[key] ?? 0) + depth * depth;
        }
        alpha = max(alpha, bestScore);
        if (beta <= alpha || nodes >= maxNodes) {
          if (bestMove != null) {
            _recordKiller(depth, _bitMoveKey(bestMove, mover));
          }
          break;
        }
      }
      _cacheBitEntry(hash, _BitTTEntry(depth: depth, score: bestScore, bestMove: bestMove));
      return _EvalResult(score: bestScore, move: bestMove, nodesVisited: nodes);
    } else {
      final opp = helper.opponent(player);
      double bestScore = 1e9;
      for (final m in moves) {
        final next = helper.applyMove(state, m, opp);
        final branches = helper.resolveMillRemovals(next, m, opp);
        double aggregated = 1e9;
        for (final branch in branches) {
          var nextDepth = max(0, depth - 1);
          final scoreRes = _bitMinimax(helper, branch, depth: nextDepth, maximizing: true, player: player, alpha: alpha, beta: beta, nodes: nodes, maxNodes: maxNodes, deadline: deadline, inQuiescence: inQuiescence);
          nodes = scoreRes.nodesVisited;
          aggregated = min(aggregated, scoreRes.score);
          if (aggregated <= alpha || nodes >= maxNodes) break;
        }
        if (aggregated < bestScore) {
          bestScore = aggregated;
          bestMove = m;
        }
        beta = min(beta, bestScore);
        if (beta <= alpha || nodes >= maxNodes) {
          if (bestMove != null) {
            _recordKiller(depth, _bitMoveKey(bestMove, opp));
          }
          break;
        }
      }
      _cacheBitEntry(hash, _BitTTEntry(depth: depth, score: bestScore, bestMove: bestMove));
      return _EvalResult(score: bestScore, move: bestMove, nodesVisited: nodes);
    }
  }

  _EvalResult _minimax(
    GameEngine engine, {
    required int depth,
    required bool maximizing,
    required int player,
    required int nodes,
    required int maxNodes,
    required DateTime deadline,
    double alpha = -1e9,
    double beta = 1e9,
  }) {
    final hash = _hash(engine);
    final cached = _tt[hash];
    if (cached != null && cached.depth >= depth) {
      return _EvalResult(score: cached.score, move: cached.bestMove, nodesVisited: nodes);
    }

    if (DateTime.now().isAfter(deadline) || nodes >= maxNodes) {
      final eval = _evaluate(engine, player);
      return _EvalResult(score: eval, move: null, nodesVisited: nodes);
    }
    nodes++;
    final winner = engine.checkWinner();
    if (winner != null) {
      return _EvalResult(score: winner == player ? 100000.0 : -100000.0, nodesVisited: nodes);
    }
    if (depth == 0) {
      return _EvalResult(score: _evaluate(engine, player), nodesVisited: nodes);
    }

    final moves = engine.legalMoves(maximizing ? player : engine.opponent(player));
    if (moves.isEmpty) {
      return _EvalResult(score: maximizing ? -100000.0 : 100000.0, nodesVisited: nodes);
    }

    moves.sort((a, b) => _moveHeuristic(engine, a, maximizing ? player : engine.opponent(player)).compareTo(_moveHeuristic(engine, b, maximizing ? player : engine.opponent(player))) * -1);

    Move? bestMove;
    if (maximizing) {
      double bestScore = -1e9;
      for (final m in moves) {
        final next = engine.clone();
        final res = next.applyMove(m, player);
        if (res.formedMill) {
          final removable = next.firstRemovable(next.opponent(player));
          if (removable != null) {
            next.removePiece(removable, next.opponent(player));
          }
        }
        final sub = _minimax(next, depth: depth - 1, maximizing: false, player: player, alpha: alpha, beta: beta, nodes: nodes, maxNodes: maxNodes, deadline: deadline);
        nodes = sub.nodesVisited;
        final score = sub.score;
        if (score > bestScore) {
          bestScore = score;
          bestMove = m;
        }
        alpha = max(alpha, score);
        if (beta <= alpha) break;
      }
      _cacheEntry(hash, _TTEntry(depth: depth, score: bestScore, bestMove: bestMove));
      return _EvalResult(score: bestScore, move: bestMove, nodesVisited: nodes);
    } else {
      final opp = engine.opponent(player);
      double bestScore = 1e9;
      for (final m in moves) {
        final next = engine.clone();
        final res = next.applyMove(m, opp);
        if (res.formedMill) {
          final removable = next.firstRemovable(next.opponent(opp));
          if (removable != null) next.removePiece(removable, next.opponent(opp));
        }
        final sub = _minimax(next, depth: depth - 1, maximizing: true, player: player, alpha: alpha, beta: beta, nodes: nodes, maxNodes: maxNodes, deadline: deadline);
        nodes = sub.nodesVisited;
        final score = sub.score;
        if (score < bestScore) {
          bestScore = score;
          bestMove = m;
        }
        beta = min(beta, score);
        if (beta <= alpha) break;
      }
      _cacheEntry(hash, _TTEntry(depth: depth, score: bestScore, bestMove: bestMove));
      return _EvalResult(score: bestScore, move: bestMove, nodesVisited: nodes);
    }
  }

  double _evaluate(GameEngine engine, int player) {
    final opp = engine.opponent(player);
    double score = 0;
    final pieceDiff = (engine.piecesOnBoard[player] + engine.piecesLeft[player]) - (engine.piecesOnBoard[opp] + engine.piecesLeft[opp]);
    score += pieceDiff * 550;

    int millsPlayer = 0, millsOpp = 0;
    for (final m in engine.mills) {
      if (m.every((p) => engine.board[p] == player)) millsPlayer++;
      if (m.every((p) => engine.board[p] == opp)) millsOpp++;
    }
    score += (millsPlayer - millsOpp) * 2200;

    // potential mills
    int potentialPlayer = 0, potentialOpp = 0;
    for (final m in engine.mills) {
      final playerCount = m.where((p) => engine.board[p] == player).length;
      final oppCount = m.where((p) => engine.board[p] == opp).length;
      if (oppCount == 0 && playerCount == 2) potentialPlayer++;
      if (playerCount == 0 && oppCount == 2) potentialOpp++;
    }
    score += (potentialPlayer - potentialOpp) * 350;

    final mobility = engine.legalMoves(player).length - engine.legalMoves(opp).length;
    score += mobility * 60;

    // penalty if opponent close to flying advantage
    if (engine.piecesOnBoard[opp] == 3 && engine.piecesLeft[opp] == 0) score -= 400;
    if (engine.piecesOnBoard[player] == 3 && engine.piecesLeft[player] == 0) score += 400;

    return score;
  }

  double _moveHeuristic(GameEngine engine, Move move, int player) {
    double score = 0;
    if (move.to != null) {
      final formsMill = engine.isPositionInMill(move.to!, player);
      if (formsMill) score += 2000;
      if (move.from == null) score += 200; // placing new piece
    }
    return score;
  }

  void _cacheEntry(int hash, _TTEntry entry) {
    _tt[hash] = entry;
    if (_tt.length > _ttCapacity) {
      _tt.remove(_tt.keys.first);
    }
  }

  void _cacheBitEntry(int hash, _BitTTEntry entry) {
    _bitTT[hash] = entry;
    if (_bitTT.length > _bitTTCapacity) {
      _bitTT.remove(_bitTT.keys.first);
    }
  }

  double _bitMoveOrderScore(BitboardMorris helper, BitState state, Move move, int mover, int depth) {
    final base = helper.moveHeuristic(state, move, mover);
    final key = _bitMoveKey(move, mover);
    final hist = _history[key] ?? 0;
    final killers = _killers[depth];
    final killerBonus = killers != null && killers.contains(key) ? 8000 : 0;
    return base + hist * 0.1 + killerBonus;
  }

  int _bitMoveKey(Move move, int mover) {
    final from = (move.from ?? 31) & 0x1f;
    final to = (move.to ?? 0) & 0x1f;
    return (mover << 10) | (from << 5) | to;
  }

  void _recordKiller(int depth, int key) {
    final list = _killers[depth] ?? <int>[];
    if (!list.contains(key)) list.insert(0, key);
    if (list.length > 2) list.length = 2;
    _killers[depth] = list;
  }

  int _hash(GameEngine engine) {
    int maskPlayer1 = 0;
    int maskPlayer2 = 0;
    for (int i = 0; i < engine.board.length; i++) {
      final v = engine.board[i];
      if (v == 1) {
        maskPlayer1 |= (1 << i);
      } else if (v == 2) {
        maskPlayer2 |= (1 << i);
      }
    }
    int key = engine.mode.index;
    key = (key << 2) | engine.phase.index;
    key = (key << 4) | engine.piecesLeft[1];
    key = (key << 4) | engine.piecesLeft[2];
    key = (key << 4) | engine.piecesOnBoard[1];
    key = (key << 4) | engine.piecesOnBoard[2];
    key = (key << 24) | maskPlayer1;
    key = (key << 24) | maskPlayer2;
    return key;
  }

  int _bitHash(BitState state, {required int mover, required int rootPlayer, required bool maximizing}) {
    int h = 17;
    h = (37 * h) ^ state.p1;
    h = (37 * h) ^ state.p2;
    h = (37 * h) ^ state.piecesLeft1;
    h = (37 * h) ^ state.piecesLeft2;
    h = (37 * h) ^ state.phase.index;
    h = (37 * h) ^ mover;
    h = (37 * h) ^ rootPlayer;
    h = (37 * h) ^ (maximizing ? 1 : 0);
    return h & 0x7fffffff;
  }
}

class _EvalResult {
  final double score;
  final Move? move;
  final int nodesVisited;
  _EvalResult({required this.score, this.move, this.nodesVisited = 0});
}

class _TTEntry {
  final int depth;
  final double score;
  final Move? bestMove;
  _TTEntry({required this.depth, required this.score, this.bestMove});
}

class _BitTTEntry {
  final int depth;
  final double score;
  final Move? bestMove;
  _BitTTEntry({required this.depth, required this.score, this.bestMove});
}

class _EngineSnapshot {
  final List<int> board;
  final List<int> piecesLeft;
  final List<int> piecesOnBoard;
  final int phase;
  final int mode;
  _EngineSnapshot({
    required this.board,
    required this.piecesLeft,
    required this.piecesOnBoard,
    required this.phase,
    required this.mode,
  });

  factory _EngineSnapshot.fromEngine(GameEngine engine) => _EngineSnapshot(
        board: List<int>.from(engine.board),
        piecesLeft: List<int>.from(engine.piecesLeft),
        piecesOnBoard: List<int>.from(engine.piecesOnBoard),
        phase: engine.phase.index,
        mode: engine.mode.index,
      );

  GameEngine toEngine() {
    final eng = GameEngine(mode: GameMode.values[mode]);
    eng.board = typed_data.Uint8List.fromList(board);
    eng.piecesLeft = typed_data.Uint8List.fromList(piecesLeft);
    eng.piecesOnBoard = typed_data.Uint8List.fromList(piecesOnBoard);
    eng.phase = GamePhase.values[phase];
    return eng;
  }
}

class BitState {
  int p1; // bitboard
  int p2; // bitboard
  int piecesLeft1;
  int piecesLeft2;
  GamePhase phase;
  BitState({required this.p1, required this.p2, required this.piecesLeft1, required this.piecesLeft2, required this.phase});

  BitState clone() => BitState(p1: p1, p2: p2, piecesLeft1: piecesLeft1, piecesLeft2: piecesLeft2, phase: phase);
}

class BitboardMorris {
  static const List<List<int>> mills = [
    [0, 1, 2],
    [2, 3, 4],
    [4, 5, 6],
    [6, 7, 0],
    [8, 9, 10],
    [10, 11, 12],
    [12, 13, 14],
    [14, 15, 8],
    [16, 17, 18],
    [18, 19, 20],
    [20, 21, 22],
    [22, 23, 16],
    [1, 9, 17],
    [3, 11, 19],
    [5, 13, 21],
    [7, 15, 23],
  ];

  static const Map<int, List<int>> adjacencyMap = {
    0: [1, 7],
    1: [0, 2, 9],
    2: [1, 3],
    3: [2, 4, 11],
    4: [3, 5],
    5: [4, 6, 13],
    6: [5, 7],
    7: [0, 6, 15],
    8: [9, 15],
    9: [1, 8, 10, 17],
    10: [9, 11],
    11: [3, 10, 12, 19],
    12: [11, 13],
    13: [5, 12, 14, 21],
    14: [13, 15],
    15: [7, 8, 14, 23],
    16: [17, 23],
    17: [9, 16, 18],
    18: [17, 19],
    19: [11, 18, 20],
    20: [19, 21],
    21: [13, 20, 22],
    22: [21, 23],
    23: [15, 16, 22],
  };
  static const int _midMask = ((1 << 8) - 1) << 8;
  static const int _innerMask = ((1 << 8) - 1) << 16;

  int opponent(int player) => player == 1 ? 2 : 1;

  BitState fromEngine(GameEngine engine) {
    int p1 = 0, p2 = 0;
    for (int i = 0; i < engine.board.length; i++) {
      if (engine.board[i] == 1) p1 |= (1 << i);
      if (engine.board[i] == 2) p2 |= (1 << i);
    }
    return BitState(
      p1: p1,
      p2: p2,
      piecesLeft1: engine.piecesLeft[1],
      piecesLeft2: engine.piecesLeft[2],
      phase: engine.phase,
    );
  }

  bool _isInMill(int pos, int bb) => mills.any((m) => m.contains(pos) && m.every((p) => (bb & (1 << p)) != 0));
  bool isInMill(BitState s, int pos, int player) => _isInMill(pos, player == 1 ? s.p1 : s.p2);

  bool _canFly(BitState s, int player) {
    final piecesLeft = player == 1 ? s.piecesLeft1 : s.piecesLeft2;
    final onBoard = _countBits(player == 1 ? s.p1 : s.p2);
    return piecesLeft == 0 && onBoard <= 3;
  }

  BitState applyMove(BitState state, Move move, int player) {
    final s = state.clone();
    int bb = player == 1 ? s.p1 : s.p2;
    if (s.phase == GamePhase.placing) {
      bb |= (1 << move.to!);
      if (player == 1) {
        s.piecesLeft1--;
      } else {
        s.piecesLeft2--;
      }
    } else {
      bb &= ~(1 << move.from!);
      bb |= (1 << move.to!);
    }
    if (player == 1) {
      s.p1 = bb;
    } else {
      s.p2 = bb;
    }
    _refreshPhase(s);
    return s;
  }

  BitState removePiece(BitState state, int player, int position) {
    final s = state.clone();
    if (player == 1) {
      s.p1 &= ~(1 << position);
    } else {
      s.p2 &= ~(1 << position);
    }
    _refreshPhase(s);
    return s;
  }

  void _refreshPhase(BitState s) {
    if (s.piecesLeft1 == 0 && s.piecesLeft2 == 0) {
      s.phase = (_canFly(s, 1) || _canFly(s, 2)) ? GamePhase.flying : GamePhase.moving;
    } else {
      s.phase = GamePhase.placing;
    }
  }

  List<Move> legalMoves(BitState state, int player) {
    final moves = <Move>[];
    final bb = player == 1 ? state.p1 : state.p2;
    final opp = player == 1 ? state.p2 : state.p1;
    final emptyMask = ~ (bb | opp) & ((1 << 24) - 1);
    if (state.phase == GamePhase.placing) {
      for (int i = 0; i < 24; i++) {
        if ((emptyMask & (1 << i)) != 0) moves.add(Move(from: null, to: i));
      }
      return moves;
    }
    final fly = _canFly(state, player);
    for (int from = 0; from < 24; from++) {
      if ((bb & (1 << from)) == 0) continue;
      final targets = fly ? List<int>.generate(24, (i) => i) : adjacencyMap[from]!;
      for (final to in targets) {
        if ((emptyMask & (1 << to)) == 0) continue;
        moves.add(Move(from: from, to: to));
      }
    }
    return moves;
  }

  List<int> removablePositions(BitState state, int player) {
    final bb = player == 1 ? state.p1 : state.p2;
    if (bb == 0) return const [];
    final positions = <int>[];
    bool hasNonMill = false;
    for (int i = 0; i < 24; i++) {
      if ((bb & (1 << i)) == 0) continue;
      if (!_isInMill(i, bb)) {
        hasNonMill = true;
        positions.add(i);
      }
    }
    if (hasNonMill) return positions;
    for (int i = 0; i < 24; i++) {
      if ((bb & (1 << i)) != 0) positions.add(i);
    }
    return positions;
  }

  List<BitState> resolveMillRemovals(BitState state, Move move, int mover) {
    if (move.to == null) return [state];
    final moverBB = mover == 1 ? state.p1 : state.p2;
    if (!_isInMill(move.to!, moverBB)) return [state];
    final targetPlayer = opponent(mover);
    final targets = removablePositions(state, targetPlayer);
    if (targets.isEmpty) return [state];
    return targets.map((pos) => removePiece(state, targetPlayer, pos)).toList();
  }

  bool canFormMillNext(BitState state, int player) {
    final bbPlayer = player == 1 ? state.p1 : state.p2;
    final bbOpp = player == 1 ? state.p2 : state.p1;
    for (final m in mills) {
      int pCount = 0;
      int oCount = 0;
      for (final pos in m) {
        if ((bbPlayer & (1 << pos)) != 0) {
          pCount++;
        } else if ((bbOpp & (1 << pos)) != 0) {
          oCount++;
        }
      }
      if (oCount == 0 && pCount == 2) return true;
    }
    return false;
  }

  int? checkWinner(BitState s) {
    if (s.phase == GamePhase.placing) return null;
    for (final player in [1, 2]) {
      final bb = player == 1 ? s.p2 : s.p1; // check opponent
      final left = player == 1 ? s.piecesLeft2 : s.piecesLeft1;
      final pieces = _countBits(bb);
      if (left == 0 && pieces < 3) return player;
      if (left == 0 && legalMoves(s, player == 1 ? 2 : 1).isEmpty) return player;
    }
    return null;
  }

  double evaluate(BitState s, int player) {
    final opp = opponent(player);
    final bbPlayer = player == 1 ? s.p1 : s.p2;
    final bbOpp = player == 1 ? s.p2 : s.p1;
    double score = 0;
    final pieceDiff = (_countBits(bbPlayer) + (player == 1 ? s.piecesLeft1 : s.piecesLeft2)) - (_countBits(bbOpp) + (opp == 1 ? s.piecesLeft1 : s.piecesLeft2));
    score += pieceDiff * 600;

    int millsPlayer = 0, millsOpp = 0, potentialsPlayer = 0, potentialsOpp = 0;
    int singleGapsPlayer = 0, singleGapsOpp = 0;
    final emptyMask = ~ (bbPlayer | bbOpp) & ((1 << 24) - 1);
    for (final m in mills) {
      final pCount = m.where((p) => (bbPlayer & (1 << p)) != 0).length;
      final oCount = m.where((p) => (bbOpp & (1 << p)) != 0).length;
      if (pCount == 3) millsPlayer++;
      if (oCount == 3) millsOpp++;
      if (oCount == 0 && pCount == 2) potentialsPlayer++;
      if (pCount == 0 && oCount == 2) potentialsOpp++;
      if (oCount == 0 && pCount == 1) singleGapsPlayer++;
      if (pCount == 0 && oCount == 1) singleGapsOpp++;
    }
    // Aggressive weighting: heavily reward forming/setting up mills
    score += (millsPlayer - millsOpp) * 4200;
    score += (potentialsPlayer - potentialsOpp) * 1800;
    score += (singleGapsPlayer - singleGapsOpp) * 300;

    final mobility = legalMoves(s, player).length - legalMoves(s, opp).length;
    score += mobility * 120;

    final blockedPlayer = _blockedPieces(s, player, emptyMask);
    final blockedOpp = _blockedPieces(s, opp, emptyMask);
    score += (blockedOpp - blockedPlayer) * 240;

    final centerDiff = _centerControl(s, player) - _centerControl(s, opp);
    score += centerDiff * 60;

    final doubleThreatDiff = _doubleThreatCount(s, player) - _doubleThreatCount(s, opp);
    score += doubleThreatDiff * 2600;

    return score;
  }

  double moveHeuristic(BitState state, Move move, int player) {
    double h = 0;
    final next = applyMove(state, move, player);
    final bb = player == 1 ? next.p1 : next.p2;
    if (_isInMill(move.to!, bb)) h += 6500;
    if (move.from == null) h += 700;
    // prefer moves that land on opponent threats
    if (move.to != null) {
      final opp = opponent(player);
      final oppBB = opp == 1 ? state.p1 : state.p2;
      for (final m in mills) {
        if (m.contains(move.to)) {
          final oppCount = m.where((p) => (oppBB & (1 << p)) != 0).length;
          if (oppCount == 2) h += 1600; // block opponent ready mill
        }
      }
    }
    return h;
  }

  int _countBits(int v) {
    var x = v;
    x = x - ((x >> 1) & 0x55555555);
    x = (x & 0x33333333) + ((x >> 2) & 0x33333333);
    return (((x + (x >> 4)) & 0x0F0F0F0F) * 0x01010101) >> 24;
  }

  int _blockedPieces(BitState state, int player, int emptyMask) {
    if (_canFly(state, player)) return 0;
    final bb = player == 1 ? state.p1 : state.p2;
    int blocked = 0;
    for (int pos = 0; pos < 24; pos++) {
      if ((bb & (1 << pos)) == 0) continue;
      final neighbors = adjacencyMap[pos]!;
      bool hasMove = false;
      for (final n in neighbors) {
        if ((emptyMask & (1 << n)) != 0) {
          hasMove = true;
          break;
        }
      }
      if (!hasMove) blocked++;
    }
    return blocked;
  }

  int _centerControl(BitState state, int player) {
    final bb = player == 1 ? state.p1 : state.p2;
    final mid = _countBits(bb & _midMask);
    final inner = _countBits(bb & _innerMask);
    return mid * 2 + inner * 3;
  }

  int _doubleThreatCount(BitState state, int player) {
    final bbPlayer = player == 1 ? state.p1 : state.p2;
    final bbOpp = player == 1 ? state.p2 : state.p1;
    final counts = List<int>.filled(24, 0);
    for (final m in mills) {
      int playerCount = 0;
      int oppCount = 0;
      int emptySpot = -1;
      for (final pos in m) {
        if ((bbPlayer & (1 << pos)) != 0) {
          playerCount++;
        } else if ((bbOpp & (1 << pos)) != 0) {
          oppCount++;
        } else {
          emptySpot = pos;
        }
      }
      if (oppCount == 0 && playerCount == 2 && emptySpot != -1) {
        counts[emptySpot]++;
      }
    }
    return counts.where((c) => c > 1).length;
  }
}

// New production AI wrapper that delegates to extreme_ai.dart.
class MinimaxAI {
  final Difficulty difficulty;
  final bool useMCTS;
  final Function(String)? onStatusUpdate; // Callback for status updates
  static bool _zobristReady = false;
  
  MinimaxAI({
    required this.difficulty, 
    this.useMCTS = false,
    this.onStatusUpdate,
  }) {
    if (!_zobristReady) {
      extreme_ai.initZobrist();
      _zobristReady = true;
    }
  }

  Future<Move?> chooseMove(GameEngine engine, {required int player}) async {
    // For Simple mode "Extreme" difficulty, use the same Hybrid/MCTS pipeline as Classic
    // to mirror the strongest search and heuristics.
    if (engine.mode == GameMode.simple && difficulty == Difficulty.extreme) {
      return _chooseMoveWithMCTS(engine, player: player);
    }
    
    // Check if MCTS hybrid AI is enabled
    if (useMCTS) {
      return _chooseMoveWithMCTS(engine, player: player);
    }
    
    // Check for Simple mode
    if (engine.mode == GameMode.simple) {
      final boardSnapshot = List<int>.from(engine.board);
      final wLeft = engine.piecesLeft[1];
      final bLeft = engine.piecesLeft[2];
      // Simple mode is finite (max 18 plies). Use reasonable depths to avoid exponential slowdown.
      // Depth 14 is extremely deep.
      final depth = difficulty == Difficulty.extreme ? 16 :
                    difficulty == Difficulty.hard ? 10 :
                    difficulty == Difficulty.medium ? 6 : 2;
      final maxNodes = difficulty.nodeLimit;
      final maxMillis = difficulty.timeLimitMs;

      return _runCompute<Move?>(() {
        final simpleAI = ExtremeSimpleAI(
          searchDepth: depth,
          maxNodes: maxNodes,
          maxMillis: maxMillis,
        );
        
        final bestTo = simpleAI.chooseMove(
          boardSnapshot,
          wLeft,
          bLeft,
          player,
        );
        
        if (bestTo == null) return null;
        return Move(from: null, to: bestTo, remove: null);
      });
    }

    // Classic mode (existing logic)
    final boardSnapshot = List<int>.from(engine.board);
    final wLeft = engine.piecesLeft[1];
    final bLeft = engine.piecesLeft[2];
    final depth = difficulty.searchDepth;
    final maxNodes = difficulty.nodeLimit;
    final maxMillis = difficulty.timeLimitMs;
    return _runCompute<Move?>(() {
      final placementsDone = wLeft == 0 && bLeft == 0;
      extreme_ai.setPlacementComplete(placementsDone);
      final pos = _toPosition(boardSnapshot, wLeft, bLeft, player);
      final best = extreme_ai.searchBestMove(pos, depth, maxNodes: maxNodes, maxMillis: maxMillis);
      if (best == null) return null;
      return Move(
        from: best.from >= 0 ? best.from : null,
        to: best.to,
        remove: best.remove >= 0 ? best.remove : null,
      );
    });
  }
  
  /// Choose move using MCTS + Tablebase hybrid AI
  Future<Move?> _chooseMoveWithMCTS(GameEngine engine, {required int player}) async {
    final boardSnapshot = List<int>.from(engine.board);
    final wLeft = engine.piecesLeft[1];
    final bLeft = engine.piecesLeft[2];
    final gameMode = engine.mode; // Extract mode before isolate
    final gamePhase = engine.phase; // Extract phase before isolate
    final difficultyLevel = difficulty; // Extract difficulty to avoid capturing 'this'
    final searchBudgetMs = (difficultyLevel.timeLimitMs * 0.9).round();
    
    // Run in isolate to prevent UI freeze
    // We use type inference here because the closure is async (returns Future<Move?>)
    
    // Update status to show we are thinking
    if (onStatusUpdate != null) {
      final timeEst = difficultyLevel == Difficulty.extreme ? "~9s" : 
                      difficultyLevel == Difficulty.hard ? "~1.5s" : "<1s";
      onStatusUpdate!("AI is thinking (${difficultyLevel.label} $timeEst)...");
    }
    
    final search = _runCompute(() async {
      // Configure MCTS based on difficulty
      // Much higher iteration counts for stronger play
      // Reduce significantly for web to prevent UI freeze
      final bool simpleMode = gameMode == GameMode.simple;
      final baseIterations = difficultyLevel == Difficulty.extreme
          ? (simpleMode ? 90000 : 50000)  // push much harder in Simple
          : difficultyLevel == Difficulty.hard
              ? 20000
              : difficultyLevel == Difficulty.medium
                  ? 10000
                  : 3000;
      final iterations = kIsWeb ? (baseIterations * 0.25).round() : baseIterations; // 75% reduction for web
      
      final config = HybridConfig(
        useParallel: !kIsWeb && difficultyLevel == Difficulty.extreme, // Use parallel search for Extreme
        parallelWorkers: 3, // Limit worker isolates to avoid starving UI thread
        isSimpleMode: gameMode == GameMode.simple, // Pass game mode
        mctsConfig: MCTSConfig(
          maxIterations: iterations,
          maxMilliseconds: simpleMode && difficultyLevel == Difficulty.extreme
              ? (searchBudgetMs + 3000) // give simple mode extra time budget
              : searchBudgetMs,
          explorationConstant: simpleMode ? 1.5 : 1.8, // bias toward best lines in Simple
          progressiveWideningFactor: difficultyLevel == Difficulty.extreme
              ? (simpleMode ? 2.5 : 3.0)
              : 6.0,
        ),
      );
      
      final wrapper = HybridAIWrapper(config: config);
      
      final phaseInt = gamePhase == GamePhase.placing ? 0 :
                       gamePhase == GamePhase.moving ? 1 : 2;
      
      final result = await wrapper.chooseFullMove(
        board: boardSnapshot,
        whitePiecesLeft: wLeft,
        blackPiecesLeft: bLeft,
        player: player,
        phase: phaseInt,
      );
      
      if (result == null) return null;
      
      return Move(
        from: result['from'],
        to: result['to'],
        remove: result['remove'],
      );
    });

    try {
      return await search.timeout(Duration(milliseconds: searchBudgetMs + 1200));
    } on TimeoutException {
      onStatusUpdate?.call('AI timed out, picking a quick move...');
      final fallbacks = engine.legalMoves(player);
      if (fallbacks.isEmpty) return null;
      final move = fallbacks.first;
      return Move(from: move.from, to: move.to, remove: move.remove);
    } catch (e, st) {
      debugPrint('AI search failed: $e\n$st');
      return null;
    }
  }
  
  /// Convert GamePhase to int for MCTS
  int _getPhase(GamePhase phase) {
    switch (phase) {
      case GamePhase.placing:
        return 0;
      case GamePhase.moving:
        return 1;
      case GamePhase.flying:
        return 2;
      case GamePhase.gameOver:
        return 0; // Should not happen
    }
  }

  extreme_ai.Position _toPosition(List<int> board, int wLeft, int bLeft, int player) {
    int whiteBits = 0, blackBits = 0;
    for (int i = 0; i < board.length; i++) {
      if (board[i] == 1) whiteBits |= (1 << i);
      if (board[i] == 2) blackBits |= (1 << i);
    }
    final stm = player == 1 ? 0 : 1;
    final white = whiteBits | (wLeft << 24);
    final black = blackBits | (bLeft << 24);
    if (!_zobristReady) {
      extreme_ai.initZobrist();
      _zobristReady = true;
    }
    final pos = extreme_ai.Position(white, black, stm, 0);
    pos.zobristKey = 0;
    return pos;
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

class MorrisHome extends StatefulWidget {
  const MorrisHome({super.key, required this.darkMode, required this.onThemeChanged});
  final bool darkMode;
  final ValueChanged<bool> onThemeChanged;

  @override
  State<MorrisHome> createState() => _MorrisHomeState();
}

class _MorrisHomeState extends State<MorrisHome> with TickerProviderStateMixin {
  static const Duration _pieceAnimDuration = Duration(milliseconds: 230);
  static const Duration _cardAnimDuration = Duration(milliseconds: 320);
  late GameEngine engine;
  MinimaxAI? ai;
  GameMode mode = GameMode.classic;
  GameType type = GameType.ai;
  Difficulty difficulty = Difficulty.hard;
  NetworkRole networkRole = NetworkRole.none;
  int currentPlayer = 1;
  int localPlayerId = 1;
  bool isRemoving = false;
  int? selectedPiece;
  String status = 'Your turn';
  bool aiThinking = false;
  bool darkMode = false;
  bool isMyTurn = true;
  bool networkConnected = false;
  bool connecting = false;
  String? networkOverlayMessage;
  bool showConfetti = false;
  String playerName = 'You';
  String opponentName = 'Opponent';
  String? roomCode;
  int pingMs = 0;
  List<_ConfettiParticle> confetti = [];
  late final AnimationController _confettiAnimation;
  Set<int> millHighlight = {};
  bool showUpdateBanner = false;
  String updateBannerText = 'Update available!';
  final _namePromptController = TextEditingController();
  late final AnimationController _loaderController;
  OverlayEntry? _statusOverlayEntry;
  bool _overlayUpdateScheduled = false;
  String _statusOverlayText = '';
  IconData _statusOverlayIcon = Icons.podcasts;

  late NetworkClient networkClient;
  final _nameController = TextEditingController();
  final _roomCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loaderController = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _confettiAnimation = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..addListener(() {
        if (!mounted) return;
        setState(() {
          for (final p in confetti) {
            p.position += p.velocity;
            p.velocity += const Offset(0, 0.0008);
            p.life -= 0.016;
          }
          confetti.removeWhere((p) => p.life <= 0.0 || p.position.dy > 1.2);
          if (confetti.isEmpty && _confettiAnimation.isAnimating) {
            _confettiAnimation.stop();
            showConfetti = false;
          }
        });
      });
    darkMode = widget.darkMode;
    engine = GameEngine(mode: mode);
    ai = MinimaxAI(difficulty: difficulty, useMCTS: USE_MCTS_AI);
    _nameController.text = playerName;
    networkClient = NetworkClient(
      onRoomCode: (code) => _safeSetState(() {
        roomCode = code;
        networkOverlayMessage = 'Waiting for opponent...';
        _markOverlayDirty();
      }),
      onOpponent: (name) => _handleOpponentReady(name),
      onGameEvent: _handleRemoteEvent,
      onPing: (ms) => _safeSetState(() => pingMs = ms),
      onError: _showError,
      onDisconnected: _handleDisconnect,
      onStatus: (message) => _safeSetState(() {
        networkOverlayMessage = message;
        _markOverlayDirty();
      }),
    );
    _loadPrefs();
  }

  @override
  void dispose() {
    _removeStatusOverlay();
    _nameController.dispose();
    _roomCodeController.dispose();
    _namePromptController.dispose();
    _loaderController.dispose();
    _confettiAnimation.dispose();
    networkClient.disconnect();
    super.dispose();
  }

  int get _remotePlayer => localPlayerId == 1 ? 2 : 1;
  double get _titlebarSpacerHeight => defaultTargetPlatform == TargetPlatform.macOS ? 32 : 0;

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      mode = GameMode.values[prefs.getInt('mode') ?? GameMode.classic.index];
      difficulty = Difficulty.values[prefs.getInt('difficulty') ?? Difficulty.hard.index];
      darkMode = prefs.getBool('darkMode') ?? widget.darkMode;
      playerName = prefs.getString('playerName') ?? 'You';
      _nameController.text = playerName;
    });
    widget.onThemeChanged(darkMode);
    _resetState();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('mode', mode.index);
    await prefs.setInt('difficulty', difficulty.index);
    await prefs.setBool('darkMode', darkMode);
    await prefs.setString('playerName', playerName);
  }

  void _safeSetState(VoidCallback cb) {
    if (!mounted) return;
    setState(cb);
  }

  void _resetState({GameMode? newMode, GameType? newType, Difficulty? newDifficulty, bool preserveConnection = false}) {
    mode = newMode ?? mode;
    type = newType ?? type;
    difficulty = newDifficulty ?? difficulty;

    final leavingNetwork = type != GameType.network && networkRole != NetworkRole.none && !preserveConnection;
    if (leavingNetwork) {
      networkClient.disconnect();
      networkRole = NetworkRole.none;
      networkConnected = false;
      roomCode = null;
      opponentName = 'Opponent';
    }

    engine = GameEngine(mode: mode);
    ai = type == GameType.ai ? MinimaxAI(
      difficulty: difficulty, 
      useMCTS: USE_MCTS_AI,
      onStatusUpdate: (msg) => _safeSetState(() => status = msg),
    ) : null;
    isRemoving = false;
    selectedPiece = null;
    aiThinking = false;
    millHighlight.clear();

    if (type == GameType.network) {
      localPlayerId = networkRole == NetworkRole.client ? 2 : 1;
      currentPlayer = networkRole == NetworkRole.client ? _remotePlayer : localPlayerId;
      isMyTurn = currentPlayer == localPlayerId;
      status = networkConnected ? (isMyTurn ? 'Your turn' : "$opponentName's turn") : 'Waiting for opponent...';
    } else {
      localPlayerId = 1;
      currentPlayer = 1;
      isMyTurn = true;
      status = type == GameType.human ? 'Player 1 turn' : 'Your turn';
    }
    setState(() {});
    _markOverlayDirty();
    _savePrefs();
  }

  void _handleOpponentReady(String name) {
    _safeSetState(() {
      opponentName = name;
      networkConnected = true;
      connecting = false;
      networkOverlayMessage = null;
      type = GameType.network;
      currentPlayer = networkRole == NetworkRole.client ? _remotePlayer : localPlayerId;
      isMyTurn = currentPlayer == localPlayerId;
      status = networkRole == NetworkRole.client ? "$opponentName's turn" : 'Your turn';
      engine = GameEngine(mode: mode);
      isRemoving = false;
      selectedPiece = null;
      millHighlight.clear();
    });
    _markOverlayDirty();
  }

  void _handleRemoteEvent(RemoteEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'move':
        final payload = event.payload;
        if (payload is Map && payload['to'] != null) {
          final to = (payload['to'] as num).toInt();
          final from = (payload['from'] as num?)?.toInt();
          setState(() {
            _applyMove(Move(from: from, to: to), fromRemote: true);
            if (engine.phase != GamePhase.gameOver && !isRemoving) {
              currentPlayer = localPlayerId;
              isMyTurn = true;
              status = 'Your turn';
            }
          });
        }
        break;
      case 'remove':
        final pos = (event.payload as num?)?.toInt();
        if (pos != null) {
          setState(() {
            _performRemoval(pos, fromRemote: true);
            currentPlayer = localPlayerId;
            isMyTurn = true;
            status = 'Your turn';
          });
        }
        break;
      case 'reset':
        _safeSetState(() {
          _resetState(preserveConnection: true, newType: GameType.network);
          currentPlayer = networkRole == NetworkRole.client ? _remotePlayer : localPlayerId;
          isMyTurn = currentPlayer == localPlayerId;
          status = isMyTurn ? 'Your turn' : "$opponentName's turn";
        });
        break;
      default:
        break;
    }
  }

  void _handleDisconnect() {
    if (!mounted) return;
    setState(() {
      networkConnected = false;
      networkRole = NetworkRole.none;
      roomCode = null;
      opponentName = 'Opponent';
      type = GameType.ai;
      currentPlayer = 1;
      localPlayerId = 1;
      isMyTurn = true;
      status = 'Connection closed';
      connecting = false;
      networkOverlayMessage = null;
      engine = GameEngine(mode: mode);
      ai = MinimaxAI(difficulty: difficulty, useMCTS: USE_MCTS_AI);
    });
    _markOverlayDirty();
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      connecting = false;
      networkOverlayMessage = null;
      if (!networkConnected) {
        networkRole = NetworkRole.none;
        type = type == GameType.network ? GameType.ai : type;
      }
    });
    _markOverlayDirty();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _hostGame() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      await _promptName();
    }
    if (_nameController.text.trim().isEmpty && playerName.isEmpty) {
      _showError('Enter a name before hosting.');
      return;
    }
    setState(() {
      playerName = _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : playerName;
      type = GameType.network;
      networkRole = NetworkRole.host;
      localPlayerId = 1;
      currentPlayer = 1;
      isMyTurn = true;
      status = 'Hosting...';
      connecting = true;
      networkOverlayMessage = 'Hosting...';
      roomCode = null;
    });
    _savePrefs();
    _markOverlayDirty();
    try {
      await networkClient.host(playerName);
    } catch (e) {
      _showError('Network error: $e');
    } finally {
      if (mounted) setState(() => connecting = false);
      _markOverlayDirty();
    }
  }

  Future<void> _joinGame() async {
    final name = _nameController.text.trim();
    final code = _roomCodeController.text.trim().toUpperCase();
    if (name.isEmpty) {
      await _promptName();
    }
    final finalName = _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : playerName;
    if (finalName.isEmpty || code.length != 4) {
      _showError('Enter a name and a 4-letter room code.');
      return;
    }
    setState(() {
      playerName = finalName;
      type = GameType.network;
      networkRole = NetworkRole.client;
      localPlayerId = 2;
      currentPlayer = _remotePlayer;
      isMyTurn = false;
      status = 'Joining room...';
      connecting = true;
      networkOverlayMessage = 'Joining room...';
      roomCode = code;
    });
    _savePrefs();
    _markOverlayDirty();
    try {
      await networkClient.join(playerName, code);
    } catch (e) {
      _showError('Network error: $e');
    } finally {
      if (mounted) setState(() => connecting = false);
      _markOverlayDirty();
    }
  }

  Future<void> _leaveNetwork() async {
    await networkClient.disconnect();
    _resetState(newType: GameType.ai);
  }

  Future<void> _playAgain() async {
    if (type == GameType.network) {
      if (networkRole == NetworkRole.host) {
        networkClient.sendReset();
        _resetState(preserveConnection: true, newType: GameType.network);
        setState(() {
          currentPlayer = localPlayerId;
          isMyTurn = true;
          status = 'Your turn';
        });
      } else {
        _showError('Only the host can restart the network game.');
      }
      return;
    }
    _resetState();
  }

  Future<void> handleTap(int position) async {
    if (aiThinking || engine.phase == GamePhase.gameOver) return;

    if (type == GameType.network) {
      if (!networkConnected || !isMyTurn || currentPlayer != localPlayerId) return;
    }

    if (isRemoving) {
      final target = engine.opponent(currentPlayer);
      if (engine.isRemovable(position, target)) {
        _performRemoval(position, sendToNetwork: type == GameType.network);
      }
      return;
    }

    if (engine.phase == GamePhase.placing) {
      if (engine.piecesLeft[currentPlayer] == 0) {
        return;
      }
      if (engine.board[position] != 0) return;
      final move = Move(from: null, to: position);
      _applyMove(move);
    } else {
      if (selectedPiece == null) {
        if (engine.board[position] == currentPlayer) {
          setState(() => selectedPiece = position);
        }
      } else {
        if (selectedPiece == position) {
          setState(() => selectedPiece = null);
          return;
        }
        final canFly = engine.canFly(currentPlayer);
        final neighbors = engine.adjacencyMap[selectedPiece!]!;
        final valid = canFly ? engine.board[position] == 0 : (neighbors.contains(position) && engine.board[position] == 0);
        if (!valid) return;
        final move = Move(from: selectedPiece, to: position);
        selectedPiece = null;
        _applyMove(move);
      }
    }
  }

  void _applyMove(Move move, {bool fromRemote = false}) {
    final result = engine.applyMove(move, currentPlayer);
    if (type == GameType.network && !fromRemote) {
      networkClient.sendMove({'from': move.from, 'to': move.to});
    }

    millHighlight.clear();
    if (result.formedMill) {
      final pattern = engine.mills.firstWhere((m) => m.contains(move.to) && m.every((p) => engine.board[p] == currentPlayer), orElse: () => []);
      millHighlight = pattern.toSet();
    }

    if (mode == GameMode.simple) {
      void updateState() {
        if (result.formedMill) {
          _endGame(currentPlayer);
        } else if (result.gameOverWinner != null) {
          _endGame(result.gameOverWinner!);
        } else {
          _switchPlayer();
        }
      }

      if (fromRemote) {
        updateState();
      } else {
        setState(updateState);
      }

      if (!result.formedMill && result.gameOverWinner == null && type == GameType.ai && currentPlayer == 2) {
        _runAIMove();
      }
      return;
    }

    if (fromRemote) {
      // Let caller manage turn switching for remote moves
      if (result.formedMill) {
        isRemoving = true;
        status = "$opponentName formed a mill";
      }
    } else {
      setState(() {
        if (result.formedMill) {
          isRemoving = true;
          status = currentPlayer == localPlayerId ? 'Remove an opponent piece' : "$opponentName is removing...";
        } else if (result.gameOverWinner != null) {
          _endGame(result.gameOverWinner!);
        } else {
          _switchPlayer();
        }
      });

      if (!result.formedMill && type == GameType.ai && currentPlayer == 2) {
        _runAIMove();
      }
    }
  }

  void _performRemoval(int position, {bool fromRemote = false, bool sendToNetwork = false}) {
    final targetPlayer = fromRemote ? localPlayerId : engine.opponent(currentPlayer);
    engine.removePiece(position, targetPlayer);
    if (sendToNetwork && !fromRemote) {
      networkClient.sendRemove(position);
    }
    if (fromRemote) {
      isRemoving = false;
      return;
    }
    setState(() {
      isRemoving = false;
      final winner = engine.checkWinner();
      if (winner != null) {
        _endGame(winner);
      } else {
        _switchPlayer();
        if (type == GameType.ai && currentPlayer == 2) _runAIMove();
      }
    });
  }

  void _switchPlayer() {
    if (engine.phase == GamePhase.gameOver) return;
    currentPlayer = engine.opponent(currentPlayer);
    if (type == GameType.network) {
      isMyTurn = currentPlayer == localPlayerId;
      status = isMyTurn ? 'Your turn' : "$opponentName's turn";
      return;
    }
    if (type == GameType.human) {
      status = currentPlayer == 1 ? 'Player 1 turn' : 'Player 2 turn';
    } else {
      status = currentPlayer == 1 ? 'Your turn' : 'AI thinking...';
    }
  }

  void _endGame(int winner) {
    engine.phase = GamePhase.gameOver;
    if (type == GameType.network) {
      status = winner == localPlayerId ? 'You win!' : '$opponentName wins';
    } else if (type == GameType.human) {
      status = winner == 1 ? 'Player 1 wins' : 'Player 2 wins';
    } else {
      status = winner == 1 ? 'You win!' : 'AI wins';
    }
    final celebrate = winner == localPlayerId || type == GameType.human;
    if (celebrate) {
      final startColor = winner == 1 ? const Color(0xff3f51b5) : const Color(0xffd32f2f);
      final endColor = winner == 1 ? Colors.lightBlueAccent : Colors.orangeAccent;
      _triggerConfetti(startColor: startColor, endColor: endColor);
    }
  }

  Future<void> _runAIMove() async {
    _setAIThinking(true);
    try {
      await Future.delayed(const Duration(milliseconds: 250));
      final move = await ai?.chooseMove(engine, player: 2);

      if (move == null || move.to == null) {
        setState(() => _endGame(1));
        return;
      }
      final result = engine.applyMove(move, 2);
      millHighlight.clear();
      if (result.formedMill && move.to != null) {
        final pattern = engine.mills.firstWhere((m) => m.contains(move.to) && m.every((p) => engine.board[p] == 2), orElse: () => []);
        millHighlight = pattern.toSet();
      }
      if (result.formedMill) {
        final removable = move.remove ?? engine.firstRemovable(1);
        if (removable != null) {
          engine.removePiece(removable, 1);
        }
      }
      final winner = result.gameOverWinner ?? engine.checkWinner();
      setState(() {
        currentPlayer = 1;
        status = 'Your turn';
        if (winner != null) {
          _endGame(winner);
        }
      });
    } catch (e, st) {
      debugPrint('AI move failed: $e\n$st');
      _showError('AI move failed. Ending the game.');
      if (mounted) {
        setState(() => _endGame(1));
      }
    } finally {
      _setAIThinking(false);
    }
  }

  Color _pieceColor(int value) {
    if (value == 1) return const Color(0xff3f51b5);
    if (value == 2) return const Color(0xffd32f2f);
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final topActive = currentPlayer == _remotePlayer;
    final bottomActive = currentPlayer == localPlayerId;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Builder(builder: (context) {
              // Draw background behind SafeArea for dark mode parity
              return Container(color: Theme.of(context).scaffoldBackgroundColor);
            }),
            Column(
              children: [
                SizedBox(height: _titlebarSpacerHeight),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: _playerCard(
                    name: type == GameType.ai ? '${difficulty.label} AI' : opponentName,
                    piecesLeft: engine.piecesLeft[2],
                    color: const Color(0xffd32f2f),
                    subtitle: networkConnected ? '${engine.piecesLeft[2]} pieces left | ${opponentName.isEmpty ? "Opponent" : opponentName}' : '${engine.piecesLeft[2]} pieces left',
                    alignTop: true,
                    isActive: topActive,
                    trailing: [
                      if (type == GameType.ai && aiThinking) _aiIndicator(),
                      if (type == GameType.network) _networkInfoBadge(),
                    ],
                  ),
                ),
                if (showUpdateBanner)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Theme.of(context).colorScheme.tertiary),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.system_update, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(updateBannerText, style: const TextStyle(fontSize: 14))),
                        TextButton(onPressed: () => setState(() => showUpdateBanner = false), child: const Text('Dismiss')),
                      ],
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: RepaintBoundary(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final size = constraints.biggest;
                              final theme = Theme.of(context);
                              final emptyColor = theme.colorScheme.onSurface.withValues(alpha: 0.18);
                              final lineColor = theme.colorScheme.outline.withValues(alpha: 0.6);
                              return Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  CustomPaint(
                                    size: size,
                                    painter: BoardPainter(lineColor: lineColor),
                                  ),
                                  ...List.generate(engine.positions.length, (i) {
                                    final pos = engine.positions[i];
                                    final removable = isRemoving &&
                                        engine.board[i] == engine.opponent(currentPlayer) &&
                                        engine.isRemovable(i, engine.opponent(currentPlayer));
                                    final pieceColor = _pieceColor(engine.board[i]);
                                    final isEmpty = engine.board[i] == 0;
                                    final highlightMill = millHighlight.contains(i);
                                    final isSelected = selectedPiece == i;
                                    final borderColor = highlightMill
                                        ? Colors.orange
                                        : isSelected
                                            ? Colors.black54
                                            : (removable ? Colors.redAccent : Colors.transparent);
                                    final borderWidth = highlightMill
                                        ? 3.0
                                        : (isSelected || removable ? 2.2 : 0.0);
                                    final scale = highlightMill
                                        ? 1.15
                                        : isSelected
                                            ? 1.08
                                            : removable
                                                ? 1.05
                                                : 1.0;
                                    final opacity = isEmpty ? 0.55 : 1.0;
                                    return AnimatedPositioned(
                                      key: ValueKey('piece_$i'),
                                      duration: _pieceAnimDuration,
                                      curve: Curves.easeOutCubic,
                                      left: pos.dx * size.width - 16,
                                      top: pos.dy * size.height - 16,
                                      child: RepaintBoundary(
                                        child: GestureDetector(
                                          onTap: () => handleTap(i),
                                          child: AnimatedScale(
                                            duration: _pieceAnimDuration,
                                            curve: Curves.easeOutBack,
                                            scale: scale,
                                            child: AnimatedOpacity(
                                              duration: _pieceAnimDuration,
                                              opacity: opacity,
                                              child: AnimatedContainer(
                                                duration: _pieceAnimDuration,
                                                curve: Curves.easeOutCubic,
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color: isEmpty ? emptyColor : pieceColor,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: borderColor,
                                                    width: borderWidth,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  child: _bottomCard(isActive: bottomActive),
                ),
              ],
            ),
            if (showConfetti)
              Positioned.fill(
                child: RepaintBoundary(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: showConfetti ? 1 : 0,
                      child: CustomPaint(
                        painter: _ConfettiPainter(confetti: confetti),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _playerCard({
    required String name,
    required int piecesLeft,
    required Color color,
    required String subtitle,
    bool alignTop = false,
    List<Widget> trailing = const [],
    bool showBorderLoader = false,
    bool isActive = false,
  }) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: isActive ? 1 : 0),
      duration: _cardAnimDuration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final background = Color.lerp(
          theme.colorScheme.surface,
          theme.colorScheme.primaryContainer.withValues(alpha: 0.65),
          value,
        )!;
        final borderColor = Color.lerp(
          Colors.transparent,
          theme.colorScheme.primary.withValues(alpha: 0.4),
          value,
        )!;
        final glowAlpha = 0.04 + (0.12 * value);
        final scale = 1 + 0.02 * value;
        final borderWidth = 0.2 + (1.2 * value);

        final baseCard = Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: borderColor, width: borderWidth),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: glowAlpha),
                blurRadius: 10 + (16 * value),
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: alignTop ? MainAxisAlignment.start : MainAxisAlignment.center,
                  children: [
                    Text(name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: onSurface)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 14, color: onSurface.withValues(alpha: 0.65))),
                  ],
                ),
              ),
              if (trailing.isNotEmpty) ...[
                const SizedBox(width: 8),
                Row(mainAxisSize: MainAxisSize.min, children: trailing),
              ],
            ],
          ),
        );

        Widget card = baseCard;
        if (showBorderLoader) {
          card = AnimatedBuilder(
            animation: _loaderController,
            child: baseCard,
            builder: (context, child) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Stack(
                  children: [
                    child!,
                    CustomPaint(
                      painter: _BorderLoaderPainter(progress: _loaderController.value, color: theme.colorScheme.primary),
                      size: Size.infinite,
                    ),
                  ],
                ),
              );
            },
          );
        }

        return Transform.scale(
          scale: scale,
          child: card,
        );
      },
    );
  }

  Widget _bottomCard({required bool isActive}) {
    final subtitle = engine.phase == GamePhase.placing
        ? '${engine.piecesLeft[1]} pieces left'
        : '${engine.piecesOnBoard[1]} on board';
    final theme = Theme.of(context);
    final surfaceVariant = theme.colorScheme.surfaceContainerHighest;
    final onSurface = theme.colorScheme.onSurface;
    return _playerCard(
      name: playerName,
      piecesLeft: engine.piecesLeft[1],
      color: const Color(0xff3f51b5),
      subtitle: subtitle,
      isActive: isActive,
      trailing: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _circleButton(
              icon: Icons.close,
              background: surfaceVariant,
              iconColor: onSurface,
              onTap: _playAgain,
            ),
            const SizedBox(width: 8),
            _circleButton(
              icon: Icons.settings,
              background: surfaceVariant,
              iconColor: onSurface,
              onTap: _openSettings,
            ),
            const SizedBox(width: 8),
            _circleButton(
              icon: Icons.badge,
              background: surfaceVariant,
              iconColor: onSurface,
              onTap: _promptName,
            ),
          ],
        ),
      ],
    );
  }

  Widget _aiIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
          ),
        ),
        const SizedBox(width: 6),
        Text('Thinking', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _networkInfoBadge() {
    final theme = Theme.of(context);
    final label = roomCode != null && roomCode!.isNotEmpty
        ? 'Room ${roomCode!}'
        : (networkOverlayMessage ?? 'Connecting...');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.network_ping, size: 14),
              const SizedBox(width: 4),
              Text('${pingMs}ms', style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circleButton({required IconData icon, required Color background, required Color iconColor, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Icon(icon, color: iconColor),
      ),
    );
  }


  Widget _overlayMessage(BuildContext overlayContext, String text, IconData icon) {
    final theme = Theme.of(overlayContext);
    return Positioned.fill(
      child: Container(
        color: Colors.black45,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 12)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 32),
                const SizedBox(height: 12),
                Text(text, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(minHeight: 6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _markOverlayDirty() {
    if (_overlayUpdateScheduled || !mounted) return;
    _overlayUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayUpdateScheduled = false;
      if (!mounted) return;
      _syncStatusOverlay();
    });
  }

  void _syncStatusOverlay() {
    final shouldShow = connecting || (type == GameType.network && !networkConnected && networkRole != NetworkRole.none && !connecting);
    if (!shouldShow) {
      _removeStatusOverlay();
      return;
    }
    final text = connecting
        ? (networkOverlayMessage ?? 'Connecting...')
        : () {
            final base = networkOverlayMessage ?? 'Waiting for opponent...';
            if (roomCode != null && roomCode!.isNotEmpty) {
              return '$base\nRoom: $roomCode';
            }
            return base;
          }();
    final icon = connecting ? Icons.podcasts : Icons.hourglass_empty;
    final changed = text != _statusOverlayText || icon != _statusOverlayIcon;
    _statusOverlayText = text;
    _statusOverlayIcon = icon;
    if (_statusOverlayEntry == null) {
      final overlay = Overlay.of(context, rootOverlay: true);
      _statusOverlayEntry = OverlayEntry(
        builder: (ctx) => _overlayMessage(ctx, _statusOverlayText, _statusOverlayIcon),
      );
      overlay.insert(_statusOverlayEntry!);
    } else if (changed) {
      _statusOverlayEntry!.markNeedsBuild();
    }
  }

  void _removeStatusOverlay() {
    _statusOverlayEntry?.remove();
    _statusOverlayEntry = null;
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return _SettingsSheet(
          type: type,
          difficulty: difficulty,
          mode: mode,
          darkMode: darkMode,
          playerName: playerName,
          networkRole: networkRole,
          networkConnected: networkConnected,
          roomCode: roomCode,
          connecting: connecting,
          networkOverlayMessage: networkOverlayMessage,
          pingMs: pingMs,
          nameController: _nameController,
          roomCodeController: _roomCodeController,
          onTypeChanged: (newType) {
            _resetState(newType: newType, preserveConnection: true);
          },
          onDifficultyChanged: (newDiff) {
            _resetState(newDifficulty: newDiff);
          },
          onModeChanged: (newMode) {
            _resetState(newMode: newMode, preserveConnection: true);
          },
          onThemeChanged: (v) {
            setState(() => darkMode = v);
            widget.onThemeChanged(v);
            _savePrefs();
          },
          onJoin: _joinGame,
          onHost: _hostGame,
          onLeave: _leaveNetwork,
          onShowUpdate: () {
            setState(() => showUpdateBanner = true);
          },
          getDebugText: _debugText,
        );
      },
    );
  }

  Widget _settingsSection(
    BuildContext ctx, {
    required String title,
    required Widget child,
    EdgeInsetsGeometry contentPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  }) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(ctx).textTheme.labelSmall),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: contentPadding,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: child,
          ),
        ],
      ),
    );
  }

  Future<void> _promptName() async {
    _namePromptController.text = playerName;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter your name'),
        content: TextField(
          controller: _namePromptController,
          maxLength: 15,
          decoration: const InputDecoration(hintText: 'Your name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final val = _namePromptController.text.trim();
              if (val.isNotEmpty) {
                setState(() => playerName = val);
                _savePrefs();
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _setAIThinking(bool value) {
    if (aiThinking == value) return;
    setState(() => aiThinking = value);
    if (value) {
      _loaderController.repeat();
    } else {
      _loaderController.stop();
      _loaderController.value = 0;
    }
  }

  String _debugText() {
    return [
      'Mode: ${mode.label}',
      'Type: ${type.label}',
      'Difficulty: ${difficulty.label}',
      'Dark: $darkMode',
      'Network role: $networkRole',
      'Connected: $networkConnected',
      'Room: ${roomCode ?? '-'}',
      'Ping: ${pingMs}ms',
      'Phase: ${engine.phase}',
      'Pieces P1: ${engine.piecesOnBoard[1]} on board / ${engine.piecesLeft[1]} left',
      'Pieces P2: ${engine.piecesOnBoard[2]} on board / ${engine.piecesLeft[2]} left',
    ].join('\n');
  }

  void _triggerConfetti({Color startColor = Colors.blueAccent, Color endColor = Colors.pinkAccent}) {
    final rand = Random();
    // Reduce particle count for web performance
    final particleCount = kIsWeb ? 50 : 80;
    final burst = List.generate(particleCount, (_) {
      final startX = rand.nextDouble();
      final vel = Offset((rand.nextDouble() - 0.5) * 0.02, rand.nextDouble() * 0.02 + 0.01);
      return _ConfettiParticle(
        position: Offset(startX, -0.1),
        velocity: vel,
        color: Color.lerp(startColor, endColor, rand.nextDouble())!,
        size: rand.nextDouble() * 6 + 4,
        life: 1.5 + rand.nextDouble() * 0.5,
      );
    });
    if (!mounted) return;
    setState(() {
      confetti = burst;
      showConfetti = true;
    });
    _confettiAnimation.reset();
    _confettiAnimation.repeat();
  }

  void _stopConfetti({bool silent = false}) {
    _confettiAnimation.stop();
    if (!silent && mounted) {
      setState(() {
        showConfetti = false;
        confetti = [];
      });
    }
  }
}

class BoardPainter extends CustomPainter {
  BoardPainter({required this.lineColor});
  final Color lineColor;

  static const List<Offset> _positions = [
    Offset(0.05, 0.05),
    Offset(0.50, 0.05),
    Offset(0.95, 0.05),
    Offset(0.95, 0.50),
    Offset(0.95, 0.95),
    Offset(0.50, 0.95),
    Offset(0.05, 0.95),
    Offset(0.05, 0.50),
    Offset(0.20, 0.20),
    Offset(0.50, 0.20),
    Offset(0.80, 0.20),
    Offset(0.80, 0.50),
    Offset(0.80, 0.80),
    Offset(0.50, 0.80),
    Offset(0.20, 0.80),
    Offset(0.20, 0.50),
    Offset(0.30, 0.30),
    Offset(0.50, 0.30),
    Offset(0.70, 0.30),
    Offset(0.70, 0.50),
    Offset(0.70, 0.70),
    Offset(0.50, 0.70),
    Offset(0.30, 0.70),
    Offset(0.30, 0.50),
  ];

  static const Map<int, List<int>> _adjacencyMap = {
    0: [1, 7],
    1: [0, 2, 9],
    2: [1, 3],
    3: [2, 4, 11],
    4: [3, 5],
    5: [4, 6, 13],
    6: [5, 7],
    7: [0, 6, 15],
    8: [9, 15],
    9: [1, 8, 10, 17],
    10: [9, 11],
    11: [3, 10, 12, 19],
    12: [11, 13],
    13: [5, 12, 14, 21],
    14: [13, 15],
    15: [7, 8, 14, 23],
    16: [17, 23],
    17: [9, 16, 18],
    18: [17, 19],
    19: [11, 18, 20],
    20: [19, 21],
    21: [13, 20, 22],
    22: [21, 23],
    23: [15, 16, 22],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    final scaled = _positions.map((p) => Offset(p.dx * size.width, p.dy * size.height)).toList();
    final drawn = <String>{};
    _adjacencyMap.forEach((from, tos) {
      for (final to in tos) {
        final key = from < to ? '$from-$to' : '$to-$from';
        if (drawn.contains(key)) continue;
        drawn.add(key);
        canvas.drawLine(scaled[from], scaled[to], paint);
      }
    });
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) => lineColor != oldDelegate.lineColor;
}

class _BorderLoaderPainter extends CustomPainter {
  final double progress;
  final Color color;
  _BorderLoaderPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(2);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(26));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics().first;
    final length = metrics.length;
    final span = length * 0.3;
    final start = (length * progress) % length;
    final end = (start + span).clamp(0, length).toDouble();
    final extract = metrics.extractPath(start, end);
    canvas.drawPath(extract, paint);
  }

  @override
  bool shouldRepaint(covariant _BorderLoaderPainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.color != color;
}

class _ConfettiParticle {
  Offset position;
  Offset velocity;
  Color color;
  double size;
  double life;

  _ConfettiParticle({
    required this.position,
    required this.velocity,
    required this.color,
    required this.size,
    required this.life,
  });
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiParticle> confetti;
  _ConfettiPainter({required this.confetti});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in confetti) {
      final alpha = (p.life.clamp(0.0, 1.0) * 255).toInt();
      paint.color = p.color.withAlpha(alpha);
      final pos = Offset(p.position.dx * size.width, p.position.dy * size.height);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 1.6), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => confetti.isNotEmpty; // Only repaint if there are particles
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsetsGeometry contentPadding;

  const _SettingsSection({
    required this.title,
    required this.child,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelSmall),
          const SizedBox(height: 6),
          RepaintBoundary(
            child: Container(
              width: double.infinity,
              padding: contentPadding,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  final GameType type;
  final Difficulty difficulty;
  final GameMode mode;
  final bool darkMode;
  final String playerName;
  final NetworkRole networkRole;
  final bool networkConnected;
  final String? roomCode;
  final bool connecting;
  final String? networkOverlayMessage;
  final int pingMs;
  final TextEditingController nameController;
  final TextEditingController roomCodeController;
  final ValueChanged<GameType> onTypeChanged;
  final ValueChanged<Difficulty> onDifficultyChanged;
  final ValueChanged<GameMode> onModeChanged;
  final ValueChanged<bool> onThemeChanged;
  final VoidCallback onJoin;
  final VoidCallback onHost;
  final VoidCallback onLeave;
  final VoidCallback onShowUpdate;
  final String Function() getDebugText;

  const _SettingsSheet({
    required this.type,
    required this.difficulty,
    required this.mode,
    required this.darkMode,
    required this.playerName,
    required this.networkRole,
    required this.networkConnected,
    required this.roomCode,
    required this.connecting,
    required this.networkOverlayMessage,
    required this.pingMs,
    required this.nameController,
    required this.roomCodeController,
    required this.onTypeChanged,
    required this.onDifficultyChanged,
    required this.onModeChanged,
    required this.onThemeChanged,
    required this.onJoin,
    required this.onHost,
    required this.onLeave,
    required this.onShowUpdate,
    required this.getDebugText,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool showAboutDebug = false;
  late GameType _type;
  late GameMode _mode;
  late Difficulty _difficulty;

  @override
  void initState() {
    super.initState();
    _type = widget.type;
    _mode = widget.mode;
    _difficulty = widget.difficulty;
  }

  @override
  void didUpdateWidget(covariant _SettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type) _type = widget.type;
    if (oldWidget.mode != widget.mode) _mode = widget.mode;
    if (oldWidget.difficulty != widget.difficulty) _difficulty = widget.difficulty;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sheetColor = theme.colorScheme.surface;
    
    return Container(
      color: sheetColor,
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
            child: RepaintBoundary(
              child: ListView(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: showAboutDebug ? 4 : 6),
                shrinkWrap: true,
                children: [
                  Row(
                    children: [
                      if (showAboutDebug)
                        IconButton(
                          onPressed: () => setState(() => showAboutDebug = false),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      Expanded(
                        child: Text(
                          showAboutDebug ? 'About & Debug' : 'Settings',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final offsetAnimation = Tween<Offset>(begin: const Offset(0.05, 0), end: Offset.zero).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(position: offsetAnimation, child: child),
                      );
                    },
                    child: showAboutDebug ? _buildAboutContent(context) : _buildMainSettings(context),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMainSettings(BuildContext context) {
    return Column(
      key: const ValueKey('main-settings'),
      children: [
        _SettingsSection(
          title: 'Game Type',
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: GameType.values
                .map((t) => ChoiceChip(
                      label: Text(t.label),
                      selected: _type == t,
                      onSelected: (_) {
                        setState(() => _type = t);
                        widget.onTypeChanged(t);
                      },
                    ))
                .toList(),
          ),
        ),
        if (_type == GameType.ai)
          _SettingsSection(
            title: 'AI Difficulty',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: Difficulty.values
                  .map((d) => ChoiceChip(
                        label: Text(d.label),
                        selected: _difficulty == d,
                        onSelected: (_) {
                          setState(() => _difficulty = d);
                          widget.onDifficultyChanged(d);
                        },
                      ))
                  .toList(),
            ),
          ),
        _SettingsSection(
          title: 'Game Mode',
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: GameMode.values
                .map((m) => ChoiceChip(
                      label: Text(m.label),
                      selected: _mode == m,
                      onSelected: (_) {
                        setState(() => _mode = m);
                        widget.onModeChanged(m);
                      },
                    ))
                .toList(),
          ),
        ),
        _SettingsSection(
          title: 'Player & Theme',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('name-field'),
                controller: widget.nameController,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Dark mode'),
                  Switch(
                    value: widget.darkMode,
                    onChanged: widget.onThemeChanged,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_type == GameType.network)
          _SettingsSection(
            title: 'Network',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('room-code-field'),
                        controller: widget.roomCodeController,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 4,
                        decoration: const InputDecoration(labelText: 'Room code', counterText: ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: widget.connecting ? null : widget.onJoin,
                      icon: const Icon(Icons.login),
                      label: const Text('Join'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: widget.connecting ? null : widget.onHost,
                      icon: const Icon(Icons.podcasts),
                      label: const Text('Host'),
                    ),
                    const SizedBox(width: 10),
                    Text(widget.roomCode != null ? 'Room: ${widget.roomCode}' : ''),
                  ],
                ),
                if (widget.networkConnected)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: widget.onLeave,
                      icon: const Icon(Icons.logout),
                      label: const Text('Leave network'),
                    ),
                  ),
              ],
            ),
          ),
        _SettingsSection(
          title: 'More',
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 2),
            dense: true,
            visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
            title: const Text('About & Debug'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => showAboutDebug = true),
          ),
        ),
      ],
    );
  }

  Widget _buildAboutContent(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('about-settings'),
      children: [
        _SettingsSection(
          title: 'About & Debug',
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(widget.getDebugText(), style: theme.textTheme.bodySmall),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => Clipboard.setData(ClipboardData(text: widget.getDebugText())),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy debug'),
                  ),
                  ElevatedButton.icon(
                    onPressed: widget.onShowUpdate,
                    icon: const Icon(Icons.system_update),
                    label: const Text('Show update'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

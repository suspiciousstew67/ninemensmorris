// High-performance Nine Men's Morris engine ("Extreme" difficulty) tuned for Flutter.
// Uses bitboards, iterative deepening alpha-beta, transposition table, move ordering,
// and fast integer evaluation. All logic lives in this single file for easy drop-in.
// Expect roughly 0.5-2M nodes/sec on mid phones with ttBits=20 (~16 MB).

import 'dart:isolate';
import 'dart:math';
import 'tablebase_loader.dart';

// ===== constants / config =====
const int boardSize = 24;
const int maxPly = 64; // search safety cap
const int ttBits = 20; // 2^20 entries (~1M); tune for memory (16 bytes each -> ~16 MB)
const int ttSize = 1 << ttBits;
const int ttMask = ttSize - 1;
const int inf = 1000000000;

// Flags for TT entries.
const int ttExact = 0;
const int ttLower = 1;
const int ttUpper = 2;

// Simple phase tags.
const int phasePlacing = 0;
const int phaseMoving = 1;
const int phaseFlying = 2;

// Board mask to clip to 24 squares.
const int _boardMask = (1 << boardSize) - 1;
const int _piecesShift = 24;
bool _placementCompleteOverride = false;

// ===== exported data classes =====
class Position {
  int white, black, sideToMove, zobristKey;
  Position(this.white, this.black, this.sideToMove, this.zobristKey);
}

class Move {
  final int from;
  final int to;
  final int remove;
  const Move(this.from, this.to, [this.remove = -1]);
  @override
  String toString() => 'Move(from:$from to:$to remove:$remove)';
}

// ===== zobrist hashing =====
List<List<int>> zobristPiece =
    List<List<int>>.generate(boardSize, (_) => List<int>.filled(2, 0));
int zobristSide = 0;
List<List<int>> zobristPiecesLeft =
    List<List<int>>.generate(2, (_) => List<int>.filled(10, 0));
bool _zobristReady = false;

void initZobrist([int? seed]) {
  final rnd = Random(seed);
  for (var sq = 0; sq < boardSize; sq++) {
    zobristPiece[sq][0] = _rand64(rnd);
    zobristPiece[sq][1] = _rand64(rnd);
  }
  zobristSide = _rand64(rnd);
  for (var c = 0; c < 2; c++) {
    for (var n = 0; n < 10; n++) {
      zobristPiecesLeft[c][n] = _rand64(rnd);
    }
  }
  _zobristReady = true;
}

int _rand64(Random rnd) {
  // Keep within JS-safe 53-bit range so web builds don't overflow.
  const int mask53 = 0x1FFFFFFFFFFFFF;
  final hi = rnd.nextInt(1 << 26);
  final lo = rnd.nextInt(1 << 27);
  return ((hi << 27) ^ lo) & mask53;
}

int _recomputeZobrist(Position pos) {
  var key = pos.sideToMove == 1 ? zobristSide : 0;
  var occ = _occ(pos.white);
  while (occ != 0) {
    final sq = _lsb(occ);
    key ^= zobristPiece[sq][0];
    occ &= occ - 1;
  }
  occ = _occ(pos.black);
  while (occ != 0) {
    final sq = _lsb(occ);
    key ^= zobristPiece[sq][1];
    occ &= occ - 1;
  }
  key ^= zobristPiecesLeft[0][_piecesLeft(pos.white)];
  key ^= zobristPiecesLeft[1][_piecesLeft(pos.black)];
  return key;
}

// ===== game-specific tables (fill these) =====
// Each mask represents one mill (3 aligned squares). This list holds 16 real mill
// masks (others are 0 to keep length==24). Mapping uses the standard 24-square
// indexing (clockwise outer, then middle, inner):
// 0:A1 1:D1 2:G1 3:B2 4:D2 5:F2 6:C3 7:D3 8:E3
// 9:A4 10:B4 11:C4 12:E4 13:F4 14:G4 15:C5 16:D5 17:E5
// 18:B6 19:D6 20:F6 21:A7 22:D7 23:G7
// ignore: non_constant_identifier_names
List<int> MILL_MASKS = _buildMillMasks();

// Adjacency lists for orthogonal neighbors used in moving phase (same indexing).
// ignore: non_constant_identifier_names
List<List<int>> ADJ = _buildAdjacency();

// Expanded opening book: Strong opening positions to avoid early mistakes.
const Map<String, List<int>> _embeddedOpeningBook = {
  // Format: "<whiteBits>|<whiteLeft>/<blackBits>|<blackLeft>/<stm>"
  // Empty board -> D2 (center cross point, index 4)
  '0|9/0|9/0': [-1, 4, -1],
  // After W:D2 (bit 4 = 16), B responds with D6 (index 19, bit 19 = 524288)
  '16|8/0|9/1': [-1, 19, -1],
  // After W:D2, B:D6, W takes B4 (index 10, bit 10 = 1024) -> total W = 16+1024 = 1040
  '16|8/524288|8/0': [-1, 10, -1],
  // After W:D2+B4 (1040), B:D6, B takes F4 (index 13, bit 13 = 8192) -> B = 524288+8192 = 532480
  '1040|7/524288|8/1': [-1, 13, -1],
  // Alternative opening: W:D1 (index 1, bit 1 = 2)
  '0|9/0|8/0': [-1, 1, -1],
  // After W:D1, B:D7 (index 22, bit 22 = 4194304)
  '2|8/0|9/1': [-1, 22, -1],
  // After W:D1, B:D7, W:A1 (index 0, bit 0 = 1) -> W = 2+1 = 3
  '2|8/4194304|8/0': [-1, 0, -1],
  // After W:D1+A1, B:D7, B:G1 (index 2, bit 2 = 4) -> B = 4194304+4 = 4194308
  '3|7/4194304|8/1': [-1, 2, -1],
  // W:D1+A1+D2 (2+1+16 = 19), B:D7+G1 (4194304+4 = 4194308), W to move
  '19|6/4194308|7/0': [-1, 7, -1],
  // Defensive: W:D2, B:G1 (bit 2 = 4), W:D1
  '16|8/4|8/0': [-1, 1, -1],
  // W:D2+D1 (18), B:G1, B to move -> D7
  '18|7/4|8/1': [-1, 22, -1],
  // Early mill formation: W at A1+D1+G1 (1+2+4 = 7), B hasn't moved
  '7|6/0|9/1': [-1, 19, -1],
};


// Endgame tablebase: Perfect play for small piece counts (scores from white POV).
// Format: "<whiteBits>|<whiteLeft>/<blackBits>|<blackLeft>/<stm>" -> score
const Map<String, int> _embeddedTablebase = {
  // 3v3 endgames (some sample positions - in practice you'd generate these)
  // W has 3 pieces at A1,D1,G1 (positions 0,1,2) = bits 1|2|4 = 7
  // B has 3 pieces scattered, W to move, slight advantage
  '7|0/448|0/0': 50, // W: A1,D1,G1; B: C3,D3,E3
  
  // 3v4 endgames (White disadvantage)
  '7|0/15360|0/1': -200, // W: 3 pieces; B: 4 pieces
  
  // 4v3 endgames (White advantage)  
  '15360|0/7|0/0': 200, // W: 4 pieces; B: 3 pieces
  
  // 4v4 endgames (balanced)
  '15|0/240|0/0': 0, // Even position
  
  // Near-win positions (2v3 - losing for side with 2)
  '3|0/448|0/0': -800, // W has only 2 pieces (A1,D1)
  '448|0/3|0/0': 800,  // B has only 2 pieces
};

List<int> _buildMillMasks() {
  int m(int a, int b, int c) => _bit(a) | _bit(b) | _bit(c);
  return <int>[
    // 16 true mill lines.
    m(0, 1, 2),
    m(3, 4, 5),
    m(6, 7, 8),
    m(9, 10, 11),
    m(12, 13, 14),
    m(15, 16, 17),
    m(18, 19, 20),
    m(21, 22, 23),
    m(0, 9, 21),
    m(3, 10, 18),
    m(6, 11, 15),
    m(1, 4, 7),
    m(16, 19, 22),
    m(8, 12, 17),
    m(5, 13, 20),
    m(2, 14, 23),
    // Padding to keep length==24 (unused zeros).
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ];
}

List<List<int>> _buildAdjacency() {
  return <List<int>>[
    [1, 9], // 0 A1
    [0, 2, 4], // 1 D1
    [1, 14], // 2 G1
    [4, 10], // 3 B2
    [1, 3, 5, 7], // 4 D2
    [4, 13], // 5 F2
    [7, 11], // 6 C3
    [4, 6, 8], // 7 D3
    [7, 12], // 8 E3
    [0, 10, 21], // 9 A4
    [3, 9, 11], // 10 B4
    [6, 10, 15], // 11 C4
    [8, 13, 17], // 12 E4
    [5, 12, 14, 20], // 13 F4
    [2, 13, 23], // 14 G4
    [11, 16], // 15 C5
    [15, 17, 19], // 16 D5
    [12, 16], // 17 E5
    [10, 19], // 18 B6
    [16, 18, 20, 22], // 19 D6
    [13, 19], // 20 F6
    [9, 22], // 21 A7
    [19, 21, 23], // 22 D7
    [14, 22], // 23 G7
  ];
}

// ===== bitboard utilities =====
@pragma('vm:prefer-inline')
int _bit(int sq) => 1 << sq;

@pragma('vm:prefer-inline')
int _lsb(int bb) => bb == 0 ? -1 : (bb & -bb).bitLength - 1;

@pragma('vm:prefer-inline')
int _popcount(int bb) {
  var x = bb & _boardMask;
  var c = 0;
  while (x != 0) {
    x &= x - 1;
    c++;
  }
  return c;
}

@pragma('vm:prefer-inline')
int _occ(int bb) => bb & _boardMask;

@pragma('vm:prefer-inline')
int _piecesLeft(int bb) => (bb >> _piecesShift) & 0xF;

@pragma('vm:prefer-inline')
int _withPiecesLeft(int occ, int left) => (occ & _boardMask) | (left << _piecesShift);

// Precompute which mills include a given square for faster detection.
final List<List<int>> _millsBySquare = _buildMillsBySquare();

List<List<int>> _buildMillsBySquare() {
  final list = List<List<int>>.generate(boardSize, (_) => <int>[]);
  for (final mask in MILL_MASKS) {
    if (mask == 0) continue;
    for (var sq = 0; sq < boardSize; sq++) {
      if ((mask & _bit(sq)) != 0) list[sq].add(mask);
    }
  }
  return list;
}

// ===== transposition table =====
// TT cuts repeated subtrees; depth-preferred replacement keeps deeper info.
final List<int> _ttKey = List<int>.filled(ttSize, 0);
final List<int> _ttVal = List<int>.filled(ttSize, 0);
final List<int> _ttDepth = List<int>.filled(ttSize, -1);
final List<int> _ttFlag = List<int>.filled(ttSize, ttExact);
final List<int> _ttMove = List<int>.filled(ttSize, 0);

// Reusable move buffer to avoid allocations in a tuned generator.
final List<Move> _moveBuf = <Move>[];

// ===== history / killer heuristics =====
final List<List<int>> _history =
    List<List<int>>.generate(boardSize + 1, (_) => List<int>.filled(boardSize, 0));
final List<List<Move?>> _killer =
    List<List<Move?>>.generate(maxPly, (_) => List<Move?>.filled(2, null));

// ===== globals for search control =====
int _nodes = 0;
int _maxNodes = 0;
int _maxMillis = 0;
Stopwatch _timer = Stopwatch();
bool _stopSearch = false;
bool _bookLoaded = false;
bool _tablebaseLoaded = false;

// Opening book keyed by zobrist.
final Map<int, Move> _openingBook = <int, Move>{};

// In-memory exact values keyed by zobrist (from white POV).
final Map<int, int> _tablebase = <int, int>{};

// ===== tablebase integration =====
/// Query tablebase for endgame position.
/// Returns score from white POV if in tablebase, null otherwise.
int? queryTablebase(Position pos) {
  // Try real tablebase first (if loaded)
  final tbScore = tablebaseLoader.probe(_occ(pos.white), _occ(pos.black), pos.sideToMove);
  if (tbScore != null) return tbScore;
  
  // Fallback: simple terminal heuristic for positions not in tablebase
  final wc = _popcount(_occ(pos.white));
  final bc = _popcount(_occ(pos.black));
  final placementsDone = _piecesLeft(pos.white) == 0 && _piecesLeft(pos.black) == 0;
  
  if (placementsDone) {
    final stmCount = pos.sideToMove == 0 ? wc : bc;
    final oppCount = pos.sideToMove == 0 ? bc : wc;
    if (stmCount < 3) return -inf + 1000; // side to move already lost
    if (oppCount < 3) return inf - 1000;  // opponent already lost
  }
  return null;
}

// Allow callers to signal when all placements are done (so generator avoids extra drops).
void setPlacementComplete(bool done) {
  _placementCompleteOverride = done;
}

// ===== move packing (for TT / ordering) =====
int _packMove(Move m) {
  final f = m.from + 1; // -1 becomes 0
  final t = m.to + 1;
  final r = m.remove + 1;
  return f | (t << 5) | (r << 10);
}

Move? _unpackMove(int data) {
  if (data == 0) return null;
  final f = (data & 0x1F) - 1;
  final t = ((data >> 5) & 0x1F) - 1;
  final r = ((data >> 10) & 0x1F) - 1;
  return Move(f, t, r);
}

bool _sameMove(Move a, Move b) =>
    a.from == b.from && a.to == b.to && a.remove == b.remove;

// ===== search (PVS + Quiescence + LMR + Futility + Razoring) =====
Move? searchBestMove(Position root, int maxDepth,
    {int maxNodes = 50000000, int maxMillis = 10000}) {
  _placementCompleteOverride = _piecesLeft(root.white) == 0 && _piecesLeft(root.black) == 0;
  loadOpeningBook();
  final book = _openingBook[root.zobristKey];
  if (book != null) return book;

  _maxNodes = maxNodes;
  _maxMillis = maxMillis;
  _nodes = 0;
  _stopSearch = false;
  _timer = Stopwatch()..start();

  Move? bestSoFar;
  var alpha = -inf;
  var beta = inf;
  var lastScore = 0;

  // Iterative deepening with Aspiration Windows
  for (var depth = 1; depth <= maxDepth; depth++) {
    var aspirationAlpha = alpha;
    var aspirationBeta = beta;
    
    // Use aspiration window after depth 3
    if (depth >= 4) {
      const aspirationWindow = 50;
      aspirationAlpha = max(-inf, lastScore - aspirationWindow);
      aspirationBeta = min(inf, lastScore + aspirationWindow);
    }
    
    var score = _negascout(root, depth, aspirationAlpha, aspirationBeta, 0);
    
    // Re-search with full window if aspiration fails
    if (score <= aspirationAlpha || score >= aspirationBeta) {
      score = _negascout(root, depth, -inf, inf, 0);
    }
    
    if (_stopSearch) break;
    
    lastScore = score;
    final ttMove = _probeBestMove(root.zobristKey);
    if (ttMove != null) {
      bestSoFar = ttMove;
    }
  }

  _timer.stop();
  return bestSoFar;
}

int _negascout(Position pos, int depth, int alpha, int beta, int ply) {
  if (_shouldStop()) {
    _stopSearch = true;
    return _evalToMove(pos);
  }
  _nodes++;

  final tb = queryTablebase(pos);
  if (tb != null) return pos.sideToMove == 0 ? tb : -tb;

  if (depth <= 0) {
    return _quiescence(pos, alpha, beta, ply);
  }

  // Razoring: At low depth, if eval is far below alpha, go straight to qsearch
  if (depth <= 3 && ply > 0 && alpha < inf - 100) {
    final staticEval = _evalToMove(pos);
    const razorMargin = 300;
    if (staticEval + razorMargin * depth < alpha) {
      final qScore = _quiescence(pos, alpha, beta, ply);
      if (qScore <= alpha) return qScore;
    }
  }

  // Null Move Pruning: Give opponent a free move; if still winning, prune.
  const nullMoveReduction = 3; // More aggressive R=3
  if (depth >= 3 && ply > 0 && beta < inf - 100) {
    final nullPos = Position(pos.black, pos.white, pos.sideToMove ^ 1, 0);
    nullPos.zobristKey = _recomputeZobrist(nullPos);
    
    final nullScore = -_negascout(nullPos, depth - 1 - nullMoveReduction, -beta, -beta + 1, ply + 1);
    if (nullScore >= beta) {
      return beta; // Null move cutoff
    }
  }

  // Futility Pruning: At low depth, skip quiet moves if eval far below alpha
  var futilityPruning = false;
  if (depth <= 2 && ply > 0 && alpha < inf - 100) {
    final staticEval = _evalToMove(pos);
    const futilityMargin = 500;
    if (staticEval + futilityMargin * depth < alpha) {
      futilityPruning = true;
    }
  }

  final alphaOrig = alpha;
  final idx = pos.zobristKey & ttMask;
  final savedKey = _ttKey[idx];
  Move? ttBest;
  
  if (savedKey == pos.zobristKey) {
    final entryDepth = _ttDepth[idx];
    if (entryDepth >= depth) {
      final val = _ttVal[idx];
      final flag = _ttFlag[idx];
      if (flag == ttExact) return val;
      if (flag == ttLower && val > alpha) alpha = val;
      if (flag == ttUpper && val < beta) beta = val;
      if (alpha >= beta) return val;
    }
    ttBest = _unpackMove(_ttMove[idx]);
  }

  final moves = genMoves(pos);
  if (moves.isEmpty) {
    return -inf + ply;
  }

  _orderMoves(moves, ttBest, ply);

  var bestScore = -inf;
  Move? bestMove;
  var cutoffCount = 0; // For multi-cut
  
  // PVS: Search first move with full window, others with null window
  for (var i = 0; i < moves.length; i++) {
    final m = moves[i];
    
    // Futility pruning: skip quiet moves late in search if hopeless
    if (futilityPruning && i > 0 && m.remove < 0) {
      continue; // Skip this quiet move
    }
    
    final child = makeMove(pos, m);
    var score = 0;

    // Mill Formation Extension: Extend when forming a mill
    var extension = 0;
    if (m.remove >= 0 && depth < maxPly - 2) {
      extension = 1; // Extend 1 ply for mill formations
    }

    // LMR: Reduce depth for late quiet moves
    var reduction = 0;
    if (depth >= 3 && i > 3 && m.remove < 0 && extension == 0) {
      reduction = 1;
      if (i > 8) reduction = 2;
      if (i > 15) reduction = 3;
    }

    if (i == 0) {
      score = -_negascout(child, depth - 1 + extension, -beta, -alpha, ply + 1);
    } else {
      // Null window search
      score = -_negascout(child, depth - 1 + extension - reduction, -alpha - 1, -alpha, ply + 1);
      
      // Re-search if LMR failed or null window failed high
      if (score > alpha && (score < beta || reduction > 0)) {
         score = -_negascout(child, depth - 1 + extension, -beta, -alpha, ply + 1);
      }
    }

    if (_stopSearch) return alpha;

    if (score > bestScore) {
      bestScore = score;
      bestMove = m;
    }
    
    if (score > alpha) {
      alpha = score;
      if (ply < maxPly && m.remove < 0) {
        _history[m.from + 1][m.to] += depth * depth;
      }
    }
    
    if (alpha >= beta) {
      if (ply < maxPly && m.remove < 0) {
        final killers = _killer[ply];
        if (killers[0] == null || !_sameMove(killers[0]!, m)) {
          killers[1] = killers[0];
          killers[0] = m;
        }
      }
      cutoffCount++;
      // Multi-cut: If we get 2+ cutoffs at depth >= 3, position is very good
      if (cutoffCount >= 2 && depth >= 3) {
        return beta; // Multi-cut prune
      }
      break; // Beta cutoff
    }
  }

  if (depth >= _ttDepth[idx] || savedKey != pos.zobristKey) {
    _ttKey[idx] = pos.zobristKey;
    _ttDepth[idx] = depth;
    _ttMove[idx] = bestMove == null ? 0 : _packMove(bestMove);
    _ttVal[idx] = bestScore;
    if (bestScore <= alphaOrig) {
      _ttFlag[idx] = ttUpper;
    } else if (bestScore >= beta) { // Use current beta (which might be original beta)
      _ttFlag[idx] = ttLower;
    } else {
      _ttFlag[idx] = ttExact;
    }
  }
  return bestScore;
}

int _quiescence(Position pos, int alpha, int beta, int ply) {
  _nodes++;
  if (_shouldStop()) return _evalToMove(pos);

  // Stand-pat
  final standPat = _evalToMove(pos);
  if (standPat >= beta) return beta;
  if (standPat > alpha) alpha = standPat;
  
  if (ply >= maxPly) return standPat;

  // Generate only captures (moves that remove a piece)
  // In 9MM, a move that forms a mill allows removing a piece.
  // So we look for moves where m.remove >= 0.
  // Note: genMoves generates all moves. We filter them.
  // Optimization: pass a flag to genMoves to only generate captures?
  // For now, just filter.
  final moves = genMoves(pos); 
  // Sort captures? usually good.
  // Simple sort: captures are already prioritized in _orderMoves but we can just pick them.
  
  for (final m in moves) {
    if (m.remove < 0) continue; // Only captures in Q-search
    
    final child = makeMove(pos, m);
    final score = -_quiescence(child, -beta, -alpha, ply + 1);
    
    if (score >= beta) return beta;
    if (score > alpha) alpha = score;
  }
  
  return alpha;
}

bool _shouldStop() =>
    _nodes >= _maxNodes || (_maxMillis > 0 && _timer.elapsedMilliseconds >= _maxMillis);

Move? _probeBestMove(int key) {
  final idx = key & ttMask;
  if (_ttKey[idx] == key) {
    return _unpackMove(_ttMove[idx]);
  }
  return null;
}

void _orderMoves(List<Move> moves, Move? ttMove, int ply) {
  moves.sort((a, b) => _scoreMove(b, ttMove, ply).compareTo(_scoreMove(a, ttMove, ply)));
}

int _scoreMove(Move m, Move? ttMove, int ply) {
  if (ttMove != null && _sameMove(m, ttMove)) return 1 << 25; // PV move huge bonus
  var score = 0;
  
  // Captures are very important
  if (m.remove >= 0) score += 1 << 20;

  // Killer moves
  final killers = ply < _killer.length ? _killer[ply] : null;
  if (killers != null) {
    if (killers[0] != null && _sameMove(m, killers[0]!)) score += 1 << 18;
    if (killers[1] != null && _sameMove(m, killers[1]!)) score += 1 << 17;
  }

  // History heuristic
  final hist = _history[m.from + 1][m.to];
  // Cap history impact to avoid overshadowing captures too much, but it scales with depth^2
  score += hist;
  
  return score;
}

// ===== evaluation =====
int _evalToMove(Position pos) {
  final eval = _evaluate(pos);
  return pos.sideToMove == 0 ? eval : -eval;
}

int _evaluate(Position pos) {
  final wOcc = _occ(pos.white);
  final bOcc = _occ(pos.black);
  final wc = _popcount(wOcc);
  final bc = _popcount(bOcc);
  
  // Material is EVERYTHING - massively weighted for survival
  var score = (wc - bc) * 10000;

  // Mills are game-winning
  final millsW = _countMills(wOcc);
  final millsB = _countMills(bOcc);
  score += (millsW - millsB) * 4000;

  // Double mills (absolutely devastating)
  final doubleMillsW = _countDoubleMills(wOcc);
  final doubleMillsB = _countDoubleMills(bOcc);
  score += (doubleMillsW - doubleMillsB) * 5500;

  // Potential mills - critical
  final potentialW = _countPotentialMills(wOcc, bOcc);
  final potentialB = _countPotentialMills(bOcc, wOcc);
  score += (potentialW - potentialB) * 1500;

  // Mobility (freedom to move)
  // Calculating exact moves is expensive, so we estimate or use the generator if cheap.
  // Since we are in eval, let's use a cheaper estimation or just the generator if we accept the cost.
  // For "Extreme" AI, we can afford a bit more cost for better quality.
  final myMoves = genMoves(pos).length;
  // We need opponent moves too.
  final opp = Position(pos.black, pos.white, pos.sideToMove ^ 1, 0);
  opp.zobristKey = _recomputeZobrist(opp); // cached/incremental would be better but this is safe
  final oppMoves = genMoves(opp).length;
  
  // Strong bias toward restricting the opponent while keeping initiative.
  score += (myMoves - oppMoves) * 140;
  
  // Blocked pieces (pieces that can't move) - CATASTROPHIC!
  if (myMoves == 0 && wc > 2) score -= 50000; // Instant loss!
  if (oppMoves == 0 && bc > 2) score += 50000; // Instant win!

  final phaseScore = _phaseBonus(pos, wc, bc);
  score += phaseScore;

  return score;
}

int _countDoubleMills(int bb) {
  // A piece is in a double mill if it belongs to two different mills.
  // We can iterate squares and check if they are part of >1 mills.
  var doubleMills = 0;
  var temp = bb;
  while (temp != 0) {
    final sq = _lsb(temp);
    var millCount = 0;
    for (final mask in _millsBySquare[sq]) {
      if ((bb & mask) == mask) millCount++;
    }
    if (millCount >= 2) doubleMills++;
    temp &= temp - 1;
  }
  return doubleMills;
}

int _phaseBonus(Position pos, int wc, int bc) {
  final phase = _detectPhase(pos, wc, bc, pos.sideToMove == 0 ? wc : bc);
  switch (phase) {
    case phasePlacing:
      // Rapid development is critical
      return (wc - bc) * 200;
    case phaseMoving:
      // Standard middlegame
      return 0;
    case phaseFlying:
      // Flying phase - MASSIVE bonus for having 4+ pieces
      final safe = (wc >= 4 ? 500 : 0) - (bc >= 4 ? 500 : 0);
      return safe;
    default:
      return 0;
  }
}

int _detectPhase(Position pos, int wc, int bc, int stmCount) {
  final wLeft = _piecesLeft(pos.white);
  final bLeft = _piecesLeft(pos.black);
  if (!_placementCompleteOverride && (wLeft > 0 || bLeft > 0)) {
    return phasePlacing;
  }
  // Flying: side to move at 3 or fewer pieces after placing finished.
  if (stmCount <= 3) return phaseFlying;
  return phaseMoving;
}

int _countMills(int bb) {
  var count = 0;
  for (final mask in MILL_MASKS) {
    if (mask != 0 && (bb & mask) == mask) count++;
  }
  return count;
}

int _countPotentialMills(int me, int opp) {
  // Count lines where we have 2 and the third is empty.
  var count = 0;
  for (final mask in MILL_MASKS) {
    if (mask == 0) continue;
    final ours = me & mask;
    final theirs = opp & mask;
    final empties = mask & ~me & ~opp;
    if (theirs == 0 && _popcount(ours) == 2 && empties != 0) count++;
  }
  return count;
}

// ===== make / generate moves =====
Position makeMove(Position pos, Move m) {
  final side = pos.sideToMove;
  final rawUs = side == 0 ? pos.white : pos.black;
  final rawThem = side == 0 ? pos.black : pos.white;
  var usOcc = _occ(rawUs);
  var themOcc = _occ(rawThem);
  var usLeft = _piecesLeft(rawUs);
  final themLeft = _piecesLeft(rawThem);
  final toMask = _bit(m.to);
  final fromMask = m.from >= 0 ? _bit(m.from) : 0;

  var key = pos.zobristKey ^ zobristSide; // toggle side

  if (m.from >= 0) {
    usOcc &= ~fromMask;
    key ^= zobristPiece[m.from][side];
  } else if (usLeft > 0) {
    key ^= zobristPiecesLeft[side][usLeft];
    usLeft -= 1;
    key ^= zobristPiecesLeft[side][usLeft];
  }
  usOcc |= toMask;
  key ^= zobristPiece[m.to][side];

  if (m.remove >= 0) {
    final rm = _bit(m.remove);
    themOcc &= ~rm;
    key ^= zobristPiece[m.remove][side ^ 1];
  }

  final newUs = _withPiecesLeft(usOcc, usLeft);
  final newThem = _withPiecesLeft(themOcc, themLeft);

  if (side == 0) {
    return Position(newUs, newThem, 1, key);
  } else {
    return Position(newThem, newUs, 0, key);
  }
}

bool _formsMill(int board, int sq) => _isInMill(board, sq);

bool _isInMill(int board, int sq) {
  for (final mask in _millsBySquare[sq]) {
    if ((board & mask) == mask) return true;
  }
  return false;
}

void _addStepOrFlyMove(
    int from, int to, int myBoard, int oppBoard, List<Move> moves) {
  final newBoard = (myBoard & ~_bit(from)) | _bit(to);
  final mill = _formsMill(newBoard, to);
  if (mill) {
    _addCaptures(from, to, oppBoard, moves);
  } else {
    moves.add(Move(from, to, -1));
  }
}

final List<int> _removalBuf = <int>[];

void _addCaptures(int from, int to, int oppBoard, List<Move> moves) {
  final removals = _collectRemovals(oppBoard);
  if (removals.isEmpty) {
    // Should not happen (no opponent pieces), but keep move legal.
    moves.add(Move(from, to, -1));
    return;
  }
  for (final r in removals) {
    moves.add(Move(from, to, r));
  }
}

List<int> _collectRemovals(int oppBoard) {
  final out = (_removalBuf..clear());
  var tmp = oppBoard;
  while (tmp != 0) {
    final sq = _lsb(tmp);
    if (!_isInMill(oppBoard, sq)) out.add(sq);
    tmp &= tmp - 1;
  }
  if (out.isNotEmpty) return out;
  // All opponent pieces are in mills, so any is legal.
  tmp = oppBoard;
  while (tmp != 0) {
    final sq = _lsb(tmp);
    out.add(sq);
    tmp &= tmp - 1;
  }
  return out;
}

List<Move> genMoves(Position pos) {
  // NOTE: Keeps allocations low via shared buffer; returns a defensive copy.
  final moves = (_moveBuf..clear());
  final rawMy = pos.sideToMove == 0 ? pos.white : pos.black;
  final rawOpp = pos.sideToMove == 0 ? pos.black : pos.white;
  final myBoard = _occ(rawMy);
  final oppBoard = _occ(rawOpp);
  final empty = ~(myBoard | oppBoard) & _boardMask;

  final myCount = _popcount(myBoard);
  final myLeft = _piecesLeft(rawMy);
  final oppLeft = _piecesLeft(rawOpp);
  final placingPhase = myLeft > 0 || oppLeft > 0;
  final canFly = !placingPhase && myCount <= 3;

  if (placingPhase && myLeft > 0) {
    for (var to = 0; to < boardSize; to++) {
      if ((empty & _bit(to)) == 0) continue;
      final newBoard = myBoard | _bit(to);
      final mill = _formsMill(newBoard, to);
      if (mill) {
        _addCaptures(-1, to, oppBoard, moves);
      } else {
        moves.add(Move(-1, to, -1));
      }
    }
    return List<Move>.from(moves);
  }

  for (var from = myBoard; from != 0; from &= from - 1) {
    final src = _lsb(from);
    if (canFly) {
      for (var to = 0; to < boardSize; to++) {
        if ((empty & _bit(to)) == 0) continue;
        _addStepOrFlyMove(src, to, myBoard, oppBoard, moves);
      }
    } else {
      for (final to in ADJ[src]) {
        if ((empty & _bit(to)) == 0) continue;
        _addStepOrFlyMove(src, to, myBoard, oppBoard, moves);
      }
    }
  }

  // Defensive copy avoids aliasing across recursive calls.
  return List<Move>.from(moves);
}

// ===== opening / tablebase hooks =====
void loadOpeningBook() {
  if (_bookLoaded) return;
  if (!_zobristReady) initZobrist(); // ensure hashing is ready
  _bookLoaded = true;
  // Embedded minimal book; replace or extend with your own data. Keys are "white/black/stm".
  const Map<String, List<int>> raw = _embeddedOpeningBook;
  _openingBook.clear();
  for (final entry in raw.entries) {
    final parts = entry.key.split('/');
    if (parts.length != 3) continue;
    final wParts = parts[0].split('|');
    final bParts = parts[1].split('|');
    final w = int.parse(wParts[0]);
    final b = int.parse(bParts[0]);
    final wLeft = wParts.length > 1 ? int.parse(wParts[1]) : 9;
    final bLeft = bParts.length > 1 ? int.parse(bParts[1]) : 9;
    final stm = int.parse(parts[2]);
    final moveList = entry.value;
    if (moveList.length < 2) continue;
    final mv = Move(moveList[0], moveList[1], moveList.length > 2 ? moveList[2] : -1);
    final pos = Position(_withPiecesLeft(w, wLeft), _withPiecesLeft(b, bLeft), stm, 0);
    pos.zobristKey = _recomputeZobrist(pos);
    _openingBook[pos.zobristKey] = mv;
  }
  // To integrate a larger JSON book, generate the same "w/b/stm" keys and call loadOpeningBook
  // after populating _embeddedOpeningBook (or swap to a runtime asset read).
}

void buildTablebase() {
  if (_tablebaseLoaded) return;
  if (!_zobristReady) initZobrist();
  _tablebaseLoaded = true;
  _tablebase.clear();
  // Minimal embedded exact values; extend with real tablebase data.
  for (final entry in _embeddedTablebase.entries) {
    final parts = entry.key.split('/');
    if (parts.length != 3) continue;
    final wParts = parts[0].split('|');
    final bParts = parts[1].split('|');
    final w = int.parse(wParts[0]);
    final b = int.parse(bParts[0]);
    final wLeft = wParts.length > 1 ? int.parse(wParts[1]) : 9;
    final bLeft = bParts.length > 1 ? int.parse(bParts[1]) : 9;
    final stm = int.parse(parts[2]);
    final pos = Position(_withPiecesLeft(w, wLeft), _withPiecesLeft(b, bLeft), stm, 0);
    pos.zobristKey = _recomputeZobrist(pos);
    _tablebase[pos.zobristKey] = entry.value;
  }
}

// ===== isolate hint =====
void useIsolateWhenIntegrated() {
  // Touch isolate API to keep analyzer happy with the import.
  if (Isolate.current.debugName == 'extreme_ai_hint') {
    // no-op
  }
  // In Flutter, run heavy search off the UI thread:
  // final port = ReceivePort();
  // Isolate.spawn((SendPort send) async {
  //   final best = await Isolate.run(() => searchBestMove(root, depth));
  //   send.send(best);
  // }, port.sendPort);
  // Listen on port in UI and update state when best arrives, then close port.
}

// ===== test harness =====
void main() {
  initZobrist(42);
  final root = Position(9 << _piecesShift, 9 << _piecesShift, 0, 0);
  root.zobristKey = _recomputeZobrist(root);

  final best = searchBestMove(root, 12, maxNodes: 50000000, maxMillis: 10000);
  // ignore: avoid_print
  print('Nodes searched: $_nodes');
  // ignore: avoid_print
  print('Best move: ${best ?? 'none'}');
}

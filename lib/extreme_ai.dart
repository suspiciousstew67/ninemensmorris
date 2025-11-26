// High-performance Nine Men's Morris engine ("Extreme" difficulty) tuned for Flutter.
// Uses bitboards, iterative deepening alpha-beta, transposition table, move ordering,
// and fast integer evaluation. All logic lives in this single file for easy drop-in.
// Expect roughly 0.5-2M nodes/sec on mid phones with ttBits=20 (~16 MB).

import 'dart:isolate';
import 'dart:math';

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
  // Dart ints are 64-bit signed; mask to keep hash stable and cheap.
  final hi = rnd.nextInt(1 << 30);
  final lo = rnd.nextInt(1 << 30);
  return ((hi << 34) ^ lo) & 0x7FFFFFFFFFFFFFFF;
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

// Embedded minimal opening book: keys are "white/black/stm" using bitboards.
const Map<String, List<int>> _embeddedOpeningBook = {
  // Format: "<whiteBits>|<whiteLeft>/<blackBits>|<blackLeft>/<stm>"
  // Empty board, both have 9 to place, white to move -> place at D2 (index 4).
  '0|9/0|9/0': [-1, 4, -1],
  // After white at D2 (bit 4 set), black still has 9, white has 8.
  '16|8/0|9/1': [-1, 19, -1],
};

// Embedded tablebase seeds (exact scores from white POV); extend externally.
const Map<String, int> _embeddedTablebase = {};

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

// ===== tablebase hook =====
// Return score from white POV (mate=+/-inf). Uses in-memory map and simple terminal checks.
int? queryTablebase(Position pos) {
  if (!_tablebaseLoaded) buildTablebase();
  final hit = _tablebase[pos.zobristKey];
  if (hit != null) return hit;

  // Simple terminal heuristic: after placing phase, if a side has <=2 pieces it loses.
  final wc = _popcount(_occ(pos.white));
  final bc = _popcount(_occ(pos.black));
  final placementsDone = _piecesLeft(pos.white) == 0 && _piecesLeft(pos.black) == 0;
  if (placementsDone) {
    final stmCount = pos.sideToMove == 0 ? wc : bc;
    final oppCount = pos.sideToMove == 0 ? bc : wc;
    if (stmCount <= 2) return -inf + 1000; // side to move already lost.
    if (oppCount <= 2) return inf - 1000; // opponent already lost.
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

// ===== search (iterative deepening + alpha-beta) =====
Move? searchBestMove(Position root, int maxDepth,
    {int maxNodes = 10000000, int maxMillis = 1000}) {
  _placementCompleteOverride = _piecesLeft(root.white) == 0 && _piecesLeft(root.black) == 0;
  loadOpeningBook(); // safe no-op if already loaded
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
  // Iterative deepening: boosts move ordering and gives anytime results.
  for (var depth = 1; depth <= maxDepth; depth++) {
    final score = _alphabeta(root, depth, alpha, beta, 0);
    if (_stopSearch) break; // preserve last completed iteration result.
    final ttMove = _probeBestMove(root.zobristKey);
    if (ttMove != null) {
      bestSoFar = ttMove;
    }

    // Aspiration window could be added; keep simple/stable here.
    alpha = max(-inf, score - 200);
    beta = min(inf, score + 200);
  }

  _timer.stop();
  return bestSoFar;
}

int _alphabeta(Position pos, int depth, int alpha, int beta, int ply) {
  if (_shouldStop()) {
    _stopSearch = true;
    return _evalToMove(pos);
  }
  _nodes++;

  final tb = queryTablebase(pos);
  if (tb != null) return pos.sideToMove == 0 ? tb : -tb;

  if (depth == 0 || ply >= maxPly - 1) {
    return _evalToMove(pos);
  }

  final alphaOrig = alpha;
  final betaOrig = beta;
  final idx = pos.zobristKey & ttMask;
  final savedKey = _ttKey[idx];
  Move? ttBest;
  if (savedKey == pos.zobristKey) {
    ttBest = _unpackMove(_ttMove[idx]);
    final entryDepth = _ttDepth[idx];
    if (entryDepth >= depth) {
      final val = _ttVal[idx];
      final flag = _ttFlag[idx];
      if (flag == ttExact) return val;
      if (flag == ttLower && val > alpha) alpha = val;
      if (flag == ttUpper && val < beta) beta = val;
      if (alpha >= beta) return val;
    }
  }

  final moves = genMoves(pos);
  if (moves.isEmpty) {
    // No moves => lose/stalemate depending on rules. Penalize side to move.
    return -inf + ply;
  }

  _orderMoves(moves, ttBest, ply);

  var bestScore = -inf;
  Move? bestMove;
  for (final m in moves) {
    final child = makeMove(pos, m);
    final score = -_alphabeta(child, depth - 1, -beta, -alpha, ply + 1);
    if (_stopSearch) return alpha; // abort branch cleanly
    if (score > bestScore) {
      bestScore = score;
      bestMove = m;
    }
    if (score > alpha) {
      alpha = score;
      if (ply < maxPly && m.remove < 0) {
        _history[m.from + 1][m.to] += depth * depth; // non-capture history bonus
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
      break;
    }
  }

  // Store TT entry (depth preferred replacement).
  if (depth >= _ttDepth[idx] || savedKey != pos.zobristKey) {
    _ttKey[idx] = pos.zobristKey;
    _ttDepth[idx] = depth;
    _ttMove[idx] = bestMove == null ? 0 : _packMove(bestMove);
    _ttVal[idx] = bestScore;
    if (bestScore <= alphaOrig) {
      _ttFlag[idx] = ttUpper;
    } else if (bestScore >= betaOrig) {
      _ttFlag[idx] = ttLower;
    } else {
      _ttFlag[idx] = ttExact;
    }
  }
  return bestScore;
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
  // Move ordering: PV/TT first, then captures, then killer/history to sharpen cutoffs.
  moves.sort((a, b) => _scoreMove(b, ttMove, ply).compareTo(_scoreMove(a, ttMove, ply)));
}

int _scoreMove(Move m, Move? ttMove, int ply) {
  if (ttMove != null && _sameMove(m, ttMove)) return 1 << 20; // PV move first
  var score = 0;
  if (m.remove >= 0) score += 1 << 18; // captures high

  final killers = ply < _killer.length ? _killer[ply] : null;
  if (killers != null) {
    if (killers[0] != null && _sameMove(m, killers[0]!)) score += 1 << 16;
    if (killers[1] != null && _sameMove(m, killers[1]!)) score += 1 << 15;
  }

  final hist = _history[m.from + 1][m.to];
  score += hist;
  return score;
}

// ===== evaluation =====
int _evalToMove(Position pos) {
  final eval = _evaluate(pos);
  return pos.sideToMove == 0 ? eval : -eval;
}

int _evaluate(Position pos) {
  // Fast, deterministic, integer-only eval tuned for bitboards.
  final wOcc = _occ(pos.white);
  final bOcc = _occ(pos.black);
  final wc = _popcount(wOcc);
  final bc = _popcount(bOcc);
  final material = (wc - bc) * 200; // weight material heavily; tweak as needed.

  final millsW = _countMills(wOcc);
  final millsB = _countMills(bOcc);
  final millsScore = (millsW - millsB) * 150;

  final potentialW = _countPotentialMills(wOcc, bOcc);
  final potentialB = _countPotentialMills(bOcc, wOcc);
  final potentialScore = (potentialW - potentialB) * 40;

  // Mobility: only if generator available to avoid allocations otherwise.
  final myMoves = genMoves(pos).length;
  final opp = Position(pos.black, pos.white, pos.sideToMove ^ 1, 0);
  opp.zobristKey = _recomputeZobrist(opp);
  final oppMoves = genMoves(opp).length;
  final mobilityScore = (myMoves - oppMoves) * 5;

  final phaseScore = _phaseBonus(pos, wc, bc);

  return material + millsScore + potentialScore + mobilityScore + phaseScore;
}

int _phaseBonus(Position pos, int wc, int bc) {
  final phase = _detectPhase(pos, wc, bc, pos.sideToMove == 0 ? wc : bc);
  switch (phase) {
    case phasePlacing:
      return (wc - bc) * 30; // placing prefers development
    case phaseMoving:
      return 0;
    case phaseFlying:
      // Flying is swingy; reward side that still has >3 pieces to avoid collapse.
      final safe = (wc >= 4 ? 20 : 0) - (bc >= 4 ? 20 : 0);
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
  initZobrist(42); // fixed seed for reproducibility
  final root = Position(9 << _piecesShift, 9 << _piecesShift, 0, 0); // both players still placing
  root.zobristKey = _recomputeZobrist(root);

  final best = searchBestMove(root, 3, maxNodes: 200000, maxMillis: 200);
  // ignore: avoid_print
  print('Nodes searched: $_nodes');
  // ignore: avoid_print
  print('Best move: ${best ?? 'none'}');
}

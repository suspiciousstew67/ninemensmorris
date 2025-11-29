// Simple mode adapter for extreme AI engine
// Adapts the extreme AI search for Simple mode (placement-only, first mill wins)

import 'dart:math';
import 'dart:typed_data';

// Mill configurations (MUST MATCH main.dart GameEngine)
final List<int> _millMasks = _buildMillMasks();

List<int> _buildMillMasks() {
  int m(int a, int b, int c) => (1 << a) | (1 << b) | (1 << c);
  return [
    // Outer
    m(0, 1, 2), m(2, 3, 4), m(4, 5, 6), m(6, 7, 0),
    // Middle
    m(8, 9, 10), m(10, 11, 12), m(12, 13, 14), m(14, 15, 8),
    // Inner
    m(16, 17, 18), m(18, 19, 20), m(20, 21, 22), m(22, 23, 16),
    // Connections
    m(1, 9, 17), m(3, 11, 19), m(5, 13, 21), m(7, 15, 23),
  ];
}

const int boardSize = 24;
const int inf = 1000000000;

// Zobrist hashing
final Uint64List _zobristTable = Uint64List(boardSize * 2 + 1);
bool _zobristInitialized = false;

void _initZobrist() {
  if (_zobristInitialized) return;
  final rnd = Random(12345);
  for (var i = 0; i < _zobristTable.length; i++) {
    // Generate 64-bit random number
    final h = (rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32);
    _zobristTable[i] = h;
  }
  _zobristInitialized = true;
}

int _computeHash(int white, int black, int sideToMove) {
  if (!_zobristInitialized) _initZobrist();
  var h = 0;
  for (var i = 0; i < boardSize; i++) {
    if ((white & (1 << i)) != 0) h ^= _zobristTable[i * 2];
    if ((black & (1 << i)) != 0) h ^= _zobristTable[i * 2 + 1];
  }
  if (sideToMove == 1) h ^= _zobristTable[boardSize * 2];
  return h;
}

// Transposition Table
class _TTEntry {
  int key = 0;
  int depth = 0;
  int score = 0;
  int flag = 0; // 0=exact, 1=lower, 2=upper
  int bestMove = -1;
}

const int _ttSize = 1 << 20; // ~1M entries
final List<_TTEntry> _tt = List.generate(_ttSize, (_) => _TTEntry());

class SimplePosition {
  final int white;
  final int black;
  final int whitePiecesLeft;
  final int blackPiecesLeft;
  final int sideToMove;
  final int hash;
  
  SimplePosition(this.white, this.black, this.whitePiecesLeft, this.blackPiecesLeft, this.sideToMove, [int? hash])
      : hash = hash ?? _computeHash(white, black, sideToMove);
}

class SimpleMove {
  final int to;
  const SimpleMove(this.to);
}

int _popcount(int bits) {
  var count = 0;
  while (bits != 0) {
    bits &= bits - 1;
    count++;
  }
  return count;
}

bool _formsMill(int board, int sq) {
  for (final mask in _millMasks) {
    if ((mask & (1 << sq)) != 0 && (board & mask) == mask) {
      return true;
    }
  }
  return false;
}

int _countMills(int board) {
  var count = 0;
  for (final mask in _millMasks) {
    if (mask != 0 && (board & mask) == mask) count++;
  }
  return count;
}

int _countPotentialMills(int me, int opp) {
  var count = 0;
  for (final mask in _millMasks) {
    if (mask == 0) continue;
    final ours = me & mask;
    final theirs = opp & mask;
    final empties = mask & ~me & ~opp;
    if (theirs == 0 && _popcount(ours) == 2 && empties != 0) count++;
  }
  return count;
}

// Check for "Double Threats" (Forks) - creating 2 potential mills at once
int _countDoubleThreats(int me, int opp) {
  // A double threat is a move that creates >= 2 potential mills
  // We can approximate this by checking intersections of potential mills
  // Or simpler: count how many empty spots complete a mill. 
  // If placing a piece creates 2 threats, that's a fork.
  
  // This function is expensive, so we use a heuristic in evaluation instead:
  // If we have multiple potential mills that share an empty spot? 
  // No, a fork is when we place a piece and it creates 2 separate threats.
  // In placement phase, we just count existing potential mills.
  // If count > 1, and they don't share the SAME missing piece (which they can't in placement usually),
  // it's a strong position.
  
  // Better heuristic: Count empty squares that would complete a mill for me
  int threats = 0;
  int threatMask = 0;
  
  for (final mask in _millMasks) {
    if (mask == 0) continue;
    final ours = me & mask;
    final theirs = opp & mask;
    final empties = mask & ~me & ~opp;
    
    if (theirs == 0 && _popcount(ours) == 2) {
      // This is a threat!
      if ((threatMask & empties) != 0) {
        // This empty square is ALREADY a threat for another mill!
        // This means filling this square completes TWO mills? No.
        // It means we have multiple threats.
      }
      threatMask |= empties;
      threats++;
    }
  }
  
  // If we have >= 2 threats, can the opponent block them all?
  // In placement phase, opponent places 1 piece.
  // If we have 2 threats on DIFFERENT squares, opponent can only block one. -> WIN
  // If we have 2 threats on the SAME square (is that possible?), opponent blocks both.
  
  // Actually, in placement, "threat" means "I have 2 pieces, need 1 more".
  // If I have 2 such configurations, and the missing pieces are different squares, I win next turn.
  
  if (threats >= 2) {
     // Check if threats are disjoint (require different squares)
     // In 9MM, potential mills usually require different squares unless they share a corner?
     // Actually, if I have (A1, A4) and (G1, D1), I need A7 and G7.
     // If I have (A1, D1) and (A1, A4)? No, A1 is used.
     // The "empty" spot is what matters.
     // If the empty spots are distinct, it's a double threat.
     if (_popcount(threatMask) >= 2) return 1;
  }
  
  return 0;
}

List<SimpleMove> generateMoves(SimplePosition pos) {
  final moves = <SimpleMove>[];
  final myBoard = pos.sideToMove == 0 ? pos.white : pos.black;
  final oppBoard = pos.sideToMove == 0 ? pos.black : pos.white;
  final occupied = myBoard | oppBoard;
  
  for (var sq = 0; sq < boardSize; sq++) {
    if ((occupied & (1 << sq)) == 0) {
      moves.add(SimpleMove(sq));
    }
  }
  
  return moves;
}

SimplePosition makeMove(SimplePosition pos, SimpleMove move) {
  final myBoard = pos.sideToMove == 0 ? pos.white : pos.black;
  final oppBoard = pos.sideToMove == 0 ? pos.black : pos.white;
  final newMy = myBoard | (1 << move.to);
  final myLeft = pos.sideToMove == 0 ? pos.whitePiecesLeft : pos.blackPiecesLeft;
  final oppLeft = pos.sideToMove == 0 ? pos.blackPiecesLeft : pos.whitePiecesLeft;
  
  // Update hash incrementally
  var h = pos.hash;
  h ^= _zobristTable[move.to * 2 + (pos.sideToMove == 0 ? 0 : 1)]; // Add piece
  h ^= _zobristTable[boardSize * 2]; // Switch side
  
  final newPos = SimplePosition(
      pos.sideToMove == 0 ? newMy : oppBoard,
      pos.sideToMove == 0 ? oppBoard : newMy,
      myLeft - 1,
      oppLeft,
      pos.sideToMove == 0 ? 1 : 0,
      h // Pass hash here
  );
  return newPos;
}

int evaluate(SimplePosition pos) {
  final wOcc = pos.white;
  final bOcc = pos.black;
  final wc = _popcount(wOcc);
  final bc = _popcount(bOcc);
  
  // Mills are the WIN CONDITION
  final millsW = _countMills(wOcc);
  final millsB = _countMills(bOcc);
  if (millsW > 0) return 100000; 
  if (millsB > 0) return -100000;
  
  // Potential mills (2 pieces + 1 empty)
  final potentialW = _countPotentialMills(wOcc, bOcc);
  final potentialB = _countPotentialMills(bOcc, wOcc);
  
  // CRITICAL FIX: If it is my turn and I have a potential mill, I WIN IMMEDIATELY.
  // In Simple Mode (placement only), I can just place the piece and win.
  if (pos.sideToMove == 0 && potentialW > 0) return 90000; // White wins next move
  if (pos.sideToMove == 1 && potentialB > 0) return -90000; // Black wins next move
  
  // DEFENSIVE PRIORITY: If opponent has a potential mill and it's MY turn,
  // this is EXTREMELY bad because I failed to block it earlier.
  // This should be almost as bad as losing.
  // INCREASED PENALTY: -95000 (nearly a loss) to force blocking
  if (pos.sideToMove == 0 && potentialB > 0) return -95000; // Must block!
  if (pos.sideToMove == 1 && potentialW > 0) return 95000; // Must block!
  
  // Double threats (Forks) - Unstoppable wins
  final forkW = _countDoubleThreats(wOcc, bOcc);
  final forkB = _countDoubleThreats(bOcc, wOcc);
  
  var score = (wc - bc) * 600;
  
  // Potential mills are VERY important in placement phase
  score += (potentialW - potentialB) * 12000; // Lean even harder into creating/denying threats
  score += (forkW - forkB) * 200000; // Fork is essentially a win, mirror classic extreme aggression
  
  // Positional bonus (center/intersections)
  // The strongest points are the middle-layer cross points (connected to 4 lines)
  // Indices: 9, 11, 13, 15
  final intersections = (1<<9) | (1<<11) | (1<<13) | (1<<15);
  final wInter = _popcount(wOcc & intersections);
  final bInter = _popcount(bOcc & intersections);
  score += (wInter - bInter) * 400; // Prefer strong anchors aggressively

  return pos.sideToMove == 0 ? score : -score;
}

bool isGameOver(SimplePosition pos) {
  return _countMills(pos.white) > 0 || _countMills(pos.black) > 0;
}

// PVS (Principal Variation Search)
int _pvs(SimplePosition pos, int depth, int alpha, int beta, int ply) {
  // TT Probe
  final ttIndex = pos.hash & (_ttSize - 1);
  final ttEntry = _tt[ttIndex];
  if (ttEntry.key == pos.hash && ttEntry.depth >= depth) {
    if (ttEntry.flag == 0) return ttEntry.score; // Exact
    if (ttEntry.flag == 1 && ttEntry.score <= alpha) return alpha; // Upper bound (fail low)
    if (ttEntry.flag == 2 && ttEntry.score >= beta) return beta; // Lower bound (fail high)
  }

  if (isGameOver(pos)) {
    final millsW = _countMills(pos.white);
    // If we are here, the PREVIOUS move created a mill.
    // So if sideToMove is 0 (White), it means Black just moved and created a mill?
    // No, isGameOver checks BOTH.
    // If White has a mill, White won.
    if (millsW > 0) return 100000 - ply; // Prefer faster wins
    return -100000 + ply;
  }
  
  if (depth == 0) return evaluate(pos);
  
  final moves = generateMoves(pos);
  if (moves.isEmpty) return evaluate(pos);
  
  // Move Ordering
  moves.sort((a, b) {
    // 1. TT Best Move
    if (ttEntry.key == pos.hash && a.to == ttEntry.bestMove) return -1000000;
    if (ttEntry.key == pos.hash && b.to == ttEntry.bestMove) return 1000000;
    
    // 2. Mill forming (Winning)
    final myBoard = pos.sideToMove == 0 ? pos.white : pos.black;
    final aBoard = myBoard | (1 << a.to);
    final bBoard = myBoard | (1 << b.to);
    final aMill = _formsMill(aBoard, a.to) ? 1 : 0;
    final bMill = _formsMill(bBoard, b.to) ? 1 : 0;
    if (aMill != bMill) return bMill - aMill;
    
    // 3. Create potential mill (Threat)
    // Expensive to compute full potential, maybe just check neighbors?
    return 0;
  });
  
  var bestScore = -inf;
  var bestMove = -1;
  var type = 1; // 1=Alpha (Upper), 2=Beta (Lower), 0=Exact
  
  for (var i = 0; i < moves.length; i++) {
    final move = moves[i];
    final child = makeMove(pos, move);
    
    int score;
    if (i == 0) {
      score = -_pvs(child, depth - 1, -beta, -alpha, ply + 1);
    } else {
      // Null Window Search
      score = -_pvs(child, depth - 1, -alpha - 1, -alpha, ply + 1);
      if (score > alpha && score < beta) {
        // Re-search
        score = -_pvs(child, depth - 1, -beta, -alpha, ply + 1);
      }
    }
    
    if (score > bestScore) {
      bestScore = score;
      bestMove = move.to;
      if (score > alpha) {
        alpha = score;
        type = 0; // Exact
      }
      if (alpha >= beta) {
        type = 2; // Lower bound (Beta cut)
        break;
      }
    }
  }
  
  // TT Store
  final saveEntry = _tt[ttIndex];
  // Always replace if deeper, or same depth
  if (saveEntry.key != pos.hash || depth >= saveEntry.depth) {
    saveEntry.key = pos.hash;
    saveEntry.depth = depth;
    saveEntry.score = bestScore;
    saveEntry.flag = type;
    saveEntry.bestMove = bestMove;
  }
  
  return bestScore;
}

SimpleMove? searchBestMove(SimplePosition root, int maxDepth, int maxNodes, int maxMillis) {
  // Ensure zobrist is initialized
  if (!_zobristInitialized) _initZobrist();
  
  SimpleMove? bestMove;
  
  // Opening Book / Optimal First Moves
  // If board is empty, take a strong intersection (e.g., D2=4, D6=19, F4=13, B4=10)
  final occupied = root.white | root.black;
  if (occupied == 0) {
    // Randomly pick one of the 4 middle cross points (strongest)
    final openings = [9, 11, 13, 15];
    return SimpleMove(openings[Random().nextInt(openings.length)]);
  }
  
  // 1. Immediate Win Check (1-ply)
  // If we can form a mill now, DO IT.
  for (final move in generateMoves(root)) {
    final myBoard = root.sideToMove == 0 ? root.white : root.black;
    final newBoard = myBoard | (1 << move.to);
    if (_formsMill(newBoard, move.to)) {
      return move; // Victory!
    }
  }

  // 2. Immediate Loss Check (Block Opponent)
  // If opponent can form a mill next turn, we MUST block it.
  // Find all squares where opponent can form a mill.
  final oppBoard = root.sideToMove == 0 ? root.black : root.white;
  final myBoard = root.sideToMove == 0 ? root.white : root.black;
  final allPieces = myBoard | oppBoard;
  
  int threatMask = 0;
  for (final mask in _millMasks) {
    if (mask == 0) continue;
    final theirs = oppBoard & mask;
    final ours = myBoard & mask;
    final empties = mask & ~allPieces;
    
    if (ours == 0 && _popcount(theirs) == 2 && empties != 0) {
       threatMask |= empties;
    }
  }
  
  // If there are threats, we MUST play on one of them.
  // We restrict the search to ONLY moves that block the threats.
  List<SimpleMove> rootMoves = generateMoves(root);
  
  if (threatMask != 0) {
    final blockingMoves = <SimpleMove>[];
    for (final move in rootMoves) {
      if ((threatMask & (1 << move.to)) != 0) {
        blockingMoves.add(move);
      }
    }
    // If we found blocking moves, use ONLY them.
    // If somehow no blocking moves found (shouldn't happen if threatMask != 0), use all.
    if (blockingMoves.isNotEmpty) {
      rootMoves = blockingMoves;
    }
  } else {
    // No immediate threats, but still filter out BAD moves:
    // 1. Moves that complete an opponent's mill (give them 3-in-a-row)
    // 2. Moves that create a future threat for opponent (give them 2-in-a-row)
    final safeMoves = <SimpleMove>[];
    for (final move in rootMoves) {
      bool isBadMove = false;
      
      // CRITICAL CHECK #1: Does this move complete an opponent mill RIGHT NOW?
      // Check if opponent already has 2 pieces in any mill, and this completes it
      for (final mask in _millMasks) {
        if (mask == 0) continue;
        // Check if this position is part of this mill
        if ((mask & (1 << move.to)) == 0) continue;
        
        final theirs = oppBoard & mask;
        final ours = myBoard & mask;
        
        // If opponent has 2 pieces in this mill, and we have 0, placing here completes their mill!
        if (_popcount(theirs) == 2 && ours == 0) {
          isBadMove = true;
          break;
        }
      }
      
      if (isBadMove) continue;
      
      // CHECK #2: Does this move create a future threat? (already existed)
      // Simulate the move
      final child = makeMove(root, move);
      final childOppBoard = child.sideToMove == 0 ? child.black : child.white;
      final childMyBoard = child.sideToMove == 0 ? child.white : child.black;
      final childAllPieces = childMyBoard | childOppBoard;
      
      // Check if this move creates a potential mill for the opponent
      for (final mask in _millMasks) {
        if (mask == 0) continue;
        final theirs = childOppBoard & mask;
        final ours = childMyBoard & mask;
        final empties = mask & ~childAllPieces;
        
        if (ours == 0 && _popcount(theirs) == 2 && empties != 0) {
          isBadMove = true;
          break;
        }
      }
      
      if (!isBadMove) {
        safeMoves.add(move);
      }
    }
    
    // If we have safe moves (that don't complete mills or create threats), prefer those
    if (safeMoves.isNotEmpty) {
      rootMoves = safeMoves;
    }
  }
  
  if (rootMoves.isEmpty) return null;
  
  // Clear TT? No, keep it for iterative deepening
  // But maybe clear if new game? 
  // For now, just let it overwrite.
  
  // Iterative Deepening
  final searchStart = DateTime.now();
  for (var depth = 1; depth <= maxDepth; depth++) {
    // Check time limit before starting new depth
    if (maxMillis > 0 && searchStart.difference(DateTime.now()).inMilliseconds.abs() >= maxMillis) {
      break; // Time's up, use best move from previous depth
    }
    
    var bestScore = -inf;
    var alpha = -inf;
    var beta = inf;
    SimpleMove? currentBestMove;
    
    // Use rootMoves instead of generating new ones
    // Sort moves?
    // Move ordering at root:
    // 1. TT Best Move
    // 2. Winning moves (already handled by immediate check)
    // 3. Blocking moves (already filtered if threats exist)
    
    rootMoves.sort((a, b) {
      final ttIndex = root.hash & (_ttSize - 1);
      final ttEntry = _tt[ttIndex];
      if (ttEntry.key == root.hash && a.to == ttEntry.bestMove) return -1000000;
      if (ttEntry.key == root.hash && b.to == ttEntry.bestMove) return 1000000;
      
      final myBoard = root.sideToMove == 0 ? root.white : root.black;
      final aBoard = myBoard | (1 << a.to);
      final bBoard = myBoard | (1 << b.to);
      final aMill = _formsMill(aBoard, a.to) ? 1 : 0;
      final bMill = _formsMill(bBoard, b.to) ? 1 : 0;
      return (bMill - aMill);
    });
    
    for (var i = 0; i < rootMoves.length; i++) {
      final move = rootMoves[i];
      final child = makeMove(root, move);
      
      int score;
      if (i == 0) {
        score = -_pvs(child, depth - 1, -beta, -alpha, 1);
      } else {
        score = -_pvs(child, depth - 1, -alpha - 1, -alpha, 1);
        if (score > alpha && score < beta) {
          score = -_pvs(child, depth - 1, -beta, -alpha, 1);
        }
      }
      
      if (score > bestScore) {
        bestScore = score;
        currentBestMove = move;
      }
      alpha = max(alpha, score);
    }
    
    // Update best move after completing this depth
    if (currentBestMove != null) {
      bestMove = currentBestMove;
    }
  }
  
  return bestMove ?? (rootMoves.isNotEmpty ? rootMoves.first : null);
}

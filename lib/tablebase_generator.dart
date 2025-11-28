// Tablebase generator using retrograde analysis for Nine Men's Morris.
// Generates perfect endgame databases for 3v3, 3v4, 4v3, 4v4 positions.

import 'dart:io';
import 'dart:typed_data';
import 'tablebase_index.dart';

// Result codes
const int UNKNOWN = 0;
const int WIN = 1;
const int LOSS = 2;
const int DRAW = 3;

// Mills (same as extreme_ai.dart)
final List<int> _millMasks = _buildMillMasks();

List<int> _buildMillMasks() {
  int m(int a, int b, int c) => (1 << a) | (1 << b) | (1 << c);
  return [
    m(0, 1, 2), m(3, 4, 5), m(6, 7, 8),
    m(9, 10, 11), m(12, 13, 14), m(15, 16, 17),
    m(18, 19, 20), m(21, 22, 23),
    m(0, 9, 21), m(3, 10, 18), m(6, 11, 15),
    m(1, 4, 7), m(16, 19, 22), m(8, 12, 17),
    m(5, 13, 20), m(2, 14, 23),
  ];
}

// Adjacency (same as extreme_ai.dart)
final List<List<int>> _adj = [
  [1, 9], [0, 2, 4], [1, 14], [4, 10], [1, 3, 5, 7],
  [4, 13], [7, 11], [4, 6, 8], [7, 12], [0, 10, 21],
  [3, 9, 11], [6, 10, 15], [8, 13, 17], [5, 12, 14, 20],
  [2, 13, 23], [11, 16], [15, 17, 19], [12, 16],
  [10, 19], [16, 18, 20, 22], [13, 19], [9, 22],
  [19, 21, 23], [14, 22],
];

bool _formsMill(int board, int sq) {
  for (final mask in _millMasks) {
    if ((mask & (1 << sq)) != 0 && (board & mask) == mask) {
      return true;
    }
  }
  return false;
}

bool _hasAnyMill(int board) {
  for (final mask in _millMasks) {
    if ((board & mask) == mask) return true;
  }
  return false;
}

List<int> _collectRemovals(int oppBoard) {
  final removals = <int>[];
  for (var sq = 0; sq < boardSize; sq++) {
    if ((oppBoard & (1 << sq)) != 0) {
      if (!_formsMill(oppBoard, sq)) {
        removals.add(sq);
      }
    }
  }
  if (removals.isEmpty) {
    // All in mills, can remove any
    for (var sq = 0; sq < boardSize; sq++) {
      if ((oppBoard & (1 << sq)) != 0) {
        removals.add(sq);
      }
    }
  }
  return removals;
}

/// Generate moves for a position.
/// If [simpleMode] is true, use Simple mode rules: no flying and no captures (first mill wins).
List<Map<String, int>> generateMoves(int myBoard, int oppBoard, bool isFlying, {bool simpleMode = true}) {
  final moves = <Map<String, int>>[];
  final empty = ~(myBoard | oppBoard) & ((1 << boardSize) - 1);
  final allowFlying = isFlying && !simpleMode;

  if (allowFlying) {
    // Flying: any piece to any empty square
    for (var from = 0; from < boardSize; from++) {
      if ((myBoard & (1 << from)) == 0) continue;
      for (var to = 0; to < boardSize; to++) {
        if ((empty & (1 << to)) == 0) continue;
        final newBoard = (myBoard & ~(1 << from)) | (1 << to);
        final forms = _formsMill(newBoard, to);
        if (forms && !simpleMode) {
          for (final remove in _collectRemovals(oppBoard)) {
            moves.add({'from': from, 'to': to, 'remove': remove});
          }
        } else {
          moves.add({'from': from, 'to': to, 'remove': -1});
        }
      }
    }
  } else {
    // Moving: adjacent squares only
    for (var from = 0; from < boardSize; from++) {
      if ((myBoard & (1 << from)) == 0) continue;
      for (final to in _adj[from]) {
        if ((empty & (1 << to)) == 0) continue;
        final newBoard = (myBoard & ~(1 << from)) | (1 << to);
        final forms = _formsMill(newBoard, to);
        if (forms && !simpleMode) {
          for (final remove in _collectRemovals(oppBoard)) {
            moves.add({'from': from, 'to': to, 'remove': remove});
          }
        } else {
          moves.add({'from': from, 'to': to, 'remove': -1});
        }
      }
    }
  }
  
  return moves;
}

/// Apply a move and return new (white, black, stm)
List<int> makeMove(int white, int black, int stm, Map<String, int> move) {
  final myBoard = stm == 0 ? white : black;
  final oppBoard = stm == 0 ? black : white;
  
  var newMy = (myBoard & ~(1 << move['from']!)) | (1 << move['to']!);
  var newOpp = oppBoard;
  
  if (move['remove']! >= 0) {
    newOpp &= ~(1 << move['remove']!);
  }
  
  return stm == 0 ? [newMy, newOpp, 1] : [newOpp, newMy, 0];
}

int _popcount(int bits) {
  var count = 0;
  while (bits != 0) {
    bits &= bits - 1;
    count++;
  }
  return count;
}

/// Generate tablebase for numWhite vs numBlack
Uint8List generateTablebase(int numWhite, int numBlack, 
    {Map<String, Uint8List>? lowerTables, bool simpleMode = false}) {
  print('Generating ${numWhite}v$numBlack tablebase...');
  
  final totalPositions = numPositions(numWhite, numBlack);
  print('Total positions: $totalPositions');
  
  final table = Uint8List(totalPositions);
  
  final isFlying = !simpleMode && numWhite <= 3 && numBlack <= 3;
  print('Flying phase: $isFlying (simpleMode: $simpleMode)');
  
  // Step 1: Initialize terminal states
  print('Initializing terminal states...');
  for (var idx = 0; idx < totalPositions; idx++) {
    final state = deindexPosition(idx, numWhite, numBlack);
    final white = state[0];
    final black = state[1];
    final stm = state[2];
    
    final wc = _popcount(white);
    final bc = _popcount(black);
    
    // Terminal: side to move has <3 pieces (classic)
    if (!simpleMode && ((stm == 0 && wc < 3) || (stm == 1 && bc < 3))) {
      table[idx] = LOSS;
    }

    // Terminal: Simple mode mill present
    if (simpleMode) {
      final hasMill = (stm == 0 ? _formsMill(white, 0) : _formsMill(black, 0)) ||
          _formsMill(white, 0) ||
          _formsMill(black, 0);
      if (hasMill) {
        // If current side already has a mill, they win; otherwise they lose.
        final stmBoard = stm == 0 ? white : black;
        if (_hasAnyMill(stmBoard)) {
          table[idx] = WIN;
        } else if (_hasAnyMill(stm == 0 ? black : white)) {
          table[idx] = LOSS;
        }
      }
    }
    
    // Check if any legal moves exist
    final myBoard = stm == 0 ? white : black;
    final oppBoard = stm == 0 ? black : white;
    final moves = generateMoves(myBoard, oppBoard, isFlying, simpleMode: simpleMode);
    
    if (moves.isEmpty) {
      table[idx] = LOSS; // No moves = loss
    }
  }
  
  // Step 2: Iterative propagation
  print('Propagating results...');
  var changed = true;
  var iteration = 0;
  
  while (changed && iteration < 100) {
    changed = false;
    iteration++;
    
    for (var idx = 0; idx < totalPositions; idx++) {
      if (table[idx] != UNKNOWN) continue;
      
      final state = deindexPosition(idx, numWhite, numBlack);
      final white = state[0];
      final black = state[1];
      final stm = state[2];
      
      final myBoard = stm == 0 ? white : black;
      final oppBoard = stm == 0 ? black : white;
      final moves = generateMoves(myBoard, oppBoard, isFlying, simpleMode: simpleMode);
      
      var hasWinningMove = false;
      var allMovesLose = true;
      
      for (final move in moves) {
        final newState = makeMove(white, black, stm, move);
        final newWhite = newState[0];
        final newBlack = newState[1];
        final newStm = newState[2];
        
        final newWc = _popcount(newWhite);
        final newBc = _popcount(newBlack);
        
        int result;
        
        // Simple mode: any mill is an immediate win (no capture/removal step)
        if (simpleMode && move['remove'] == -1) {
          final formsMill = _formsMill(stm == 0 ? newWhite : newBlack, move['to']!);
          if (formsMill) {
            result = LOSS; // From opponent POV after the move
          } else {
            final newIdx = indexPosition(newWhite, newBlack, newStm, numWhite, numBlack);
            result = table[newIdx];
          }
        } else if (move['remove']! >= 0 && lowerTables != null) {
          final key = '${newWc}v$newBc';
          if (lowerTables.containsKey(key)) {
            final lowerTable = lowerTables[key]!;
            final lowerIdx = indexPosition(newWhite, newBlack, newStm, newWc, newBc);
            result = lowerTable[lowerIdx];
          } else {
            final newIdx = indexPosition(newWhite, newBlack, newStm, numWhite, numBlack);
            result = table[newIdx];
          }
        } else {
          final newIdx = indexPosition(newWhite, newBlack, newStm, numWhite, numBlack);
          result = table[newIdx];
        }
        
        if (result == LOSS) {
          hasWinningMove = true; // Opponent loses = we win
          break;
        }
        if (result != WIN) {
          allMovesLose = false;
        }
      }
      
      if (hasWinningMove) {
        table[idx] = WIN;
        changed = true;
      } else if (allMovesLose) {
        table[idx] = LOSS;
        changed = true;
      }
    }
    
    final resolved = table.where((x) => x != UNKNOWN).length;
    print('Iteration $iteration: $resolved/$totalPositions resolved');
  }
  
  // Step 3: Mark remaining as DRAW
  for (var idx = 0; idx < totalPositions; idx++) {
    if (table[idx] == UNKNOWN) {
      table[idx] = DRAW;
    }
  }
  
  final wins = table.where((x) => x == WIN).length;
  final losses = table.where((x) => x == LOSS).length;
  final draws = table.where((x) => x == DRAW).length;
  print('Results: $wins wins, $losses losses, $draws draws');
  
  return table;
}

void main() async {
  print('Nine Men\'s Morris Tablebase Generator');
  print('====================================\n');

  // Toggle this to generate Simple mode (placement-only, first mill wins) tables.
  const simpleMode = true;
  
  // Create output directory
  final outputDir = Directory('assets/tablebase');
  if (!await outputDir.exists()) {
    await outputDir.create(recursive: true);
  }
  
  // Generate 3v3
  final tb3v3 = generateTablebase(3, 3, simpleMode: simpleMode);
  await File('assets/tablebase/3v3.tb').writeAsBytes(tb3v3);
  print('Saved 3v3.tb\n');
  
  // Generate 3v4 and 4v3
  final lowerTables = <String, Uint8List>{'3v3': tb3v3};
  
  final tb3v4 = generateTablebase(3, 4, lowerTables: lowerTables, simpleMode: simpleMode);
  await File('assets/tablebase/3v4.tb').writeAsBytes(tb3v4);
  print('Saved 3v4.tb\n');
  
  final tb4v3 = generateTablebase(4, 3, lowerTables: lowerTables, simpleMode: simpleMode);
  await File('assets/tablebase/4v3.tb').writeAsBytes(tb4v3);
  print('Saved 4v3.tb\n');
  
  // Generate 4v4
  lowerTables['3v4'] = tb3v4;
  lowerTables['4v3'] = tb4v3;
  
  final tb4v4 = generateTablebase(4, 4, lowerTables: lowerTables, simpleMode: simpleMode);
  await File('assets/tablebase/4v4.tb').writeAsBytes(tb4v4);
  print('Saved 4v4.tb\n');
  
  print('Tablebase generation complete!');
}

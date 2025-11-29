// Monte Carlo Tree Search implementation for Nine Men's Morris
// Uses UCT (Upper Confidence Bound for Trees) for move selection

import 'dart:math';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'mcts_node.dart';
import 'tablebase_loader.dart';

/// MCTS Configuration
class MCTSConfig {
  final double explorationConstant; // UCT C parameter (√2 ≈ 1.414)
  final int maxIterations;
  final int maxMilliseconds;
  final int maxSimulationDepth; // Prevent infinite rollouts
  final bool useTablebaseInSimulation; // Use TB during rollouts
  final double progressiveWideningFactor; // Limit branching: factor * sqrt(visits)
  
  const MCTSConfig({
    this.explorationConstant = 1.414,
    this.maxIterations = 10000,
    this.maxMilliseconds = 5000,
    this.maxSimulationDepth = 100,
    this.useTablebaseInSimulation = true,
    this.progressiveWideningFactor = 4.0, // Default factor
  });
}

/// Monte Carlo Tree Search Engine
class MCTSEngine {
  final MCTSConfig config;
  final bool isSimpleMode; // True for Simple mode (placement-only, first mill wins)
  final Random _random = Random();
  
  // Mill definitions (same for both Classic and Simple modes)
  // Both modes use the same 24-point board layout
  static const List<List<int>> _mills = [
    [0, 1, 2], [2, 3, 4], [4, 5, 6], [6, 7, 0],
    [8, 9, 10], [10, 11, 12], [12, 13, 14], [14, 15, 8],
    [16, 17, 18], [18, 19, 20], [20, 21, 22], [22, 23, 16],
    [1, 9, 17], [3, 11, 19], [5, 13, 21], [7, 15, 23],
  ];
  
  // Adjacency map (same for both modes)
  static const Map<int, List<int>> _adjacency = {
    0: [1, 7], 1: [0, 2, 9], 2: [1, 3], 3: [2, 4, 11],
    4: [3, 5], 5: [4, 6, 13], 6: [5, 7], 7: [0, 6, 15],
    8: [9, 15], 9: [1, 8, 10, 17], 10: [9, 11], 11: [3, 10, 12, 19],
    12: [11, 13], 13: [5, 12, 14, 21], 14: [13, 15], 15: [7, 8, 14, 23],
    16: [17, 23], 17: [9, 16, 18], 18: [17, 19], 19: [11, 18, 20],
    20: [19, 21], 21: [13, 20, 22], 22: [21, 23], 23: [15, 16, 22],
  };

  MCTSEngine({
    this.config = const MCTSConfig(),
    this.isSimpleMode = false,
  });
  
  /// Main MCTS search function
  /// Returns the best move found after searching
  Future<MCTSMove?> search(MCTSPosition rootPosition) async {
    final startTime = DateTime.now();
    
    // Generate initial moves
    final rootMoves = generateMoves(rootPosition);
    if (rootMoves.isEmpty) return null;
    if (rootMoves.length == 1) return rootMoves.first;
    
    // Create root node
    final rootNode = MCTSNode(
      position: rootPosition,
      untriedMoves: rootMoves,
      playerJustMoved: 1 - rootPosition.sideToMove,
    );
    
    var iterations = 0;
    
    // Main MCTS loop
    while (iterations < config.maxIterations) {
      // Check time limit
      final elapsed =  DateTime.now().difference(startTime).inMilliseconds;
      if (elapsed >= config.maxMilliseconds) {
        break;
      }
      
      // On web, yield to event loop periodically to prevent UI freeze
      // since we can't use isolates effectively for heavy compute
      // Yield frequently (every 25 iterations) to keep UI responsive
      if (kIsWeb && iterations % 25 == 0) {
        await Future.delayed(Duration.zero);
      }
      
      // 1. SELECTION: Navigate tree using UCT
      var node = select(rootNode);
      
      // 2. EXPANSION: Add a new child if possible
      if (!_isTerminal(node.position) && node.untriedMoves.isNotEmpty) {
        node = expand(node);
      }
      
      // 3. SIMULATION: Random playout to terminal state
      final movesPlayed = <MCTSMove>[];
      final result = simulate(node.position, rootPosition.sideToMove, movesPlayed);
      
      // 4. BACKPROPAGATION: Update statistics up the tree
      backpropagate(node, result, rootPosition.sideToMove, movesPlayed);
      
      iterations++;
    }
    
    
    // print('[MCTS] Completed $iterations iterations in '
    //       '${DateTime.now().difference(startTime).inMilliseconds}ms');
    // print('[MCTS] Root stats: ${rootNode}');
    
    // Return move with most visits (most robust)
    final bestChild = rootNode.selectMostVisitedChild();
    return bestChild?.moveToReach;
  }
  
  /// Phase 1: SELECTION - Navigate tree using UCT
  MCTSNode select(MCTSNode node) {
    while (node.isFullyExpanded(config.progressiveWideningFactor) && node.children.isNotEmpty) {
      node = node.selectBestChild(config.explorationConstant)!;
    }
    return node;
  }
  
  /// Phase 2: EXPANSION - Add a new child node
  MCTSNode expand(MCTSNode node) {
    if (node.untriedMoves.isEmpty) return node;
    
    // Pick a random untried move
    final move = node.untriedMoves[_random.nextInt(node.untriedMoves.length)];
    
    // Apply move to get child position
    final childPosition = makeMove(node.position, move);
    final childMoves = generateMoves(childPosition);
    
    // Add child to tree
    return node.addChild(move, childPosition, childMoves);
  }
  
  /// Phase 3: SIMULATION - Smart playout from current position
  /// Uses domain knowledge to prefer critical moves (mills, blocks) over random
  double simulate(MCTSPosition position, int rootPlayer, List<MCTSMove> movesPlayed) {
    var current = position.clone();
    var depth = 0;
    
    while (!_isTerminal(current) && depth < config.maxSimulationDepth) {
      // Check tablebase if enabled and in endgame
      if (config.useTablebaseInSimulation && _isEndgame(current)) {
        final tbResult = _probeTablebase(current);
        if (tbResult != null) {
          // Convert tablebase score to win probability
          return _tablebaseScoreToResult(tbResult, rootPlayer, current.sideToMove);
        }
      }
      
      // Smart playout: prefer critical moves
      final moves = generateMoves(current);
      if (moves.isEmpty) break;
      
      // Categorize moves by priority
      final winningMoves = <MCTSMove>[];
      final blockingMoves = <MCTSMove>[];
      final normalMoves = <MCTSMove>[];
      
      for (final move in moves) {
        final child = makeMove(current, move);
        
        // Check if this move forms a mill (winning)
        if (_formsMill(child, move.to!, current.sideToMove)) {
          winningMoves.add(move);
        }
        // Check if this move blocks opponent mill
        else if (_blocksOpponentMill(current, move)) {
          blockingMoves.add(move);
        } else {
          normalMoves.add(move);
        }
      }
      
      // Select move with priority: winning > blocking > random
      final selectedMove = winningMoves.isNotEmpty
          ? winningMoves[_random.nextInt(winningMoves.length)]
          : (blockingMoves.isNotEmpty
              ? blockingMoves[_random.nextInt(blockingMoves.length)]
              : normalMoves[_random.nextInt(normalMoves.length)]);
      
      current = makeMove(current, selectedMove);
      movesPlayed.add(selectedMove); // Track move for RAVE
      depth++;
    }
    
    // Evaluate terminal position
    return _evaluateTerminal(current, rootPlayer);
  }
  
  /// Phase 4: BACKPROPAGATION - Update node statistics
  void backpropagate(MCTSNode? node, double result, int rootPlayer, List<MCTSMove> movesPlayed) {
    var current = node;
    
    while (current != null) {
      // Update standard stats
      current.update(result);
      
      // Update RAVE stats for children
      // If a move in 'movesPlayed' is also a child of 'current', update its RAVE stats
      if (current.children.isNotEmpty) {
        for (final child in current.children) {
          if (child.moveToReach != null && movesPlayed.contains(child.moveToReach)) {
            // This child's move was played later in the simulation
            // So it gets credit via AMAF (All-Moves-As-First)
            
            // Result needs to be from the perspective of the player who made the move
            // child.moveToReach was made by current.position.sideToMove
            
            // If rootPlayer won (result=1.0), and child move was by rootPlayer, score=1.0
            // If rootPlayer won, and child move was by opponent, score=0.0
            
            // Simplified: If result is good for rootPlayer, it's good for moves made by rootPlayer
            
            double raveResult = result;
            if (child.playerJustMoved != rootPlayer) {
               raveResult = 1.0 - result;
            }
            
            child.updateRave(raveResult);
          }
        }
      }
      
      // Flip result for opponent's perspective (for standard stats)
      result = 1.0 - result;
      
      current = current.parent;
    }
  }
  
  /// Generate legal moves for a position
  List<MCTSMove> generateMoves(MCTSPosition pos) {
    final moves = <MCTSMove>[];
    final occupied = pos.whiteBits | pos.blackBits;
    
    if (pos.phase == 0) { // Placing phase
      final piecesLeft = pos.sideToMove == 0 
          ? pos.whitePiecesLeft 
          : pos.blackPiecesLeft;
      
      if (piecesLeft == 0) return moves; // No more pieces to place
      
      // Add all empty squares as placement moves
      for (var i = 0; i < 24; i++) {
        if ((occupied & (1 << i)) == 0) {
          moves.add(MCTSMove(to: i));
        }
      }
    } else { // Moving/Flying phase
      final myBits = pos.sideToMove == 0 ? pos.whiteBits : pos.blackBits;
      final canFly = _canFly(pos);
      
      for (var from = 0; from < 24; from++) {
        if ((myBits & (1 << from)) == 0) continue; // Not my piece
        
        final destinations = canFly 
            ? _allEmptySquares(occupied)
            : _adjacentEmptySquares(from, occupied);
        
        for (final to in destinations) {
          moves.add(MCTSMove(from: from, to: to));
        }
      }
    }
    
    return moves;
  }
  
  /// Apply a move to a position
  MCTSPosition makeMove(MCTSPosition pos, MCTSMove move) {
    var newWhite = pos.whiteBits;
    var newBlack = pos.blackBits;
    var newWhiteLeft = pos.whitePiecesLeft;
    var newBlackLeft = pos.blackPiecesLeft;
    
    if (pos.phase == 0) { // Placing
      if (pos.sideToMove == 0) {
        newWhite |= (1 << move.to!);
        newWhiteLeft--;
      } else {
        newBlack |= (1 << move.to!);
        newBlackLeft--;
      }
    } else { // Moving
      if (pos.sideToMove == 0) {
        newWhite &= ~(1 << move.from!);
        newWhite |= (1 << move.to!);
      } else {
        newBlack &= ~(1 << move.from!);
        newBlack |= (1 << move.to!);
      }
    }
    
    // Check for mill formation and handle captures
    // (Simplified - full implementation would handle piece removal)
    
    // Update phase
    var newPhase = pos.phase;
    // In Simple mode, always stay in placing phase
    if (!isSimpleMode && newWhiteLeft == 0 && newBlackLeft == 0 && pos.phase == 0) {
      newPhase = 1; // Switch to moving phase
    }
    
    return MCTSPosition(
      whiteBits: newWhite,
      blackBits: newBlack,
      whitePiecesLeft: newWhiteLeft,
      blackPiecesLeft: newBlackLeft,
      sideToMove: 1 - pos.sideToMove,
      phase: newPhase,
    );
  }
  
  /// Check if position is terminal (game over)
  bool _isTerminal(MCTSPosition pos) {
    // Check for winner
    final winner = _checkWinner(pos);
    if (winner != null) return true;
    
    // Check if current player has any moves
    final moves = generateMoves(pos);
    return moves.isEmpty;
  }
  
  /// Check for winner
  int? _checkWinner(MCTSPosition pos) {
    // In Simple mode, first mill wins immediately
    if (isSimpleMode) {
      for (final mill in _mills) {
        final allWhite = mill.every((sq) => (pos.whiteBits & (1 << sq)) != 0);
        final allBlack = mill.every((sq) => (pos.blackBits & (1 << sq)) != 0);
        
        if (allWhite) return 0; // White wins
        if (allBlack) return 1; // Black wins
      }
      return null; // No winner yet in Simple mode
    }
    
    // Classic mode: check piece count (< 3 pieces = loss)
    final wc = _popcount(pos.whiteBits);
    final bc = _popcount(pos.blackBits);
    
    if (wc < 3 && pos.whitePiecesLeft == 0) return 1; // Black wins
    if (bc < 3 && pos.blackPiecesLeft == 0) return 0; // White wins
    
    return null; // No winner yet
  }
  
  /// Evaluate terminal position (0.0 = loss, 0.5 = draw, 1.0 = win)
  double _evaluateTerminal(MCTSPosition pos, int rootPlayer) {
    final winner = _checkWinner(pos);
    
    if (winner == null) return 0.5; // Draw
    return winner == rootPlayer ? 1.0 : 0.0;
  }
  
  /// Check if position is in endgame (for tablebase lookup)
  bool _isEndgame(MCTSPosition pos) {
    if (pos.phase == 0) return false; // Not in endgame during placement
    
    final wc = _popcount(pos.whiteBits);
    final bc = _popcount(pos.blackBits);
    
    return wc >= 3 && wc <= 4 && bc >= 3 && bc <= 4;
  }
  
  /// Probe tablebase
  int? _probeTablebase(MCTSPosition pos) {
    return tablebaseLoader.probe(
      pos.whiteBits,
      pos.blackBits,
      pos.sideToMove,
    );
  }
  
  /// Convert tablebase score to simulation result
  double _tablebaseScoreToResult(int tbScore, int rootPlayer, int sideToMove) {
    // tbScore is from white's POV
    // Result should be from rootPlayer's POV
    
    if (rootPlayer == 0) {
      // Root is white
      return tbScore > 0 ? 1.0 : (tbScore < 0 ? 0.0 : 0.5);
    } else {
      // Root is black
      return tbScore < 0 ? 1.0 : (tbScore > 0 ? 0.0 : 0.5);
    }
  }
  
  /// Helper: can this side fly?
  bool _canFly(MCTSPosition pos) {
    // Simple mode never allows flying
    if (isSimpleMode) return false;
    
    final myBits = pos.sideToMove == 0 ? pos.whiteBits : pos.blackBits;
    final piecesLeft = pos.sideToMove == 0 
        ? pos.whitePiecesLeft 
        : pos.blackPiecesLeft;
    
    return _popcount(myBits) <= 3 && piecesLeft == 0;
  }
  
  /// Helper: get adjacent empty squares
  List<int> _adjacentEmptySquares(int square, int occupied) {
    final result = <int>[];
    final adjacent = _adjacency[square] ?? [];
    
    for (final sq in adjacent) {
      if ((occupied & (1 << sq)) == 0) {
        result.add(sq);
      }
    }
    
    return result;
  }
  
  /// Helper: get all empty squares
  List<int> _allEmptySquares(int occupied) {
    final result = <int>[];
    for (var i = 0; i < 24; i++) {
      if ((occupied & (1 << i)) == 0) {
        result.add(i);
      }
    }
    return result;
  }
  
  /// Helper: population count (number of 1 bits)
  int _popcount(int bits) {
    var count = 0;
    while (bits != 0) {
      bits &= bits - 1;
      count++;
    }
    return count;
  }
  
  /// Helper: Check if placing a piece at 'square' forms a mill for 'player'
  bool _formsMill(MCTSPosition pos, int square, int player) {
    final myBits = player == 0 ? pos.whiteBits : pos.blackBits;
    
    for (final mill in _mills) {
      if (!mill.contains(square)) continue;
      
      // Check if all positions in this mill belong to me
      if (mill.every((sq) => (myBits & (1 << sq)) != 0)) {
        return true;
      }
    }
    
    return false;
  }
  
  /// Helper: Check if this move blocks an opponent mill
  bool _blocksOpponentMill(MCTSPosition pos, MCTSMove move) {
    final oppPlayer = 1 - pos.sideToMove;
    final oppBits = oppPlayer == 0 ? pos.whiteBits : pos.blackBits;
    final myBits = pos.sideToMove == 0 ? pos.whiteBits : pos.blackBits;
    final allPieces = myBits | oppBits;
    
    // Check if placing at move.to blocks any opponent mills
    for (final mill in _mills) {
      if (!mill.contains(move.to!)) continue;
      
      final oppInMill = mill.where((sq) => (oppBits & (1 << sq)) != 0).length;
      final myInMill = mill.where((sq) => (myBits & (1 << sq)) != 0).length;
      final empties = mill.where((sq) => (allPieces & (1 << sq)) == 0).length;
      
      // If opponent has 2 in this mill, and we have 0, and there's 1 empty
      // Then placing here blocks their mill
      if (oppInMill == 2 && myInMill == 0 && empties == 1) {
        return true;
      }
    }
    
    return false;
  }
}

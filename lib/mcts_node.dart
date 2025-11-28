// MCTS Node structure for Monte Carlo Tree Search
// Each node represents a game state in the search tree

import 'dart:math';

/// Move representation for MCTS
class MCTSMove {
  final int? from;
  final int? to;
  final int? remove;
  
  MCTSMove({this.from, this.to, this.remove});
  
  @override
  bool operator ==(Object other) =>
      other is MCTSMove &&
      from == other.from &&
      to == other.to &&
      remove == other.remove;
  
  @override
  int get hashCode => Object.hash(from, to, remove);
  
  @override
  String toString() => 'Move(from:$from, to:$to, remove:$remove)';
}

/// Position representation for MCTS (using bitboards for efficiency)
class MCTSPosition {
  final int whiteBits;
  final int blackBits;
  final int whitePiecesLeft;
  final int blackPiecesLeft;
  final int sideToMove; // 0 = white, 1 = black
  final int phase; // 0 = placing, 1 = moving, 2 = flying
  
  MCTSPosition({
    required this.whiteBits,
    required this.blackBits,
    required this.whitePiecesLeft,
    required this.blackPiecesLeft,
    required this.sideToMove,
    required this.phase,
  });
  
  MCTSPosition clone() {
    return MCTSPosition(
      whiteBits: whiteBits,
      blackBits: blackBits,
      whitePiecesLeft: whitePiecesLeft,
      blackPiecesLeft: blackPiecesLeft,
      sideToMove: sideToMove,
      phase: phase,
    );
  }
  
  @override
  String toString() =>
      'Pos(W:$whiteBits B:$blackBits STM:$sideToMove P:$phase)';
}

/// MCTS Tree Node
class MCTSNode {
  // Position this node represents
  final MCTSPosition position;
  
  // Move that led to this position (null for root)
  final MCTSMove? moveToReach;
  
  // Tree structure
  MCTSNode? parent;
  List<MCTSNode> children = [];
  
  // Moves not yet explored
  List<MCTSMove> untriedMoves;
  
  // Statistics
  int visits = 0;
  double totalScore = 0.0; // Sum of all simulation results
  
  // RAVE / AMAF Statistics
  int raveVisits = 0;
  double raveScore = 0.0;
  
  // Player who just moved to create this position
  final int playerJustMoved;
  
  MCTSNode({
    required this.position,
    required this.untriedMoves,
    required this.playerJustMoved,
    this.moveToReach,
    this.parent,
  });
  
  /// Win rate from this node's perspective
  double get winRate => visits > 0 ? totalScore / visits : 0.0;
  
  /// RAVE win rate
  double get raveWinRate => raveVisits > 0 ? raveScore / raveVisits : 0.0;
  
  /// UCT value with RAVE (MC-RAVE)
  /// Formula: (1-beta)*Q + beta*AMAF + Bias
  double uctValue(double explorationConstant) {
    if (visits == 0) return double.infinity; // Unexplored nodes have max priority
    
    if (parent == null || parent!.visits == 0) return winRate;
    
    // Standard UCT components
    final exploitation = totalScore / visits;
    final exploration = explorationConstant * 
                       sqrt(log(parent!.visits) / visits);
                       
    // RAVE beta calculation (hand-tuned constant k=1000)
    // beta approaches 0 as visits increase (relying more on real MCTS stats)
    const k = 1000.0;
    final beta = sqrt(k / (3 * visits + k));
    
    // If we have RAVE stats, blend them
    if (raveVisits > 0) {
      final amaf = raveScore / raveVisits;
      return (1.0 - beta) * exploitation + beta * amaf + exploration;
    }
    
    return exploitation + exploration;
  }
  
  /// Update RAVE statistics
  void updateRave(double result) {
    raveVisits++;
    raveScore += result;
  }
  
  /// Add a child node for the given move
  MCTSNode addChild(MCTSMove move, MCTSPosition childPosition, 
                    List<MCTSMove> childMoves) {
    untriedMoves.remove(move);
    
    final child = MCTSNode(
      position: childPosition,
      moveToReach: move,
      untriedMoves: childMoves,
      playerJustMoved: 1 - playerJustMoved, // Opponent just moved
      parent: this,
    );
    
    children.add(child);
    return child;
  }
  
  /// Select child with highest UCT value
  MCTSNode? selectBestChild(double explorationConstant) {
    if (children.isEmpty) return null;
    
    return children.reduce((a, b) {
      final aUCT = a.uctValue(explorationConstant);
      final bUCT = b.uctValue(explorationConstant);
      return aUCT > bUCT ? a : b;
    });
  }
  
  /// Select most visited child (most robust choice for final move)
  MCTSNode? selectMostVisitedChild() {
    if (children.isEmpty) return null;
    return children.reduce((a, b) => a.visits > b.visits ? a : b);
  }
  
  /// Select child with highest win rate
  MCTSNode? selectBestWinRateChild() {
    if (children.isEmpty) return null;
    return children.reduce((a, b) => a.winRate > b.winRate ? a : b);
  }
  
  /// Update node statistics with simulation result
  void update(double result) {
    visits++;
    totalScore += result;
  }
  
  /// Check if this is a fully expanded node (all moves tried)
  /// Uses Progressive Widening: limit children based on visits
  /// Formula: max_children = factor * visits^0.5
  bool isFullyExpanded(double progressiveWideningFactor) {
    if (untriedMoves.isEmpty) return true;
    
    // If factor is 0 or negative, disable progressive widening (standard MCTS)
    if (progressiveWideningFactor <= 0) return untriedMoves.isEmpty;
    
    // Calculate max allowed children for current visit count
    final maxChildren = (progressiveWideningFactor * sqrt(visits)).ceil();
    
    return children.length >= maxChildren;
  }
  
  /// Check if this is a terminal node (game over)
  bool get isTerminal => children.isEmpty && untriedMoves.isEmpty;
  
  @override
  String toString() {
    return 'MCTSNode(visits:$visits, score:${totalScore.toStringAsFixed(2)}, '
           'winRate:${(winRate * 100).toStringAsFixed(1)}%, '
           'children:${children.length}, untried:${untriedMoves.length})';
  }
  
  /// Get detailed tree statistics for debugging
  String getTreeStats({int depth = 0}) {
    final indent = '  ' * depth;
    final buffer = StringBuffer();
    
    buffer.writeln('$indent$this');
    if (depth < 2) { // Limit depth to avoid huge output
      for (final child in children.take(5)) { // Show top 5 children
        buffer.write(child.getTreeStats(depth: depth + 1));
      }
      if (children.length > 5) {
        buffer.writeln('$indent  ... and ${children.length - 5} more children');
      }
    }
    
    return buffer.toString();
  }
}

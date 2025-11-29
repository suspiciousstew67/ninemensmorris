// Hybrid AI: Combines MCTS for midgame with Retrograde Analysis (Tablebase) for endgame
// Automatically switches between strategies based on game phase

import 'package:flutter/foundation.dart';
import 'mcts_ai.dart';
import 'mcts_node.dart';
import 'tablebase_loader.dart';

import 'parallel_mcts.dart';

/// Hybrid AI Configuration
class HybridConfig {
  final MCTSConfig mctsConfig;
  final bool useTablebaseInEndgame;
  final int endgamePieceThreshold; // Max pieces per side to use tablebase
  final bool useParallel; // Use parallel search (isolates)
  final bool isSimpleMode; // True for 6 Men's Morris
  final int parallelWorkers; // Max worker isolates when parallel
  
  const HybridConfig({
    this.mctsConfig = const MCTSConfig(),
    this.useTablebaseInEndgame = true,
    this.endgamePieceThreshold = 4,
    this.useParallel = false,
    this.isSimpleMode = false,
    this.parallelWorkers = 2,
  });
}

/// Hybrid AI Engine - Combines MCTS + Tablebase
class HybridAI {
  final HybridConfig config;
  final MCTSEngine mctsEngine;
  final ParallelMCTS? parallelMCTS;
  
  HybridAI({HybridConfig? config})
      : config = config ?? const HybridConfig(),
        mctsEngine = MCTSEngine(
          config: config?.mctsConfig ?? const MCTSConfig(),
          isSimpleMode: config?.isSimpleMode ?? false,
        ),
        parallelMCTS = (config?.useParallel ?? false) 
            ? ParallelMCTS(
                config: config!.mctsConfig,
                numIsolates: config.parallelWorkers,
              ) 
            : null;
  
  /// Main entry point: Choose best move using hybrid approach
  Future<MCTSMove?> chooseMove(MCTSPosition position) async {
    // Check if we're in endgame phase and should use tablebase
    // Note: Tablebase currently only supports Classic mode (24 points)
    // TODO: Generate tablebase for Simple mode
    if (!config.isSimpleMode && config.useTablebaseInEndgame && _isEndgamePhase(position)) {
      // debugPrint('[Hybrid] Endgame detected - using tablebase');
      final tbMove = _searchWithTablebase(position);
      if (tbMove != null) return tbMove;
      
      // Fallback to MCTS if tablebase fails
      // debugPrint('[Hybrid] Tablebase failed - falling back to MCTS');
    }
    
    // Use MCTS for midgame/opening
    if (config.useParallel && parallelMCTS != null) {
      // debugPrint('[Hybrid] Using Parallel MCTS search');
      return await parallelMCTS!.search(position);
    } else {
      // debugPrint('[Hybrid] Using Single-threaded MCTS search');
      return mctsEngine.search(position);
    }
  }
  
  /// Detect endgame phase (suitable for tablebase lookup)
  bool _isEndgamePhase(MCTSPosition pos) {
    // Only use tablebase after placement phase
    if (pos.phase == 0) return false;
    
    final wc = _popcount(pos.whiteBits);
    final bc = _popcount(pos.blackBits);
    
    // Tablebase available for 3v3, 3v4, 4v3, 4v4
    return wc >= 3 && 
           wc <= config.endgamePieceThreshold && 
           bc >= 3 && 
           bc <= config.endgamePieceThreshold;
  }
  
  /// Search using tablebase for perfect endgame play
  MCTSMove? _searchWithTablebase(MCTSPosition pos) {
    final moves = mctsEngine.generateMoves(pos);
    if (moves.isEmpty) return null;
    
    MCTSMove? bestMove;
    int bestScore = -999999;
    
    // Try each move and probe tablebase
    for (final move in moves) {
      final childPos = mctsEngine.makeMove(pos, move);
      
      // Probe tablebase for child position
      final tbScore = tablebaseLoader.probe(
        childPos.whiteBits,
        childPos.blackBits,
        childPos.sideToMove,
      );
      
      if (tbScore == null) continue;
      
      // Convert score to our perspective
      final scoreFromOurPOV = pos.sideToMove == 0 
          ? tbScore   // White's perspective
          : -tbScore; // Black's perspective (flip)
      
      if (scoreFromOurPOV > bestScore) {
        bestScore = scoreFromOurPOV;
        bestMove = move;
      }
    }
    
    if (bestMove != null) {
      debugPrint('[Tablebase] Found move with score $bestScore');
    }
    
    return bestMove;
  }
  
  /// Helper: population count
  int _popcount(int bits) {
    var count = 0;
    while (bits != 0) {
      bits &= bits - 1;
      count++;
    }
    return count;
  }
}

/// Wrapper for easy integration with existing game engine
class HybridAIWrapper {
  final HybridAI ai;
  
  HybridAIWrapper({HybridConfig? config}) : ai = HybridAI(config: config);
  
  /// Choose move given board state in standard format
  /// Returns position (0-23) to place/move to, or null if no move
  Future<int?> chooseMove({
    required List<int> board,
    required int whitePiecesLeft,
    required int blackPiecesLeft,
    required int player,        // 1=white, 2=black
    required int phase,         // 0=placing, 1=moving, 2=flying
  }) async {
    // Convert board to bitboards
    int whiteBits = 0;
    int blackBits = 0;
    
    for (var i = 0; i < board.length; i++) {
      if (board[i] == 1) whiteBits |= (1 << i);
      if (board[i] == 2) blackBits |= (1 << i);
    }
    
    // Create position
    final position = MCTSPosition(
      whiteBits: whiteBits,
      blackBits: blackBits,
      whitePiecesLeft: whitePiecesLeft,
      blackPiecesLeft: blackPiecesLeft,
      sideToMove: player == 1 ? 0 : 1,
      phase: phase,
    );
    
    // Get best move
    final move = await ai.chooseMove(position);
    
    // Return destination square
    return move?.to;
  }
  
  /// Choose full move (from/to/remove) for complex moves
  Future<Map<String, int?>?> chooseFullMove({
    required List<int> board,
    required int whitePiecesLeft,
    required int blackPiecesLeft,
    required int player,
    required int phase,
  }) async {
    // Convert board to bitboards
    int whiteBits = 0;
    int blackBits = 0;
    
    for (var i = 0; i < board.length; i++) {
      if (board[i] == 1) whiteBits |= (1 << i);
      if (board[i] == 2) blackBits |= (1 << i);
    }
    
    // Create position
    final position = MCTSPosition(
      whiteBits: whiteBits,
      blackBits: blackBits,
      whitePiecesLeft: whitePiecesLeft,
      blackPiecesLeft: blackPiecesLeft,
      sideToMove: player == 1 ? 0 : 1,
      phase: phase,
    );
    
    // Get best move
    final move = await ai.chooseMove(position);
    if (move == null) return null;
    
    return {
      'from': move.from,
      'to': move.to,
      'remove': move.remove,
    };
  }
}

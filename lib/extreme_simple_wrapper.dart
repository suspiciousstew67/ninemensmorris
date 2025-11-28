// Extreme AI for Simple mode (placement only, first mill wins)
// This is a wrapper around extreme_ai_simple.dart

import 'extreme_ai_simple.dart' as simple_ai;

class ExtremeSimpleAI {
  final int searchDepth;
  final int maxNodes;
  final int maxMillis;
  
  ExtremeSimpleAI({required this.searchDepth, required this.maxNodes, required this.maxMillis});
  
  int? chooseMove(List<int> board, int whitePiecesLeft, int blackPiecesLeft, int player) {
    // Convert board to bitboards
    int whiteBits = 0, blackBits = 0;
    for (int i = 0; i < board.length; i++) {
      if (board[i] == 1) whiteBits |= (1 << i);
      if (board[i] == 2) blackBits |= (1 << i);
    }
    
    final pos = simple_ai.SimplePosition(
      whiteBits,
      blackBits,
      whitePiecesLeft,
      blackPiecesLeft,
      player == 1 ? 0 : 1,
    );
    
    final best = simple_ai.searchBestMove(pos, searchDepth, maxNodes, maxMillis);
    return best?.to;
  }
}

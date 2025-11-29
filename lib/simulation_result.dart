import 'mcts_node.dart';

class SimulationResult {
  final double score;
  final List<MCTSMove> movesPlayed;
  
  SimulationResult(this.score, this.movesPlayed);
}

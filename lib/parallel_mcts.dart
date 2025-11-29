// Parallel MCTS implementation using Isolates
// Uses Root Parallelization: multiple independent trees are searched in parallel,
// and their results are aggregated to select the best move.

import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:io';

import 'mcts_ai.dart';
import 'mcts_node.dart';

/// Message sent to worker isolate
class _WorkerInput {
  final MCTSPosition position;
  final MCTSConfig config;
  final SendPort sendPort;

  _WorkerInput(this.position, this.config, this.sendPort);
}

/// Message received from worker isolate
class _WorkerOutput {
  final Map<MCTSMove, int> rootVisits; // Visit counts for each root move
  final Map<MCTSMove, double> rootScores; // Total scores for each root move
  final int iterations;

  _WorkerOutput(this.rootVisits, this.rootScores, this.iterations);
}

class ParallelMCTS {
  final MCTSConfig config;
  final int numIsolates;

  ParallelMCTS({
    required this.config,
    int? numIsolates,
  }) : numIsolates = numIsolates ??
            max(1, min(Platform.numberOfProcessors > 1 ? Platform.numberOfProcessors - 1 : 1, 4));

  /// Run parallel MCTS search
  Future<MCTSMove?> search(MCTSPosition position) async {
    final startTime = DateTime.now();
    
    // Divide iterations among isolates?
    // No, for root parallelization, we run full iterations on each isolate
    // to maximize tree size. The time limit ensures we don't run too long.
    // However, if maxIterations is small, we might want to split it.
    // But for "Extreme" difficulty, we want MAX power.
    
    final workerConfig = MCTSConfig(
      explorationConstant: config.explorationConstant,
      maxIterations: config.maxIterations, // Each worker runs full iterations
      maxMilliseconds: config.maxMilliseconds,
      maxSimulationDepth: config.maxSimulationDepth,
      useTablebaseInSimulation: config.useTablebaseInSimulation,
      progressiveWideningFactor: config.progressiveWideningFactor,
    );

    final futures = <Future<_WorkerOutput>>[];

    for (var i = 0; i < numIsolates; i++) {
      futures.add(_spawnWorker(position, workerConfig));
    }

    // Wait for all workers
    final results = await Future.wait(futures);

    // Aggregate results
    final aggregatedVisits = <MCTSMove, int>{};
    final aggregatedScores = <MCTSMove, double>{};
    for (final result in results) {
      
      for (final entry in result.rootVisits.entries) {
        final move = entry.key;
        final visits = entry.value;
        final score = result.rootScores[move] ?? 0.0;
        
        aggregatedVisits[move] = (aggregatedVisits[move] ?? 0) + visits;
        aggregatedScores[move] = (aggregatedScores[move] ?? 0.0) + score;
      }
    }



    if (aggregatedVisits.isEmpty) return null;

    // Select best move (most visited)
    var bestMove = aggregatedVisits.keys.first;
    var maxVisits = -1;

    for (final entry in aggregatedVisits.entries) {
      if (entry.value > maxVisits) {
        maxVisits = entry.value;
        bestMove = entry.key;
      }
    }
    
    // final winRate = aggregatedScores[bestMove]! / maxVisits;
    // print('[Parallel MCTS] Best move: $bestMove (visits: $maxVisits, winRate: ${(winRate * 100).toStringAsFixed(1)}%)');

    return bestMove;
  }

  /// Spawn a worker isolate
  Future<_WorkerOutput> _spawnWorker(MCTSPosition position, MCTSConfig config) async {
    final receivePort = ReceivePort();
    
    await Isolate.spawn(
      _workerEntry,
      _WorkerInput(position, config, receivePort.sendPort),
    );
    
    return await receivePort.first as _WorkerOutput;
  }

  /// Worker entry point
  static void _workerEntry(_WorkerInput input) {
    final engine = MCTSEngine(config: input.config);
    
    final rootMoves = engine.generateMoves(input.position);
    if (rootMoves.isEmpty) {
      input.sendPort.send(_WorkerOutput({}, {}, 0));
      return;
    }

    final rootNode = MCTSNode(
      position: input.position,
      untriedMoves: rootMoves,
      playerJustMoved: 1 - input.position.sideToMove,
    );

    var iterations = 0;
    final startTime = DateTime.now();

    while (iterations < input.config.maxIterations) {
      if (DateTime.now().difference(startTime).inMilliseconds >= input.config.maxMilliseconds) {
        break;
      }

      // 1. Selection
      var node = engine.select(rootNode);

      // 2. Expansion
      if (!node.isTerminal && node.untriedMoves.isNotEmpty) {
        node = engine.expand(node);
      }

      // 3. Simulation
      final movesPlayed = <MCTSMove>[];
      final result = engine.simulate(node.position, input.position.sideToMove, movesPlayed);

      // 4. Backpropagation
      engine.backpropagate(node, result, input.position.sideToMove, movesPlayed);
      
      iterations++;
    }
    
    // Collect root stats
    final rootVisits = <MCTSMove, int>{};
    final rootScores = <MCTSMove, double>{};
    
    for (final child in rootNode.children) {
      if (child.moveToReach != null) {
        rootVisits[child.moveToReach!] = child.visits;
        rootScores[child.moveToReach!] = child.totalScore;
      }
    }
    
    input.sendPort.send(_WorkerOutput(rootVisits, rootScores, iterations));
  }
}

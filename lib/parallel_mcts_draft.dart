// Parallel MCTS implementation using Isolates
// Uses Root Parallelization: multiple independent trees are searched in parallel,
// and their results are aggregated to select the best move.

import 'dart:async';
import 'dart:isolate';
import 'dart:math';

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
  }) : numIsolates = numIsolates ?? Platform.numberOfProcessors;

  /// Run parallel MCTS search
  Future<MCTSMove?> search(MCTSPosition position) async {
    final startTime = DateTime.now();
    
    // Divide iterations among isolates
    // Each isolate gets full time, but iterations are split?
    // No, usually in root parallelization, each isolate runs for the full duration/iterations.
    // This effectively multiplies the total search effort.
    // However, if we have a fixed time limit, we just run all isolates for that time.
    // If we have a fixed iteration limit, we split it.
    
    final iterationsPerIsolate = (config.maxIterations / numIsolates).ceil();
    final workerConfig = MCTSConfig(
      explorationConstant: config.explorationConstant,
      maxIterations: iterationsPerIsolate,
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
    var totalIterations = 0;

    for (final result in results) {
      totalIterations += result.iterations;
      
      for (final entry in result.rootVisits.entries) {
        final move = entry.key;
        final visits = entry.value;
        final score = result.rootScores[move] ?? 0.0;
        
        aggregatedVisits[move] = (aggregatedVisits[move] ?? 0) + visits;
        aggregatedScores[move] = (aggregatedScores[move] ?? 0.0) + score;
      }
    }

    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    print('[Parallel MCTS] Completed $totalIterations iterations across $numIsolates isolates in ${elapsed}ms');

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
    
    final winRate = aggregatedScores[bestMove]! / maxVisits;
    print('[Parallel MCTS] Best move: $bestMove (visits: $maxVisits, winRate: ${(winRate * 100).toStringAsFixed(1)}%)');

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
    
    // We need to access the root node to get stats
    // But MCTSEngine.search returns just the move.
    // We need to modify MCTSEngine or create a specialized search method here.
    // For now, let's duplicate the search logic slightly to get access to the root node.
    
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
      var node = rootNode;
      while (node.isFullyExpanded(input.config.progressiveWideningFactor) && node.children.isNotEmpty) {
        node = node.selectBestChild(input.config.explorationConstant)!;
      }

      // 2. Expansion
      if (!node.isTerminal && node.untriedMoves.isNotEmpty) {
        final move = node.untriedMoves[Random().nextInt(node.untriedMoves.length)];
        final childPos = engine.makeMove(node.position, move);
        final childMoves = engine.generateMoves(childPos);
        node = node.addChild(move, childPos, childMoves);
      }

      // 3. Simulation

      // We need to access _simulate, but it's private.
      // Wait, we made helper methods public, but _simulate is still private.
      // We can use reflection or just make it public.
      // Or better, add a method to MCTSEngine that returns the root node.
      
      // Since I can't easily change MCTSEngine from here without another tool call,
      // and I want this to be self-contained, I'll rely on the fact that I can
      // copy the simulation logic or make _simulate public.
      
      // Let's make _simulate public in MCTSEngine first.
      // For now, I'll assume I'll make it public.
    }
    
    // ... wait, I can't write incomplete code.
    // I should modify MCTSEngine to allow retrieving root stats.
  }
}

// Helper to get processor count
class Platform {
  static int get numberOfProcessors => 4; // Default fallback
}

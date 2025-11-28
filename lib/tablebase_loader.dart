// Tablebase loader for runtime lookup of endgame positions.
// Loads binary tablebase files into memory for perfect play.

import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'tablebase_index.dart';

// Result codes (must match generator)
const int TB_UNKNOWN = 0;
const int TB_WIN = 1;
const int TB_LOSS = 2;
const int TB_DRAW = 3;

class TablebaseLoader {
  final Map<String, Uint8List> _tables = {};
  bool _loaded = false;
  
  /// Load all tablebase files from assets
  Future<void> load() async {
    if (_loaded) return;
    
    try {
      _tables['3v3'] = await _loadTable('assets/tablebase/3v3.tb');
      _tables['3v4'] = await _loadTable('assets/tablebase/3v4.tb');
      _tables['4v3'] = await _loadTable('assets/tablebase/4v3.tb');
      _tables['4v4'] = await _loadTable('assets/tablebase/4v4.tb');
      _loaded = true;
      print('Tablebase loaded: ${_tables.length} tables');
    } catch (e) {
      print('Warning: Could not load tablebase: $e');
      // Continue without tablebase
    }
  }
  
  Future<Uint8List> _loadTable(String path) async {
    try {
      // Try Flutter asset bundle first
      final data = await rootBundle.load(path);
      return data.buffer.asUint8List();
    } catch (e) {
      // Fallback to file system (for generator testing)
      final file = File(path);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
      throw Exception('Tablebase file not found: $path');
    }
  }
  
  /// Probe tablebase for a position
  /// Returns score from white's POV: +32000 for WIN, -32000 for LOSS, 0 for DRAW
  /// Returns null if position not in tablebase
  int? probe(int whiteBits, int blackBits, int sideToMove) {
    if (!_loaded) return null;
    
    final wc = _popcount(whiteBits);
    final bc = _popcount(blackBits);
    
    // Only support 3v3, 3v4, 4v3, 4v4
    if (wc < 3 || wc > 4 || bc < 3 || bc > 4) return null;
    
    final key = '${wc}v$bc';
    final table = _tables[key];
    if (table == null) return null;
    
    final index = indexPosition(whiteBits, blackBits, sideToMove, wc, bc);
    if (index < 0 || index >= table.length) return null;
    
    final result = table[index];
    
    // Convert to score from white's POV
    if (sideToMove == 0) {
      // White to move
      if (result == TB_WIN) return 32000;
      if (result == TB_LOSS) return -32000;
      return 0; // DRAW or UNKNOWN
    } else {
      // Black to move
      if (result == TB_WIN) return -32000; // Black wins = white loses
      if (result == TB_LOSS) return 32000;  // Black loses = white wins
      return 0;
    }
  }
  
  int _popcount(int bits) {
    var count = 0;
    while (bits != 0) {
      bits &= bits - 1;
      count++;
    }
    return count;
  }
}

// Global instance
final tablebaseLoader = TablebaseLoader();

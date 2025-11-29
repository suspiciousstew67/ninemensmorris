// Combinatorial indexing for Nine Men's Morris tablebase.
// Maps board positions to unique integer indices for dense array storage.



const int boardSize = 24;

// Precomputed binomial coefficients C(n, k) for n <= 24
final List<List<int>> _binomialCache = _buildBinomialCache();

List<List<int>> _buildBinomialCache() {
  final cache = List<List<int>>.generate(25, (n) => List<int>.filled(25, 0));
  for (var n = 0; n <= 24; n++) {
    cache[n][0] = 1;
    for (var k = 1; k <= n; k++) {
      cache[n][k] = cache[n - 1][k - 1] + cache[n - 1][k];
    }
  }
  return cache;
}

int binomial(int n, int k) {
  if (k < 0 || k > n) return 0;
  return _binomialCache[n][k];
}

// Convert list of occupied squares (sorted) to combinatorial index
int squaresToIndex(List<int> squares) {
  if (squares.isEmpty) return 0;
  var index = 0;
  for (var i = 0; i < squares.length; i++) {
    index += binomial(squares[i], i + 1);
  }
  return index;
}

// Convert combinatorial index back to list of occupied squares
List<int> indexToSquares(int index, int numPieces) {
  final squares = <int>[];
  var remaining = index;
  var square = boardSize - 1;
  
  for (var piece = numPieces; piece > 0; piece--) {
    while (square >= 0 && binomial(square, piece) > remaining) {
      square--;
    }
    if (square >= 0) {
      squares.insert(0, square);
      remaining -= binomial(square, piece);
    }
  }
  
  return squares;
}

// Extract occupied squares from bitboard
List<int> bitboardToSquares(int bitboard) {
  final squares = <int>[];
  for (var sq = 0; sq < boardSize; sq++) {
    if ((bitboard & (1 << sq)) != 0) {
      squares.add(sq);
    }
  }
  return squares;
}

// Convert squares to bitboard
int squaresToBitboard(List<int> squares) {
  var bb = 0;
  for (final sq in squares) {
    bb |= (1 << sq);
  }
  return bb;
}

/// Index a position for tablebase lookup.
/// Returns the unique index for this position in the tablebase.
/// 
/// Formula: index = whiteIndex * numBlackConfigs + blackIndex * 2 + stm
int indexPosition(int whiteBits, int blackBits, int stm, int numWhite, int numBlack) {
  final whiteSquares = bitboardToSquares(whiteBits);
  final blackSquares = bitboardToSquares(blackBits);
  
  final whiteIndex = squaresToIndex(whiteSquares);
  final blackIndex = squaresToIndex(blackSquares);
  
  // Calculate how many ways to place black pieces on remaining squares
  final numBlackConfigs = binomial(boardSize - numWhite, numBlack);
  
  return whiteIndex * numBlackConfigs * 2 + blackIndex * 2 + stm;
}

/// Deindex a tablebase position back to board state.
/// Returns (whiteBits, blackBits, stm).
List<int> deindexPosition(int index, int numWhite, int numBlack) {
  final numBlackConfigs = binomial(boardSize - numWhite, numBlack);
  final configsPerSide = numBlackConfigs * 2;
  
  final whiteIndex = index ~/ configsPerSide;
  final remainder = index % configsPerSide;
  final blackIndex = remainder ~/ 2;
  final stm = remainder % 2;
  
  final whiteSquares = indexToSquares(whiteIndex, numWhite);
  final blackSquares = indexToSquares(blackIndex, numBlack);
  
  final whiteBits = squaresToBitboard(whiteSquares);
  final blackBits = squaresToBitboard(blackSquares);
  
  return [whiteBits, blackBits, stm];
}

/// Calculate total number of positions for given piece counts
int numPositions(int numWhite, int numBlack) {
  return binomial(boardSize, numWhite) * 
         binomial(boardSize - numWhite, numBlack) * 2;
}

// START OF FINAL AI.JS
window.AIPlayer = class AIPlayer {
    constructor(difficulty = 'medium') {
        this.difficulty = difficulty;
        this.player = 2; // AI is always player 2
    }

    makeMove(game) {
        if (game.settings.gameMode === 'simple') {
            const position = this.runSimpleLogic(game);
            return { to: position };
        } else {
            return this.runClassicLogic(game);
        }
    }

    runSimpleLogic(game) {
        switch (this.difficulty) {
            case 'easy':
                return this.makeRandomMove(game);
            case 'medium':
                return this.makeSimpleMediumMove(game);
            case 'hard':
                const simulationGame = { board: [...game.board], millPatterns: game.millPatterns };
                const result = this.minimaxSimple(simulationGame, 4, -Infinity, Infinity, true);
                return result.move !== -1 ? result.move : this.makeRandomMove(game);
            default:
                return this.makeSimpleMediumMove(game);
        }
    }

    makeSimpleMediumMove(game) {
        const winningMove = this.findWinningMove(game, this.player);
        if (winningMove !== -1) return winningMove;

        const blockingMove = this.findWinningMove(game, 1);
        if (blockingMove !== -1) return blockingMove;

        return this.makeRandomMove(game);
    }

    makeRandomMove(game) {
        const emptyPositions = game.board.map((p, i) => (p === null ? i : null)).filter(p => p !== null);
        if (emptyPositions.length === 0) return -1;
        return emptyPositions[Math.floor(Math.random() * emptyPositions.length)];
    }
    
    minimaxSimple(game, depth, alpha, beta, isMaximizing) {
        const winner = this.checkSimpleWinner(game);
        if (winner !== null) return { move: null, score: winner === this.player ? 100 : -100 };
        if (depth === 0) return { move: null, score: 0 };
        const emptyPositions = game.board.map((p, i) => (p === null ? i : null)).filter(p => p !== null);
        if (emptyPositions.length === 0) return { move: null, score: 0 };
        let bestMove = -1;
        if (isMaximizing) {
            let maxEval = -Infinity;
            for (const move of emptyPositions) {
                game.board[move] = this.player;
                let evalScore = this.minimaxSimple(game, depth - 1, alpha, beta, false).score;
                game.board[move] = null;
                if (evalScore > maxEval) { maxEval = evalScore; bestMove = move; }
                alpha = Math.max(alpha, evalScore);
                if (beta <= alpha) break;
            }
            return { move: bestMove, score: maxEval };
        } else {
            let minEval = Infinity;
            for (const move of emptyPositions) {
                game.board[move] = 1;
                let evalScore = this.minimaxSimple(game, depth - 1, alpha, beta, true).score;
                game.board[move] = null;
                if (evalScore < minEval) { minEval = evalScore; bestMove = move; }
                beta = Math.min(beta, evalScore);
                if (beta <= alpha) break;
            }
            return { move: bestMove, score: minEval };
        }
    }

    checkSimpleWinner(game) {
        for (const pattern of game.millPatterns) {
            const p1 = game.board[pattern[0]];
            if (p1 !== null && p1 === game.board[pattern[1]] && p1 === game.board[pattern[2]]) {
                return p1;
            }
        }
        return null;
    }

    runClassicLogic(game) {
        const opponent = 1;
        const allMyMoves = this.generateAllMoves(game, this.player);
        if (allMyMoves.length === 0) return { from: null, to: null, remove: null };

        const millMoves = allMyMoves.filter(m => m.createsMill);
        if (millMoves.length > 0) {
            const move = millMoves[0];
            move.remove = this.choosePieceToRemove(game, opponent, move.board);
            return move;
        }

        const opponentWinningMove = this.findWinningMove(game, opponent);
        if (opponentWinningMove !== -1) {
            const blockingMove = allMyMoves.find(myMove => myMove.to === opponentWinningMove);
            if (blockingMove) return blockingMove;
        }
        
        const setupMoves = allMyMoves.filter(move => this.createsSetup(move, this.player, game.millPatterns));
        if (setupMoves.length > 0) return setupMoves[Math.floor(Math.random() * setupMoves.length)];

        const allOpponentMoves = this.generateAllMoves(game, opponent);
        const opponentSetupMove = allOpponentMoves.find(move => this.createsSetup(move, opponent, game.millPatterns));
        if (opponentSetupMove) {
            const blockingMove = allMyMoves.find(myMove => myMove.to === opponentSetupMove.to);
            if (blockingMove) return blockingMove;
        }

        return allMyMoves[Math.floor(Math.random() * allMyMoves.length)];
    }
    
    createsSetup(move, player, millPatterns) {
        return millPatterns.some(pattern => {
            if (!pattern.includes(move.to)) return false;
            const pieces = pattern.map(p => move.board[p]);
            return pieces.filter(p => p === player).length === 2 && pieces.filter(p => p === null).length === 1;
        });
    }

    choosePieceToRemove(game, opponent, boardState) {
        const removablePieces = this.getRemovablePieces(game, opponent, boardState);
        if (removablePieces.length === 0) return null;
        return removablePieces[0];
    }
    
    findWinningMove(game, player) {
        for (const pattern of game.millPatterns) {
            const pieces = pattern.map(pos => game.board[pos]);
            if (pieces.filter(p => p === player).length === 2 && pieces.includes(null)) {
                return pattern[pieces.indexOf(null)];
            }
        }
        return -1;
    }

    generateAllMoves(game, player) {
        let moves = [];
        const board = game.board;
        const gamePhase = (game.piecesLeft[player] > 0) ? 'placing' : (game.piecesOnBoard[player] === 3 ? 'flying' : 'moving');

        if (gamePhase === 'placing') {
            for (let i = 0; i < board.length; i++) {
                if (board[i] === null) {
                    const tempBoard = [...board];
                    tempBoard[i] = player;
                    moves.push({ from: null, to: i, remove: null, createsMill: this.isPositionInMill(i, player, tempBoard, game.millPatterns), board: tempBoard });
                }
            }
        } else {
            const playerPieces = [...board.keys()].filter(i => board[i] === player);
            const isFlying = gamePhase === 'flying';
            for (const from of playerPieces) {
                const destinations = isFlying ? [...board.keys()].filter(i => board[i] === null) : game.adjacencyMap[from].filter(i => board[i] === null);
                for (const to of destinations) {
                    const tempBoard = [...board];
                    tempBoard[to] = player;
                    tempBoard[from] = null;
                    moves.push({ from: from, to: to, remove: null, createsMill: this.isPositionInMill(to, player, tempBoard, game.millPatterns), board: tempBoard });
                }
            }
        }
        return moves;
    }

    getRemovablePieces(game, player, boardState) {
        const board = boardState || game.board;
        const allPieces = [...board.keys()].filter(i => board[i] === player);
        const nonMillPieces = allPieces.filter(p => !this.isPositionInMill(p, player, board, game.millPatterns));
        return nonMillPieces.length > 0 ? nonMillPieces : allPieces;
    }

    isPositionInMill(position, player, board, millPatterns) {
        if (position === null || player === null) return false;
        return millPatterns.some(pattern => pattern.includes(position) && pattern.every(p => board[p] === player));
    }
};
/**
 * AI Player with different difficulty levels
 */
class AIPlayer {
    constructor(difficulty = 'medium') {
        this.difficulty = difficulty;
        this.player = 2; // AI is always player 2
    }

    makeMove(game) {
        switch (this.difficulty) {
            case 'easy': return this.makeRandomMove(game);
            case 'medium': return this.makeMediumMove(game);
            case 'hard': return this.makeHardMove(game);
            default: return this.makeMediumMove(game);
        }
    }

    makeRandomMove(game) {
        const emptyPositions = game.board.map((p, i) => p === null ? i : null).filter(p => p !== null);
        if (emptyPositions.length === 0) return -1;
        return emptyPositions[Math.floor(Math.random() * emptyPositions.length)];
    }

    makeMediumMove(game) {
        const moves = [
            this.findWinningMove(game, this.player), // 1. Win
            this.findWinningMove(game, 1),           // 2. Block win
            this.findSetupMove(game, this.player),   // 3. Setup mill
            this.getStrategicMove(game),             // 4. Strategic move
            this.makeRandomMove(game)                // 5. Fallback
        ];
        // Find the first valid move from the priority list
        return moves.find(move => move !== -1 && move !== undefined);
    }

    makeHardMove(game) {
        const moves = [
            this.findWinningMove(game, this.player),
            this.findWinningMove(game, 1),
            this.findDoubleMill(game, this.player), // FIX: Corrected logic
            this.findDoubleMill(game, 1),
            this.findSetupMove(game, this.player),
            this.getBestPositionalMove(game),       // FIX: Corrected logic
            this.makeRandomMove(game)
        ];
        // Find the first valid move from the priority list
        return moves.find(move => move !== -1 && move !== undefined);
    }
    
    getStrategicMove(game) {
        const centerPositions = [9, 11, 13, 15, 17, 19, 21, 23];
        const availableCenters = centerPositions.filter(pos => game.board[pos] === null);
        if (availableCenters.length > 0) {
            return availableCenters[Math.floor(Math.random() * availableCenters.length)];
        }
        return -1;
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

    findSetupMove(game, player) {
        for (const pattern of game.millPatterns) {
            const pieces = pattern.map(pos => game.board[pos]);
            if (pieces.filter(p => p === player).length === 1 && pieces.filter(p => p === null).length === 2) {
                const emptyIndex = pieces.indexOf(null);
                return pattern[emptyIndex];
            }
        }
        return -1;
    }

    /**
     * FIX: Corrected the logic for finding a double mill.
     * It now correctly checks if placing a piece at 'move' would create two separate threats.
     */
    findDoubleMill(game, player) {
        const emptyPositions = game.board.map((p, i) => (p === null ? i : null)).filter(p => p !== null);

        for (const move of emptyPositions) {
            let potentialThreatsFormed = 0;
            const relevantPatterns = game.millPatterns.filter(p => p.includes(move));
            
            for (const pattern of relevantPatterns) {
                const otherPositions = pattern.filter(p => p !== move);
                const pos1 = otherPositions[0];
                const pos2 = otherPositions[1];

                if ((game.board[pos1] === player && game.board[pos2] === null) || 
                    (game.board[pos2] === player && game.board[pos1] === null)) {
                    potentialThreatsFormed++;
                }
            }

            if (potentialThreatsFormed >= 2) {
                return move;
            }
        }

        return -1;
    }

    /**
     * FIX: Corrected the logic for finding the best positional move.
     * It now properly references `this.player` and has sounder logic.
     */
    getBestPositionalMove(game) {
        const empty = game.board.map((p, i) => (p === null ? i : null)).filter(p => p !== null);
        if (empty.length === 0) return -1;

        let bestMove = -1;
        let bestScore = -Infinity;
        const opponent = this.player === 1 ? 2 : 1;

        for (const pos of empty) {
            let score = 0;
            for (const pattern of game.millPatterns) {
                if (pattern.includes(pos)) {
                    if (!pattern.some(p => game.board[p] === opponent)) {
                        score++;
                    }
                }
            }
            if (score > bestScore) {
                bestScore = score;
                bestMove = pos;
            }
        }
        return bestMove;
    }
}

class NineMensMorrisGame {
    constructor() {
        this.board = Array(24).fill(null);
        this.currentPlayer = 1;
        this.piecesLeft = { 1: 9, 2: 9 };
        this.gameOver = false;
        this.winningPositions = [];
        this.isAIThinking = false;
        
        this.millPatterns = [
            [0, 1, 2], [2, 3, 4], [4, 5, 6], [6, 7, 0], [8, 9, 10], [10, 11, 12], 
            [12, 13, 14], [14, 15, 8], [16, 17, 18], [18, 19, 20], [20, 21, 22], 
            [22, 23, 16], [1, 9, 17], [3, 11, 19], [5, 13, 21], [7, 15, 23]
        ];
        
        this.confettiPool = [];
        this.confettiContainer = document.getElementById('confetti-container');
        
        this.prepareConfetti();
        this.initializeGame();
    }

    initializeGame() {
        document.querySelector('.game-board').addEventListener('click', (e) => {
            if (e.target.classList.contains('board-position')) this.handlePositionClick(e.target);
        });
        const initialMode = document.querySelector('.mode-button.active').getAttribute('onclick').match(/'([^']+)'/)[1];
        this.setGameMode(initialMode, true);
    }
    
    prepareConfetti() {
        const confettiCount = 50;
        const colors = ['#e67e22', '#3498db', '#9b59b6', '#f1c40f', '#e74c3c'];
        for (let i = 0; i < confettiCount; i++) {
            const confetti = document.createElement('div');
            confetti.className = 'confetti';
            confetti.style.background = colors[Math.floor(Math.random() * colors.length)];
            this.confettiContainer.appendChild(confetti);
            this.confettiPool.push(confetti);
        }
    }

    setGameMode(mode, isInitial = false) {
        this.gameMode = mode;
        if (mode !== 'human') {
            const difficulty = mode.replace('ai-', '');
            this.ai = new AIPlayer(difficulty);
            document.body.setAttribute('data-ai-mode', 'true');
        } else {
            this.ai = null;
            document.body.setAttribute('data-ai-mode', 'false');
        }
        
        this.updateModeButtons();
        if (!isInitial) this.reset();
    }

    updateModeButtons() {
        document.querySelectorAll('.mode-button').forEach(btn => btn.classList.remove('active'));
        const activeBtn = document.querySelector(`.mode-button[onclick="setGameMode('${this.gameMode}')"]`);
        if (activeBtn) activeBtn.classList.add('active');
    }

    updatePlayerLabels() {
        const p1Name = document.getElementById('player1-name');
        const p2Name = document.getElementById('player2-name');
        if (this.gameMode === 'human') {
            p1Name.textContent = 'Player 1';
            p2Name.textContent = 'Player 2';
        } else {
            p1Name.textContent = 'Human';
            p2Name.textContent = 'AI';
        }
    }

    handlePositionClick(target) {
        if (this.gameOver || this.isAIThinking) return;
        if (this.gameMode !== 'human' && this.currentPlayer === 2) return;
        
        const position = parseInt(target.dataset.position);
        if (this.board[position] !== null) return;
        
        this.makeMove(position);
    }

    async makeMove(position) {
        if (this.gameOver) return;
        
        this.board[position] = this.currentPlayer;
        this.piecesLeft[this.currentPlayer]--;
        
        if (this.checkForMill(position, this.currentPlayer)) {
            this.renderBoard();
            this.endGame(`${this.getPlayerName(this.currentPlayer)} Wins!`);
            return;
        }
        
        if (this.piecesLeft[1] === 0 && this.piecesLeft[2] === 0) {
            this.renderBoard();
            this.endGame("It's a Draw!");
            return;
        }
        
        this.currentPlayer = this.currentPlayer === 1 ? 2 : 1;
        this.renderBoard();
        this.updateDisplay();
        
        if (this.gameMode !== 'human' && this.currentPlayer === 2 && !this.gameOver) {
            await this.makeAIMove();
        }
    }

    async makeAIMove() {
        if (!this.ai || this.gameOver) return;
        
        this.isAIThinking = true;
        this.showAIThinking(true);
        
        await new Promise(resolve => setTimeout(resolve, 600 + Math.random() * 400));
        
        const aiMove = this.ai.makeMove(this);
        
        this.isAIThinking = false;
        this.showAIThinking(false);

        if (aiMove !== -1 && aiMove !== undefined) {
            this.makeMove(aiMove);
        } else {
            this.endGame("It's a Draw!");
        }
    }

    showAIThinking(show) {
        document.getElementById('player2-panel').classList.toggle('thinking', show);
    }

    getPlayerName(player) {
        return document.getElementById(`player${player}-name`).textContent;
    }

    checkForMill(position, player) {
        for (const pattern of this.millPatterns) {
            if (pattern.includes(position) && pattern.every(pos => this.board[pos] === player)) {
                this.winningPositions = pattern;
                return true;
            }
        }
        return false;
    }

    renderBoard() {
        document.querySelectorAll('.board-position').forEach((pos, index) => {
            pos.classList.remove('occupied', 'winning-position', 'player1', 'player2');
            if (this.board[index] !== null) {
                pos.classList.add('occupied', `player${this.board[index]}`);
            }
            if (this.gameOver && this.winningPositions.includes(index)) {
                pos.classList.add('winning-position');
            }
        });
    }

    updateDisplay() {
        document.getElementById('player1-pieces').textContent = `${this.piecesLeft[1]} pieces remaining`;
        document.getElementById('player2-pieces').textContent = `${this.piecesLeft[2]} pieces remaining`;
        
        const p1Panel = document.getElementById('player1-panel');
        const p2Panel = document.getElementById('player2-panel');
        
        if (!this.gameOver) {
            p1Panel.classList.toggle('active', this.currentPlayer === 1);
            p2Panel.classList.toggle('active', this.currentPlayer === 2);
        }
    }

    endGame(message) {
        this.gameOver = true;
        document.getElementById('game-over-message').textContent = message;
        document.getElementById('player1-panel').classList.remove('active');
        document.getElementById('player2-panel').classList.remove('active');
        
        if (message.includes('Wins!')) {
            this.launchConfetti();
        }
    }
    
    launchConfetti() {
        this.confettiPool.forEach(confetti => {
            confetti.classList.remove('animate');
            confetti.style.left = Math.random() * 100 + 'vw';
            confetti.style.animationDelay = Math.random() * 0.3 + 's';
            setTimeout(() => confetti.classList.add('animate'), 10);
        });
    }

    reset() {
        this.board.fill(null);
        this.currentPlayer = 1;
        this.piecesLeft = { 1: 9, 2: 9 };
        this.gameOver = false;
        this.winningPositions = [];
        this.isAIThinking = false;
        
        document.getElementById('game-over-message').textContent = '';
        this.showAIThinking(false);
        this.renderBoard();
        this.updatePlayerLabels();
        this.updateDisplay();
    }
}

let game;
document.addEventListener('DOMContentLoaded', () => { game = new NineMensMorrisGame(); });
function resetGame() { if (game) game.reset(); }
function setGameMode(mode) { if (game) game.setGameMode(mode); }
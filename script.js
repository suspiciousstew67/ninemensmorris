// script.js (FINAL - With DOM and Bug Fixes)
const AIPlayer = window.AIPlayer;

class NineMensMorrisGame {
    constructor() {
        this.board = Array(24).fill(null);
        this.currentPlayer = 1;
        this.gameOver = false;
        this.isAIThinking = false;
        this.player1Name = "You";
        this.player2Name = "Opponent";
        this.onNameSetCallback = null;
        this.networkSocket = null;
        this.lastPingTime = null;
        this.currentPing = 0;

        this.settings = {
            difficulty: 'hard', gameType: 'ai', gameMode: 'classic',
            darkMode: true, networkRole: 'none', isMyTurn: true,
        };
        
        this.availableGameTypes = ['ai', 'human', 'network'];
        this.loadSettings();

        this.gamePhase = 'placing';
        this.piecesLeft = { 1: 9, 2: 9 };
        this.piecesOnBoard = { 1: 0, 2: 0 };
        this.isRemovingPiece = false;
        this.selectedPiece = null;
        this.winningPositions = [];
        this.availableDifficulties = ['easy', 'medium', 'hard'];
        this.availableGameModes = ['simple', 'classic'];
        this.ai = null;
        this.millPatterns = [[0,1,2],[2,3,4],[4,5,6],[6,7,0],[8,9,10],[10,11,12],[12,13,14],[14,15,8],[16,17,18],[18,19,20],[20,21,22],[22,23,16],[1,9,17],[3,11,19],[5,13,21],[7,15,23]];
        this.adjacencyMap = { 0:[1,7],1:[0,2,9],2:[1,3],3:[2,4,11],4:[3,5],5:[4,6,13],6:[5,7],7:[0,6,15],8:[9,15],9:[1,8,10,17],10:[9,11],11:[3,10,12,19],12:[11,13],13:[5,12,14,21],14:[13,15],15:[7,8,14,23],16:[17,23],17:[9,16,18],18:[17,19],19:[11,18,20],20:[19,21],21:[13,20,22],22:[21,23],23:[15,16,22] };

        this.dom = {
    player1: { name: document.getElementById('player1-name'), pieces: document.getElementById('player1-pieces'), nameInput: document.getElementById('player1-name-input') },
    player2: { panel: document.getElementById('player2-panel'), name: document.getElementById('player2-name'), pieces: document.getElementById('player2-pieces') },
    resetButton: document.getElementById('reset-button'),
    settingsButton: document.getElementById('settings-button'),
    boardSVG: document.getElementById('game-board-svg'),
    allHitboxes: document.querySelectorAll('#game-board-svg .hitbox'),
    allPieces: document.querySelectorAll('#game-board-svg .piece'),
    confettiContainer: document.getElementById('confetti-container'),
    settingsModal: document.getElementById('settings-modal'),
    closeSettingsBtn: document.getElementById('close-settings-button'),
    gametypeSetting: document.getElementById('gametype-setting'),
    gametypeValue: document.getElementById('gametype-value'),
    difficultySetting: document.getElementById('difficulty-setting'),
    difficultyValue: document.getElementById('difficulty-value'),
    gamemodeSetting: document.getElementById('gamemode-setting'),
    gamemodeValue: document.getElementById('gamemode-value'),
    darkmodeSetting: document.getElementById('darkmode-setting'),
    darkmodeValue: document.getElementById('darkmode-value'),
    updateNotification: document.getElementById('update-notification'),
    updateMessage: document.getElementById('update-message'),
    downloadUpdateBtn: document.getElementById('download-update-btn'),
    dismissUpdateBtn: document.getElementById('dismiss-update-btn'),
    networkSettings: document.getElementById('network-settings'),
    joinIpInput: document.getElementById('join-ip-input'),
    networkActions: document.getElementById('network-actions'),
    hostInfoPanel: document.getElementById('host-info-panel'),
    roomCodeDisplay: document.getElementById('room-code-display'),
    hostStatus: document.getElementById('host-status'),
    cancelHostBtn: document.getElementById('cancel-host-btn'),
    hostGameBtn: document.getElementById('host-game-btn'),
    joinGameBtn: document.getElementById('join-game-btn'),
    namePromptModal: document.getElementById('name-prompt-modal'),
    namePromptInput: document.getElementById('name-prompt-input'),
    namePromptConfirm: document.getElementById('name-prompt-confirm'),
    namePromptCancel: document.getElementById('name-prompt-cancel'),
    playAgainBtn: document.getElementById('play-again-button'),
    pingIndicator: document.querySelector('.ping-indicator'),
    pingValue: document.getElementById('ping-value'),
    pingFill: document.getElementById('ping-fill'),
};
    }
    
    saveSettings() {
        const settingsToSave = { gameType: this.settings.gameType, difficulty: this.settings.difficulty, gameMode: this.settings.gameMode, darkMode: this.settings.darkMode, player1Name: this.player1Name, };
        localStorage.setItem('nineMensMorrisSettings', JSON.stringify(settingsToSave));
    }

    loadSettings() {
        const savedSettings = localStorage.getItem('nineMensMorrisSettings');
        if (savedSettings) {
            const parsed = JSON.parse(savedSettings);
            this.settings.gameType = parsed.gameType || 'ai';
            this.settings.difficulty = parsed.difficulty || 'hard';
            this.settings.gameMode = parsed.gameMode || 'classic';
            this.settings.darkMode = parsed.darkMode !== undefined ? parsed.darkMode : true;
            this.player1Name = parsed.player1Name || 'You';
        }
    }
    
    applySettings() {
        document.body.classList.toggle('light-mode', !this.settings.darkMode);
        this.updateSettingsDisplay();
    }

    initialize() {
        this.applySettings();
        this.setupDOMListeners();
        if (window.ipcRenderer) {
            window.ipcRenderer.on('update-info-available', (info) => this.showUpdateNotification(info));
        }
        if (window.Capacitor && window.Capacitor.isNativePlatform()) {
            this.setupCapacitorListeners();
        }
        this.reset();
    }
    
    setupCapacitorListeners() {
        const { App, StatusBar, Style } = window.Capacitor.Plugins;
        StatusBar.setStyle({ style: this.settings.darkMode ? Style.Dark : Style.Light });
        App.addListener('backButton', () => {
            if (!this.dom.settingsModal.classList.contains('hidden')) { this.toggleSettingsModal(false); } 
            else { App.exitApp(); }
        });
    }

    setupDOMListeners() {
        if (!this.dom.settingsButton) {
            console.error('Settings button not found');
            return;
        }
        
        this.dom.boardSVG.addEventListener('click', (e) => { if (e.target.classList.contains('hitbox')) this.handlePositionClick(e.target); });
        this.dom.resetButton.addEventListener('click', () => this.reset());
        this.dom.settingsButton.addEventListener('click', () => this.toggleSettingsModal(true));
        this.dom.closeSettingsBtn.addEventListener('click', () => this.toggleSettingsModal(false));
        this.dom.gametypeSetting.addEventListener('click', () => this.cycleGameType());
        this.dom.difficultySetting.addEventListener('click', () => this.cycleDifficulty());
        this.dom.hostGameBtn.addEventListener('click', () => this.hostGame());
        this.dom.joinGameBtn.addEventListener('click', () => this.joinGame());
        this.dom.cancelHostBtn.addEventListener('click', () => this.cancelHost());
        if (this.dom.joinIpInput) {
            // Force uppercase and allow only A-Z0-9 characters as the user types
            this.dom.joinIpInput.addEventListener('input', (e) => {
                const cleaned = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
                if (e.target.value !== cleaned) e.target.value = cleaned;
            });
        }
        this.dom.gamemodeSetting.addEventListener('click', () => this.cycleGameMode());
        this.dom.darkmodeSetting.addEventListener('click', () => this.toggleDarkMode());
        if (this.dom.downloadUpdateBtn) this.dom.downloadUpdateBtn.addEventListener('click', () => this.downloadUpdate());
        if (this.dom.dismissUpdateBtn) this.dom.dismissUpdateBtn.addEventListener('click', () => this.hideUpdateNotification());
        this.dom.player1.name.addEventListener('click', () => this.toggleNameEdit(true));
        this.dom.player1.nameInput.addEventListener('blur', () => this.toggleNameEdit(false));
        this.dom.player1.nameInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') this.toggleNameEdit(false); });
        this.dom.namePromptConfirm.addEventListener('click', () => this.confirmNamePrompt());
        this.dom.namePromptCancel.addEventListener('click', () => this.closeNamePrompt());
        this.dom.namePromptInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') this.confirmNamePrompt(); });
        if (this.dom.playAgainBtn) this.dom.playAgainBtn.addEventListener('click', () => this.playAgain());
        // Settings -> About panel
        this.dom.aboutRow = document.getElementById('about-row');
        this.dom.aboutPanel = document.getElementById('about-modal');
        this.dom.aboutBackBtn = document.getElementById('about-back-btn');
        this.dom.copyDebugBtn = document.getElementById('copy-debug-btn');
        this.dom.openRepoBtn = document.getElementById('open-repo-btn');
        this.dom.aboutGithub = document.getElementById('about-github');
        this.dom.debugBox = document.getElementById('debug-box');
        this.dom.aboutBuild = document.getElementById('about-build');
        if (this.dom.aboutRow) this.dom.aboutRow.addEventListener('click', () => this.showAboutPanel());
        if (this.dom.aboutBackBtn) this.dom.aboutBackBtn.addEventListener('click', () => this.hideAboutPanel());
        if (this.dom.copyDebugBtn) this.dom.copyDebugBtn.addEventListener('click', () => this.copyDebugInfo());
        if (this.dom.openRepoBtn) this.dom.openRepoBtn.addEventListener('click', () => { if (this.dom.aboutGithub) window.open(this.dom.aboutGithub.href, '_blank'); });
    }

    playAgain() {
        if (this.settings.gameType === 'network') {
            if (this.settings.networkRole === 'host') {
                if (this.networkSocket && this.networkSocket.readyState === WebSocket.OPEN) {
                    // notify opponent via network that a reset is happening
                    this.networkSocket.send(JSON.stringify({ type: 'game_event', payload: { type: 'reset' } }));
                }
                // locally reset game-state but keep the connection
                this.reset(false);
                // host always starts after reset
                this.settings.isMyTurn = true;
                this.updateDisplay();
            } else {
                alert('Only the host can start a new networked game.');
            }
        } else {
            // For local games just perform a full reset
            this.reset(true);
        }
    }

    toggleNameEdit(isEditing, callback) {
        this.onNameSetCallback = callback || null;
        if (isEditing) {
            this.dom.player1.nameInput.value = this.player1Name === "You" ? "" : this.player1Name;
            this.dom.player1.name.classList.add('hidden');
            this.dom.player1.nameInput.classList.remove('hidden');
            this.dom.player1.nameInput.focus();
            this.dom.player1.nameInput.select();
        } else {
            const newName = this.dom.player1.nameInput.value.trim();
            this.player1Name = newName || "You";
            this.dom.player1.name.classList.remove('hidden');
            this.dom.player1.nameInput.classList.add('hidden');
            this.saveSettings();
            this.updateDisplay();
            if (this.onNameSetCallback) { this.onNameSetCallback(); this.onNameSetCallback = null; }
        }
    }
    
    showUpdateNotification(info) { if (this.dom.updateNotification) { this.dom.updateMessage.textContent = `Update v${info.version} available`; this.dom.updateNotification.classList.add('show'); } }
    hideUpdateNotification() { if (this.dom.updateNotification) { this.dom.updateNotification.classList.remove('show'); } }
    
    downloadUpdate() {
        if (window.ipcRenderer) {
            window.ipcRenderer.send('open-download-page');
        } else if (window.Capacitor && window.Capacitor.isNativePlatform()) {
            const { Browser } = window.Capacitor.Plugins;
            Browser.open({ url: 'https://github.com/suspiciousstew67/ninemensmorris/releases/latest' });
        }
        this.hideUpdateNotification();
    }
    
    ensurePlayerName(callback) {
        if (this.player1Name === "You") {
            this.showNamePrompt(callback);
        } else {
            callback();
        }
    }

    showNamePrompt(callback) {
        this.namePromptCallback = callback;
        this.dom.namePromptInput.value = '';
        this.dom.namePromptInput.placeholder = 'Your name';
        this.toggleNamePrompt(true);
        this.dom.namePromptInput.focus();
    }

    closeNamePrompt() {
        this.toggleNamePrompt(false);
        if (this.namePromptCallback) {
            this.namePromptCallback();
            this.namePromptCallback = null;
        }
    }

    confirmNamePrompt() {
        const newName = this.dom.namePromptInput.value.trim();
        if (newName.length > 0) {
            this.player1Name = newName;
            this.saveSettings();
            this.updateDisplay();
            this.closeNamePrompt();
        } else {
            this.dom.namePromptInput.style.borderColor = '#dc3545';
            setTimeout(() => {
                this.dom.namePromptInput.style.borderColor = '';
            }, 500);
        }
    }

    toggleNamePrompt(show) {
        if (!this.dom.namePromptModal) {
            console.error('Name prompt modal not found');
            return;
        }
        this.dom.namePromptModal.classList.toggle('hidden', !show);
    }

    hostGame() {
        this.ensurePlayerName(() => {
            const RELAY_SERVER_URL = 'wss://morris-relay.onrender.com';
            this.networkSocket = new WebSocket(RELAY_SERVER_URL);
            this.dom.networkActions.classList.add('hidden');
            this.dom.hostInfoPanel.classList.remove('hidden');
            this.dom.hostStatus.textContent = "Connecting to server...";
            this.dom.roomCodeDisplay.textContent = "----";
            
            this.networkSocket.onopen = () => {
                console.log('WebSocket connected');
                this.dom.hostStatus.textContent = "Waiting for opponent...";
                this.networkSocket.send(JSON.stringify({ type: 'host', payload: { name: this.player1Name } }));
                // send an immediate ping so latency shows up quickly
                try {
                    this.lastPingTime = Date.now();
                    this.networkSocket.send(JSON.stringify({ type: 'ping' }));
                    console.debug('Sent initial ping');
                } catch (err) {
                    console.warn('Failed to send initial ping', err);
                }
                this.startKeepAlive();
                // Show ping UI when connected to relay
                if (this.dom.pingIndicator) this.dom.pingIndicator.classList.remove('hidden');
            };
            
            this.networkSocket.onerror = (error) => {
                console.error('WebSocket error:', error);
                this.dom.hostStatus.textContent = "Connection failed. Retrying...";
            };
            
            this.networkSocket.onmessage = (event) => {
                this.handleNetworkMessage(event);
            };
            
            this.networkSocket.onclose = (event) => {
                console.log('WebSocket closed:', event.code, event.reason);
                this.stopKeepAlive();
                if (this.settings.gameType === 'network' && !event.wasClean) {
                    this.dom.hostStatus.textContent = "Connection lost. Reconnecting...";
                    setTimeout(() => this.hostGame(), 3000);
                }
            };
        });
    }

    joinGame() {
        const roomCode = this.dom.joinIpInput.value.trim().toUpperCase();
        if (!roomCode) { alert("Please enter a room code."); return; }
        this.ensurePlayerName(() => {
            const RELAY_SERVER_URL = 'wss://morris-relay.onrender.com';
            this.networkSocket = new WebSocket(RELAY_SERVER_URL);
            this.toggleSettingsModal(false);
            
            this.networkSocket.onopen = () => {
                console.log('WebSocket connected');
                this.networkSocket.send(JSON.stringify({ type: 'join', payload: { name: this.player1Name, roomCode: roomCode } }));
                // immediate ping for faster feedback
                try {
                    this.lastPingTime = Date.now();
                    this.networkSocket.send(JSON.stringify({ type: 'ping' }));
                    console.debug('Sent initial ping');
                } catch (err) {
                    console.warn('Failed to send initial ping', err);
                }
                this.startKeepAlive();
                // Show ping UI when connected to relay
                if (this.dom.pingIndicator) this.dom.pingIndicator.classList.remove('hidden');
            };
            
            this.networkSocket.onerror = (error) => {
                console.error('WebSocket error:', error);
                alert('Failed to connect. Please check the room code and try again.');
                this.cancelHost();
            };
            
            this.networkSocket.onmessage = (event) => {
                this.handleNetworkMessage(event);
            };
            
            this.networkSocket.onclose = (event) => {
                console.log('WebSocket closed:', event.code, event.reason);
                this.stopKeepAlive();
                if (this.settings.gameType === 'network' && !event.wasClean) {
                    alert('Connection lost. Please try again.');
                    this.cancelHost();
                }
            };
        });
    }
    
    startKeepAlive() {
        this.keepAliveInterval = setInterval(() => {
            if (this.networkSocket && this.networkSocket.readyState === WebSocket.OPEN) {
                this.lastPingTime = Date.now();
                try {
                    this.networkSocket.send(JSON.stringify({ type: 'ping' }));
                    console.debug('Sent keepalive ping');
                } catch (err) {
                    console.warn('Keepalive ping failed', err);
                }
            }
        }, 25000);
    }
    
    stopKeepAlive() {
        if (this.keepAliveInterval) {
            clearInterval(this.keepAliveInterval);
            this.keepAliveInterval = null;
        }
    }

    updatePingDisplay() {
        // Update ping value and bar indicator
        if (this.dom.pingValue) {
            this.dom.pingValue.textContent = this.currentPing;
        }
        if (this.dom.pingFill) {
            // Scale bar from 0-200ms: 0ms = 0%, 200ms = 100%
            const maxPing = 200;
            const percentage = Math.min((this.currentPing / maxPing) * 100, 100);
            this.dom.pingFill.style.width = percentage + '%';
        }
        // No inline ping bars — settings panel ping indicator is used instead.
    }

    cancelHost() {
        if (this.networkSocket) { this.networkSocket.close(); this.networkSocket = null; }
        this.stopKeepAlive();
        this.currentPing = 0;
        if (this.dom.pingIndicator) {
            this.dom.pingIndicator.classList.add('hidden');
        }
        // hide inline ping bars (removed) — leave settings panel indicator hidden
        this.dom.hostInfoPanel.classList.add('hidden');
        this.dom.networkActions.classList.remove('hidden');
    }

    handleNetworkMessage(event) {
        try {
            const message = JSON.parse(event.data);
            console.log('Network message received:', message.type);
            
            switch(message.type) {
                case 'host_success':
                    this.dom.roomCodeDisplay.textContent = message.payload.roomCode;
                    this.settings.networkRole = 'host';
                    this.settings.gameType = 'network';
                    break;
                    
                case 'join_success':
                case 'opponent_joined':
                    this.player2Name = message.payload.opponentName || 'Opponent';
                    this.settings.networkRole = (message.type === 'join_success') ? 'client' : 'host';
                    this.settings.gameType = 'network';
                    this.toggleSettingsModal(false);
                        // Update host status and show ping indicator when game starts
                        if (message.type === 'opponent_joined') {
                            this.dom.hostStatus.textContent = `${message.payload.opponentName || 'Opponent'} joined`;
                        } else if (message.type === 'join_success') {
                            this.dom.hostStatus.textContent = `Connected to ${message.payload.opponentName || 'Host'}`;
                        }
                        if (this.dom.pingIndicator) this.dom.pingIndicator.classList.remove('hidden');
                        this.reset(false);
                        // Ensure turn assignment: host always starts.
                        this.settings.isMyTurn = (this.settings.networkRole === 'host');
                        this.updateDisplay();
                    break;
                    
                case 'game_event':
                    const { type, payload } = message.payload;
                    if(type === 'move') this.applyNetworkMove(payload);
                    if(type === 'remove') this.applyNetworkRemove(payload);
                    if(type === 'reset') { 
                        this.reset(false); 
                        alert('The host has started a new game.');
                    }
                    break;
                    
                case 'game_reset':
                    // Opponent initiated a reset
                    this.reset(false);
                    alert('Opponent started a new game.');
                    break;
                    
                case 'pong':
                    // Server acknowledged our ping - calculate latency
                    console.debug('Pong message received');
                    if (this.lastPingTime) {
                        this.currentPing = Date.now() - this.lastPingTime;
                        this.updatePingDisplay();
                        console.log(`Pong received - latency: ${this.currentPing}ms`);
                    } else {
                        // if we don't have lastPingTime, still show indicator
                        this.currentPing = 0;
                        this.updatePingDisplay();
                        console.log('Pong received but no lastPingTime recorded');
                    }
                    // Make sure settings-panel ping UI is visible when we receive pongs
                    if (this.dom.pingIndicator) this.dom.pingIndicator.classList.remove('hidden');
                    break;
                    
                case 'error':
                    console.error('Network error:', message.payload.message);
                    alert(`Error: ${message.payload.message}`);
                    this.cancelHost();
                    break;
                    
                case 'opponent_disconnected':
                    alert('Opponent has disconnected.');
                    this.settings.gameType = 'ai';
                    this.reset(false);
                    break;
                    
                default:
                    console.log('Unknown message type:', message.type);
            }
        } catch (error) {
            console.error('Error parsing network message:', error);
        }
    }

    makeMove(move) {
        if (move.to === null || move.to === -1 || this.board[move.to] !== null) return;
        if (this.settings.gameType === 'network' && this.settings.isMyTurn && this.networkSocket) {
            this.networkSocket.send(JSON.stringify({ type: 'game_event', payload: { type: 'move', payload: move } }));
        }
        this.board[move.to] = this.currentPlayer;
        if (move.from !== null) { this.board[move.from] = null; }
        else { this.piecesLeft[this.currentPlayer]--; this.piecesOnBoard[this.currentPlayer]++; }
        this.updatePhase();
        this.renderBoard();
        const justMadeMill = this.isPositionInMill(move.to, this.currentPlayer);
        if (this.settings.gameMode === 'simple') {
            if (justMadeMill) this.endGame(this.currentPlayer);
            else if (this.piecesLeft[1] === 0 && this.piecesLeft[2] === 0) this.endGame(null);
            else this.switchPlayer();
        } else {
            if (justMadeMill) { this.isRemovingPiece = true; this.updateDisplay(); }
            else { this.switchPlayer(); }
        }
    }

    handleRemovePiece(position) {
        const opponent = this.currentPlayer === 1 ? 2 : 1;
        if (this.board[position] === opponent && this.isRemovable(position, opponent)) {
            if(this.settings.gameType === 'network' && this.settings.isMyTurn && this.networkSocket) {
                this.networkSocket.send(JSON.stringify({ type: 'game_event', payload: { type: 'remove', payload: position } }));
            }
            this.board[position] = null;
            this.piecesOnBoard[opponent]--;
            this.isRemovingPiece = false;
            if (this.gamePhase !== 'placing' && this.piecesOnBoard[opponent] < 3) { this.endGame(this.currentPlayer); }
            else { this.switchPlayer(); }
        }
    }

    reset(sendNetworkEvent = true) {
        // If this reset was triggered locally and we're *not* trying to
        // signal the network (sendNetworkEvent === false), keep the
        // existing WebSocket open. This is used when the server tells us
        // a game has started (opponent joined) and we want to reset game
        // state but keep the connection.
        if (this.networkSocket && sendNetworkEvent) {
            this.networkSocket.onclose = null;
            this.networkSocket.close();
            this.networkSocket = null;
            // when connection is closed, show the default network UI
            this.dom.hostInfoPanel.classList.add('hidden');
            this.dom.networkActions.classList.remove('hidden');
            this.stopKeepAlive();
        } else if (!this.networkSocket) {
            // no socket at all: ensure UI shows network actions
            this.dom.hostInfoPanel.classList.add('hidden');
            this.dom.networkActions.classList.remove('hidden');
        }
        this.board.fill(null);
        this.currentPlayer = 1;
        this.piecesLeft = { 1: 9, 2: 9 };
        this.piecesOnBoard = { 1: 0, 2: 0 };
        this.gameOver = false;
        this.isAIThinking = false;
        this.isRemovingPiece = false;
        this.selectedPiece = null;
        this.winningPositions = [];
        // Only reset network role/turn when this is a full/local reset
        // (sendNetworkEvent === true). When called with sendNetworkEvent
        // === false we are performing a UI/game-state reset while keeping
        // the network session/role intact (e.g. at the start of a
        // networked game), so preserve those values.
        if (sendNetworkEvent) {
            this.settings.isMyTurn = true;
            this.settings.networkRole = 'none';
            this.player2Name = "Opponent";
        } else {
            // preserve existing network role & turn; ensure player2Name
            // has a sensible default if it wasn't set by the join message.
            this.player2Name = this.player2Name || "Opponent";
        }
        if (this.settings.gameType === 'ai') this.ai = new AIPlayer(this.settings.difficulty);
        else this.ai = null;
        this.updatePhase();
        this.updateDisplay();
        this.renderBoard();
        this.showAIThinking(false);
        // hide play again button until next game end
        if (this.dom.playAgainBtn) this.dom.playAgainBtn.classList.add('hidden');
    }
    
    updateDisplay() {
        let p1NameText = this.player1Name;
        let p2NameText = "Opponent";
        if (this.settings.gameType === 'ai') p2NameText = `${this.settings.difficulty.charAt(0).toUpperCase() + this.settings.difficulty.slice(1)} AI`;
        if (this.settings.gameType === 'human') { p1NameText = 'Player 1'; p2NameText = 'Player 2'; }
        if (this.settings.gameType === 'network') {
            p1NameText = `${this.player1Name} (${this.settings.networkRole === 'host' ? 'Host' : 'Client'})`;
            p2NameText = this.player2Name;
        }
        if (this.isRemovingPiece && this.currentPlayer === 1) p1NameText = 'Remove a piece!';
        this.dom.player1.name.textContent = p1NameText;
        this.dom.player2.name.textContent = p2NameText;
        this.dom.player1.pieces.classList.remove('winner-text', 'loser-text');
        this.dom.player2.pieces.classList.remove('winner-text', 'loser-text');
        const p1PiecesText = this.settings.gameMode === 'classic' ? (`${this.gamePhase === 'placing' ? this.piecesLeft[1] : this.piecesOnBoard[1]} ${this.gamePhase === 'placing' ? 'left' : 'on board'}`) : `${this.piecesLeft[1]} pieces left`;
        const p2PiecesText = this.settings.gameMode === 'classic' ? (`${this.gamePhase === 'placing' ? this.piecesLeft[2] : this.piecesOnBoard[2]} ${this.gamePhase === 'placing' ? 'left' : 'on board'}`) : `${this.piecesLeft[2]} pieces left`;
        this.dom.player1.pieces.textContent = p1PiecesText;
        this.dom.player2.pieces.textContent = p2PiecesText;
        const isClientInNetworkGame = this.settings.gameType === 'network' && this.settings.networkRole === 'client';
        this.dom.resetButton.disabled = isClientInNetworkGame;
        this.dom.resetButton.style.cursor = isClientInNetworkGame ? 'not-allowed' : 'pointer';
        this.dom.resetButton.style.opacity = isClientInNetworkGame ? '0.6' : '1';
    }

    handlePositionClick(target) {
        const isAITurn = this.settings.gameType === 'ai' && this.currentPlayer === 2;
        const isNetworkOpponentTurn = this.settings.gameType === 'network' && !this.settings.isMyTurn;
        if (isAITurn || isNetworkOpponentTurn || this.gameOver || this.isAIThinking) {
            return;
        }
        const position = parseInt(target.dataset.position);
        if (this.settings.gameMode === 'simple') {
            if (this.gamePhase === 'placing' && this.board[position] === null) this.makeMove({ to: position });
        } else {
            if (this.isRemovingPiece) this.handleRemovePiece(position);
            else if (this.gamePhase === 'placing') { if (this.board[position] === null) this.makeMove({ to: position }); }
            else this.handleMovePiece(position);
        }
    }

    applyNetworkMove(move) {
        const { from, to } = move;
        // Determine numeric player IDs: host = 1, client = 2
        const localPlayerNumber = this.settings.networkRole === 'host' ? 1 : (this.settings.networkRole === 'client' ? 2 : 1);
        const remotePlayer = localPlayerNumber === 1 ? 2 : 1;
        if (to === null || this.board[to] !== null) return;
        // Apply the incoming move as the remote player's action
        this.board[to] = remotePlayer;
        if (from !== null) {
            this.board[from] = null;
        } else {
            this.piecesLeft[remotePlayer]--;
            this.piecesOnBoard[remotePlayer]++;
        }
        this.updatePhase();
        this.renderBoard();
        const justMadeMill = this.isPositionInMill(to, remotePlayer);
        if (this.settings.gameMode === 'simple') {
            if (justMadeMill) this.endGame(remotePlayer);
            else {
                // After remote's move it's the local player's turn
                this.currentPlayer = localPlayerNumber;
                this.settings.isMyTurn = true;
                this.updateDisplay();
            }
        } else {
            if (!justMadeMill) {
                this.currentPlayer = localPlayerNumber;
                this.settings.isMyTurn = true;
                this.updateDisplay();
            } else {
                // Remote formed a mill; they will send a 'remove' when they choose a piece.
                this.updateDisplay();
            }
        }
    }

    applyNetworkRemove(position) {
        // Determine player numbers for clarity
        const localPlayerNumber = this.settings.networkRole === 'host' ? 1 : (this.settings.networkRole === 'client' ? 2 : 1);
        const remotePlayer = localPlayerNumber === 1 ? 2 : 1;
        // Incoming remove means remote removed one of local player's pieces
        if (this.board[position] === localPlayerNumber) {
            this.board[position] = null;
            this.piecesOnBoard[localPlayerNumber]--;
        } else {
            // fallback: clear anyway
            this.board[position] = null;
        }
        if (this.gamePhase !== 'placing' && this.piecesOnBoard[localPlayerNumber] < 3) {
            this.endGame(remotePlayer);
        } else {
            // After remote removed, it's local player's turn
            this.currentPlayer = localPlayerNumber;
            this.settings.isMyTurn = true;
            this.updateDisplay();
            this.renderBoard();
        }
    }

    switchPlayer() {
        if (this.gameOver) return;
        this.currentPlayer = this.currentPlayer === 1 ? 2 : 1;
        if (this.settings.gameType === 'network') {
            this.settings.isMyTurn = !this.settings.isMyTurn;
        }
        if (this.settings.gameMode === 'classic' && this.gamePhase !== 'placing' && !this.hasValidMoves(this.currentPlayer)) {
            this.endGame(this.currentPlayer === 1 ? 2 : 1);
            return;
        }
        this.updateDisplay();
        if (this.settings.gameType === 'ai' && this.currentPlayer === 2 && !this.gameOver) {
            this.makeAIMove();
        }
    }

    async makeAIMove() {
        if (!this.ai || this.gameOver) return;
        this.isAIThinking = true;
        this.showAIThinking(true);
        await new Promise(resolve => setTimeout(resolve, 500 + Math.random() * 400));
        const aiMove = this.ai.makeMove(this);
        this.isAIThinking = false;
        this.showAIThinking(false);
        if (aiMove && aiMove.to !== null) {
            this.makeMove(aiMove);
            if (aiMove.remove !== null) {
                await new Promise(resolve => setTimeout(resolve, 400));
                this.handleRemovePiece(aiMove.remove);
            }
        }
    }

    showAIThinking(show) {
        this.dom.player2.panel.classList.toggle('thinking', show);
    }

    handleMovePiece(position) {
        if (this.selectedPiece === null) {
            if (this.board[position] === this.currentPlayer) {
                this.selectedPiece = position;
                this.renderBoard();
            }
        } else {
            const canFly = this.piecesOnBoard[this.currentPlayer] === 3;
            const isValid = (canFly) ? this.board[position] === null : this.adjacencyMap[this.selectedPiece].includes(position) && this.board[position] === null;
            if (isValid) {
                const move = { from: this.selectedPiece, to: position };
                this.selectedPiece = null;
                this.makeMove(move);
            } else {
                this.selectedPiece = null;
                this.renderBoard();
            }
        }
    }

    updatePhase() {
        if (this.piecesLeft[1] > 0 || this.piecesLeft[2] > 0) this.gamePhase = 'placing';
        else this.gamePhase = 'moving';
    }

    isRemovable(position, player) {
        if (!this.isPositionInMill(position, player)) return true;
        const allPieces = [...this.board.keys()].filter(p => this.board[p] === player);
        const nonMillPieces = allPieces.filter(p => !this.isPositionInMill(p, player));
        return nonMillPieces.length === 0;
    }

    isPositionInMill(position, player, board = this.board) {
        if (position === null || player === null) return false;
        return this.millPatterns.some(pattern => pattern.includes(position) && pattern.every(p => board[p] === player));
    }

    getMillPattern(position, player) {
        return this.millPatterns.find(pattern => pattern.includes(position) && pattern.every(p => this.board[p] === player));
    }

    hasValidMoves(player) {
        if (this.gamePhase === 'placing') return this.board.includes(null);
        if (this.piecesOnBoard[player] === 3) return this.board.includes(null);
        const playerPieces = [...this.board.keys()].filter(i => this.board[i] === player);
        return playerPieces.some(pos => this.adjacencyMap[pos].some(adj => this.board[adj] === null));
    }

    renderBoard() {
        this.dom.allPieces.forEach((piece, index) => {
            let classes = 'piece';
            if (this.board[index] !== null) classes += ` occupied player${this.board[index]}`;
            if (this.gameOver && this.winningPositions.includes(index)) classes += ' winning-position';
            if (this.selectedPiece === index) classes += ' selected';
            piece.setAttribute('class', classes);
        });
        this.dom.allHitboxes.forEach((hitbox, index) => {
            const opponent = this.currentPlayer === 1 ? 2 : 1;
            hitbox.classList.toggle('removable', this.isRemovingPiece && this.board[index] === opponent && this.isRemovable(index, opponent));
        });
    }

    cycleGameType() {
        const currentIndex = this.availableGameTypes.indexOf(this.settings.gameType);
        this.settings.gameType = this.availableGameTypes[(currentIndex + 1) % this.availableGameTypes.length];
        this.saveSettings();
        this.updateSettingsDisplay();
        this.reset();
    }

    cycleDifficulty() {
        const currentIndex = this.availableDifficulties.indexOf(this.settings.difficulty);
        this.settings.difficulty = this.availableDifficulties[(currentIndex + 1) % this.availableDifficulties.length];
        this.saveSettings();
        this.updateSettingsDisplay();
        this.reset();
    }

    cycleGameMode() {
        const currentIndex = this.availableGameModes.indexOf(this.settings.gameMode);
        this.settings.gameMode = this.availableGameModes[(currentIndex + 1) % this.availableGameModes.length];
        this.saveSettings();
        this.updateSettingsDisplay();
        this.reset();
    }

    toggleDarkMode() {
        this.settings.darkMode = !this.settings.darkMode;
        this.saveSettings();
        this.applySettings();
        if (window.Capacitor && window.Capacitor.isNativePlatform()) {
            const { StatusBar, Style } = window.Capacitor.Plugins;
            StatusBar.setStyle({ style: this.settings.darkMode ? Style.Dark : Style.Light });
        }
    }

    toggleSettingsModal(show) {
        if (!this.dom.settingsModal) {
            console.error('Settings modal not found');
            return;
        }
        this.dom.settingsModal.classList.toggle('hidden', !show);
        if (show) this.updateSettingsDisplay();
    }

    updateSettingsDisplay() {
        const gameTypeLabels = { ai: 'vs. AI', human: 'vs. Human', network: 'Network' };
        this.dom.gametypeValue.textContent = gameTypeLabels[this.settings.gameType];
        
        const difficultyLabel = this.settings.difficulty.charAt(0).toUpperCase() + this.settings.difficulty.slice(1);
        this.dom.difficultyValue.textContent = difficultyLabel;
        
        const gameModeLabel = this.settings.gameMode.charAt(0).toUpperCase() + this.settings.gameMode.slice(1);
        this.dom.gamemodeValue.textContent = gameModeLabel;
        
        this.dom.darkmodeValue.textContent = this.settings.darkMode ? 'On' : 'Off';
        
        const isNetworkMode = this.settings.gameType === 'network';
        this.dom.difficultySetting.style.display = isNetworkMode ? 'none' : '';
        this.dom.networkSettings.classList.toggle('hidden', !isNetworkMode);
        // If About panel is visible while switching settings, ensure it's hidden
        if (this.dom.aboutPanel && !this.dom.aboutPanel.classList.contains('hidden')) {
            this.dom.aboutPanel.classList.add('hidden');
        }
    }

    showAboutPanel() {
        if (!this.dom.aboutPanel) return;
        // populate debug info
        const debug = {
            time: new Date().toISOString(),
            userAgent: navigator.userAgent,
            gameType: this.settings.gameType,
            networkRole: this.settings.networkRole,
            isMyTurn: this.settings.isMyTurn,
            roomCode: (this.dom.roomCodeDisplay && this.dom.roomCodeDisplay.textContent) ? this.dom.roomCodeDisplay.textContent : null,
            currentPing: this.currentPing,
            socketReadyState: this.networkSocket ? this.networkSocket.readyState : null,
            piecesLeft: this.piecesLeft,
        };
        if (this.dom.debugBox) this.dom.debugBox.textContent = JSON.stringify(debug, null, 2);
        if (this.dom.aboutBuild) this.dom.aboutBuild.textContent = 'dev';
        // show about panel and hide main settings rows visually
        this.dom.aboutPanel.classList.remove('hidden');
    }

    hideAboutPanel() {
        if (!this.dom.aboutPanel) return;
        this.dom.aboutPanel.classList.add('hidden');
    }

    // TEST/DEBUG: Simulate update notification for testing
    testShowUpdateNotification(version = '2.0.0') {
        this.showUpdateNotification({ version });
        console.log(`[TEST] Update notification triggered for v${version}`);
    }

    // TEST/DEBUG: Hide the update notification
    testHideUpdateNotification() {
        this.hideUpdateNotification();
        console.log('[TEST] Update notification hidden');
    }

    async copyDebugInfo() {
        if (!this.dom.debugBox) return;
        try {
            await navigator.clipboard.writeText(this.dom.debugBox.textContent);
            alert('Debug info copied to clipboard');
        } catch (err) {
            console.error('Copy failed', err);
            alert('Unable to copy debug info');
        }
    }

    endGame(winner) {
        if (this.gameOver) return;
        this.gameOver = true;
        this.isRemovingPiece = false;
        this.showAIThinking(false);
        if (winner === 1) {
            this.dom.player1.pieces.textContent = "Winner!";
            this.dom.player1.pieces.classList.add('winner-text');
            this.dom.player2.pieces.textContent = "Loser!";
            this.dom.player2.pieces.classList.add('loser-text');
            this.launchConfetti();
        } else if (winner === 2) {
            this.dom.player1.pieces.textContent = "Loser!";
            this.dom.player1.pieces.classList.add('loser-text');
            this.dom.player2.pieces.textContent = "Winner!";
            this.dom.player2.pieces.classList.add('winner-text');
        } else {
            this.dom.player1.pieces.textContent = "Draw!";
            this.dom.player2.pieces.textContent = "Draw!";
        }
        this.renderBoard();
        // Show Play Again button only for network games (host can restart)
        if (this.dom.playAgainBtn) {
            if (this.settings.gameType === 'network') {
                this.dom.playAgainBtn.classList.remove('hidden');
            }
        }
    }

    launchConfetti() {
        this.dom.confettiContainer.innerHTML = '';
        for (let i = 0; i < 50; i++) {
            const c = document.createElement('div');
            c.className = 'confetti animate';
            c.style.background = `hsl(${Math.random() * 360}, 90%, 65%)`;
            c.style.left = `${Math.random() * 100}vw`;
            c.style.animationDuration = `${2 + Math.random() * 3}s`;
            c.style.animationDelay = `${Math.random() * 0.2}s`;
            c.addEventListener('animationend', () => c.remove());
            this.dom.confettiContainer.appendChild(c);
        }
    }
}

document.addEventListener('DOMContentLoaded', () => {
    const game = new NineMensMorrisGame();
    game.initialize();
    window.game = game;
});
import 'dart:async';
import 'dart:convert';

import 'dart:io' show WebSocket, CompressionOptions;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

typedef StringCallback = void Function(String value);
typedef VoidCallback = void Function();
typedef IntCallback = void Function(int value);

class RemoteEvent {
  final String type;
  final dynamic payload;
  RemoteEvent(this.type, this.payload);
}

class NetworkClient {
  NetworkClient({
    required this.onRoomCode,
    required this.onOpponent,
    required this.onGameEvent,
    required this.onPing,
    required this.onError,
    required this.onDisconnected,
    this.onStatus,
  });

  static const String relayUrl = 'wss://morris-relay.onrender.com';
  static const String relayUrlFallback = 'ws://morris-relay.onrender.com';
  static const int _ackTimeoutMs = 5000;
  static const int _maxRetries = 5;
  static const int _maxMessageAgeMs = 30000;
  static const int _keepAliveMs = 25000;
  static const int _queueFlushMs = 2000;

  final StringCallback onRoomCode;
  final StringCallback onOpponent;
  final void Function(RemoteEvent event) onGameEvent;
  final IntCallback onPing;
  final StringCallback onError;
  final VoidCallback onDisconnected;
  final StringCallback? onStatus;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _keepAliveTimer;
  Timer? _queueTimer;
  DateTime? _lastPingSent;
  int _messageId = 0;
  bool _connectionCancelled = false;

  final Map<int, _PendingMessage> _pendingMessages = {};
  final List<_QueuedMessage> _messageQueue = [];
  final Set<int> _receivedIds = {};

  bool get connected => _channel != null;

  Future<void> host(String name) async {
    await _connect(isHost: true, name: name);
  }

  Future<void> join(String name, String roomCode) async {
    await _connect(isHost: false, name: name, roomCode: roomCode);
  }

  Future<void> _connect({required bool isHost, required String name, String? roomCode}) async {
    await disconnect();
    _connectionCancelled = false;
    try {
      _channel = await _openChannelWithRetry();

      _subscription = _channel!.stream.listen(_handleMessage, onError: (error, stack) {
        onError('Network error: $error');
        _handleClose();
      }, onDone: _handleClose, cancelOnError: true);

      _startKeepAlive();
      final message = isHost
          ? {'type': 'host', 'payload': {'name': name}}
          : {'type': 'join', 'payload': {'name': name, 'roomCode': roomCode}};
      _send(message);
      _send({'type': 'ping'});
    } catch (e) {
      onError('Failed to connect: $e');
      await disconnect();
      rethrow;
    }
  }

  Future<WebSocketChannel> _openChannelWithRetry() async {
    // Try primary (wss), then fallback (ws) if available
    final urls = [relayUrl, relayUrlFallback];
    int attempt = 0;
    while (true) {
      attempt++;
      if (_connectionCancelled) {
        throw Exception('Connection cancelled');
      }
      onStatus?.call(
        attempt == 1 ? 'Connecting to relay...' : 'Waiting for relay server (attempt $attempt)...',
      );
      for (final url in urls) {
        try {
          if (kIsWeb) {
            final channel = WebSocketChannel.connect(Uri.parse(url));
            onStatus?.call('Connected to relay');
            return channel;
          } else {
            final socket = await WebSocket.connect(url, compression: CompressionOptions.compressionDefault)
                .timeout(const Duration(seconds: 6));
            onStatus?.call('Connected to relay');
            return IOWebSocketChannel(socket);
          }
        } catch (_) {
          if (_connectionCancelled) {
            throw Exception('Connection cancelled');
          }
          // continue to next url
        }
      }
      final capped = attempt > 4 ? 4 : attempt;
      final delayMs = 1000 * (1 << capped);
      final bounded = delayMs > 8000 ? 8000 : delayMs;
      await Future.delayed(Duration(milliseconds: bounded));
    }
  }

  void _handleMessage(dynamic data) {
    if (data == null) return;
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      final type = message['type'] as String?;
      final payload = message['payload'];
      switch (type) {
        case 'host_success':
          onRoomCode((payload as Map?)?['roomCode']?.toString() ?? '----');
          break;
        case 'join_success':
        case 'opponent_joined':
          onOpponent((payload as Map?)?['opponentName']?.toString() ?? 'Opponent');
          break;
        case 'game_event':
          final messageId = message['messageId'] as int?;
          if (messageId != null) {
            if (_receivedIds.contains(messageId)) {
              _send({'type': 'ack', 'messageId': messageId});
              return;
            }
            _receivedIds.add(messageId);
            if (_receivedIds.length > 1000) {
              _receivedIds.remove(_receivedIds.first);
            }
          }
          final eventType = (payload as Map?)?['type']?.toString();
          if (eventType != null) {
            onGameEvent(RemoteEvent(eventType, (payload as Map)['payload']));
          }
          if (messageId != null) {
            _send({'type': 'ack', 'messageId': messageId});
          }
          break;
        case 'ack':
          final id = message['messageId'] as int?;
          if (id != null) {
            _pendingMessages.remove(id);
          }
          break;
        case 'pong':
          if (_lastPingSent != null) {
            onPing(DateTime.now().difference(_lastPingSent!).inMilliseconds);
          } else {
            onPing(0);
          }
          break;
        case 'error':
          onError((payload as Map?)?['message']?.toString() ?? 'Unknown error');
          break;
        case 'opponent_disconnected':
          onDisconnected();
          break;
        default:
          break;
      }
    } catch (e) {
      onError('Bad network message: $e');
    }
  }

  void sendMove(Map<String, dynamic> move) {
    _sendGameEvent('move', move);
  }

  void sendRemove(int position) {
    _sendGameEvent('remove', position);
  }

  void sendReset() {
    _sendGameEvent('reset', null);
  }

  void _sendGameEvent(String type, dynamic payload) {
    final message = {'type': 'game_event', 'payload': {'type': type, 'payload': payload}};
    _send(message, requiresAck: true);
  }

  void _send(Map<String, dynamic> message, {bool requiresAck = false}) {
    if (requiresAck) {
      final id = ++_messageId;
      message['messageId'] = id;
      _pendingMessages[id] = _PendingMessage(message);
      Timer(const Duration(milliseconds: _ackTimeoutMs), () => _checkAndResend(id));
    }

    if (_channel == null) {
      _queueMessage(message);
      return;
    }

    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (_) {
      _queueMessage(message);
    }
  }

  void _checkAndResend(int id) {
    final pending = _pendingMessages[id];
    if (pending == null) return;

    final age = DateTime.now().difference(pending.timestamp).inMilliseconds;
    if (age > _maxMessageAgeMs || pending.retryCount >= _maxRetries) {
      _pendingMessages.remove(id);
      return;
    }

    pending.retryCount += 1;
    pending.timestamp = DateTime.now();
    _send(Map<String, dynamic>.from(pending.message));
    Timer(const Duration(milliseconds: _ackTimeoutMs), () => _checkAndResend(id));
  }

  void _queueMessage(Map<String, dynamic> message) {
    const maxQueueSize = 100;
    if (_messageQueue.length >= maxQueueSize) {
      _messageQueue.removeAt(0);
    }
    _messageQueue.add(_QueuedMessage(message));
  }

  void _flushQueue() {
    if (_channel == null || _messageQueue.isEmpty) return;
    final now = DateTime.now();
    _messageQueue.removeWhere((entry) => now.difference(entry.timestamp).inMilliseconds > _maxMessageAgeMs);
    final pending = List<_QueuedMessage>.from(_messageQueue);
    _messageQueue.clear();
    for (final queued in pending) {
      _send(Map<String, dynamic>.from(queued.message));
    }
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _queueTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(milliseconds: _keepAliveMs), (_) {
      _lastPingSent = DateTime.now();
      _send({'type': 'ping'});
    });
    _queueTimer = Timer.periodic(const Duration(milliseconds: _queueFlushMs), (_) => _flushQueue());
  }

  void _handleClose() {
    _stopKeepAlive();
    _channel = null;
    onDisconnected();
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _queueTimer?.cancel();
    _keepAliveTimer = null;
    _queueTimer = null;
  }

  Future<void> disconnect() async {
    _connectionCancelled = true;
    _stopKeepAlive();
    _pendingMessages.clear();
    _receivedIds.clear();
    _messageQueue.clear();
    _lastPingSent = null;
    final channel = _channel;
    _channel = null;
    await _subscription?.cancel();
    _subscription = null;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }
}

class _PendingMessage {
  _PendingMessage(this.message) : timestamp = DateTime.now();
  final Map<String, dynamic> message;
  DateTime timestamp;
  int retryCount = 0;
}

class _QueuedMessage {
  _QueuedMessage(this.message) : timestamp = DateTime.now();
  final Map<String, dynamic> message;
  final DateTime timestamp;
}

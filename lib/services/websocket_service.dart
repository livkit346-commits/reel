import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:reel/services/supabase_service.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  // Dynamic host resolver based on platform (safely supporting Web and Mobile emulators)
  static String get backendHost => '54.205.149.147:8080';

  static String get wsUrl => 'ws://$backendHost/ws';
  static String get httpUrl => 'http://$backendHost';

  WebSocketChannel? _channel;
  bool _isConnecting = false;
  bool _shouldReconnect = true;
  Timer? _reconnectTimer;

  // Stream controller to broadcast incoming messages
  final StreamController<Map<String, dynamic>> _messageStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageStreamController.stream;

  // Stream controller to broadcast connection state changes
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  bool get isConnected => _channel != null;

  // Helper to fetch fresh custom JWT Token
  Future<String?> _getAuthToken() async {
    return await SupabaseService().getValidAccessToken();
  }

  // Connect to the Go WebSocket Gateway
  Future<void> connect() async {
    if (isConnected) return;
    if (_isConnecting) return;
    _isConnecting = true;
    _shouldReconnect = true;

    try {
      final token = await _getAuthToken();
      if (token == null) {
        debugPrint('WebSocket connect aborted: No active session.');
        _isConnecting = false;
        return;
      }

      final uri = Uri.parse('$wsUrl?token=$token');
      debugPrint('Connecting to WebSocket Gateway: $uri');
      
      _channel = WebSocketChannel.connect(uri);
      _isConnecting = false;
      _connectionStateController.add(true);
      debugPrint('WebSocket connection successfully initiated.');

      _channel!.stream.listen(
        (data) {
          _handleIncomingData(data);
        },
        onError: (err) {
          debugPrint('WebSocket connection error: $err');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('WebSocket connection closed by server.');
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint('Failed to connect to WebSocket Gateway: $e');
      _isConnecting = false;
      _handleDisconnect();
    }
  }

  // Handle incoming string data and parse it into map
  void _handleIncomingData(dynamic data) {
    try {
      if (data is String) {
        final decoded = jsonDecode(data) as Map<String, dynamic>;
        _messageStreamController.add(decoded);
      }
    } catch (e) {
      debugPrint('Error parsing incoming WebSocket data: $e');
    }
  }

  // Handle connection drops and trigger auto-reconnection
  void _handleDisconnect() {
    _channel = null;
    _connectionStateController.add(false);
    _reconnectTimer?.cancel();
    
    if (_shouldReconnect) {
      debugPrint('Scheduling auto-reconnect in 5 seconds...');
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        connect();
      });
    }
  }

  // Explicitly disconnect from the gateway
  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _connectionStateController.add(false);
    debugPrint('WebSocket manually disconnected.');
  }

  // Send a message over the active socket connection
  bool sendMessage({
    required String chatId,
    required String recipientId,
    required String text,
    String? mediaUrl,
    String? mediaType,
    required String tempId,
  }) {
    if (!isConnected) {
      debugPrint('WebSocket is offline, cannot transmit message immediately.');
      return false;
    }

    try {
      final payload = {
        "tempId": tempId,
        "chatId": chatId,
        "recipientId": recipientId,
        "text": text,
        "mediaUrl": mediaUrl ?? "",
        "mediaType": mediaType ?? "",
      };

      _channel!.sink.add(jsonEncode(payload));
      return true;
    } catch (e) {
      debugPrint('Error writing to WebSocket sink: $e');
      return false;
    }
  }

  // Send a status change event (e.g. marking a message as received to delete it from DynamoDB)
  void sendStatusUpdate({
    required String chatId,
    required String messageId,
    required String recipientId,
    required String status,
  }) {
    if (!isConnected) return;

    try {
      final payload = {
        "type": "status",
        "chatId": chatId,
        "messageId": messageId,
        "recipientId": recipientId,
        "status": status,
      };

      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('Error sending status update: $e');
    }
  }

  // Send a delete event (to notify recipients in real-time)
  void sendDeleteMessage({
    required String chatId,
    required String messageId,
    required String recipientId,
  }) {
    if (!isConnected) return;

    try {
      final payload = {
        "type": "delete",
        "chatId": chatId,
        "messageId": messageId,
        "recipientId": recipientId,
      };

      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('Error sending delete message: $e');
    }
  }

  // Fetch history for a chat from DynamoDB since a specific message ID
  Future<List<dynamic>> fetchHistory(String chatId, {String? lastMessageId}) async {
    try {
      final token = await _getAuthToken();
      if (token == null) throw Exception('User not authenticated');

      var urlStr = '$httpUrl/history?chatId=$chatId&token=$token';
      if (lastMessageId != null && lastMessageId.isNotEmpty) {
        urlStr += '&since=$lastMessageId';
      }
      final uri = Uri.parse(urlStr);
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> history = jsonDecode(response.body);
        return history;
      } else {
        debugPrint('Failed to query history from DynamoDB gateway: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('Error fetching history: $e');
      return [];
    }
  }
}

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:reel/main.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/services/supabase_service.dart';

// Background message handler (Must be a top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("Handling background messaging: ${message.messageId}");
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;

  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;
  late SupabaseService _supabaseService;

  Future<void> init(SupabaseService supabaseService) async {
    if (_initialized) return;
    _supabaseService = supabaseService;

    try {
      // 1. Request notifications permissions
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        debugPrint('User granted push notifications permission.');
      } else {
        debugPrint('User declined or has not accepted push notifications permission.');
      }

      // 2. Set background message handler
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // 3. Register current push token
      await _registerToken(supabaseService);

      // 4. Listen for token refresh and update Supabase
      _messaging.onTokenRefresh.listen((newToken) {
        supabaseService.updatePushToken(newToken);
      });

      // 5. Handle foreground notifications
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        debugPrint('Message data: ${message.data}');

        final chatId = message.data['chatId'];
        if (chatId != null && chatId == _supabaseService.activeChatId) {
          // User is actively in this chat, do not show notification banner
          return;
        }

        if (message.notification != null) {
          final title = message.notification!.title ?? 'New Message';
          final body = message.notification!.body ?? '';

          if (navigatorKey.currentContext != null) {
            ScaffoldMessenger.of(navigatorKey.currentContext!).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                backgroundColor: Colors.grey[950],
                duration: const Duration(seconds: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF00BFFF), width: 1),
                ),
                margin: const EdgeInsets.all(12),
                content: Row(
                  children: [
                    const Icon(Icons.chat_bubble_outline, color: Color(0xFF00BFFF)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            body,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                action: SnackBarAction(
                  label: 'View',
                  textColor: const Color(0xFF00BFFF),
                  onPressed: () {
                    if (chatId != null) {
                      _navigateToChat(chatId);
                    }
                  },
                ),
              ),
            );
          }
        }
      });

      // 6. Handle app opened from a notification click (background state)
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('App opened from notification: ${message.data}');
        final chatId = message.data['chatId'];
        if (chatId != null) {
          _navigateToChat(chatId);
        }
      });

      // 7. Check if the app was opened from a terminated state via a notification click
      RemoteMessage? initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('App opened from terminated state via notification: ${initialMessage.data}');
        final chatId = initialMessage.data['chatId'];
        if (chatId != null) {
          Future.delayed(const Duration(milliseconds: 1000), () {
            _navigateToChat(chatId);
          });
        }
      }

      _initialized = true;
    } catch (e) {
      debugPrint('FcmService initialization error: $e');
    }
  }

  void _navigateToChat(String chatId) async {
    try {
      final details = await _supabaseService.getChatDetails(chatId);
      if (details == null) {
        debugPrint('Could not resolve chat details for chatId: $chatId');
        return;
      }

      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => ChatRoomPage(
            chatId: details['chatId'],
            otherUserId: details['otherUserId'],
            otherUserName: details['chatName'],
            isGroup: details['isGroup'],
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error navigating to chat page: $e');
    }
  }

  Future<void> _registerToken(SupabaseService supabaseService) async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        debugPrint('FcmToken fetched: $token');
        await supabaseService.updatePushToken(token);
      }
    } catch (e) {
      debugPrint('Error fetching/registering FCM Token: $e');
    }
  }
}

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
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

  Future<void> init(SupabaseService supabaseService) async {
    if (_initialized) return;

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

        if (message.notification != null) {
          debugPrint('Message also contained a notification: ${message.notification!.title}');
          // You could display an in-app banner here or play a sound
        }
      });

      // 6. Handle app opened from a notification click
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('App opened from notification: ${message.data}');
      });

      _initialized = true;
    } catch (e) {
      debugPrint('FcmService initialization error: $e');
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

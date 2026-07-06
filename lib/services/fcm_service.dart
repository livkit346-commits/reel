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
          final senderId = message.data['senderId'] as String?;

          showHeadsUpBanner(title, body, chatId, senderId);
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

  OverlayEntry? _currentOverlay;

  void showHeadsUpBanner(String title, String body, String? chatId, String? senderId) {
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) return;

    // Remove any previous active overlay
    _currentOverlay?.remove();
    _currentOverlay = null;

    _currentOverlay = OverlayEntry(
      builder: (context) {
        return Positioned(
          top: MediaQuery.of(context).padding.top,
          left: 0,
          right: 0,
          child: _HeadsUpNotificationBanner(
            title: title,
            body: body,
            senderId: senderId,
            onTap: () {
              if (chatId != null) {
                _navigateToChat(chatId);
              }
            },
            onDismiss: () {
              _currentOverlay?.remove();
              _currentOverlay = null;
            },
          ),
        );
      },
    );

    overlayState.insert(_currentOverlay!);
  }
}

class _HeadsUpNotificationBanner extends StatefulWidget {
  final String title;
  final String body;
  final String? senderId;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _HeadsUpNotificationBanner({
    required this.title,
    required this.body,
    this.senderId,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  State<_HeadsUpNotificationBanner> createState() => _HeadsUpNotificationBannerState();
}

class _HeadsUpNotificationBannerState extends State<_HeadsUpNotificationBanner> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _offsetAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _offsetAnimation = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _controller.forward();

    // Auto-dismiss after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        _dismiss();
      }
    });
  }

  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return SlideTransition(
      position: _offsetAnimation,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          if (details.primaryDelta! < -5) {
            _dismiss();
          }
        },
        onTap: () {
          widget.onTap();
          _dismiss();
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E24) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: Row(
              children: [
                // Sender Icon/Avatar
                CircleAvatar(
                  radius: 20,
                  backgroundColor: isDark ? Colors.white10 : Colors.black.withOpacity(0.08),
                  child: Icon(Icons.person, color: isDark ? Colors.white30 : Colors.black38, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.body,
                        style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.black54,
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Swipe-up drag handle
                Icon(
                  Icons.drag_handle,
                  color: isDark ? Colors.white24 : Colors.black26,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

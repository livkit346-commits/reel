import 'dart:ui';
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
            supabaseService: _supabaseService,
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
  final SupabaseService supabaseService;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _HeadsUpNotificationBanner({
    required this.title,
    required this.body,
    this.senderId,
    required this.supabaseService,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  State<_HeadsUpNotificationBanner> createState() => _HeadsUpNotificationBannerState();
}

class _HeadsUpNotificationBannerState extends State<_HeadsUpNotificationBanner> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _offsetAnimation;
  double _dragOffset = 0.0;
  Map<String, dynamic>? _senderProfile;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _offsetAnimation = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    _controller.forward();
    _fetchSenderProfile();
  }

  Future<void> _fetchSenderProfile() async {
    final sId = widget.senderId;
    if (sId == null || sId.isEmpty) return;
    try {
      final profile = await widget.supabaseService.getUserProfile(sId);
      if (profile != null && mounted) {
        setState(() {
          _senderProfile = profile;
        });
      }
    } catch (_) {}
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
      child: Transform.translate(
        offset: Offset(0, _dragOffset.clamp(-200.0, 0.0)),
        child: GestureDetector(
          onVerticalDragUpdate: (details) {
            setState(() {
              _dragOffset += details.delta.dy;
            });
          },
          onVerticalDragEnd: (details) {
            if (_dragOffset < -30 || details.velocity.pixelsPerSecond.dy < -200) {
              _dismiss();
            } else {
              setState(() {
                _dragOffset = 0.0;
              });
            }
          },
          onTap: () {
            widget.onTap();
            _dismiss();
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xE01E1E24) : const Color(0xF0FFFFFF),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Elegant Profile Avatar with green online status dot
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: isDark ? Colors.white10 : Colors.black.withOpacity(0.06),
                            backgroundImage: (_senderProfile != null && _senderProfile!['photoUrl'] != null)
                                ? NetworkImage(_senderProfile!['photoUrl'])
                                : null,
                            child: (_senderProfile == null || _senderProfile!['photoUrl'] == null)
                                ? Icon(Icons.person, color: isDark ? Colors.white54 : Colors.black45, size: 22)
                                : null,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: const Color(0xFF00FF7F), // Spring Green
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark ? const Color(0xFF1E1E24) : Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _senderProfile != null ? (_senderProfile!['name'] ?? widget.title) : widget.title,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white : Colors.black87,
                                fontSize: 14,
                                letterSpacing: 0.1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.body,
                              style: TextStyle(
                                color: isDark ? Colors.white70 : Colors.black54,
                                fontSize: 13,
                                height: 1.2,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Modern Drag/Dismiss Hint Handle
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.keyboard_arrow_up,
                            color: isDark ? Colors.white30 : Colors.black26,
                            size: 18,
                          ),
                          Text(
                            "SWIPE UP",
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              color: isDark ? Colors.white24 : Colors.black26,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

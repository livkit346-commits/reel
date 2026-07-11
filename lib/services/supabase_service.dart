import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/services/websocket_service.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/services/fcm_service.dart';
import 'package:crypto/crypto.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;

  SupabaseService._internal();

  final SupabaseClient client = Supabase.instance.client;

  // Track active chat room ID to avoid race conditions with background listeners
  String? activeChatId;

  StreamSubscription? _globalWsSubscription;

  void initializeGlobalRealtime() {
    WebSocketService().connect();

    _globalWsSubscription?.cancel();
    _globalWsSubscription = WebSocketService().messageStream.listen((event) async {
      try {
        final type = event['type'];
        
        // Handle incoming text/media messages
        if (type == null || type == 'message' || event.containsKey('text') || event.containsKey('mediaUrl')) {
          final chatId = event['chatId'] as String?;
          final msgId = (event['messageId'] ?? event['id']) as String?;
          final senderId = event['senderId'] as String?;
          final text = event['text'] as String? ?? '';
          
          if (chatId != null && msgId != null) {
            final myId = currentUser?.id ?? await LocalStorageService().getString('last_logged_in_user_id');
            
            if (senderId != null && senderId != myId) {
              // 1. Persist message locally into chat file
              final directory = await getApplicationDocumentsDirectory();
              final file = File('${directory.path}/chats/${chatId}_messages.json');
              List<Map<String, dynamic>> localMessages = [];
              if (await file.exists()) {
                try {
                  final content = await file.readAsString();
                  final List<dynamic> decoded = jsonDecode(content);
                  localMessages = decoded.map((m) => Map<String, dynamic>.from(m)).toList();
                } catch (_) {}
              }

              final exists = localMessages.any((m) => m['id'] == msgId || m['messageId'] == msgId);
              if (!exists) {
                final localMsg = {
                  'id': msgId,
                  'messageId': msgId,
                  'chatId': chatId,
                  'senderId': senderId,
                  'text': text,
                  'mediaUrl': event['mediaUrl'],
                  'mediaType': event['mediaType'],
                  'createdAt': event['createdAt'] ?? DateTime.now().toIso8601String(),
                  'received': true,
                  'status': 'delivered',
                };
                localMessages.add(localMsg);
                localMessages.sort((a, b) {
                  final timeA = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
                  final timeB = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
                  return timeA.compareTo(timeB);
                });

                final dir = Directory('${directory.path}/chats');
                if (!await dir.exists()) await dir.create(recursive: true);
                await file.writeAsString(jsonEncode(localMessages));
              }

              // 2. Send 'delivered' status update back to sender online
              WebSocketService().sendStatusUpdate(
                chatId: chatId,
                messageId: msgId,
                recipientId: senderId,
                status: 'delivered',
              );

              // 3. If currently in this active chat, send 'read' receipt immediately
              if (activeChatId == chatId) {
                WebSocketService().sendStatusUpdate(
                  chatId: chatId,
                  messageId: msgId,
                  recipientId: senderId,
                  status: 'read',
                );
              } else {
                // Show in-app heads-up notification banner if user is elsewhere in the app
                String senderName = 'New Message';
                try {
                  final profile = await getUserProfile(senderId);
                  if (profile != null && profile['name'] != null && (profile['name'] as String).isNotEmpty) {
                    senderName = profile['name'];
                  }
                } catch (_) {}

                final previewText = text.isNotEmpty ? text : (event['mediaUrl'] != null ? '📷 Media message' : 'New message');
                FcmService().showHeadsUpBanner(senderName, previewText, chatId, senderId);
              }
            }
          }
        } 
        // Handle real-time status updates (delivered, read/seen)
        else if (type == 'status') {
          final chatId = event['chatId'] as String?;
          final msgId = (event['messageId'] ?? event['id']) as String?;
          final status = (event['status'] ?? '').toString();

          if (chatId != null && msgId != null && status.isNotEmpty) {
            final directory = await getApplicationDocumentsDirectory();
            final file = File('${directory.path}/chats/${chatId}_messages.json');
            if (await file.exists()) {
              try {
                final content = await file.readAsString();
                final List<dynamic> decoded = jsonDecode(content);
                final localMessages = decoded.map((m) => Map<String, dynamic>.from(m)).toList();
                
                bool updated = false;
                for (var m in localMessages) {
                  if (m['id'] == msgId || m['messageId'] == msgId) {
                    m['status'] = status;
                    if (status == 'read' || status == 'seen') {
                      m['seen'] = true;
                      m['received'] = true;
                    } else if (status == 'delivered' || status == 'received') {
                      m['received'] = true;
                    }
                    updated = true;
                    break;
                  }
                }

                if (updated) {
                  await file.writeAsString(jsonEncode(localMessages));
                }
              } catch (_) {}
            }
          }
        }
      } catch (e) {
        debugPrint('Error handling global WebSocket message: $e');
      }
    });
  }

  // Background refresh timer
  Timer? _tokenRefreshTimer;

  // Future lock to prevent duplicate concurrent refresh requests
  Future<String?>? _activeRefreshFuture;

  // Status upload progress tracking notifier (0.0 to 1.0)
  final ValueNotifier<double?> statusUploadProgress = ValueNotifier<double?>(null);

  // In-session liked posts cache to persist hearts across scroll/navigation
  final Set<String> _likedPostIds = {};
  Set<String> get likedPostIds => _likedPostIds;

  final Set<String> _savedPostIds = {};
  Set<String> get savedPostIds => _savedPostIds;

  // Cloudflare R2 / CDN Integration Configuration
  static const bool _useCdn = false; // Set to true when R2 is connected
  static const String _cdnBaseUrl = 'https://cdn.reelapp.com';

  // Helper to convert Supabase Storage paths to R2 CDN URLs
  String getMediaUrl(String bucket, String path) {
    if (_useCdn) {
      return '$_cdnBaseUrl/$bucket/$path';
    }
    return client.storage.from(bucket).getPublicUrl(path);
  }

  static String get backendUrl => 'http://54.205.149.147:8080';

  // Parse JWT and check if expired or expiring within 5 minutes
  bool _isTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = parts[1];
      
      var normalized = payload;
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      
      final payloadDecoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> claims = jsonDecode(payloadDecoded);
      final exp = claims['exp'] as int?;
      if (exp == null) return true;
      
      final expirationTime = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      return DateTime.now().add(const Duration(minutes: 5)).isAfter(expirationTime);
    } catch (_) {
      return true;
    }
  }

  // Offline session recovery helper for custom JWT
  Future<AuthResponse> _setSessionOffline(String accessToken, String refreshToken) async {
    try {
      final parts = accessToken.split('.');
      if (parts.length != 3) {
        throw Exception('Invalid custom JWT format');
      }
      final payload = parts[1];
      var normalized = payload;
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final payloadDecoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> claims = jsonDecode(payloadDecoded);
      final userId = claims['sub'] as String? ?? '';
      final email = claims['email'] as String? ?? 'user@reelapp.com';

      // Set far-future expiration (10 years) for permanent offline session persistence (WhatsApp-style)
      final farFutureExp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 315360000;
      const expiresIn = 315360000;

      final sessionMap = {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': expiresIn,
        'expires_at': farFutureExp,
        'token_type': 'bearer',
        'user': {
          'id': userId,
          'email': email,
          'created_at': DateTime.now().toIso8601String(),
          'last_sign_in_at': DateTime.now().toIso8601String(),
          'app_metadata': {'provider': 'email', 'providers': ['email']},
          'user_metadata': {},
          'aud': 'authenticated',
          'role': 'authenticated',
        }
      };

      final jsonStr = jsonEncode(sessionMap);
      final res = await client.auth.recoverSession(jsonStr);
      if (userId.isNotEmpty) {
        await LocalStorageService().setString('last_logged_in_user_id', userId);
      }
      _loadMutedChats();
      _loadArchivedChats();
      return res;
    } catch (e) {
      debugPrint('Error in _setSessionOffline: $e');
      rethrow;
    }
  }

  // Check if a valid saved session exists in local storage
  Future<bool> hasSavedSession() async {
    try {
      final cached = await LocalStorageService().getCachedJson('auth_tokens');
      if (cached != null && cached is Map) {
        final accessToken = cached['accessToken'] as String?;
        final refreshToken = cached['refreshToken'] as String?;
        return accessToken != null && accessToken.isNotEmpty && refreshToken != null && refreshToken.isNotEmpty;
      }
    } catch (_) {}
    return false;
  }

  void _startTokenRefreshTimer() {
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      final cached = await LocalStorageService().getCachedJson('auth_tokens');
      if (cached != null && cached is Map) {
        final accessToken = cached['accessToken'] as String?;
        if (accessToken != null && _isTokenExpired(accessToken)) {
          debugPrint('Periodic token check: Token is expired or expiring soon, refreshing...');
          await getValidAccessToken();
        }
      }
    });
  }

  // Retrieve valid access token, auto-refreshing if expired
  Future<String?> getValidAccessToken() async {
    try {
      final cached = await LocalStorageService().getCachedJson('auth_tokens');
      if (cached == null || cached is! Map) return null;
      
      final accessToken = cached['accessToken'] as String?;
      final refreshToken = cached['refreshToken'] as String?;
      
      if (accessToken == null || refreshToken == null) return null;
      
      if (!_isTokenExpired(accessToken)) {
        return accessToken;
      }
      
      // Token expired, refresh it
      return await _refreshTokens(refreshToken);
    } catch (e) {
      debugPrint('Error getting valid access token: $e');
      return null;
    }
  }

  // Call the refresh endpoint to obtain new tokens
  Future<String?> _refreshTokens(String refreshToken) async {
    if (_activeRefreshFuture != null) {
      return _activeRefreshFuture;
    }

    final completer = Completer<String?>();
    _activeRefreshFuture = completer.future;

    try {
      final uri = Uri.parse('$backendUrl/auth/refresh');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': refreshToken}),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newAccessToken = data['accessToken'] as String?;
        final newRefreshToken = data['refreshToken'] as String?;
        
        if (newAccessToken != null && newRefreshToken != null) {
          await LocalStorageService().cacheJson('auth_tokens', {
            'accessToken': newAccessToken,
            'refreshToken': newRefreshToken,
          });
          
          // Apply to Supabase client offline
          await _setSessionOffline(newAccessToken, newRefreshToken);
          completer.complete(newAccessToken);
          return newAccessToken;
        }
      } else if (response.statusCode == 400 || response.statusCode == 401) {
        // If refresh fails due to invalid/expired refresh token, clear local tokens
        _likedPostIds.clear();
        _savedPostIds.clear();
        await clearLocalChatCache();
        await LocalStorageService().cacheJson('auth_tokens', null);
        await client.auth.signOut();
        completer.complete(null);
        return null;
      }
      completer.complete(null);
      return null;
    } catch (e) {
      debugPrint('Error refreshing tokens: $e');
      completer.complete(null);
      return null;
    } finally {
      _activeRefreshFuture = null;
    }
  }

  // Load persisted session on startup
  Future<void> initializeSession() async {
    try {
      final cached = await LocalStorageService().getCachedJson('auth_tokens');
      if (cached != null && cached is Map) {
        final accessToken = cached['accessToken'] as String?;
        final refreshToken = cached['refreshToken'] as String?;
        if (accessToken != null && refreshToken != null) {
          // Always restore session offline first so the user is immediately logged in
          await _setSessionOffline(accessToken, refreshToken);
          debugPrint('Restored user session offline on startup.');
          
          if (_isTokenExpired(accessToken)) {
            // Try to refresh in the background
            _refreshTokens(refreshToken).then((newAccess) {
              if (newAccess != null) {
                debugPrint('Successfully refreshed token in background on startup.');
              }
            }).catchError((err) {
              debugPrint('Failed background token refresh on startup: $err');
            });
          }
          _startTokenRefreshTimer();
        }
      }
    } catch (e) {
      debugPrint('Failed to initialize session: $e');
    }
  }

  // Auth: Send verification code to email via Go backend
  Future<void> sendVerificationCode(String email) async {
    try {
      final uri = Uri.parse('$backendUrl/auth/send-code');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(response.body.isNotEmpty ? response.body : 'Failed to send verification code');
      }
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Send Password Reset Code via Go backend
  Future<void> sendResetCode(String email) async {
    try {
      final uri = Uri.parse('$backendUrl/auth/send-reset-code');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      if (response.statusCode != 200) {
        throw Exception(response.body.isNotEmpty ? response.body : 'Failed to send reset code');
      }
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Reset Password with Email, OTP Code, and New Password via Go backend
  Future<void> resetPassword(String email, String code, String newPassword) async {
    try {
      final uri = Uri.parse('$backendUrl/auth/reset-password');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'code': code,
          'newPassword': newPassword,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(response.body.isNotEmpty ? response.body : 'Failed to reset password');
      }
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Sign Up with Email via Go backend and auto-login
  Future<AuthResponse> signUpWithEmail(String email, String password, String code) async {
    try {
      final uri = Uri.parse('$backendUrl/auth/register');
      // Use email prefix as a placeholder display name
      final defaultName = email.split('@').first;
      
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'name': defaultName,
          'photoUrl': '',
          'code': code,
        }),
      );

      if (response.statusCode != 201) {
        throw Exception(response.body.isNotEmpty ? response.body : 'Registration failed with code ${response.statusCode}');
      }

      // Automatically sign in the user after successful registration
      return await signInWithEmail(email, password);
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Sign In with Email via Go backend
  Future<AuthResponse> signInWithEmail(String email, String password) async {
    try {
      final uri = Uri.parse('$backendUrl/auth/login');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(response.body.isNotEmpty ? response.body : 'Invalid email or password');
      }

      final data = jsonDecode(response.body);
      final accessToken = data['accessToken'] as String?;
      final refreshToken = data['refreshToken'] as String?;

      if (accessToken == null || refreshToken == null) {
        throw Exception('Invalid session tokens returned by server');
      }

      // Persist tokens locally
      await LocalStorageService().cacheJson('auth_tokens', {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
      });

      // Pass token to Supabase client offline
      final authResponse = await _setSessionOffline(accessToken, refreshToken);
      _startTokenRefreshTimer();

      // Sign in to Firebase Auth as a fallback/sync (if firebase is still active for other things, though we don't require it)
      try {
        await fb.FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      } catch (fbError) {
        debugPrint('Firebase signIn sync failed (ignored): $fbError');
      }

      return authResponse;
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Sign Out
  Future<void> signOut() async {
    try {
      final cached = await LocalStorageService().getCachedJson('auth_tokens');
      if (cached != null && cached is Map) {
        final refreshToken = cached['refreshToken'] as String?;
        if (refreshToken != null) {
          final uri = Uri.parse('$backendUrl/auth/logout');
          await http.post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refreshToken': refreshToken}),
          ).timeout(const Duration(seconds: 5), onTimeout: () => http.Response('timeout', 408));
        }
      }
    } catch (e) {
      debugPrint('Error calling logout endpoint: $e');
    } finally {
      // Clear cache and sign out Supabase/Firebase clients
      _tokenRefreshTimer?.cancel();
      _mutedChatIds.clear();
      _mutedChatsLoaded = false;
      _archivedChatIds.clear();
      _archivedChatsLoaded = false;
      _likedPostIds.clear();
      _savedPostIds.clear();
      await clearLocalChatCache();
      await LocalStorageService().cacheJson('auth_tokens', null);
      await client.auth.signOut();
      try {
        await fb.FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
  }

  // Clear local JSON chat cache from disk and memory
  Future<void> clearLocalChatCache() async {
    try {
      ChatRoomPage.clearAllCache();
      final directory = await getApplicationDocumentsDirectory();
      final chatsDir = Directory('${directory.path}/chats');
      if (await chatsDir.exists()) {
        await chatsDir.delete(recursive: true);
        debugPrint('Cleared local chat cache directory and RAM.');
      }
    } catch (e) {
      debugPrint('Error clearing local chat cache: $e');
    }
  }

  // Reset group join times for the current user to now() (e.g. on new device/session login)
  Future<void> resetGroupJoinTimes() async {
    final myId = currentUser?.id ?? await LocalStorageService().getString('last_logged_in_user_id');
    if (myId == null || myId.isEmpty) return;
    try {
      final participants = await client
          .from('chat_participants')
          .select('chatId')
          .eq('userId', myId);

      final nowStr = DateTime.now().toUtc().toIso8601String();

      for (final p in participants) {
        final chatId = p['chatId'] as String;
        await client
            .from('chat_participants')
            .update({'joinedAt': nowStr})
            .eq('chatId', chatId)
            .eq('userId', myId);
      }
      debugPrint('Reset all chat join times on server for user $myId');
    } catch (e) {
      debugPrint('Error resetting chat join times: $e');
    }
  }

  // Auth: Get Current User
  User? get currentUser {
    final user = client.auth.currentUser;
    if (user != null && user.id.isNotEmpty) {
      LocalStorageService().setString('last_logged_in_user_id', user.id);
    }
    return user;
  }

  Future<String?> getEffectiveUserId() async {
    final uid = client.auth.currentUser?.id;
    if (uid != null && uid.isNotEmpty) {
      await LocalStorageService().setString('last_logged_in_user_id', uid);
      return uid;
    }
    return await LocalStorageService().getString('last_logged_in_user_id');
  }

  // Profile: Create/Update user doc
  Future<void> createUserProfile(String userId, String name, String? photoUrl, String? phoneNumber, {String? bio}) async {
    try {
      await client.from('users').upsert({
        'id': userId,
        'name': name,
        'photoUrl': photoUrl,
        'phone': phoneNumber,
        'bio': bio,
        'createdAt': DateTime.now().toIso8601String(),
        'latitude': 0.0,
        'longitude': 0.0,
        'lastSeen': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  // Upload any file directly to Cloudflare R2 via our Supabase Edge Function (with Supabase Storage fallback)
  Future<String> uploadToR2(File file) async {
    final filename = file.path.split(RegExp(r'[/\\]')).last;
    
    // Determine contentType
    String contentType = 'application/octet-stream';
    final ext = filename.split('.').last.toLowerCase();
    if (ext == 'jpg' || ext == 'jpeg') {
      contentType = 'image/jpeg';
    } else if (ext == 'png') {
      contentType = 'image/png';
    } else if (ext == 'mp4') {
      contentType = 'video/mp4';
    } else if (ext == 'm4a' || ext == 'mp3' || ext == 'wav') {
      contentType = 'audio/mpeg';
    }

    try {
      // 1. Try invoking Supabase Edge Function to get presigned URL
      final response = await client.functions.invoke(
        'r2-presign',
        body: {
          'filename': filename,
          'contentType': contentType,
        },
      );

      if (response.status == 200 && response.data != null && response.data['uploadUrl'] != null) {
        final String uploadUrl = response.data['uploadUrl'];
        final String publicUrl = response.data['publicUrl'] ?? '';

        final fileBytes = await file.readAsBytes();
        final totalBytes = fileBytes.length;
        
        final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl));
        request.headers['Content-Type'] = contentType;
        request.contentLength = totalBytes;

        int uploadedBytes = 0;
        final chunkSize = 64 * 1024;
        
        Future.microtask(() async {
          for (int i = 0; i < totalBytes; i += chunkSize) {
            final end = (i + chunkSize < totalBytes) ? i + chunkSize : totalBytes;
            request.sink.add(fileBytes.sublist(i, end));
            uploadedBytes += (end - i);
            
            final progress = uploadedBytes / totalBytes;
            if (statusUploadProgress.value != null) {
              statusUploadProgress.value = progress;
            }
          }
          await request.sink.close();
        });

        final responseStream = await request.send();
        final uploadResponse = await http.Response.fromStream(responseStream);

        if (uploadResponse.statusCode == 200) {
          return publicUrl;
        }
      }
    } catch (e) {
      debugPrint('Cloudflare R2 upload un-available ($e), falling back to Supabase Storage...');
    }

    // 2. Fallback: Direct upload to Supabase Storage bucket 'media'
    try {
      final storagePath = 'uploads/${DateTime.now().millisecondsSinceEpoch}_$filename';
      await client.storage.from('media').upload(storagePath, file);
      final publicUrl = getMediaUrl('media', storagePath);
      return publicUrl;
    } catch (e) {
      debugPrint('Supabase storage fallback error: $e');
      rethrow;
    }
  }

  // Profile: Upload avatar image
  Future<String> uploadAvatar(File imageFile) async {
    await getValidAccessToken();
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      final photoUrl = await uploadToR2(imageFile);

      // Update users table (supporting camelCase and lowercase)
      try {
        await client.from('users').update({'photoUrl': photoUrl}).eq('id', myId);
      } catch (_) {
        try {
          await client.from('users').update({'photourl': photoUrl}).eq('id', myId);
        } catch (_) {}
      }
      return photoUrl;
    } catch (e) {
      rethrow;
    }
  }

  // Profile: Upload cover image
  Future<String> uploadCoverImage(File imageFile) async {
    await getValidAccessToken();
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      final coverUrl = await uploadToR2(imageFile);

      // Update users table (supporting camelCase and lowercase)
      try {
        await client.from('users').update({'coverUrl': coverUrl}).eq('id', myId);
      } catch (_) {
        try {
          await client.from('users').update({'coverurl': coverUrl}).eq('id', myId);
        } catch (_) {}
      }
      return coverUrl;
    } catch (e) {
      rethrow;
    }
  }

  // Profile: Update location
  Future<void> updateLocation(String userId, double lat, double lng) async {
    try {
      await client.from('users').update({
        'latitude': lat,
        'longitude': lng,
        'lastSeen': DateTime.now().toIso8601String(),
      }).eq('id', userId);
    } catch (e) {
      rethrow;
    }
  }

  // Profile Cache
  final Map<String, Map<String, dynamic>> _profileCache = {};
  Map<String, Map<String, dynamic>> get profileCache => _profileCache;

  // Profile: Get user doc
  Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    if (userId.isEmpty) return null;
    if (_profileCache.containsKey(userId)) {
      return _profileCache[userId];
    }
    try {
      final response = await client.from('users').select().eq('id', userId).maybeSingle();
      if (response != null) {
        _profileCache[userId] = response;
        await LocalStorageService().cacheJson('user_profile_$userId', response);
        return response;
      }
    } catch (e) {
      debugPrint('Error fetching user profile online: $e');
    }
    try {
      final cached = await LocalStorageService().getCachedJson('user_profile_$userId');
      if (cached != null && cached is Map) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(cached);
        _profileCache[userId] = map;
        return map;
      }
    } catch (_) {}
    return null;
  }

  // Profile: Clear cache (useful when editing own profile)
  void clearProfileCache(String userId) {
    _profileCache.remove(userId);
  }

  // Posts: Create post
  Future<void> createPost(String userId, String userName, String text, String? imageUrl) async {
    try {
      // 1. Fetch AI vector embedding from Go Backend
      List<double>? embedding;
      try {
        final uri = Uri.parse('$backendUrl/ai/embed');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': text}),
        ).timeout(const Duration(seconds: 3));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['embedding'] is List) {
            embedding = List<double>.from((data['embedding'] as List).map((e) => (e as num).toDouble()));
          }
        }
      } catch (embedError) {
        debugPrint('Failed to fetch post embedding from backend: $embedError');
      }

      // Format vector array string if we have it, else null
      String? embeddingStr;
      if (embedding != null && embedding.isNotEmpty) {
        embeddingStr = '[${embedding.join(',')}]';
      }

      // 2. Insert post to Supabase
      await client.from('posts').insert({
        'userId': userId,
        'userName': userName,
        'text': text,
        'imageUrl': imageUrl,
        'createdAt': DateTime.now().toIso8601String(),
        'likes': 0,
        if (embeddingStr != null) 'embedding': embeddingStr,
      });
    } catch (e) {
      rethrow;
    }
  }

  // Posts: Upload image and create post
  Future<void> uploadAndCreatePost(String text, File? imageFile) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      final userProfile = await getUserProfile(myId);
      final userName = userProfile?['name'] ?? 'User';

      String? imageUrl;
      if (imageFile != null) {
        try {
          imageUrl = await uploadToR2(imageFile);
        } catch (r2Error) {
          debugPrint('Post R2 upload failed, falling back to Supabase: $r2Error');
          final fileName = 'post_${DateTime.now().millisecondsSinceEpoch}.jpg';
          final storagePath = 'posts/$myId/$fileName';
          await client.storage.from('media').upload(storagePath, imageFile);
          imageUrl = getMediaUrl('media', storagePath);
        }
      }

      await createPost(myId, userName, text, imageUrl);
    } catch (e) {
      rethrow;
    }
  }

  // Posts: Get feed
  Future<List<dynamic>> getExploreFeed() async {
    try {
      final myId = currentUser?.id;
      if (myId != null) {
        if (_likedPostIds.isEmpty) {
          final cachedLiked = await LocalStorageService().getCachedJson('liked_posts_$myId');
          if (cachedLiked is List) {
            _likedPostIds.addAll(List<String>.from(cachedLiked.map((e) => e.toString())));
          }
        }
        if (_savedPostIds.isEmpty) {
          final cachedSaved = await LocalStorageService().getCachedJson('saved_posts_$myId');
          if (cachedSaved is List) {
            _savedPostIds.addAll(List<String>.from(cachedSaved.map((e) => e.toString())));
          }
        }
      }

      dynamic response;
      if (myId != null) {
        try {
          response = await client.rpc('get_explore_feed_recommendations', params: {
            'p_user_id': myId,
            'p_limit': 25,
          });
        } catch (rpcError) {
          debugPrint('get_explore_feed_recommendations RPC failed, falling back to standard feed: $rpcError');
        }
      }

      if (response == null) {
        response = await client.from('posts').select().order('createdAt', ascending: false).limit(25);
      }

      await LocalStorageService().cacheJson('explore_feed', response);
      return response as List<dynamic>;
    } catch (e) {
      final cached = await LocalStorageService().getCachedJson('explore_feed');
      if (cached != null && cached is List) {
        return cached;
      }
      return [];
    }
  }

  // Posts: Report active user engagement metrics
  Future<void> reportPostMetric({
    required String postId,
    int? watchedDuration,
    bool? completed,
    bool? skipped,
    bool? shared,
    bool? liked,
    bool? commented,
  }) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Log metric remotely in public.post_metrics
      final existing = await client
          .from('post_metrics')
          .select()
          .eq('postId', postId)
          .eq('userId', myId)
          .maybeSingle();

      final payload = {
        'postId': postId,
        'userId': myId,
        'updated_at': DateTime.now().toIso8601String(),
        if (watchedDuration != null) 'watched_duration': watchedDuration,
        if (completed != null) 'completed': completed,
        if (skipped != null) 'skipped': skipped,
        if (shared != null) 'shared': shared,
        if (liked != null) 'liked': liked,
        if (commented != null) 'commented': commented,
      };

      if (existing != null) {
        await client
            .from('post_metrics')
            .update(payload)
            .eq('postId', postId)
            .eq('userId', myId);
      } else {
        await client.from('post_metrics').insert(payload);
      }

      // 2. Drift user interest vector if user liked or completed a video post
      if (completed == true || liked == true) {
        try {
          final uri = Uri.parse('$backendUrl/ai/interact');
          await http.post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'userId': myId,
              'postId': postId,
            }),
          ).timeout(const Duration(seconds: 3));
        } catch (driftError) {
          debugPrint('Failed to drift user interest vector: $driftError');
        }
      }
    } catch (e) {
      debugPrint('Failed to report post metrics: $e');
    }
  }

  // Status: Create status
  Future<void> createStatus(String userId, String userName, String imageUrl) async {
    try {
      await client.from('statuses').insert({
        'userId': userId,
        'userName': userName,
        'imageUrl': imageUrl,
        'createdAt': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  // Status: Create fully custom status
  Future<void> createCustomStatus({
    String? text,
    File? mediaFile,
    String? mediaType, // 'image' or 'video'
    File? voiceFile,
    double? trimStart,
    double? trimEnd,
    String? customImageUrl,
  }) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    statusUploadProgress.value = 0.0;

    try {
      try {
      final userProfile = await getUserProfile(myId);
      final userName = userProfile?['name'] ?? 'User';

      String? imageUrl = customImageUrl;
      if (mediaFile != null) {
        final isVideo = mediaType == 'video';
        final extension = isVideo ? 'mp4' : 'jpg';
        try {
          imageUrl = await uploadToR2(mediaFile);
        } catch (r2Error) {
          debugPrint('Custom status media R2 upload failed, falling back to Supabase: $r2Error');
          final fileName = 'status_${DateTime.now().millisecondsSinceEpoch}.$extension';
          final storagePath = 'statuses/$myId/$fileName';
          await client.storage.from('media').upload(storagePath, mediaFile);
          imageUrl = getMediaUrl('media', storagePath);
        }

        // Store video trimming metadata inside the media URL parameters
        if (isVideo && trimStart != null && trimEnd != null) {
          imageUrl = '$imageUrl?trimStart=$trimStart&trimEnd=$trimEnd';
        }

        // Pre-cache the uploaded media locally so we don't have to download it when opening the viewer
        await LocalStorageService().cacheLocalFileForUrl(imageUrl, mediaFile);
      }

      String? voiceUrl;
      if (voiceFile != null) {
        try {
          voiceUrl = await uploadToR2(voiceFile);
        } catch (r2Error) {
          debugPrint('Custom status voice R2 upload failed, falling back to Supabase: $r2Error');
          final fileName = 'status_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
          final storagePath = 'statuses/$myId/$fileName';
          await client.storage.from('media').upload(storagePath, voiceFile);
          voiceUrl = getMediaUrl('media', storagePath);
        }

        // Pre-cache the uploaded voice file locally
        await LocalStorageService().cacheLocalFileForUrl(voiceUrl, voiceFile);
      }

      try {
        // 1. Try camelCase full format (supporting mediaType, voiceUrl, text, etc.)
        await client.from('statuses').insert({
          'userId': myId,
          'userName': userName,
          'imageUrl': imageUrl,
          'mediaType': mediaType ?? 'image',
          'text': text,
          'voiceUrl': voiceUrl,
          'createdAt': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e1) {
        debugPrint('Insert fallback 1 (camelCase full) failed: $e1. Trying lowercase full...');
      }

      try {
        // 2. Try lowercase full format
        await client.from('statuses').insert({
          'userid': myId,
          'username': userName,
          'imageurl': imageUrl,
          'mediatype': mediaType ?? 'image',
          'text': text,
          'voiceurl': voiceUrl,
          'createdat': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e2) {
        debugPrint('Insert fallback 2 (lowercase full) failed: $e2. Trying camelCase with text...');
      }

      try {
        // 3. Try camelCase with mediaType and text (without voiceUrl)
        await client.from('statuses').insert({
          'userId': myId,
          'userName': userName,
          'imageUrl': imageUrl,
          'mediaType': mediaType ?? 'image',
          'text': text,
          'createdAt': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e3) {
        debugPrint('Insert fallback 3 (camelCase with text) failed: $e3. Trying lowercase with text...');
      }

      try {
        // 4. Try lowercase with mediatype and text (without voiceurl)
        await client.from('statuses').insert({
          'userid': myId,
          'username': userName,
          'imageurl': imageUrl,
          'mediatype': mediaType ?? 'image',
          'text': text,
          'createdat': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e4) {
        debugPrint('Insert fallback 4 (lowercase with text) failed: $e4. Trying camelCase basic...');
      }

      try {
        // 5. Try camelCase basic format (with text, but without mediaType/voiceUrl)
        await client.from('statuses').insert({
          'userId': myId,
          'userName': userName,
          'imageUrl': imageUrl,
          'text': text,
          'createdAt': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e5) {
        debugPrint('Insert fallback 5 (camelCase basic) failed: $e5. Trying lowercase basic...');
      }

      try {
        // 6. Try lowercase basic format (with text, but without mediatype/voiceurl)
        await client.from('statuses').insert({
          'userid': myId,
          'username': userName,
          'imageurl': imageUrl,
          'text': text,
          'createdat': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e6) {
        debugPrint('Insert fallback 6 (lowercase basic) failed: $e6. Trying camelCase minimal...');
      }

      try {
        // 7. Try camelCase minimal format (without voiceUrl/text)
        await client.from('statuses').insert({
          'userId': myId,
          'userName': userName,
          'imageUrl': imageUrl,
          'createdAt': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e7) {
        debugPrint('Insert fallback 7 (camelCase minimal) failed: $e7. Trying lowercase minimal as final fallback...');
      }

      // 8. Try lowercase minimal format as final absolute fallback
      await client.from('statuses').insert({
        'userid': myId,
        'username': userName,
        'imageurl': imageUrl,
        'createdat': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
    } finally {
      statusUploadProgress.value = null;
    }
  }

  // Status: Upload and Create status (Legacy helper kept for backward compatibility)
  Future<void> uploadAndCreateStatus(File imageFile, String userName) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      String imageUrl;
      try {
        imageUrl = await uploadToR2(imageFile);
      } catch (r2Error) {
        debugPrint('Legacy status R2 upload failed, falling back to Supabase: $r2Error');
        final fileName = 'status_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final storagePath = 'statuses/$myId/$fileName';
        await client.storage.from('media').upload(storagePath, imageFile);
        imageUrl = getMediaUrl('media', storagePath);
      }

      await createStatus(myId, userName, imageUrl);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteStatus(String statusId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      // 1. Try camelCase userId
      await client.from('statuses').delete().eq('id', statusId).eq('userId', myId);
    } catch (e1) {
      debugPrint('Delete status camelCase failed: $e1. Trying lowercase userid...');
      try {
        // 2. Try lowercase userid
        await client.from('statuses').delete().eq('id', statusId).eq('userid', myId);
      } catch (e2) {
        debugPrint('Delete status lowercase failed: $e2');
        rethrow;
      }
    }
  }

  // Status View tracking
  Future<void> viewStatus(String statusId) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    try {
      await client.from('status_views').insert({
        'statusId': statusId,
        'userId': myId,
      });
    } catch (_) {
      // Ignore if already marked as viewed
    }
  }

  // Get view count and details for a status
  Future<List<dynamic>> getStatusViews(String statusId) async {
    try {
      final response = await client
          .from('status_views')
          .select('createdAt, users(id, name, photoUrl)')
          .eq('statusId', statusId);
      return response;
    } catch (_) {
      return [];
    }
  }

  // Get all status IDs viewed by the current user
  Future<List<String>> getViewedStatusIds() async {
    final myId = currentUser?.id;
    if (myId == null) return [];
    try {
      final response = await client
          .from('status_views')
          .select('statusId')
          .eq('userId', myId);
      return (response as List).map<String>((e) => (e['statusId'] ?? '').toString()).toList();
    } catch (_) {
      try {
        final response = await client
            .from('status_views')
            .select('statusid')
            .eq('userid', myId);
        return (response as List).map<String>((e) => (e['statusid'] ?? '').toString()).toList();
      } catch (_) {
        return [];
      }
    }
  }

  // Status: Retrieve active statuses
  Future<List<dynamic>> getActiveStatuses() async {
    try {
      final oneDayAgo = DateTime.now().subtract(const Duration(hours: 24)).toIso8601String();
      final response = await client
          .from('statuses')
          .select()
          .gt('createdAt', oneDayAgo)
          .order('createdAt', ascending: false);
      await LocalStorageService().cacheJson('active_statuses', response);
      return response;
    } catch (e) {
      final cached = await LocalStorageService().getCachedJson('active_statuses');
      if (cached != null && cached is List) {
        return cached;
      }
      return [];
    }
  }

  // Status: Retrieve followed and discovering active statuses for Explore
  Future<List<dynamic>> getExploreStatuses() async {
    final myId = currentUser?.id;
    if (myId == null) return [];

    try {
      // 1. Get followed user IDs
      final followsList = await client
          .from('follows')
          .select('followingId')
          .eq('followerId', myId);
      final followedIds = (followsList as List)
          .map((f) => (f['followingId'] ?? f['followingid'] ?? '').toString())
          .toList();

      // 2. Fetch all active statuses in the last 24 hours
      final oneDayAgo = DateTime.now().subtract(const Duration(hours: 24)).toIso8601String();
      final allStatuses = await client
          .from('statuses')
          .select()
          .gt('createdAt', oneDayAgo)
          .order('createdAt', ascending: false);

      // 3. Separate them into followed statuses, discovering statuses and filter out mock statuses
      final followedStatuses = [];
      final discoveryStatuses = [];

      for (var s in allStatuses) {
        final statusUserId = (s['userId'] ?? s['userid'] ?? '').toString();
        final statusUserName = (s['userName'] ?? s['username'] ?? 'User').toString();

        // Filter out static mock statuses that say "Nearby"
        if (statusUserName.toLowerCase() == 'nearby') {
          continue;
        }

        if (statusUserId == myId) {
          followedStatuses.add(s);
        } else if (followedIds.contains(statusUserId)) {
          followedStatuses.add(s);
        } else {
          discoveryStatuses.add(s);
        }
      }

      final result = [...followedStatuses, ...discoveryStatuses];
      await LocalStorageService().cacheJson('explore_statuses', result);
      return result;
    } catch (e) {
      final cached = await LocalStorageService().getCachedJson('explore_statuses');
      if (cached != null && cached is List) {
        return cached;
      }
      return getActiveStatuses();
    }
  }

  // Discovery: Update location sharing toggle and coordinates
  Future<void> updateLocationSharing(bool enabled, {double? lat, double? lng}) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    final data = {
      'shareLocation': enabled,
      if (lat != null) 'latitude': lat,
      if (lng != null) 'longitude': lng,
    };

    try {
      // 1. Try camelCase shareLocation
      await client.from('users').update(data).eq('id', myId);
    } catch (e1) {
      debugPrint('updateLocationSharing camelCase failed: $e1. Trying lowercase...');
      try {
        // 2. Try lowercase sharelocation
        final lowercaseData = {
          'sharelocation': enabled,
          if (lat != null) 'latitude': lat,
          if (lng != null) 'longitude': lng,
        };
        await client.from('users').update(lowercaseData).eq('id', myId);
      } catch (e2) {
        debugPrint('updateLocationSharing lowercase failed: $e2');
        // If neither toggle column exists, at least try updating coordinates if they exist
        try {
          final coordData = {
            if (lat != null) 'latitude': lat,
            if (lng != null) 'longitude': lng,
          };
          await client.from('users').update(coordData).eq('id', myId);
        } catch (_) {}
      }
    }
  }

  // Discovery: Check if current user has location sharing enabled
  Future<bool> isLocationSharingEnabled() async {
    final myId = currentUser?.id;
    if (myId == null) return false;

    try {
      // 1. Try camelCase shareLocation
      final response = await client
          .from('users')
          .select('shareLocation')
          .eq('id', myId)
          .single();
      return response['shareLocation'] as bool? ?? false;
    } catch (e1) {
      try {
        // 2. Try lowercase sharelocation
        final response = await client
            .from('users')
            .select('sharelocation')
            .eq('id', myId)
            .single();
        return response['sharelocation'] as bool? ?? false;
      } catch (_) {
        return false;
      }
    }
  }

  // Push Notifications: Update user FCM push token in Supabase
  Future<void> updatePushToken(String token) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Try camelCase pushToken
      await client.from('users').update({'pushToken': token}).eq('id', myId);
    } catch (e1) {
      debugPrint('updatePushToken camelCase failed: $e1. Trying lowercase...');
      try {
        // 2. Try lowercase pushtoken
        await client.from('users').update({'pushtoken': token}).eq('id', myId);
      } catch (e2) {
        debugPrint('updatePushToken lowercase failed: $e2');
      }
    }
  }

  // Discovery: Get nearby users sharing location within 50 meters
  Future<List<dynamic>> getNearbyUsers(double currentLat, double currentLng) async {
    try {
      // 1. Try fetching with camelCase shareLocation
      final response = await client
          .from('users')
          .select()
          .eq('shareLocation', true);
      return _filterUsersByDistance(response, currentLat, currentLng);
    } catch (e1) {
      debugPrint('getNearbyUsers camelCase failed: $e1. Trying lowercase...');
      try {
        // 2. Try fetching with lowercase sharelocation
        final response = await client
            .from('users')
            .select()
            .eq('sharelocation', true);
        return _filterUsersByDistance(response, currentLat, currentLng);
      } catch (e2) {
        debugPrint('getNearbyUsers lowercase failed: $e2. Fetching basic active users...');
        try {
          // 3. Fallback: Fetch basic users and filter by distance (ignoring shareLocation flag if not migrated)
          final response = await client
              .from('users')
              .select()
              .limit(50);
          return _filterUsersByDistance(response, currentLat, currentLng);
        } catch (_) {
          return [];
        }
      }
    }
  }

  List<dynamic> _filterUsersByDistance(List<dynamic> users, double currentLat, double currentLng) {
    final List<dynamic> nearby = [];
    final myId = currentUser?.id;
    for (var user in users) {
      if (user['id'] == myId) continue;

      final double? userLat = double.tryParse((user['latitude'] ?? '').toString());
      final double? userLng = double.tryParse((user['longitude'] ?? '').toString());

      // Skip default 0.0 values (no real location)
      if (userLat != null && userLng != null && (userLat != 0.0 || userLng != 0.0)) {
        final distance = _calculateDistance(currentLat, currentLng, userLat, userLng);
        if (distance <= 50) { // 50 meters
          user['distance'] = distance;
          nearby.add(user);
        }
      }
    }
    return nearby;
  }

  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    var p = 0.017453292519943295; // Math.PI / 180
    var c = cos;
    var a = 0.5 - c((lat2 - lat1) * p)/2 + 
          c(lat1 * p) * c(lat2 * p) * 
          (1 - c((lon2 - lon1) * p))/2;
    return 12742 * asin(sqrt(a)) * 1000; // Distance in meters
  }

  // Discovery: Search by name or phone
  Future<List<dynamic>> searchUsers(String query) async {
    final myId = currentUser?.id;
    try {
      if (myId != null) {
        final response = await client
            .from('users')
            .select()
            .neq('id', myId)
            .or('name.ilike.%$query%,phone.ilike.%$query%')
            .limit(10);
        return response;
      } else {
        final response = await client
            .from('users')
            .select()
            .or('name.ilike.%$query%,phone.ilike.%$query%')
            .limit(10);
        return response;
      }
    } catch (e) {
      rethrow;
    }
  }

  // CHAT SERVICES

  // Check if mutual friends (both users follow each other)
  Future<bool> isMutualFriend(String otherUserId) async {
    final myId = currentUser?.id;
    if (myId == null) return false;

    try {
      // Check if current user follows other user
      final myFollow = await client
          .from('follows')
          .select()
          .eq('followerId', myId)
          .eq('followingId', otherUserId)
          .maybeSingle();

      // Check if other user follows current user
      final otherFollow = await client
          .from('follows')
          .select()
          .eq('followerId', otherUserId)
          .eq('followingId', myId)
          .maybeSingle();

      return myFollow != null && otherFollow != null;
    } catch (_) {
      return false;
    }
  }

  // Create or get chat between current user and another user
  Future<String> createOrGetChat(String otherUserId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    // Snapchat Friendship Enforcer: Restrict chats to mutual friends only
    final areFriends = await isMutualFriend(otherUserId);
    if (!areFriends) {
      throw Exception('Not mutual friends');
    }

    try {
      // Check if a chat already exists between these participants
      final myChats = await client.from('chat_participants').select('chatId').eq('userId', myId);
      final otherChats = await client.from('chat_participants').select('chatId').eq('userId', otherUserId);

      final myChatIds = myChats.map((c) => c['chatId'] as String).toSet();
      final otherChatIds = otherChats.map((c) => c['chatId'] as String).toSet();

      final commonChatIds = myChatIds.intersection(otherChatIds);

      if (commonChatIds.isNotEmpty) {
        return commonChatIds.first;
      }

      // No common chat exists, create a new one
      final chatInsert = await client.from('chats').insert({
        'disappearingDuration': 'off'
      }).select('id').single();

      final newChatId = chatInsert['id'] as String;

      // Add participants
      await client.from('chat_participants').insert([
        {'chatId': newChatId, 'userId': myId},
        {'chatId': newChatId, 'userId': otherUserId},
      ]);

      return newChatId;
    } catch (e) {
      rethrow;
    }
  }

  // Create a new group chat with name, participants list, and optional group icon
  Future<String> createGroupChat(String name, List<String> participantIds, File? iconFile) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      String? groupIconUrl;

      // 1. Upload group icon if provided
      if (iconFile != null) {
        try {
          groupIconUrl = await uploadToR2(iconFile);
        } catch (r2Error) {
          debugPrint('Group icon R2 upload failed, falling back to Supabase Storage: $r2Error');
          final ext = iconFile.path.split('.').last.toLowerCase();
          final fileName = 'group_icon_${DateTime.now().millisecondsSinceEpoch}.$ext';
          final storagePath = 'group_icons/$fileName';
          
          await client.storage.from('media').upload(storagePath, iconFile);
          groupIconUrl = getMediaUrl('media', storagePath);
        }
      }

      // 2. Insert chat row
      final chatInsert = await client.from('chats').insert({
        'isGroup': true,
        'name': name,
        'groupIcon': groupIconUrl,
        'creatorId': myId,
        'disappearingDuration': 'off'
      }).select('id').single();

      final newChatId = chatInsert['id'] as String;

      // 3. Add participants (current user + selected friends)
      final allParticipants = {myId, ...participantIds}.toList();
      final participantInserts = allParticipants.map((uid) => {
        'chatId': newChatId,
        'userId': uid,
      }).toList();

      await client.from('chat_participants').insert(participantInserts);

      return newChatId;
    } catch (e) {
      debugPrint('Error creating group chat: $e');
      rethrow;
    }
  }

  // Fetch a single chat's details (chatName, chatIcon, isGroup, otherUserId) for routing
  Future<Map<String, dynamic>?> getChatDetails(String chatId) async {
    final myId = currentUser?.id;
    if (myId == null) return null;

    try {
      final chatMeta = await client.from('chats').select('id, isGroup, name, groupIcon').eq('id', chatId).maybeSingle();
      if (chatMeta == null) return null;

      final isGroup = chatMeta['isGroup'] as bool? ?? false;
      final data = <String, dynamic>{
        'chatId': chatId,
        'isGroup': isGroup,
      };

      if (isGroup) {
        data['chatName'] = chatMeta['name'] ?? 'Group Chat';
        data['chatIcon'] = chatMeta['groupIcon'];
        data['otherUserId'] = '';
      } else {
        final otherParticipant = await client
            .from('chat_participants')
            .select('users(id, name, photoUrl)')
            .eq('chatId', chatId)
            .neq('userId', myId)
            .maybeSingle();

        if (otherParticipant != null && otherParticipant['users'] != null) {
          final user = otherParticipant['users'] as Map<String, dynamic>;
          data['chatName'] = user['name'] ?? 'User';
          data['chatIcon'] = user['photoUrl'];
          data['otherUserId'] = user['id'];
        } else {
          data['chatName'] = 'User';
          data['chatIcon'] = null;
          data['otherUserId'] = '';
        }
      }
      return data;
    } catch (e) {
      debugPrint('Error getting chat details: $e');
      return null;
    }
  }

  // Get active chats list for the current user with latest-message sorting and offline cache support
  Future<List<dynamic>> getActiveChats() async {
    final myId = currentUser?.id ?? await LocalStorageService().getString('last_logged_in_user_id');
    if (myId == null || myId.isEmpty) {
      try {
        final cached = await LocalStorageService().getCachedJson('active_chats_offline_fallback');
        if (cached != null && cached is List) {
          return cached;
        }
      } catch (_) {}
      return [];
    }

    try {
      // Find all chats where I am a participant
      final participants = await client.from('chat_participants').select('chatId').eq('userId', myId);
      final chatIds = participants.map((p) => p['chatId'] as String).toList();

      if (chatIds.isEmpty) return [];

      // Fetch chats metadata (isGroup, name, groupIcon, createdAt) for these chatIds
      final chatsMetaResponse = await client
          .from('chats')
          .select('id, isGroup, name, groupIcon, createdAt')
          .inFilter('id', chatIds);

      final List<dynamic> chatsList = [];

      for (final chatMeta in chatsMetaResponse) {
        final cid = chatMeta['id'] as String;
        final isGroup = chatMeta['isGroup'] as bool? ?? false;

        final chatData = <String, dynamic>{
          'chatId': cid,
          'isGroup': isGroup,
        };

        if (isGroup) {
          chatData['chatName'] = chatMeta['name'] ?? 'Group Chat';
          chatData['chatIcon'] = chatMeta['groupIcon'];
          chatData['otherUserId'] = '';
        } else {
          // 1-on-1 chat: Fetch the other participant's profile
          final otherParticipant = await client
              .from('chat_participants')
              .select('users(id, name, photoUrl)')
              .eq('chatId', cid)
              .neq('userId', myId)
              .maybeSingle();

          if (otherParticipant != null && otherParticipant['users'] != null) {
            final user = otherParticipant['users'] as Map<String, dynamic>;
            chatData['chatName'] = user['name'] ?? 'User';
            chatData['chatIcon'] = user['photoUrl'];
            chatData['otherUserId'] = user['id'];
          } else {
            // Fallback if other user is deleted or not found: skip this chat completely
            continue;
          }
        }

        // 1. Try loading the latest message from local JSON cache
        Map<String, dynamic>? latestMsg;
        try {
          final directory = await getApplicationDocumentsDirectory();
          final file = File('${directory.path}/chats/${cid}_messages.json');
          if (await file.exists()) {
            final content = await file.readAsString();
            final List<dynamic> decoded = jsonDecode(content);
            if (decoded.isNotEmpty) {
              latestMsg = Map<String, dynamic>.from(decoded.last);
            }
          }
        } catch (_) {}

        if (latestMsg != null) {
          chatData['latestMessageText'] = latestMsg['text'];
          String? timeStr;
          if (latestMsg['createdAt'] != null) {
            timeStr = latestMsg['createdAt'] as String;
          } else if (latestMsg['timestamp'] != null) {
            final ts = latestMsg['timestamp'] as int;
            timeStr = DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String();
          }
          chatData['latestMessageTime'] = timeStr ?? '1970-01-01T00:00:00Z';
          chatData['latestMessageType'] = latestMsg['mediaType'];

          // Compute hasUnread locally
          final isMe = latestMsg['senderId'] == myId;
          final isSeen = latestMsg['seen'] as bool? ?? false;
          chatData['hasUnread'] = !isMe && !isSeen;
        } else {
          // Fallback: Query legacy messages
          chatData['latestMessageText'] = null;
          chatData['latestMessageTime'] = chatMeta['createdAt'] ?? '1970-01-01T00:00:00Z';
          chatData['latestMessageType'] = null;
          chatData['hasUnread'] = false;
        }

        chatsList.add(chatData);
      }

      // Sort chats descending by the latest message's timestamp
      chatsList.sort((a, b) {
        final timeA = DateTime.tryParse(a['latestMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final timeB = DateTime.tryParse(b['latestMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA);
      });

      // Cache active chats list locally for offline fallback
      await LocalStorageService().cacheJson('active_chats_$myId', chatsList);
      await LocalStorageService().cacheJson('active_chats_offline_fallback', chatsList);

      return chatsList;
    } catch (e) {
      // Offline fallback: load cached active chats
      try {
        final cached = await LocalStorageService().getCachedJson('active_chats_$myId') ??
            await LocalStorageService().getCachedJson('active_chats_offline_fallback');
        if (cached != null && cached is List) {
          return cached;
        }
      } catch (_) {}
      return [];
    }
  }

  // Fetch chat participant details (join time and last received message ID)
  Future<Map<String, dynamic>?> getChatParticipantDetails(String chatId) async {
    final myId = currentUser?.id;
    if (myId == null) return null;
    try {
      final response = await client
          .from('chat_participants')
          .select('joinedAt, lastReceivedMessageId')
          .eq('chatId', chatId)
          .eq('userId', myId)
          .maybeSingle();
      return response;
    } catch (_) {}
    return null;
  }

  // Update user's last received message ID for a chat
  Future<void> updateLastReceivedMessageId(String chatId, String messageId) async {
    final myId = currentUser?.id;
    if (myId == null) return;
    try {
      await client
          .from('chat_participants')
          .update({'lastReceivedMessageId': messageId})
          .eq('chatId', chatId)
          .eq('userId', myId);
    } catch (_) {}
  }

  // Sync offline/undelivered messages for all active chats
  Future<void> syncOfflineMessages() async {
    final myId = currentUser?.id;
    if (myId == null) return;

    // Clean up expired media messages from the server
    deleteExpiredMessagesFromServer();

    try {
      // 1. Find all active chats
      final participants = await client.from('chat_participants').select('chatId').eq('userId', myId);
      final chatIds = participants.map((p) => p['chatId'] as String).toList();
      if (chatIds.isEmpty) return;

      final directory = await getApplicationDocumentsDirectory();

      // 2. Fetch history for each chat
      for (final cid in chatIds) {
        if (cid == activeChatId) continue; // Skip active chat room as it manages its own history/cache
        if (!WebSocketService().isConnected) continue;

        // Load existing local messages for this chat first to get lastMessageId
        final file = File('${directory.path}/chats/${cid}_messages.json');
        List<Map<String, dynamic>> localMessages = [];
        if (await file.exists()) {
          try {
            final content = await file.readAsString();
            final List<dynamic> decoded = jsonDecode(content);
            localMessages = decoded.map((m) => Map<String, dynamic>.from(m)).toList();
          } catch (_) {}
        }

        // Get cleared timestamp if any
        final clearTimestampStr = await LocalStorageService().getCachedJson('clear_timestamp_$cid') as String?;
        final clearTimestamp = clearTimestampStr != null ? DateTime.tryParse(clearTimestampStr) : null;
        
        // Filter out any local messages that are before the clear timestamp
        if (clearTimestamp != null) {
          localMessages = localMessages.where((m) {
            final createdAtStr = m['createdAt'] as String?;
            if (createdAtStr != null) {
              final parsed = DateTime.tryParse(createdAtStr);
              if (parsed != null && parsed.isBefore(clearTimestamp)) {
                return false;
              }
            }
            return true;
          }).toList();
        }

        String? lastMessageId;
        if (localMessages.isNotEmpty) {
          final nonPending = localMessages.where((m) => m['isPending'] != true).toList();
          if (nonPending.isNotEmpty) {
            nonPending.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
            lastMessageId = nonPending.last['id'];
          }
        }

        // Fetch participant details to override lastMessageId if empty, and get join time
        final details = await getChatParticipantDetails(cid);
        DateTime? joinedAt;
        if (details != null) {
          if (lastMessageId == null) {
            lastMessageId = details['lastReceivedMessageId'] as String?;
          }
          if (details['joinedAt'] != null) {
            joinedAt = DateTime.tryParse(details['joinedAt']);
          }
        }

        final history = await WebSocketService().fetchHistory(cid, lastMessageId: lastMessageId);
        if (history.isEmpty) continue;



        bool hasChanges = false;
        for (final msg in history) {
          final typedMsg = Map<String, dynamic>.from(msg);
          final msgId = typedMsg['messageId'] ?? typedMsg['id'];

          // Skip messages sent before the user joined
          if (joinedAt != null) {
            final msgTime = typedMsg['timestamp'] != null
                ? DateTime.fromMillisecondsSinceEpoch((typedMsg['timestamp'] as num).toInt())
                : DateTime.tryParse(typedMsg['createdAt'] ?? '');
            if (msgTime != null && msgTime.isBefore(joinedAt)) {
              continue;
            }
          }

          // Filter out already read/seen messages if we are bootstrapping history after a fresh login (no local messages)
          final isMe = typedMsg['senderId'] == myId;
          final seenParticipants = List<String>.from(typedMsg['seenParticipants'] ?? []);
          final isSeenByMe = typedMsg['seen'] == true || seenParticipants.contains(myId);
          if (lastMessageId == null && (isMe || isSeenByMe)) {
            continue;
          }

          final exists = localMessages.any((m) => m['id'] == msgId || m['messageId'] == msgId);
          if (!exists) {
            final createdAtStr = typedMsg['timestamp'] != null
                ? DateTime.fromMillisecondsSinceEpoch(typedMsg['timestamp']).toIso8601String()
                : DateTime.now().toIso8601String();

            // Skip history messages before cleared timestamp
            if (clearTimestamp != null) {
              final parsed = DateTime.tryParse(createdAtStr);
              if (parsed != null && parsed.isBefore(clearTimestamp)) {
                continue;
              }
            }

            final localMsg = {
              'id': msgId,
              'messageId': msgId,
              'chatId': typedMsg['chatId'],
              'senderId': typedMsg['senderId'],
              'text': typedMsg['text'],
              'mediaUrl': typedMsg['mediaUrl'],
              'mediaType': typedMsg['mediaType'],
              'createdAt': createdAtStr,
              'received': true,
            };
            localMessages.add(localMsg);
            hasChanges = true;

            if (typedMsg['senderId'] != myId) {
              final mediaUrl = typedMsg['mediaUrl'] as String?;
              if (mediaUrl != null && mediaUrl.isNotEmpty) {
                // Pre-cache media file locally first so we don't lose it
                try {
                  await LocalStorageService().getCachedFile(mediaUrl, ttl: const Duration(days: 30));
                  debugPrint('Pre-cached offline media file: $mediaUrl');
                } catch (e) {
                  debugPrint('Failed to pre-cache offline media: $e');
                }
              }
              // Immediately delete both database row and storage file from server
              await deleteMessageFromServer(msgId, deleteStorage: true);
            }
          }
        }

        if (hasChanges) {
          // Sort messages chronologically
          localMessages.sort((a, b) {
            final timeA = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
            final timeB = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
            return timeA.compareTo(timeB);
          });

          // Save back to local file cache
          final dir = Directory('${directory.path}/chats');
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          await file.writeAsString(jsonEncode(localMessages));

          // Sync the latest received message ID back to the server
          final nonPending = localMessages.where((m) => m['isPending'] != true).toList();
          if (nonPending.isNotEmpty) {
            nonPending.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
            final latestId = nonPending.last['id'];
            updateLastReceivedMessageId(cid, latestId);
          }
        }
      }
    } catch (e) {
      debugPrint('Error syncing offline messages: $e');
    }
  }

  // Save a single incoming WebSocket message to the local cache and send received status
  Future<void> saveIncomingMessage(Map<String, dynamic> event) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    final chatId = event['chatId'];
    if (chatId == null) return;
    
    // Skip if this is the active chat room (which is currently open and has its own handler)
    if (chatId == activeChatId) return;

    final messageId = event['messageId'] ?? event['id'];
    if (messageId == null) return;

    // Skip if message was sent before local clear timestamp
    final clearTimestampStr = await LocalStorageService().getCachedJson('clear_timestamp_$chatId') as String?;
    if (clearTimestampStr != null) {
      final clearTimestamp = DateTime.tryParse(clearTimestampStr);
      if (clearTimestamp != null) {
        final timestampVal = event['timestamp'];
        final msgTime = timestampVal != null
            ? DateTime.fromMillisecondsSinceEpoch((timestampVal as num).toInt())
            : DateTime.now();
        if (msgTime.isBefore(clearTimestamp)) {
          return;
        }
      }
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/chats/${chatId}_messages.json');
      List<Map<String, dynamic>> localMessages = [];
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          final List<dynamic> decoded = jsonDecode(content);
          localMessages = decoded.map((m) => Map<String, dynamic>.from(m)).toList();
        } catch (_) {}
      }

      final exists = localMessages.any((m) => m['id'] == messageId || m['messageId'] == messageId);
      if (!exists) {
        final senderId = event['senderId'];
        final localMsg = {
          'id': messageId,
          'messageId': messageId,
          'chatId': chatId,
          'senderId': senderId,
          'text': event['text'],
          'mediaUrl': event['mediaUrl'],
          'mediaType': event['mediaType'],
          'createdAt': event['timestamp'] != null
              ? DateTime.fromMillisecondsSinceEpoch((event['timestamp'] as num).toInt()).toIso8601String()
              : DateTime.now().toIso8601String(),
          'received': true,
        };
        localMessages.add(localMsg);

        // Sort messages chronologically
        localMessages.sort((a, b) {
          final timeA = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
          final timeB = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
          return timeA.compareTo(timeB);
        });

        // Save back to local file cache
        final dir = Directory('${directory.path}/chats');
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        await file.writeAsString(jsonEncode(localMessages));
        debugPrint('Saved incoming message $messageId to local cache for chat $chatId');

        // Automatically unarchive the chat if a new message arrives
        if (isChatArchived(chatId)) {
          await toggleArchiveChat(chatId);
          debugPrint('Chat $chatId automatically unarchived due to new message.');
        }

        // Pre-cache media locally and immediately delete message from server database and storage
        if (senderId != myId) {
          final mediaUrl = event['mediaUrl'] as String?;
          if (mediaUrl != null && mediaUrl.isNotEmpty) {
            try {
              await LocalStorageService().getCachedFile(mediaUrl, ttl: const Duration(days: 30));
              debugPrint('Pre-cached incoming WS media file: $mediaUrl');
            } catch (e) {
              debugPrint('Failed to pre-cache incoming WS media: $e');
            }
          }
          // Immediately purge database row and media file from server
          deleteMessageFromServer(messageId, deleteStorage: true);

          if (WebSocketService().isConnected) {
            WebSocketService().sendStatusUpdate(
              chatId: chatId,
              messageId: messageId,
              recipientId: senderId,
              status: 'received',
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Error saving incoming message: $e');
    }
  }

  // Save incoming WebSocket status update to the local cache
  Future<void> saveIncomingStatus(Map<String, dynamic> event) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    final chatId = event['chatId'];
    final messageId = event['messageId'] ?? event['id'];
    final status = event['status'];
    final fromUserId = event['senderId']; // Added by Go backend when forwarding status

    if (chatId == null || messageId == null || status == null) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/chats/${chatId}_messages.json');
      if (!await file.exists()) return;

      List<Map<String, dynamic>> localMessages = [];
      try {
        final content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        localMessages = decoded.map((m) => Map<String, dynamic>.from(m)).toList();
      } catch (_) {
        return;
      }

      final index = localMessages.indexWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
      if (index == -1) return;

      final msg = localMessages[index];

      // Retrieve isGroup from cached active chats
      bool isGroup = false;
      final cached = await LocalStorageService().getCachedJson('active_chats_$myId');
      if (cached != null && cached is List) {
        final chat = cached.firstWhere((c) => c['chatId'] == chatId, orElse: () => null);
        if (chat != null) {
          isGroup = chat['isGroup'] as bool? ?? false;
        }
      }

      if (!isGroup) {
        msg['received'] = (status == 'received' || status == 'seen');
        msg['seen'] = (status == 'seen');
      } else {
        // Group chat status update tracking
        List<String> receivedList = List<String>.from(msg['receivedParticipants'] ?? []);
        List<String> seenList = List<String>.from(msg['seenParticipants'] ?? []);

        if (fromUserId != null) {
          if (status == 'received') {
            if (!receivedList.contains(fromUserId)) {
              receivedList.add(fromUserId);
            }
          } else if (status == 'seen') {
            if (!receivedList.contains(fromUserId)) {
              receivedList.add(fromUserId);
            }
            if (!seenList.contains(fromUserId)) {
              seenList.add(fromUserId);
            }
          }
        }

        msg['receivedParticipants'] = receivedList;
        msg['seenParticipants'] = seenList;

        // Resolve group participants from local storage cache
        final participantCacheKey = 'group_participants_$chatId';
        final cachedParticipants = await LocalStorageService().getCachedJson(participantCacheKey);
        List<String> otherMembers = [];
        if (cachedParticipants != null && cachedParticipants is List) {
          otherMembers = cachedParticipants.map((p) => p.toString()).where((uid) => uid != myId).toList();
        }

        if (otherMembers.isNotEmpty) {
          msg['received'] = otherMembers.any((uid) => receivedList.contains(uid));
          msg['seen'] = otherMembers.every((uid) => seenList.contains(uid));
        } else {
          msg['received'] = (status == 'received' || status == 'seen');
          msg['seen'] = (status == 'seen');
        }
      }

      await file.writeAsString(jsonEncode(localMessages));
      debugPrint('Saved status update ($status) for message $messageId in chat $chatId');
    } catch (e) {
      debugPrint('Error saving incoming status: $e');
    }
  }

  // Send a message
  Future<Map<String, dynamic>> sendMessage({
    required String chatId,
    String? text,
    File? mediaFile,
    String? mediaType, // 'image', 'video', 'sticker'
    String? mediaUrl,
    String disappearingDuration = 'off', // 'off', '24h', '48h'
    String? replyToMessageId,
  }) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      String? finalMediaUrl = mediaUrl;
      if (mediaFile != null && finalMediaUrl == null) {
        try {
          finalMediaUrl = await uploadToR2(mediaFile);
        } catch (r2Error) {
          debugPrint('Chat media R2 upload failed, falling back to Supabase: $r2Error');
          final fileName = '${DateTime.now().millisecondsSinceEpoch}_${mediaFile.path.split(RegExp(r'[/\\]')).last}';
          final storagePath = 'chat_media/$chatId/$fileName';
          await client.storage.from('media').upload(storagePath, mediaFile);
          finalMediaUrl = getMediaUrl('media', storagePath);
        }
      }

      // Calculate expiration time if disappearing is enabled
      DateTime? expiresAt;
      if (disappearingDuration == '24h') {
        expiresAt = DateTime.now().add(const Duration(hours: 24));
      } else if (disappearingDuration == '48h') {
        expiresAt = DateTime.now().add(const Duration(hours: 48));
      } else if (mediaType == 'image' || mediaType == 'video') {
        // Automatically expire images/videos in 48 hours if not received
        expiresAt = DateTime.now().add(const Duration(hours: 48));
      }

      final response = await client.from('messages').insert({
        'chatId': chatId,
        'senderId': myId,
        'text': text,
        'mediaUrl': finalMediaUrl,
        'mediaType': mediaType,
        'expiresAt': expiresAt?.toIso8601String(),
        'received': false,
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
      }).select().single();
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // Pin or unpin a message
  Future<void> pinMessage(String messageId, bool isPinned) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('messages').update({'is_pinned': isPinned}).eq('id', messageId);
    } catch (e) {
      rethrow;
    }
  }

  // Delete message for everyone (sender only)
  Future<void> deleteMessageForEveryone(String messageId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('messages').update({
        'isDeleted': true,
        'text': null,
        'mediaUrl': null,
        'mediaType': null,
      }).eq('id', messageId).eq('senderId', myId);
    } catch (e) {
      rethrow;
    }
  }

  // Delete message for me
  Future<void> deleteMessageForMe(String messageId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      // Fetch current message to get the array
      final response = await client.from('messages').select('deletedFor').eq('id', messageId).single();
      List<dynamic> currentDeletedFor = response['deletedFor'] ?? [];
      if (!currentDeletedFor.contains(myId)) {
        currentDeletedFor.add(myId);
        await client.from('messages').update({
          'deletedFor': currentDeletedFor,
        }).eq('id', messageId);
      }
    } catch (e) {
      rethrow;
    }
  }

  // Fetch message history for a chat room
  Future<List<dynamic>> getChatMessages(String chatId) async {
    try {
      final response = await client
          .from('messages')
          .select()
          .eq('chatId', chatId)
          .order('createdAt', ascending: true);
      return response;
    } catch (e) {
      return [];
    }
  }

  // Mark message as received
  Future<void> markMessageAsReceived(String messageId) async {
    try {
      // This will update the status, triggering the server-side Postgres trigger 
      // to immediately purge the message from the backend database for zero-retention!
      await client.from('messages').update({'received': true}).eq('id', messageId);
    } catch (e) {
      // Ignore background errors
    }
  }

  // Delete message immediately from the server database (if manual cleanup is desired)
  Future<void> deleteMessageFromServer(String messageId, {bool deleteStorage = false}) async {
    try {
      if (deleteStorage) {
        final msg = await client.from('messages').select('mediaUrl').eq('id', messageId).maybeSingle();
        if (msg != null) {
          final mediaUrl = msg['mediaUrl'] as String?;
          if (mediaUrl != null) {
            if (mediaUrl.contains('storage/v1/object/public/media/')) {
              final parts = mediaUrl.split('storage/v1/object/public/media/');
              if (parts.length > 1) {
                final storagePath = parts[1];
                await client.storage.from('media').remove([storagePath]);
                debugPrint('Successfully deleted media from storage: $storagePath');
              }
            } else if (mediaUrl.contains('/chat_media/')) {
              final idx = mediaUrl.indexOf('chat_media/');
              if (idx != -1) {
                final storagePath = mediaUrl.substring(idx);
                try {
                  await client.storage.from('media').remove([storagePath]);
                  debugPrint('Successfully deleted media from fallback storage: $storagePath');
                } catch (_) {}
              }
            }
          }
        }
      }
      await client.from('messages').delete().eq('id', messageId);
      debugPrint('Successfully deleted message from DB: $messageId');
    } catch (e) {
      debugPrint('Error deleting message from server: $e');
    }
  }

  // Delete expired messages from the server (both database row and storage file)
  Future<void> deleteExpiredMessagesFromServer() async {
    try {
      final nowStr = DateTime.now().toUtc().toIso8601String();
      
      // Fetch expired messages to clean up their storage files
      final expiredMsgs = await client
          .from('messages')
          .select('id, mediaUrl')
          .lt('expiresAt', nowStr);
      
      if (expiredMsgs.isNotEmpty) {
        for (final msg in expiredMsgs) {
          final messageId = msg['id'] as String;
          final mediaUrl = msg['mediaUrl'] as String?;
          if (mediaUrl != null && mediaUrl.contains('storage/v1/object/public/media/')) {
            final parts = mediaUrl.split('storage/v1/object/public/media/');
            if (parts.length > 1) {
              final storagePath = parts[1];
              await client.storage.from('media').remove([storagePath]);
              debugPrint('Expired media deleted: $storagePath');
            }
          }
          await client.from('messages').delete().eq('id', messageId);
        }
      }
    } catch (e) {
      debugPrint('Error cleaning up expired messages from server: $e');
    }
  }

  // SOCIALS & FRIENDS SERVICES

  // Follow/Add user
  Future<void> followUser(String otherUserId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('follows').insert({
        'followerId': myId,
        'followingId': otherUserId,
      });
    } catch (e) {
      rethrow;
    }
  }

  // Unfollow user
  Future<void> unfollowUser(String otherUserId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('follows').delete().eq('followerId', myId).eq('followingId', otherUserId);
    } catch (e) {
      rethrow;
    }
  }

  // Check if following
  Future<bool> isFollowing(String otherUserId) async {
    final myId = currentUser?.id;
    if (myId == null) return false;

    try {
      final response = await client
          .from('follows')
          .select()
          .eq('followerId', myId)
          .eq('followingId', otherUserId)
          .maybeSingle();
      return response != null;
    } catch (e) {
      return false;
    }
  }

  // Get following count
  Future<int> getFollowingCount(String userId) async {
    try {
      final response = await client
          .from('follows')
          .select('id')
          .eq('followerId', userId);
      return response.length;
    } catch (e) {
      return 0;
    }
  }

  // Get followers count
  Future<int> getFollowersCount(String userId) async {
    try {
      final response = await client
          .from('follows')
          .select('id')
          .eq('followingId', userId);
      return response.length;
    } catch (e) {
      return 0;
    }
  }

  // CHANNELS SERVICES

  // Create channel
  Future<void> createChannel(String name) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      final channel = await client.from('channels').insert({
        'name': name,
        'creatorId': myId,
      }).select('id').single();

      // Automatically subscribe creator
      await followChannel(channel['id'] as String);
    } catch (e) {
      rethrow;
    }
  }

  // Get all channels
  Future<List<dynamic>> getChannels() async {
    try {
      final response = await client.from('channels').select().order('createdAt', ascending: false);
      await LocalStorageService().cacheJson('all_channels_cache', response);
      return response;
    } catch (e) {
      final cached = await LocalStorageService().getCachedJson('all_channels_cache');
      if (cached != null && cached is List) {
        return cached;
      }
      return [];
    }
  }

  // Follow/Subscribe channel
  Future<void> followChannel(String channelId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('channel_subscribers').insert({
        'channelId': channelId,
        'userId': myId,
      });
    } catch (e) {
      rethrow;
    }
  }

  // Unfollow/Unsubscribe channel
  Future<void> unfollowChannel(String channelId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('channel_subscribers').delete().eq('channelId', channelId).eq('userId', myId);
    } catch (e) {
      rethrow;
    }
  }

  // Check if subscribed to channel
  Future<bool> isSubscribedToChannel(String channelId) async {
    final myId = currentUser?.id;
    if (myId == null) return false;

    try {
      final response = await client
          .from('channel_subscribers')
          .select()
          .eq('channelId', channelId)
          .eq('userId', myId)
          .maybeSingle();
      return response != null;
    } catch (e) {
      return false;
    }
  }

  // Posts: Delete post (clearing comments and reports first to avoid foreign key violations)
  Future<void> deletePost(String postId) async {
    try {
      // Delete comments first
      await client.from('comments').delete().eq('postId', postId);
    } catch (_) {
      try {
        await client.from('comments').delete().eq('postid', postId);
      } catch (_) {}
    }

    try {
      // Delete reports first
      await client.from('reports').delete().eq('postId', postId);
    } catch (_) {
      try {
        await client.from('reports').delete().eq('postid', postId);
      } catch (_) {}
    }

    try {
      // Delete the post
      await client.from('posts').delete().eq('id', postId);
    } catch (e) {
      rethrow;
    }
  }

  // Comments: Delete comment
  Future<void> deleteComment(String commentId) async {
    try {
      await client.from('comments').delete().eq('id', commentId);
    } catch (e) {
      rethrow;
    }
  }

  // Posts: Report post
  Future<void> reportPost(String postId) async {
    final myId = currentUser?.id;
    try {
      await client.from('reports').insert({
        'postId': postId,
        'reporterId': myId,
        'createdAt': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  // Posts: Toggle Like
  Future<void> toggleLikePost(String postId, int currentLikes, bool increment) async {
    try {
      final newLikes = increment ? currentLikes + 1 : currentLikes - 1;
      await client.from('posts').update({'likes': newLikes >= 0 ? newLikes : 0}).eq('id', postId);
      if (increment) {
        _likedPostIds.add(postId);
      } else {
        _likedPostIds.remove(postId);
      }
      final myId = currentUser?.id;
      if (myId != null) {
        await LocalStorageService().cacheJson('liked_posts_$myId', _likedPostIds.toList());
        // Report like metrics in the background
        reportPostMetric(postId: postId, liked: increment);
      }
    } catch (e) {
      rethrow;
    }
  }

  // Posts: Toggle Save (Bookmark)
  Future<void> toggleSavePost(String postId) async {
    final myId = currentUser?.id;
    if (myId == null) return;
    try {
      if (_savedPostIds.contains(postId)) {
        _savedPostIds.remove(postId);
      } else {
        _savedPostIds.add(postId);
      }
      await LocalStorageService().cacheJson('saved_posts_$myId', _savedPostIds.toList());
    } catch (e) {
      debugPrint('Error toggling save post: $e');
    }
  }

  // Posts: Get post by ID (for rendering quoted/reposted post details)
  Future<Map<String, dynamic>?> getPostById(String postId) async {
    try {
      final response = await client.from('posts').select().eq('id', postId).maybeSingle();
      return response;
    } catch (e) {
      debugPrint('Error getting post by ID: $e');
      return null;
    }
  }

  // Comments: Add comment
  Future<Map<String, dynamic>> addComment(String postId, String text, {String? parentId, String? replyToUserName}) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');
    try {
      final profile = await getUserProfile(myId);
      final userName = profile?['name'] ?? 'User';
      
      try {
        // 1. Try camelCase format
        final Map<String, dynamic> insertData = {
          'postId': postId,
          'userId': myId,
          'userName': userName,
          'text': text,
          'createdAt': DateTime.now().toIso8601String(),
        };
        if (parentId != null) {
          insertData['parentId'] = parentId;
        }
        if (replyToUserName != null) {
          insertData['replyToUserName'] = replyToUserName;
        }
        final response = await client.from('comments').insert(insertData).select().single();
        reportPostMetric(postId: postId, commented: true);
        return response;
      } catch (e1) {
        debugPrint('Comment insert camelCase failed: $e1. Trying lowercase...');
        // 2. Try lowercase format
        final Map<String, dynamic> insertDataLower = {
          'postid': postId,
          'userid': myId,
          'username': userName,
          'text': text,
          'createdat': DateTime.now().toIso8601String(),
        };
        if (parentId != null) {
          insertDataLower['parentid'] = parentId;
        }
        if (replyToUserName != null) {
          insertDataLower['replytousername'] = replyToUserName;
        }
        final response = await client.from('comments').insert(insertDataLower).select().single();
        reportPostMetric(postId: postId, commented: true);
        return response;
      }
    } catch (e) {
      rethrow;
    }
  }

  // Comments: Get comments for post
  Future<List<dynamic>> getComments(String postId) async {
    try {
      // 1. Try camelCase
      return await client.from('comments').select().eq('postId', postId).order('createdAt', ascending: true);
    } catch (e1) {
      try {
        // 2. Try lowercase
        return await client.from('comments').select().eq('postid', postId).order('createdat', ascending: true);
      } catch (e2) {
        debugPrint('Failed to get comments: $e2');
        return [];
      }
    }
  }

  // Posts: Repost
  Future<void> repostPost(String postId, int currentReposts) async {
    try {
      await client.from('posts').update({'reposts': currentReposts + 1}).eq('id', postId);
      reportPostMetric(postId: postId, shared: true);
    } catch (e) {
      rethrow;
    }
  }

  // Get all friends/users we follow
  Future<List<Map<String, dynamic>>> getAddedFriends() async {
    final myId = currentUser?.id;
    if (myId == null) return [];

    try {
      // Fetch followed users details using foreign key relationship
      final response = await client
          .from('follows')
          .select('followingId, users!follows_followingId_fkey(id, name, photoUrl)')
          .eq('followerId', myId);

      final List<Map<String, dynamic>> friends = [];
      for (final item in (response as List)) {
        final userDetail = item['users'] ?? item['users!follows_followingId_fkey'];
        if (userDetail != null) {
          friends.add(Map<String, dynamic>.from(userDetail));
        }
      }
      return friends;
    } catch (e) {
      debugPrint('Error getting added friends: $e');
      // Fallback: get all users (excluding current user) so the user is never stuck
      try {
        final response = await client.from('users').select('id, name, photoUrl').neq('id', myId).limit(30);
        return List<Map<String, dynamic>>.from(response);
      } catch (_) {
        return [];
      }
    }
  }

  // Local JSON-based mute notification persistence
  Set<String> _mutedChatIds = {};
  bool _mutedChatsLoaded = false;

  Future<void> _loadMutedChats() async {
    if (_mutedChatsLoaded) return;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/muted_chats.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        _mutedChatIds = list.map((e) => e.toString()).toSet();
      }
    } catch (e) {
      debugPrint('Error loading cached muted chats: $e');
    }

    try {
      final token = await getValidAccessToken();
      if (token != null) {
        final uri = Uri.parse('$backendUrl/mute');
        final response = await http.get(
          uri,
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 5));
        
        if (response.statusCode == 200) {
          final List<dynamic> list = jsonDecode(response.body);
          _mutedChatIds = list.map((e) => e.toString()).toSet();
          await _saveMutedChats();
        }
      }
    } catch (e) {
      debugPrint('Error syncing muted chats from backend: $e');
    }
    _mutedChatsLoaded = true;
  }

  Future<void> _saveMutedChats() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/muted_chats.json');
      await file.writeAsString(jsonEncode(_mutedChatIds.toList()));
    } catch (e) {
      debugPrint('Error saving muted chats: $e');
    }
  }

  bool isChatMuted(String chatId) {
    if (!_mutedChatsLoaded) {
      _loadMutedChats();
    }
    return _mutedChatIds.contains(chatId);
  }

  Future<void> toggleMuteChat(String chatId) async {
    await _loadMutedChats();
    final isMuted = _mutedChatIds.contains(chatId);
    if (isMuted) {
      _mutedChatIds.remove(chatId);
    } else {
      _mutedChatIds.add(chatId);
    }
    await _saveMutedChats();

    try {
      final token = await getValidAccessToken();
      if (token != null) {
        final uri = Uri.parse('$backendUrl/mute');
        await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'chatId': chatId,
            'isMuted': !isMuted,
          }),
        ).timeout(const Duration(seconds: 5));
      }
    } catch (e) {
      debugPrint('Error syncing mute toggle to backend: $e');
    }
  }

  // Local JSON-based archive persistence
  Set<String> _archivedChatIds = {};
  bool _archivedChatsLoaded = false;

  Future<void> _loadArchivedChats() async {
    if (_archivedChatsLoaded) return;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/archived_chats.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        _archivedChatIds = list.map((e) => e.toString()).toSet();
      }
    } catch (e) {
      debugPrint('Error loading archived chats: $e');
    }
    _archivedChatsLoaded = true;
  }

  Future<void> _saveArchivedChats() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/archived_chats.json');
      await file.writeAsString(jsonEncode(_archivedChatIds.toList()));
    } catch (e) {
      debugPrint('Error saving archived chats: $e');
    }
  }

  bool isChatArchived(String chatId) {
    if (!_archivedChatsLoaded) {
      _loadArchivedChats();
    }
    return _archivedChatIds.contains(chatId);
  }

  Future<void> toggleArchiveChat(String chatId) async {
    await _loadArchivedChats();
    if (_archivedChatIds.contains(chatId)) {
      _archivedChatIds.remove(chatId);
    } else {
      _archivedChatIds.add(chatId);
    }
    await _saveArchivedChats();
  }

  // Group Management Methods
  Future<void> updateGroupName(String chatId, String name) async {
    await client.from('chats').update({'name': name}).eq('id', chatId);
  }

  Future<void> updateGroupIcon(String chatId, File iconFile) async {
    final iconUrl = await uploadToR2(iconFile);
    await client.from('chats').update({'groupIcon': iconUrl}).eq('id', chatId);
  }

  Future<void> addGroupParticipant(String chatId, String userId) async {
    await client.from('chat_participants').insert({
      'chatId': chatId,
      'userId': userId,
    });
  }

  Future<void> removeGroupParticipant(String chatId, String userId) async {
    await client.from('chat_participants').delete().eq('chatId', chatId).eq('userId', userId);
  }

  // Fetch group metadata JSON from Supabase storage
  Future<Map<String, dynamic>> getGroupMetadata(String chatId) async {
    try {
      final storagePath = 'group_metadata/$chatId.json';
      final Uint8List bytes = await client.storage.from('media').download(storagePath);
      final String jsonString = utf8.decode(bytes);
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('No group metadata found for $chatId, returning default: $e');
      return {
        'description': '',
        'admins': [],
        'restrictions': {
          'editGroupInfo': 'all', // 'all' or 'admins'
          'sendMessages': 'all',  // 'all' or 'admins'
        }
      };
    }
  }

  // Upload/save group metadata JSON to Supabase storage
  Future<void> saveGroupMetadata(String chatId, Map<String, dynamic> metadata) async {
    try {
      final storagePath = 'group_metadata/$chatId.json';
      final jsonString = jsonEncode(metadata);
      final List<int> bytes = utf8.encode(jsonString);
      
      final directory = await getTemporaryDirectory();
      final tempFile = File('${directory.path}/temp_$chatId.json');
      await tempFile.writeAsBytes(bytes);
      
      await client.storage.from('media').upload(
        storagePath,
        tempFile,
        fileOptions: const FileOptions(upsert: true),
      );
      
      try {
        await tempFile.delete();
      } catch (_) {}
    } catch (e) {
      debugPrint('Failed to save group metadata: $e');
      rethrow;
    }
  }

  // Clear chat locally and set clear timestamp (WhatsApp-style)
  Future<void> clearChatLocally(String chatId) async {
    try {
      ChatRoomPage.clearCacheFor(chatId);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/chats/${chatId}_messages.json');
      await file.writeAsString(jsonEncode([]));
      
      final nowStr = DateTime.now().toUtc().toIso8601String();
      await LocalStorageService().cacheJson('clear_timestamp_$chatId', nowStr);

      final myId = currentUser?.id;
      if (myId != null) {
        await client
            .from('chat_participants')
            .update({'joinedAt': nowStr})
            .eq('chatId', chatId)
            .eq('userId', myId);
        debugPrint('Updated joinedAt for chat $chatId on server to $nowStr due to clear chat');
      }
    } catch (e) {
      debugPrint('Failed to clear chat locally: $e');
    }
  }

  // Join group using code or invite link
  Future<void> joinGroup(String inviteLinkOrId) async {
    String chatId = inviteLinkOrId.trim();
    if (chatId.contains('/join/')) {
      chatId = chatId.split('/join/').last;
    }
    chatId = chatId.split('?').first.replaceAll('/', '').trim();

    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    final chat = await client.from('chats').select('isGroup').eq('id', chatId).maybeSingle();
    if (chat == null) {
      throw Exception('Group not found');
    }
    if (chat['isGroup'] != true) {
      throw Exception('This ID does not belong to a group chat');
    }

    await addGroupParticipant(chatId, myId);
  }

  // Get custom stickers for current user from database
  Future<List<String>> getCustomStickers() async {
    final myId = currentUser?.id;
    if (myId == null) return [];

    try {
      final response = await client
          .from('user_stickers')
          .select('stickers(url)')
          .eq('userId', myId);

      final List<String> list = [];
      for (final item in response) {
        final sticker = item['stickers'] as Map<String, dynamic>?;
        if (sticker != null && sticker['url'] != null) {
          list.add(sticker['url'] as String);
        }
      }
      // Cache locally
      await LocalStorageService().cacheJson('custom_stickers_$myId', list);
      return list;
    } catch (e) {
      debugPrint('Error getting custom stickers from server: $e');
      // Offline fallback
      final cached = await LocalStorageService().getCachedJson('custom_stickers_$myId');
      if (cached != null && cached is List) {
        return cached.cast<String>();
      }
      return [];
    }
  }

  // Upload/Add custom sticker with SHA-256 deduplication
  Future<String> addCustomSticker(File file) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    // 1. Calculate SHA-256 hash of the file
    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes).toString();

    // 2. Check if sticker with this hash already exists on the server
    final existing = await client.from('stickers').select().eq('sha256', hash).maybeSingle();
    String url;
    String stickerId;

    if (existing != null) {
      url = existing['url'] as String;
      stickerId = existing['id'] as String;
      debugPrint('Sticker already exists on server, reusing url: $url');
    } else {
      // 3. Upload to R2 (with Supabase fallback)
      url = await uploadToR2(file);
      // Insert into stickers table
      final newSticker = await client.from('stickers').insert({
        'sha256': hash,
        'url': url,
      }).select('id').single();
      stickerId = newSticker['id'] as String;
      debugPrint('Sticker uploaded and saved as new entry: $url');
    }

    // 4. Associate user with this sticker in user_stickers junction table
    final association = await client
        .from('user_stickers')
        .select()
        .eq('userId', myId)
        .eq('stickerId', stickerId)
        .maybeSingle();

    if (association == null) {
      await client.from('user_stickers').insert({
        'userId': myId,
        'stickerId': stickerId,
      });
      debugPrint('Associated user $myId with sticker $stickerId');
    }

    // Sync local cache
    await getCustomStickers();

    return url;
  }

  // Delete sticker association, and delete file if no references remain
  Future<void> removeCustomSticker(String url) async {
    final myId = currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Find sticker ID
      final sticker = await client.from('stickers').select().eq('url', url).maybeSingle();
      if (sticker == null) return;

      final stickerId = sticker['id'] as String;

      // 2. Remove user association
      await client.from('user_stickers').delete().eq('userId', myId).eq('stickerId', stickerId);
      debugPrint('Removed association for user $myId and sticker $stickerId');

      // 3. Check if any other users reference this sticker
      final refs = await client.from('user_stickers').select('userId').eq('stickerId', stickerId);
      if (refs.isEmpty) {
        // No more references, delete sticker from DB
        await client.from('stickers').delete().eq('id', stickerId);
        debugPrint('Sticker $stickerId has 0 references, deleting from DB');

        // Delete physical file from storage if it is in Supabase storage
        if (url.contains('storage/v1/object/public/media/')) {
          final parts = url.split('storage/v1/object/public/media/');
          if (parts.length > 1) {
            final storagePath = parts[1];
            try {
              await client.storage.from('media').remove([storagePath]);
              debugPrint('Deleted sticker file from Supabase storage: $storagePath');
            } catch (_) {}
          }
        }
      }

      // Sync local cache
      await getCustomStickers();
    } catch (e) {
      debugPrint('Error removing custom sticker: $e');
    }
  }
}

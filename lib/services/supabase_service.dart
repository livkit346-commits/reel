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

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;

  SupabaseService._internal();

  final SupabaseClient client = Supabase.instance.client;

  // Track active chat room ID to avoid race conditions with background listeners
  String? activeChatId;

  // In-session liked posts cache to persist hearts across scroll/navigation
  final Set<String> _likedPostIds = {};
  Set<String> get likedPostIds => _likedPostIds;

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
      final exp = claims['exp'] as int? ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600);
      final timeNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expiresIn = exp - timeNow;

      final sessionMap = {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': expiresIn,
        'expires_at': exp,
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
      _loadMutedChats();
      _loadArchivedChats();
      return res;
    } catch (e) {
      debugPrint('Error in _setSessionOffline: $e');
      rethrow;
    }
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
          return newAccessToken;
        }
      }
      
      // If refresh fails (e.g. token compromised or expired refresh token), clear local tokens
      await LocalStorageService().cacheJson('auth_tokens', null);
      await client.auth.signOut();
      return null;
    } catch (e) {
      debugPrint('Error refreshing tokens: $e');
      return null;
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
          if (!_isTokenExpired(accessToken)) {
            await _setSessionOffline(accessToken, refreshToken);
            debugPrint('Successfully restored user session from cached custom JWT.');
          } else {
            // Try to refresh
            await _refreshTokens(refreshToken);
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to initialize session: $e');
    }
  }

  // Auth: Sign Up with Email via Go backend and auto-login
  Future<AuthResponse> signUpWithEmail(String email, String password) async {
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
      _mutedChatIds.clear();
      _mutedChatsLoaded = false;
      _archivedChatIds.clear();
      _archivedChatsLoaded = false;
      await LocalStorageService().cacheJson('auth_tokens', null);
      await client.auth.signOut();
      try {
        await fb.FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
  }

  // Auth: Get Current User
  User? get currentUser => client.auth.currentUser;

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

  // Upload any file directly to Cloudflare R2 via our Supabase Edge Function
  Future<String> uploadToR2(File file) async {
    try {
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

      // 1. Invoke Supabase Edge Function to get presigned URL
      final response = await client.functions.invoke(
        'r2-presign',
        body: {
          'filename': filename,
          'contentType': contentType,
        },
      );

      if (response.status != 200) {
        throw Exception('Edge function returned status ${response.status}: ${response.data}');
      }

      final data = response.data;
      if (data == null || data['uploadUrl'] == null) {
        throw Exception('Invalid response from edge function: $data');
      }

      final String uploadUrl = data['uploadUrl'];
      final String publicUrl = data['publicUrl'] ?? '';

      // 2. Perform direct HTTP PUT request to Cloudflare R2
      final fileBytes = await file.readAsBytes();
      final uploadResponse = await http.put(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Type': contentType,
        },
        body: fileBytes,
      );

      if (uploadResponse.statusCode != 200) {
        throw Exception('Cloudflare R2 upload failed with code ${uploadResponse.statusCode}');
      }

      return publicUrl;
    } catch (e) {
      debugPrint('uploadToR2 error: $e');
      rethrow;
    }
  }

  // Profile: Upload avatar image
  Future<String> uploadAvatar(File imageFile) async {
    await getValidAccessToken();
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storagePath = 'avatars/$myId/$fileName';

      // Upload to avatars bucket
      await client.storage.from('media').upload(storagePath, imageFile);
      final photoUrl = getMediaUrl('media', storagePath);

      // Update users table
      await client.from('users').update({'photoUrl': photoUrl}).eq('id', myId);
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
      final fileName = 'cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storagePath = 'covers/$myId/$fileName';

      // Upload to media bucket
      await client.storage.from('media').upload(storagePath, imageFile);
      final coverUrl = getMediaUrl('media', storagePath);

      // Update users table
      await client.from('users').update({'coverUrl': coverUrl}).eq('id', myId);
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
    try {
      final response = await client.from('users').select().eq('id', userId).maybeSingle();
      if (response != null) {
        _profileCache[userId] = response;
      }
      return response;
    } catch (e) {
      return null;
    }
  }

  // Profile: Clear cache (useful when editing own profile)
  void clearProfileCache(String userId) {
    _profileCache.remove(userId);
  }

  // Posts: Create post
  Future<void> createPost(String userId, String userName, String text, String? imageUrl) async {
    try {
      await client.from('posts').insert({
        'userId': userId,
        'userName': userName,
        'text': text,
        'imageUrl': imageUrl,
        'createdAt': DateTime.now().toIso8601String(),
        'likes': 0,
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
      final response = await client.from('posts').select().order('createdAt', ascending: false).limit(25);
      await LocalStorageService().cacheJson('explore_feed', response);
      return response;
    } catch (e) {
      final cached = await LocalStorageService().getCachedJson('explore_feed');
      if (cached != null && cached is List) {
        return cached;
      }
      return [];
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
  }) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      final userProfile = await getUserProfile(myId);
      final userName = userProfile?['name'] ?? 'User';

      String? imageUrl;
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
        debugPrint('Insert fallback 2 (lowercase full) failed: $e2. Trying camelCase intermediate...');
      }

      try {
        // 3. Try camelCase intermediate format (with mediaType but without text/voiceUrl)
        await client.from('statuses').insert({
          'userId': myId,
          'userName': userName,
          'imageUrl': imageUrl,
          'mediaType': mediaType ?? 'image',
          'createdAt': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e3) {
        debugPrint('Insert fallback 3 (camelCase intermediate) failed: $e3. Trying lowercase intermediate...');
      }

      try {
        // 4. Try lowercase intermediate format (with mediatype but without text/voiceurl)
        await client.from('statuses').insert({
          'userid': myId,
          'username': userName,
          'imageurl': imageUrl,
          'mediatype': mediaType ?? 'image',
          'createdat': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e4) {
        debugPrint('Insert fallback 4 (lowercase intermediate) failed: $e4. Trying camelCase basic...');
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
        // 7. Try camelCase minimal format (without mediaType/voiceUrl/text)
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
    final myId = currentUser?.id;
    if (myId == null) return [];

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
            // Fallback if other user is deleted or not found
            chatData['chatName'] = 'Deleted User';
            chatData['chatIcon'] = null;
            chatData['otherUserId'] = '';
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

        if (latestMsg == null && !isGroup) {
          // Skip empty 1-on-1 chats
          continue;
        }

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
          final isReceived = latestMsg['received'] as bool? ?? false;
          chatData['hasUnread'] = !isMe && !isReceived;
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

      return chatsList;
    } catch (e) {
      // Offline fallback: load cached active chats
      try {
        final cached = await LocalStorageService().getCachedJson('active_chats_$myId');
        if (cached != null) {
          return cached as List<dynamic>;
        }
      } catch (_) {}
      return [];
    }
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

        final history = await WebSocketService().fetchHistory(cid, lastMessageId: lastMessageId);
        if (history.isEmpty) continue;

        bool hasChanges = false;
        for (final msg in history) {
          final typedMsg = Map<String, dynamic>.from(msg);
          final msgId = typedMsg['messageId'] ?? typedMsg['id'];

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
              final mType = typedMsg['mediaType'] as String?;
              if (mType != 'image' && mType != 'video' && mType != 'audio') {
                deleteMessageFromServer(msgId, deleteStorage: false);
              }
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

        // Notify the server we received it so it gets deleted from DynamoDB
        if (senderId != myId && WebSocketService().isConnected) {
          WebSocketService().sendStatusUpdate(
            chatId: chatId,
            messageId: messageId,
            recipientId: senderId,
            status: 'received',
          );
        }
      }
    } catch (e) {
      debugPrint('Error saving incoming message: $e');
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
          if (mediaUrl != null && mediaUrl.contains('storage/v1/object/public/media/')) {
            final parts = mediaUrl.split('storage/v1/object/public/media/');
            if (parts.length > 1) {
              final storagePath = parts[1];
              await client.storage.from('media').remove([storagePath]);
              debugPrint('Successfully deleted media from storage: $storagePath');
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
      return response;
    } catch (e) {
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

  // Posts: Delete post
  Future<void> deletePost(String postId) async {
    try {
      await client.from('posts').delete().eq('id', postId);
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
    } catch (e) {
      rethrow;
    }
  }

  // Comments: Add comment
  Future<void> addComment(String postId, String text) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');
    try {
      final profile = await getUserProfile(myId);
      final userName = profile?['name'] ?? 'User';
      await client.from('comments').insert({
        'postId': postId,
        'userId': myId,
        'userName': userName,
        'text': text,
        'createdAt': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }

  // Comments: Get comments for post
  Future<List<dynamic>> getComments(String postId) async {
    try {
      return await client.from('comments').select().eq('postId', postId).order('createdAt', ascending: true);
    } catch (e) {
      return [];
    }
  }

  // Posts: Repost
  Future<void> repostPost(String postId, int currentReposts) async {
    try {
      await client.from('posts').update({'reposts': currentReposts + 1}).eq('id', postId);
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

  // Clear chat locally and set clear timestamp
  Future<void> clearChatLocally(String chatId) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/chats/${chatId}_messages.json');
      await file.writeAsString(jsonEncode([]));
      
      final nowStr = DateTime.now().toUtc().toIso8601String();
      await LocalStorageService().cacheJson('clear_timestamp_$chatId', nowStr);
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
}

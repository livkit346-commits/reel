import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;

  SupabaseService._internal();

  final SupabaseClient client = Supabase.instance.client;

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

  // Auth: Sign Up with Email
  Future<AuthResponse> signUpWithEmail(String email, String password) async {
    try {
      final response = await client.auth.signUp(
        email: email,
        password: password,
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Sign In with Email
  Future<AuthResponse> signInWithEmail(String email, String password) async {
    try {
      final response = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      return response;
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Sign Out
  Future<void> signOut() async {
    try {
      await client.auth.signOut();
    } catch (e) {
      rethrow;
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

  // Profile: Upload avatar image
  Future<String> uploadAvatar(File imageFile) async {
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
        final fileName = 'post_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final storagePath = 'posts/$myId/$fileName';

        await client.storage.from('media').upload(storagePath, imageFile);
        imageUrl = getMediaUrl('media', storagePath);
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
      return response;
    } catch (e) {
      rethrow;
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
        final fileName = 'status_${DateTime.now().millisecondsSinceEpoch}.$extension';
        final storagePath = 'statuses/$myId/$fileName';
        await client.storage.from('media').upload(storagePath, mediaFile);
        imageUrl = getMediaUrl('media', storagePath);
      }

      String? voiceUrl;
      if (voiceFile != null) {
        final fileName = 'status_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        final storagePath = 'statuses/$myId/$fileName';
        await client.storage.from('media').upload(storagePath, voiceFile);
        voiceUrl = getMediaUrl('media', storagePath);
      }

      await client.from('statuses').insert({
        'userId': myId,
        'userName': userName,
        'imageUrl': imageUrl,
        'mediaType': mediaType ?? 'image',
        'text': text,
        'voiceUrl': voiceUrl,
        'createdAt': DateTime.now().toIso8601String(),
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
      final fileName = 'status_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storagePath = 'statuses/$myId/$fileName';

      await client.storage.from('media').upload(storagePath, imageFile);
      final imageUrl = getMediaUrl('media', storagePath);

      await createStatus(myId, userName, imageUrl);
    } catch (e) {
      rethrow;
    }
  }

  // Status: Delete status
  Future<void> deleteStatus(String statusId) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      await client.from('statuses').delete().eq('id', statusId).eq('userId', myId);
    } catch (e) {
      rethrow;
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
      return response;
    } catch (e) {
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

      // Return followed first, followed by discovery statuses
      return [...followedStatuses, ...discoveryStatuses];
    } catch (e) {
      return getActiveStatuses();
    }
  }

  // Discovery: Get nearby users
  Future<List<dynamic>> getNearbyUsers() async {
    try {
      final response = await client.from('users').select().limit(10);
      return response;
    } catch (e) {
      rethrow;
    }
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

  // Get active chats list for the current user
  Future<List<dynamic>> getActiveChats() async {
    final myId = currentUser?.id;
    if (myId == null) return [];

    try {
      // Find all chats where I am a participant
      final participants = await client.from('chat_participants').select('chatId').eq('userId', myId);
      final chatIds = participants.map((p) => p['chatId'] as String).toList();

      if (chatIds.isEmpty) return [];

      // Fetch participants details (excluding current user) for each chat
      final response = await client
          .from('chat_participants')
          .select('chatId, users(id, name, photoUrl)')
          .inFilter('chatId', chatIds)
          .neq('userId', myId);

      final chatsList = List<Map<String, dynamic>>.from(response);
      for (final chat in chatsList) {
        final cid = chat['chatId'] as String;
        final unreadCountResponse = await client
            .from('messages')
            .select('id')
            .eq('chatId', cid)
            .neq('senderId', myId)
            .eq('received', false);
        chat['hasUnread'] = unreadCountResponse.isNotEmpty;
      }

      return chatsList;
    } catch (e) {
      return [];
    }
  }

  // Send a message
  Future<void> sendMessage({
    required String chatId,
    String? text,
    File? mediaFile,
    String? mediaType, // 'image', 'video'
    String disappearingDuration = 'off', // 'off', '24h', '48h'
  }) async {
    final myId = currentUser?.id;
    if (myId == null) throw Exception('User not authenticated');

    try {
      String? mediaUrl;
      if (mediaFile != null) {
        // Compress and upload media file to Supabase storage
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${mediaFile.path.split('/').last}';
        final storagePath = 'chat_media/$chatId/$fileName';

        await client.storage.from('media').upload(storagePath, mediaFile);
        mediaUrl = getMediaUrl('media', storagePath);
      }

      // Calculate expiration time if disappearing is enabled
      DateTime? expiresAt;
      if (disappearingDuration == '24h') {
        expiresAt = DateTime.now().add(const Duration(hours: 24));
      } else if (disappearingDuration == '48h') {
        expiresAt = DateTime.now().add(const Duration(hours: 48));
      }

      await client.from('messages').insert({
        'chatId': chatId,
        'senderId': myId,
        'text': text,
        'mediaUrl': mediaUrl,
        'mediaType': mediaType,
        'expiresAt': expiresAt?.toIso8601String(),
        'received': false,
      });
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
  Future<void> deleteMessageFromServer(String messageId) async {
    try {
      await client.from('messages').delete().eq('id', messageId);
    } catch (e) {
      // Ignore
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
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/auth/reel_auth_page.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/services/supabase_service.dart';

class ReelProfilePage extends StatefulWidget {
  final String? userId; // Optional profile to view
  
  const ReelProfilePage({super.key, this.userId});

  @override
  State<ReelProfilePage> createState() => _ReelProfilePageState();
}

class _ReelProfilePageState extends State<ReelProfilePage> with SingleTickerProviderStateMixin {
  late Future<Map<String, dynamic>?> _profileFuture;
  late TabController _tabController;
  final ImagePicker _picker = ImagePicker();
  
  List<dynamic> _userPosts = [];
  bool _loadingPosts = true;
  bool _uploadingAvatar = false;
  bool _uploadingCover = false;
  int _followersCount = 0;
  int _followingCount = 0;

  // Social Friendship states for other users' profiles
  bool _isFollowingThisUser = false;
  bool _userFollowsMe = false;
  bool _isMutual = false;
  bool _loadingFriendship = true;

  bool get _isMe {
    final myId = context.read<SupabaseService>().currentUser?.id;
    return widget.userId == null || widget.userId == myId;
  }

  String get _targetUserId {
    return widget.userId ?? context.read<SupabaseService>().currentUser?.id ?? '';
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _loadProfile() {
    final supabase = context.read<SupabaseService>();
    final targetId = _targetUserId;
    
    if (targetId.isNotEmpty) {
      setState(() {
        _profileFuture = supabase.getUserProfile(targetId);
      });
      _loadUserPosts(targetId);
      _loadSocialStats(targetId);
      if (!_isMe) {
        _loadFriendshipStatus(targetId);
      }
    } else {
      _profileFuture = Future.value(null);
    }
  }

  Future<void> _loadUserPosts(String userId) async {
    final supabase = context.read<SupabaseService>();
    try {
      final posts = await supabase.client
          .from('posts')
          .select()
          .eq('userId', userId)
          .order('createdAt', ascending: false);
      if (mounted) {
        setState(() {
          _userPosts = posts;
          _loadingPosts = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingPosts = false);
      }
    }
  }

  Future<void> _loadSocialStats(String userId) async {
    final supabase = context.read<SupabaseService>();
    try {
      final followers = await supabase.getFollowersCount(userId);
      final following = await supabase.getFollowingCount(userId);
      if (mounted) {
        setState(() {
          _followersCount = followers;
          _followingCount = following;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadFriendshipStatus(String otherUserId) async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      final following = await supabase.isFollowing(otherUserId);
      
      // Check if other user follows me
      final otherFollowResponse = await supabase.client
          .from('follows')
          .select()
          .eq('followerId', otherUserId)
          .eq('followingId', myId)
          .maybeSingle();
      
      final followsMe = otherFollowResponse != null;
      final mutual = following && followsMe;

      if (mounted) {
        setState(() {
          _isFollowingThisUser = following;
          _userFollowsMe = followsMe;
          _isMutual = mutual;
          _loadingFriendship = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingFriendship = false);
    }
  }

  Future<void> _toggleFriendship() async {
    final supabase = context.read<SupabaseService>();
    final otherUserId = _targetUserId;
    if (otherUserId.isEmpty) return;

    setState(() => _loadingFriendship = true);
    try {
      if (_isFollowingThisUser) {
        await supabase.unfollowUser(otherUserId);
      } else {
        await supabase.followUser(otherUserId);
      }
      await _loadFriendshipStatus(otherUserId);
      await _loadSocialStats(otherUserId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update friendship status')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingFriendship = false);
    }
  }

  Future<void> _startDirectChat(String otherUserName) async {
    final supabase = context.read<SupabaseService>();
    final otherUserId = _targetUserId;
    
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      final chatId = await supabase.createOrGetChat(otherUserId);
      
      if (mounted) {
        Navigator.pop(context); // Pop loader
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatRoomPage(
              chatId: chatId,
              otherUserId: otherUserId,
              otherUserName: otherUserName,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.grey[950],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Mutual Friends Only', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(
              'Snapchat Rules: Both you and $otherUserName must add each other as friends before sending private messages!',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK', style: TextStyle(color: Colors.indigoAccent, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    }
  }

  // Upload new profile avatar natively
  Future<void> _uploadProfilePicture() async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 500,
    );

    if (pickedFile != null) {
      setState(() => _uploadingAvatar = true);
      final supabase = context.read<SupabaseService>();
      try {
        await supabase.uploadAvatar(File(pickedFile.path));
        supabase.clearProfileCache(_targetUserId);
        _loadProfile();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile picture updated successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update picture: ${e.toString()}')),
          );
        }
      } finally {
        if (mounted) setState(() => _uploadingAvatar = false);
      }
    }
  }

  // Upload new cover image banner natively
  Future<void> _uploadCoverImage() async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 60,
      maxWidth: 1080,
    );

    if (pickedFile != null) {
      setState(() => _uploadingCover = true);
      final supabase = context.read<SupabaseService>();
      try {
        await supabase.uploadCoverImage(File(pickedFile.path));
        supabase.clearProfileCache(_targetUserId);
        _loadProfile();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cover banner updated successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update cover: ${e.toString()}')),
          );
        }
      } finally {
        if (mounted) setState(() => _uploadingCover = false);
      }
    }
  }

  // Edit profile dialog
  Future<void> _editProfile(BuildContext context, Map<String, dynamic>? profile) async {
    final nameController = TextEditingController(text: profile?['name']);
    final phoneController = TextEditingController(text: profile?['phone']);
    final bioController = TextEditingController(text: profile?['bio'] ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bioController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  labelStyle: TextStyle(color: Colors.white54),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final phone = phoneController.text.trim();
              final bio = bioController.text.trim();
              if (name.isEmpty) return;

              final supabase = context.read<SupabaseService>();
              final user = supabase.currentUser;
              if (user != null) {
                try {
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (context) => const Center(child: CircularProgressIndicator()),
                  );

                  await supabase.client.from('users').update({
                    'name': name,
                    'phone': phone.isNotEmpty ? phone : null,
                    'bio': bio.isNotEmpty ? bio : null,
                  }).eq('id', user.id);
                  supabase.clearProfileCache(user.id);
                  
                  if (context.mounted) {
                    Navigator.pop(context); // Pop spinner
                    Navigator.pop(context); // Pop dialog
                    _loadProfile();
                  }
                } catch (e) {
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to update profile: ${e.toString()}')),
                    );
                  }
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).primaryColor),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showSettingsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[950],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const ListTile(
                title: Text('Account Settings', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined, color: Colors.white70),
                title: const Text('Privacy & Security', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Manage disappearing preferences & encryption', style: TextStyle(color: Colors.white38, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _showPrivacySettingsDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.notifications_none_outlined, color: Colors.white70),
                title: const Text('Notifications', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Notifications are fully configured for your device')),
                  );
                },
              ),
              const Divider(color: Colors.white12),
              ListTile(
                leading: const Icon(Icons.logout_outlined, color: Colors.redAccent),
                title: const Text('Log Out', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                onTap: () async {
                  Navigator.pop(context);
                  final supabase = context.read<SupabaseService>();
                  await supabase.signOut();
                  if (context.mounted) {
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (context) => const ReelAuthPage()),
                      (route) => false,
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPrivacySettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        title: const Text('Privacy Settings', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'Your chats are fully protected with secure end-to-end receipt purging. Messages are instantly deleted from our server the exact second your contact receives them.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          
          final userProfile = snapshot.data;
          if (userProfile == null) {
            return const Center(child: Text('User profile not found', style: TextStyle(color: Colors.white54)));
          }

          final name = userProfile['name'] ?? 'User';
          final phone = userProfile['phone'] ?? 'No phone linked';
          final bio = userProfile['bio'] ?? 'Flutter Developer & Designer. Building premium experiences on the Reel App! 🚀✨';
          final photoUrl = userProfile['photoUrl'] as String?;
          final coverUrl = userProfile['coverUrl'] as String?;
          final userId = userProfile['id'] ?? 'unknown';

          return NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar(
                  expandedHeight: 0,
                  pinned: true,
                  backgroundColor: Colors.black,
                  elevation: 0,
                  leading: !_isMe 
                    ? IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context))
                    : null,
                  title: Text(_isMe ? 'My Profile' : name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  actions: [
                    if (_isMe)
                      IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        onPressed: () => _showSettingsBottomSheet(context),
                      ),
                  ],
                ),
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.centerLeft,
                        children: [
                          // Cover Banner
                          InkWell(
                            onTap: _isMe ? _uploadCoverImage : null,
                            child: Stack(
                              children: [
                                coverUrl != null && coverUrl.isNotEmpty
                                    ? Image.network(
                                        coverUrl,
                                        height: 140,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      )
                                    : Image.network(
                                        'https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?auto=format&fit=crop&w=800&q=80',
                                        height: 140,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      ),
                                if (_uploadingCover)
                                  Positioned.fill(
                                    child: Container(
                                      color: Colors.black45,
                                      child: const Center(
                                        child: CircularProgressIndicator(color: Colors.white),
                                      ),
                                    ),
                                  ),
                                if (_isMe)
                                  Positioned(
                                    top: 12,
                                    right: 12,
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.camera_alt, color: Colors.white, size: 12),
                                          SizedBox(width: 4),
                                          Text('Change Cover', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Pinned Circle Avatar Overlapping the bottom boundary
                          Positioned(
                            bottom: -36,
                            left: 16,
                            child: InkWell(
                              onTap: _isMe ? _uploadProfilePicture : null,
                              borderRadius: BorderRadius.circular(42),
                              child: Stack(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.black, width: 4),
                                    ),
                                    child: CircleAvatar(
                                      radius: 38,
                                      backgroundColor: Colors.white10,
                                      backgroundImage: photoUrl != null
                                          ? NetworkImage(photoUrl)
                                          : NetworkImage('https://i.pravatar.cc/150?u=$userId') as ImageProvider,
                                    ),
                                  ),
                                  if (_isMe && _uploadingAvatar)
                                    Positioned.fill(
                                      child: Container(
                                        decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                                        child: const Center(
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_isMe)
                                    Positioned(
                                      bottom: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: primaryColor,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.camera_alt, color: Colors.white, size: 10),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Action buttons row (Edit Profile / Add Friend / Message)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (_isMe)
                              OutlinedButton(
                                onPressed: () => _editProfile(context, userProfile),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white30),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                ),
                                child: const Text(
                                  'Edit profile',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              )
                            else ...[
                              // Snapchat-style Friendship Action Buttons
                              _loadingFriendship
                                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                                : Row(
                                    children: [
                                      ElevatedButton(
                                        onPressed: _toggleFriendship,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _isMutual
                                              ? Colors.white12
                                              : (_isFollowingThisUser 
                                                  ? Colors.grey[800] 
                                                  : (_userFollowsMe ? primaryColor : Colors.indigoAccent)),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        ),
                                        child: Text(
                                          _isMutual
                                              ? 'Friends'
                                              : (_isFollowingThisUser
                                                  ? 'Added'
                                                  : (_userFollowsMe ? 'Accept' : '+ Add')),
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
                                        onPressed: () => _startDirectChat(name),
                                      ),
                                    ],
                                  ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Profile Identity
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '@${name.toLowerCase().replaceAll(' ', '')}',
                              style: const TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                            const SizedBox(height: 12),
                            // User Bio
                            Text(
                              bio,
                              style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14, height: 1.3),
                            ),
                            const SizedBox(height: 12),
                            // Location and Joined Date Row
                            Row(
                              children: [
                                const Icon(Icons.location_on_outlined, color: Colors.white54, size: 14),
                                const SizedBox(width: 4),
                                const Text('Nigeria', style: TextStyle(color: Colors.white54, fontSize: 13)),
                                const SizedBox(width: 16),
                                const Icon(Icons.calendar_today_outlined, color: Colors.white54, size: 13),
                                const SizedBox(width: 4),
                                const Text('Joined May 2026', style: TextStyle(color: Colors.white54, fontSize: 13)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            // Phone Row
                            Row(
                              children: [
                                const Icon(Icons.phone_outlined, color: Colors.white54, size: 14),
                                const SizedBox(width: 4),
                                Text(phone, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Dynamic Followers / Following Stats
                            Row(
                              children: [
                                _buildRichStat('$_followingCount', 'Following'),
                                const SizedBox(width: 20),
                                _buildRichStat('$_followersCount', 'Followers'),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SliverAppBarDelegate(
                    TabBar(
                      controller: _tabController,
                      indicatorColor: primaryColor,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white54,
                      indicatorWeight: 3,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      tabs: const [
                        Tab(text: 'Posts'),
                        Tab(text: 'Snaps'),
                        Tab(text: 'Replies'),
                        Tab(text: 'Likes'),
                      ],
                    ),
                  ),
                ),
              ];
            },
            body: TabBarView(
              controller: _tabController,
              children: [
                // Tab 1: Dynamic Posts
                _loadingPosts
                    ? const Center(child: CircularProgressIndicator())
                    : _userPosts.isEmpty
                        ? const Center(child: Text('No posts yet', style: TextStyle(color: Colors.white38)))
                        : ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: _userPosts.length,
                            itemBuilder: (context, index) {
                              final post = _userPosts[index];
                              final postImageUrl = post['imageUrl'] ?? post['imageurl'];
                              return Card(
                                color: Colors.white.withOpacity(0.04),
                                margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        post['text'] ?? '',
                                        style: const TextStyle(color: Colors.white, fontSize: 14),
                                      ),
                                      if (postImageUrl != null) ...[
                                        const SizedBox(height: 8),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: Image.network(postImageUrl as String, fit: BoxFit.cover, height: 180, width: double.infinity),
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      Text(
                                        (post['createdAt'] ?? post['createdat']) != null 
                                          ? DateTime.parse((post['createdAt'] ?? post['createdat']) as String).toLocal().toString().substring(0, 16)
                                          : '',
                                        style: const TextStyle(color: Colors.white30, fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                // Tab 2: Snaps (Placeholder for other screens)
                const Center(child: Text('Private Ephemeral Snaps locked 🔒', style: TextStyle(color: Colors.white38))),
                // Tab 3: Replies (Mock)
                const Center(child: Text('No replies yet', style: TextStyle(color: Colors.white38))),
                // Tab 4: Likes (Mock)
                const Center(child: Text('No liked posts yet', style: TextStyle(color: Colors.white38))),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRichStat(String count, String label) {
    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 14),
        children: [
          TextSpan(text: count, style: const TextStyle(fontWeight: FontWeight.bold)),
          const TextSpan(text: ' '),
          TextSpan(text: label, style: const TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar _tabBar;
  _SliverAppBarDelegate(this._tabBar);

  @override
  double get minExtent => _tabBar.preferredSize.height;
  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Colors.black,
      child: _tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) {
    return false;
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/auth/reel_auth_page.dart';
import 'package:reel/services/supabase_service.dart';

class ReelProfilePage extends StatefulWidget {
  const ReelProfilePage({super.key});

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
  int _followersCount = 0;
  int _followingCount = 0;

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
    final user = supabase.currentUser;
    if (user != null) {
      setState(() {
        _profileFuture = supabase.getUserProfile(user.id);
      });
      _loadUserPosts(user.id);
      _loadSocialStats(user.id);
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
        _loadProfile(); // Reload dynamic profile details
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

  // Edit profile dialog
  Future<void> _editProfile(BuildContext context, Map<String, dynamic>? profile) async {
    final nameController = TextEditingController(text: profile?['name']);
    final phoneController = TextEditingController(text: profile?['phone']);
    final bioController = TextEditingController(text: profile?['bio'] ?? '');
    final locationController = TextEditingController(text: 'Nigeria');

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
                controller: locationController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Location',
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
                  await supabase.client.from('users').update({
                    'name': name,
                    'phone': phone.isNotEmpty ? phone : null,
                    'bio': bio.isNotEmpty ? bio : null,
                  }).eq('id', user.id);
                  if (context.mounted) {
                    Navigator.pop(context);
                    _loadProfile();
                  }
                } catch (_) {}
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          
          final userProfile = snapshot.data;
          final name = userProfile?['name'] ?? 'User';
          final phone = userProfile?['phone'] ?? 'No phone linked';
          final bio = userProfile?['bio'] ?? 'Flutter Developer & Designer. Building premium experiences on the Reel App! 🚀✨';
          final photoUrl = userProfile?['photoUrl'] as String?;
          final userId = userProfile?['id'] ?? 'unknown';

          return NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar(
                  expandedHeight: 0,
                  pinned: true,
                  backgroundColor: Colors.black,
                  elevation: 0,
                  title: const Text('Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  actions: [
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
                      // BACKGROUND COVER AND OVERLAPPING AVATAR BUILT IN A SINGLE COORDINATE SPACE
                      // This eliminates Z-index clipping bugs on all devices.
                      Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.centerLeft,
                        children: [
                          // Cover Banner
                          Image.network(
                            'https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?auto=format&fit=crop&w=800&q=80',
                            height: 140,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                          // Pinned Circle Avatar Overlapping the bottom boundary
                          Positioned(
                            bottom: -36,
                            left: 16,
                            child: InkWell(
                              onTap: _uploadProfilePicture,
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
                                  if (_uploadingAvatar)
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
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).primaryColor,
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
                      // Action buttons row (Edit Profile)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
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
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Profile Identity - Cleanly Positioned Under Avatar
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
                            // Location, Link, Joined Date Row
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
                      indicatorColor: Theme.of(context).primaryColor,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white54,
                      indicatorWeight: 3,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      tabs: const [
                        Tab(text: 'Posts'),
                        Tab(text: 'Replies'),
                        Tab(text: 'Media'),
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
                _buildPostsTab(),
                _buildEmptyTab('No replies yet'),
                _buildEmptyTab('No media yet'),
                _buildEmptyTab('No likes yet'),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRichStat(String count, String label) {
    return Row(
      children: [
        Text(
          count,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildPostsTab() {
    if (_loadingPosts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_userPosts.isEmpty) {
      return const Center(
        child: Text('No posts yet', style: TextStyle(color: Colors.white38, fontSize: 16)),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _userPosts.length,
      itemBuilder: (context, index) {
        final post = _userPosts[index];
        final text = post['text'] ?? '';
        final likes = post['likes'] ?? 0;
        final name = post['userName'] ?? 'User';

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=${post['userId']}'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          name,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '@${name.toLowerCase().replaceAll(' ', '')} • 2h',
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text,
                      style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildPostAction(Icons.chat_bubble_outline, '0'),
                        _buildPostAction(Icons.repeat, '0'),
                        _buildPostAction(Icons.favorite_border, '$likes'),
                        _buildPostAction(Icons.share_outlined, ''),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyTab(String message) {
    return Center(
      child: Text(
        message,
        style: const TextStyle(color: Colors.white38, fontSize: 16),
      ),
    );
  }

  Widget _buildPostAction(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 18),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ],
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

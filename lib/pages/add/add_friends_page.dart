import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class AddFriendsPage extends StatefulWidget {
  const AddFriendsPage({super.key});

  @override
  State<AddFriendsPage> createState() => _AddFriendsPageState();
}

class _AddFriendsPageState extends State<AddFriendsPage> {
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  List<dynamic> _addedMeList = []; // People who added me but I haven't added back
  Set<String> _myFollowing = {}; // User IDs that I am following
  bool _searching = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSnapchatSocials();
  }

  Future<void> _loadSnapchatSocials() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Get all followers (people who added me)
      final followersResponse = await supabase.client
          .from('follows')
          .select('followerId, users!follows_followerId_fkey(id, name, photoUrl)')
          .eq('followingId', myId);

      // 2. Get all people I am following
      final followingResponse = await supabase.client
          .from('follows')
          .select('followingId')
          .eq('followerId', myId);

      final followingIds = (followingResponse as List)
          .map((item) => item['followingId'] as String)
          .toSet();

      // Filter "Added Me" list: people who follow me but I DO NOT follow back yet
      final addedMeFiltered = (followersResponse as List).where((item) {
        final followerId = item['followerId'] as String;
        return !followingIds.contains(followerId);
      }).toList();

      if (mounted) {
        setState(() {
          _addedMeList = addedMeFiltered;
          _myFollowing = followingIds;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addFriend(String userId) async {
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.followUser(userId);
      setState(() {
        _myFollowing.add(userId);
      });
      // Refresh to recalculate lists
      _loadSnapchatSocials();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add friend')),
        );
      }
    }
  }

  Future<void> _removeFriend(String userId) async {
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.unfollowUser(userId);
      setState(() {
        _myFollowing.remove(userId);
      });
      _loadSnapchatSocials();
    } catch (_) {}
  }

  Future<void> _startChat(BuildContext context, String otherUserId, String otherUserName) async {
    final supabase = context.read<SupabaseService>();
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      final chatId = await supabase.createOrGetChat(otherUserId);
      
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
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
        Navigator.pop(context); // Pop loading dialog
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

  Future<void> _searchUsers(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    setState(() => _searching = true);
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    
    try {
      final response = await supabase.searchUsers(query);
      final filteredResults = response.where((u) => u['id'] != myId).toList();
      setState(() => _searchResults = filteredResults);
    } catch (e) {
      // Ignore
    } finally {
      setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'Add Friends',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Colors.white),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSnapchatSocials,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // SEARCH BAR (Snapchat style: Rounded, wide, clean)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: TextField(
                        controller: _searchController,
                        onChanged: _searchUsers,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Find Friends',
                          hintStyle: const TextStyle(color: Colors.white38, fontWeight: FontWeight.bold),
                          prefixIcon: const Icon(Icons.search, color: Colors.white54),
                          fillColor: Colors.white.withOpacity(0.08),
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30),
                            borderSide: BorderSide.none,
                          ),
                          suffixIcon: _searching
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // "NEARBY DISCOVERY (50M)" HORIZONTAL LIST
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.location_on, color: Colors.cyanAccent, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'NEARBY DISCOVERY (50M)',
                            style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 125,
                      child: FutureBuilder<List<dynamic>>(
                        future: context.read<SupabaseService>().getNearbyUsers(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(child: CircularProgressIndicator());
                          }

                          final allUsers = snapshot.data!;
                          final myId = context.read<SupabaseService>().currentUser?.id;
                          final nearby = allUsers.where((u) => u['id'] != myId).toList();

                          if (nearby.isEmpty) {
                            return const Center(
                              child: Text('No active users nearby.', style: TextStyle(color: Colors.white38, fontSize: 13)),
                            );
                          }

                          return ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: nearby.length,
                            itemBuilder: (context, index) {
                              final user = nearby[index];
                              final name = user['name'] ?? 'User';
                              final photoUrl = user['photoUrl'] as String?;
                              final isAdded = _myFollowing.contains(user['id']);

                              return Container(
                                width: 110,
                                margin: const EdgeInsets.symmetric(horizontal: 6),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.04),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: Colors.white.withOpacity(0.05), width: 0.8),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    UserAvatar(
                                      userId: user['id'],
                                      radius: 20,
                                      border: Border.all(color: Colors.cyanAccent, width: 1.5),
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => ReelProfilePage(userId: user['id']),
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      height: 22,
                                      child: ElevatedButton(
                                        onPressed: () {
                                          if (isAdded) {
                                            _removeFriend(user['id']);
                                          } else {
                                            _addFriend(user['id']);
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isAdded ? Colors.white12 : Colors.indigoAccent,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                        child: Text(
                                          isAdded ? 'Added' : '+ Add',
                                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),

                    // SEARCH RESULTS SECTION
                    if (_searchResults.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'SEARCH RESULTS',
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                        ),
                      ),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final user = _searchResults[index];
                          final name = user['name'] ?? 'User';
                          final username = '@${name.toLowerCase().replaceAll(' ', '')}';
                          final isAdded = _myFollowing.contains(user['id']);

                          return _buildSnapchatCard(
                            userId: user['id'],
                            name: name,
                            username: username,
                            subtext: 'In search results',
                            isAdded: isAdded,
                            onActionPressed: () {
                              if (isAdded) {
                                _removeFriend(user['id']);
                              } else {
                                _addFriend(user['id']);
                              }
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ],

                    // "ADDED ME" SECTION (Snapchat style: list of people who added you)
                    if (_addedMeList.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'ADDED ME',
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _addedMeList.length,
                          itemBuilder: (context, index) {
                            final item = _addedMeList[index];
                            final user = item['users'];
                            if (user == null) return const SizedBox.shrink();
                            
                            final name = user['name'] ?? 'User';
                            final username = '@${name.toLowerCase().replaceAll(' ', '')}';

                            return _buildSnapchatCard(
                              userId: user['id'],
                              name: name,
                              username: username,
                              subtext: 'Added you back',
                              isAdded: false,
                              isAddedMeText: 'Accept',
                              onActionPressed: () => _addFriend(user['id']),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // "QUICK ADD" SECTION (Snapchat style: nearby discover & suggestions)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        'QUICK ADD',
                        style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                      ),
                    ),
                    FutureBuilder<List<dynamic>>(
                      future: context.read<SupabaseService>().getNearbyUsers(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        final users = snapshot.data!;
                        // Filter out self and people we already followed
                        final myId = context.read<SupabaseService>().currentUser?.id;
                        final quickAddUsers = users.where((u) {
                          return u['id'] != myId && !_myFollowing.contains(u['id']);
                        }).toList();

                        if (quickAddUsers.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
                            child: Text(
                              'No suggestions currently. Find friends using search above!',
                              style: TextStyle(color: Colors.white38, fontSize: 13),
                            ),
                          );
                        }

                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: quickAddUsers.length,
                            itemBuilder: (context, index) {
                              final user = quickAddUsers[index];
                              final name = user['name'] ?? 'Suggested';
                              final username = '@${name.toLowerCase().replaceAll(' ', '')}';

                              return _buildSnapchatCard(
                                userId: user['id'],
                                name: name,
                                username: username,
                                subtext: 'Recently Active Nearby',
                                isAdded: false,
                                onActionPressed: () => _addFriend(user['id']),
                              );
                            },
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  // SNAPCHAT STYLE CARD WIDGET
  Widget _buildSnapchatCard({
    required String userId,
    required String name,
    required String username,
    required String subtext,
    required bool isAdded,
    String? isAddedMeText,
    required VoidCallback onActionPressed,
  }) {
    final primaryColor = Theme.of(context).primaryColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Row(
        children: [
          // Circular Avatar (Clean, bordered) - Tapping opens their profile!
          UserAvatar(
            userId: userId,
            radius: 24,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ReelProfilePage(userId: userId),
                ),
              );
            },
          ),
          const SizedBox(width: 14),
          // User Metadata (Snapchat typography: Bold Name, subtext Username & Mutuals)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ReelProfilePage(userId: userId),
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        username,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 3,
                        height: 3,
                        decoration: const BoxDecoration(color: Colors.white38, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          subtext,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Action Buttons: Pill-shaped purple/primary button or checkmark
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 20),
                onPressed: () => _startChat(context, userId, name),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: onActionPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isAdded
                      ? Colors.white12
                      : (isAddedMeText != null ? primaryColor : Colors.indigoAccent),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: Text(
                  isAdded
                      ? 'Added'
                      : (isAddedMeText ?? '+ Add'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

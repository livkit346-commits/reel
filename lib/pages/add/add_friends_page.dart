import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/services/supabase_service.dart';

class AddFriendsPage extends StatefulWidget {
  const AddFriendsPage({super.key});

  @override
  State<AddFriendsPage> createState() => _AddFriendsPageState();
}

class _AddFriendsPageState extends State<AddFriendsPage> {
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  List<dynamic> _incomingFollows = []; // Real followers who follow the current user
  Set<String> _myFollowing = {}; // User IDs that the current user is following
  bool _searching = false;
  bool _loadingFollowers = true;

  @override
  void initState() {
    super.initState();
    _loadAllSocials();
  }

  void _loadAllSocials() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Get all followers (people who follow me)
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

      if (mounted) {
        setState(() {
          _incomingFollows = followersResponse;
          _myFollowing = followingIds;
          _loadingFollowers = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingFollowers = false);
    }
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
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to initiate chat')),
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
    
    try {
      final response = await supabase.searchUsers(query);
      setState(() => _searchResults = response);
    } catch (e) {
      // Handle error
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _toggleFollow(String userId) async {
    final supabase = context.read<SupabaseService>();
    final isFollowing = _myFollowing.contains(userId);

    try {
      if (isFollowing) {
        await supabase.unfollowUser(userId);
        setState(() {
          _myFollowing.remove(userId);
        });
      } else {
        await supabase.followUser(userId);
        setState(() {
          _myFollowing.add(userId);
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update friendship status')),
        );
      }
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
        title: const Text('Add Friends', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Nearby Section
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(Icons.location_on, color: primaryColor, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Nearby Discovery (50m)',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            Container(
              height: 120,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: primaryColor.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: primaryColor.withOpacity(0.2)),
              ),
              child: FutureBuilder<List<dynamic>>(
                future: context.read<SupabaseService>().getNearbyUsers(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final users = snapshot.data!;
                  return ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final user = users[index];
                      final name = user['name'] ?? 'Nearby';
                      return InkWell(
                        onTap: () => _startChat(context, user['id'], name),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: Column(
                            children: [
                              CircleAvatar(
                                radius: 30,
                                backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=${user['id']}'),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                name.split(' ')[0],
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
            // Contact Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                onChanged: _searchUsers,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search by name...',
                  prefixIcon: const Icon(Icons.search, color: Colors.white38),
                  fillColor: Colors.white.withOpacity(0.05),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                  suffixIcon: _searching 
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
                ),
              ),
            ),
            if (_searchResults.isNotEmpty) ...[
              const SizedBox(height: 16),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final user = _searchResults[index];
                  final name = user['name'] ?? 'User';
                  final isFollowing = _myFollowing.contains(user['id']);

                  return ListTile(
                    leading: CircleAvatar(
                      radius: 24,
                      backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=${user['id']}'),
                    ),
                    title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    onTap: () => _startChat(context, user['id'], name),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
                          onPressed: () => _startChat(context, user['id'], name),
                        ),
                        ElevatedButton(
                          onPressed: () => _toggleFollow(user['id']),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isFollowing ? Colors.white10 : primaryColor,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          child: Text(isFollowing ? 'Following' : 'Add', style: const TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 32),
            // Real Incoming Follow Requests Section (People who followed the current user)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Follow Requests / Followers',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            _loadingFollowers
                ? const Center(child: CircularProgressIndicator())
                : _incomingFollows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'No incoming follow requests yet.',
                          style: TextStyle(color: Colors.white38, fontSize: 14),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _incomingFollows.length,
                        itemBuilder: (context, index) {
                          final item = _incomingFollows[index];
                          final user = item['users'];
                          if (user == null) return const SizedBox.shrink();
                          
                          final name = user['name'] ?? 'User';
                          final isFollowing = _myFollowing.contains(user['id']);

                          return ListTile(
                            leading: CircleAvatar(
                              radius: 24,
                              backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=${user['id']}'),
                            ),
                            title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: const Text('Follows you', style: TextStyle(color: Colors.white54, fontSize: 12)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ElevatedButton(
                                  onPressed: () => _toggleFollow(user['id']),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isFollowing ? Colors.white10 : primaryColor,
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  ),
                                  child: Text(isFollowing ? 'Mutual Follow' : 'Follow Back', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

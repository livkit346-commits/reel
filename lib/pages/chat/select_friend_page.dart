import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/chat/create_group_page.dart';
import 'package:reel/pages/add/add_friends_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class SelectFriendPage extends StatefulWidget {
  const SelectFriendPage({super.key});

  @override
  State<SelectFriendPage> createState() => _SelectFriendPageState();
}

class _SelectFriendPageState extends State<SelectFriendPage> {
  List<Map<String, dynamic>> _friends = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchFriends();
  }

  Future<void> _fetchFriends() async {
    final supabase = context.read<SupabaseService>();
    try {
      final friendsList = await supabase.getAddedFriends();
      if (mounted) {
        setState(() {
          _friends = friendsList;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showGroupComingSoonDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.group_add, color: Colors.cyanAccent),
            SizedBox(width: 8),
            Text(
              'Create Group',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: const Text(
          'Group messaging is currently in development and will be available in a future update!',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'OK',
              style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startChat(String otherUserId, String otherUserName) async {
    final supabase = context.read<SupabaseService>();
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
      );

      final chatId = await supabase.createOrGetChat(otherUserId);
      
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        Navigator.pushReplacement(
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
              'Reel Rule: Both you and $otherUserName must add each other as friends before sending private messages!',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Contact',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 2),
            Text(
              _loading ? 'Loading...' : '${_friends.length} friends',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // Option: Create Group
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.cyanAccent.withOpacity(0.1),
                    child: const Icon(Icons.group, color: Colors.cyanAccent),
                  ),
                  title: const Text(
                    'New Group',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const CreateGroupPage()),
                    );
                  },
                ),
                // Option: Add Friends (New Contact)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.indigoAccent.withOpacity(0.1),
                    child: const Icon(Icons.person_add, color: Colors.indigoAccent),
                  ),
                  title: const Text(
                    'Add Friends (New Contact)',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const AddFriendsPage()),
                    );
                  },
                ),
                const Divider(color: Colors.white10, height: 24, thickness: 1),
                
                // Friends List
                if (_friends.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                    child: Center(
                      child: Text(
                        'No friends added yet. Tap "Add Friends" to find active users!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 14),
                      ),
                    ),
                  )
                else
                  ..._friends.map((friend) {
                    final String name = friend['name'] ?? 'User';
                    final String friendId = friend['id'] ?? '';

                    return ListTile(
                      leading: UserAvatar(userId: friendId, radius: 22),
                      title: Text(
                        name,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                      ),
                      onTap: () => _startChat(friendId, name),
                    );
                  }),
              ],
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  late Future<List<dynamic>> _chatsFuture;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  void _loadChats() {
    final supabase = context.read<SupabaseService>();
    setState(() {
      _chatsFuture = supabase.getActiveChats();
    });
  }

  Future<void> _startChat(String otherUserId, String otherUserName) async {
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
        ).then((_) => _loadChats());
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Reel Secure Chat',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: const [],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _chatsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final activeChats = snapshot.data ?? [];

          if (activeChats.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.white24),
                  SizedBox(height: 16),
                  Text(
                    'No active chats yet.',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Use the Add Friends tab to find and message users!',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _loadChats(),
            child: ListView.builder(
              itemCount: activeChats.length,
              itemBuilder: (context, index) {
                final chatMap = activeChats[index] as Map<String, dynamic>;
                final chatId = chatMap['chatId'] as String;
                final userProfile = chatMap['users'] as Map<String, dynamic>;
                
                final otherUserId = userProfile['id'] as String;
                final otherUserName = userProfile['name'] as String? ?? 'User';
                final otherPhoto = userProfile['photoUrl'] as String?;

                final hasUnread = chatMap['hasUnread'] as bool? ?? false;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: UserAvatar(
                    userId: otherUserId,
                    radius: 26,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ReelProfilePage(userId: otherUserId),
                        ),
                      );
                    },
                  ),
                  title: Text(
                    otherUserName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  subtitle: Text(
                    hasUnread ? 'New secure message received!' : 'Tap to view encrypted ephemeral messages',
                    style: TextStyle(
                      color: hasUnread ? const Color(0xFF00BFFF) : Colors.white38,
                      fontSize: 13,
                      fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasUnread)
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Color(0xFF00BFFF),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0xFF00BFFF),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(width: 8),
                      const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white24),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ChatRoomPage(
                          chatId: chatId,
                          otherUserId: otherUserId,
                          otherUserName: otherUserName,
                        ),
                      ),
                    ).then((_) => _loadChats());
                  },
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Go to search / discovery list
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Search and tap a profile to start a new chat!')),
          );
        },
        backgroundColor: Theme.of(context).primaryColor,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}

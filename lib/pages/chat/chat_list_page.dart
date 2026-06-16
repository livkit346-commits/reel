import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/chat/select_friend_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/add/add_friends_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/services/websocket_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  List<dynamic> _chats = [];
  bool _loading = true;
  final Set<String> _selectedChats = {};
  StreamSubscription? _wsSubscription;
  StreamSubscription? _connSubscription;

  void _toggleSelection(String chatId) {
    setState(() {
      if (_selectedChats.contains(chatId)) {
        _selectedChats.remove(chatId);
      } else {
        _selectedChats.add(chatId);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WebSocketService().connect();
    _initChats();
    
    // Listen to real-time incoming messages
    _wsSubscription = WebSocketService().messageStream.listen((event) async {
      if (event['type'] == 'message') {
        final supabase = context.read<SupabaseService>();
        await supabase.saveIncomingMessage(event);
        if (mounted) {
          _loadChats();
        }
      }
    });

    // Automatically sync offline messages when WebSocket successfully connects/reconnects
    _connSubscription = WebSocketService().connectionStateStream.listen((connected) {
      if (connected) {
        final supabase = context.read<SupabaseService>();
        supabase.syncOfflineMessages().then((_) {
          if (mounted) {
            _loadChats();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    _connSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initChats() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId != null) {
      try {
        final cached = await LocalStorageService().getCachedJson('active_chats_$myId');
        if (cached != null && cached is List) {
          setState(() {
            _chats = cached;
            _loading = false;
          });
        }
      } catch (_) {}
    }
    await _loadChats();
  }

  Future<void> _loadChats() async {
    final supabase = context.read<SupabaseService>();
    try {
      final freshChats = await supabase.getActiveChats();
      if (mounted) {
        setState(() {
          _chats = freshChats;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _formatMessageTime(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return '';
    try {
      final dateTime = DateTime.tryParse(timeStr)?.toLocal();
      if (dateTime == null) return '';

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      final dateToCheck = DateTime(dateTime.year, dateTime.month, dateTime.day);

      if (dateToCheck == today) {
        final hour = dateTime.hour.toString().padLeft(2, '0');
        final minute = dateTime.minute.toString().padLeft(2, '0');
        return '$hour:$minute';
      } else if (dateToCheck == yesterday) {
        return 'Yesterday';
      } else {
        return '${dateTime.year}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.day.toString().padLeft(2, '0')}';
      }
    } catch (_) {
      return '';
    }
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
              'Reel Rule: Both you and $otherUserName must add each other as friends before sending private messages!',
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
        backgroundColor: _selectedChats.isNotEmpty ? Theme.of(context).primaryColor.withOpacity(0.2) : Colors.black,
        elevation: 0,
        title: Text(
          _selectedChats.isNotEmpty ? '${_selectedChats.length} Selected' : 'Reel Secure Chat',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: _selectedChats.isNotEmpty
            ? [
                IconButton(
                  icon: const Icon(Icons.push_pin_outlined, color: Colors.white),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chats Pinned')));
                    setState(() => _selectedChats.clear());
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.volume_off_outlined, color: Colors.white),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chats Muted')));
                    setState(() => _selectedChats.clear());
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () async {
                    final supabase = context.read<SupabaseService>();
                    for (final id in _selectedChats) {
                       await supabase.client.from('chat_participants').delete().eq('chatId', id).eq('userId', supabase.currentUser!.id);
                    }
                    setState(() {
                      _selectedChats.clear();
                      _loadChats();
                    });
                  },
                ),
              ]
            : const [],
      ),
      body: _loading && _chats.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async => _loadChats(),
              child: _chats.isEmpty
                  ? Center(
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
                    )
                  : ListView.builder(
                      itemCount: _chats.length,
                      itemBuilder: (context, index) {
                        final chatMap = _chats[index] as Map<String, dynamic>;
                        final chatId = chatMap['chatId'] as String;
                        final isGroup = chatMap['isGroup'] as bool? ?? false;
                        final chatName = chatMap['chatName'] as String? ?? 'Chat';
                        final chatIcon = chatMap['chatIcon'] as String?;
                        final otherUserId = chatMap['otherUserId'] as String? ?? '';

                        final hasUnread = chatMap['hasUnread'] as bool? ?? false;

                        final isSelected = _selectedChats.contains(chatId);

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          selected: isSelected,
                          selectedTileColor: Colors.white.withOpacity(0.1),
                          onLongPress: () => _toggleSelection(chatId),
                          leading: isGroup
                              ? CircleAvatar(
                                  radius: 26,
                                  backgroundColor: Colors.indigo.withOpacity(0.3),
                                  backgroundImage: chatIcon != null && chatIcon.isNotEmpty
                                      ? NetworkImage(chatIcon)
                                      : null,
                                  child: chatIcon != null && chatIcon.isNotEmpty
                                      ? null
                                      : const Icon(Icons.group, color: Colors.indigoAccent),
                                )
                              : UserAvatar(
                                  userId: otherUserId,
                                  radius: 26,
                                  onTap: () {
                                    if (_selectedChats.isNotEmpty) {
                                      _toggleSelection(chatId);
                                      return;
                                    }
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => ReelProfilePage(userId: otherUserId),
                                      ),
                                    );
                                  },
                                ),
                          title: Text(
                            chatName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          subtitle: Text(
                            hasUnread
                                ? 'New secure message received!'
                                : (chatMap['latestMessageText'] != null && chatMap['latestMessageText'].toString().isNotEmpty
                                    ? chatMap['latestMessageText'].toString()
                                    : (chatMap['latestMessageType'] == 'image'
                                        ? '📷 Photo'
                                        : (chatMap['latestMessageType'] == 'video'
                                            ? '🎥 Video'
                                            : (chatMap['latestMessageType'] == 'audio'
                                                ? '🎤 Voice Message'
                                                : 'Tap to view encrypted ephemeral messages')))),
                            style: TextStyle(
                              color: hasUnread ? const Color(0xFF00BFFF) : Colors.white38,
                              fontSize: 13,
                              fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (chatMap['latestMessageTime'] != null && chatMap['latestMessageTime'] != '1970-01-01T00:00:00Z') ...[
                                Text(
                                  _formatMessageTime(chatMap['latestMessageTime']?.toString()),
                                  style: const TextStyle(color: Colors.white30, fontSize: 11),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (isSelected)
                                const Icon(Icons.check_circle, color: Color(0xFF00BFFF), size: 20)
                              else if (hasUnread)
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
                            if (_selectedChats.isNotEmpty) {
                              _toggleSelection(chatId);
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ChatRoomPage(
                                  chatId: chatId,
                                  otherUserId: otherUserId,
                                  otherUserName: chatName,
                                  isGroup: isGroup,
                                ),
                              ),
                            ).then((_) => _loadChats());
                          },
                        );
                      },
                    ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const SelectFriendPage()),
          ).then((_) => _loadChats());
        },
        backgroundColor: Theme.of(context).primaryColor,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/chat/group_info_page.dart';
import 'package:reel/widgets/user_avatar.dart';

class ArchivedChatsPage extends StatefulWidget {
  const ArchivedChatsPage({super.key});

  @override
  State<ArchivedChatsPage> createState() => _ArchivedChatsPageState();
}

class _ArchivedChatsPageState extends State<ArchivedChatsPage> {
  List<dynamic> _chats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  Future<void> _loadChats() async {
    final supabase = context.read<SupabaseService>();
    try {
      final freshChats = await supabase.getActiveChats();
      final archived = freshChats.where((chat) => supabase.isChatArchived(chat['chatId'] as String)).toList();
      if (mounted) {
        setState(() {
          _chats = archived;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Archived Chats',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
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
                          Icon(Icons.archive_outlined, size: 64, color: Colors.white24),
                          SizedBox(height: 16),
                          Text(
                            'No archived chats.',
                            style: TextStyle(color: Colors.white54, fontSize: 16),
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
                        final isMuted = context.read<SupabaseService>().isChatMuted(chatId);

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                            (chatMap['latestMessageText'] != null && chatMap['latestMessageText'].toString().isNotEmpty
                                ? chatMap['latestMessageText'].toString()
                                : (chatMap['latestMessageType'] == 'image'
                                    ? '📷 Photo'
                                    : (chatMap['latestMessageType'] == 'video'
                                        ? '🎥 Video'
                                        : (chatMap['latestMessageType'] == 'audio'
                                            ? '🎤 Voice Message'
                                            : (chatMap['latestMessageType'] == 'sticker'
                                                ? '👾 Sticker'
                                                : 'Tap to view encrypted ephemeral messages'))))),
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
                              if ((chatMap['latestMessageText'] != null || chatMap['latestMessageType'] != null) &&
                                  chatMap['latestMessageTime'] != null &&
                                  chatMap['latestMessageTime'] != '1970-01-01T00:00:00Z') ...[
                                Text(
                                  _formatMessageTime(chatMap['latestMessageTime']?.toString()),
                                  style: const TextStyle(color: Colors.white30, fontSize: 11),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (isMuted) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.volume_off, color: Colors.white30, size: 14),
                              ],
                              const SizedBox(width: 4),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, color: Colors.white38, size: 20),
                                color: Colors.grey[950],
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: const BorderSide(color: Colors.white10),
                                ),
                                onSelected: (value) async {
                                  if (value == 'info') {
                                    if (isGroup) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => GroupInfoPage(chatId: chatId),
                                        ),
                                      ).then((_) => _loadChats());
                                    } else {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => ReelProfilePage(userId: otherUserId),
                                        ),
                                      ).then((_) => _loadChats());
                                    }
                                  } else if (value == 'mute') {
                                    await context.read<SupabaseService>().toggleMuteChat(chatId);
                                    _loadChats();
                                  } else if (value == 'unarchive') {
                                    await context.read<SupabaseService>().toggleArchiveChat(chatId);
                                    _loadChats();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Chat unarchived')),
                                    );
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'info',
                                    child: Text(isGroup ? 'Group Info' : 'View Profile', style: const TextStyle(color: Colors.white)),
                                  ),
                                  PopupMenuItem(
                                    value: 'mute',
                                    child: Text(isMuted ? 'Unmute Notifications' : 'Mute Notifications', style: const TextStyle(color: Colors.white)),
                                  ),
                                  const PopupMenuItem(
                                    value: 'unarchive',
                                    child: Text('Unarchive Chat', style: TextStyle(color: Colors.white)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () {
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
    );
  }
}

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/widgets/chat/cached_media_view.dart';

class ChatRoomPage extends StatefulWidget {
  final String chatId;
  final String otherUserId;
  final String otherUserName;

  const ChatRoomPage({
    super.key,
    required this.chatId,
    required this.otherUserId,
    required this.otherUserName,
  });

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  
  String _disappearingDuration = 'off';
  bool _isSending = false;
  bool _isFollowing = false;
  bool _isBlocked = false;

  List<Map<String, dynamic>> _localMessages = [];
  bool _isLoadingLocal = true;

  @override
  void initState() {
    super.initState();
    _loadChatSettings();
    _checkFollowingStatus();
    _loadLocalMessages();
  }

  Future<void> _loadLocalMessages() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/chats/${widget.chatId}_messages.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        setState(() {
          _localMessages = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
          _isLoadingLocal = false;
        });
      } else {
        setState(() {
          _isLoadingLocal = false;
        });
      }
    } catch (_) {
      setState(() {
        _isLoadingLocal = false;
      });
    }
  }

  Future<void> _saveLocalMessages() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final dir = Directory('${directory.path}/chats');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/${widget.chatId}_messages.json');
      await file.writeAsString(jsonEncode(_localMessages));
    } catch (_) {}
  }

  void _mergeMessages(List<Map<String, dynamic>> streamMessages) {
    bool changed = false;
    for (final streamMsg in streamMessages) {
      final msgId = streamMsg['id'];
      final existingIndex = _localMessages.indexWhere((m) => m['id'] == msgId);
      if (existingIndex == -1) {
        _localMessages.add(streamMsg);
        changed = true;
      } else {
        // Update values if changed (e.g. received status)
        final existing = _localMessages[existingIndex];
        if (existing['received'] != streamMsg['received'] ||
            existing['mediaUrl'] != streamMsg['mediaUrl'] ||
            existing['text'] != streamMsg['text']) {
          _localMessages[existingIndex] = streamMsg;
          changed = true;
        }
      }
    }

    if (changed) {
      _localMessages.sort((a, b) {
        final aTime = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
        final bTime = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
        return aTime.compareTo(bTime);
      });
      _saveLocalMessages();
    }
  }

  Future<void> _loadChatSettings() async {
    final supabase = context.read<SupabaseService>();
    try {
      final chat = await supabase.client.from('chats').select('disappearingDuration').eq('id', widget.chatId).single();
      setState(() {
        _disappearingDuration = chat['disappearingDuration'] as String? ?? 'off';
      });
    } catch (_) {}
  }

  Future<void> _checkFollowingStatus() async {
    final supabase = context.read<SupabaseService>();
    try {
      final following = await supabase.isFollowing(widget.otherUserId);
      setState(() {
        _isFollowing = following;
      });
    } catch (_) {}
  }

  Future<void> _toggleFollow() async {
    final supabase = context.read<SupabaseService>();
    try {
      if (_isFollowing) {
        await supabase.unfollowUser(widget.otherUserId);
        setState(() => _isFollowing = false);
      } else {
        await supabase.followUser(widget.otherUserId);
        setState(() => _isFollowing = true);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isFollowing ? 'You followed ${widget.otherUserName}!' : 'You unfollowed ${widget.otherUserName}')),
        );
      }
    } catch (_) {}
  }

  Future<void> _toggleBlock() async {
    setState(() {
      _isBlocked = !_isBlocked;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isBlocked ? 'You have blocked ${widget.otherUserName}' : 'You have unblocked ${widget.otherUserName}'),
        backgroundColor: _isBlocked ? Colors.redAccent : Colors.green,
      ),
    );
  }

  void _reportUser() {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Report User', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Please specify the reason for reporting this user:', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Reason (e.g. Spam, Abuse)',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Report submitted. We will review this shortly.')),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Submit Report'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateDisappearingSettings(String duration) async {
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.client.from('chats').update({'disappearingDuration': duration}).eq('id', widget.chatId);
      setState(() {
        _disappearingDuration = duration;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Disappearing messages set to $duration'),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
    } catch (_) {}
  }

  Future<void> _sendImage() async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 60,
      maxWidth: 1080,
    );

    if (pickedFile != null) {
      _sendMediaMessage(File(pickedFile.path), 'image');
    }
  }

  Future<void> _sendVideo() async {
    final pickedFile = await _picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(seconds: 30),
    );

    if (pickedFile != null) {
      final file = File(pickedFile.path);
      final sizeInBytes = await file.length();
      final sizeInMB = sizeInBytes / (1024 * 1024);

      if (sizeInMB > 15.0) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: Colors.grey[900],
              title: const Text('File Too Large', style: TextStyle(color: Colors.white)),
              content: const Text(
                'Videos must be smaller than 15MB to save bandwidth.',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }

      _sendMediaMessage(file, 'video');
    }
  }

  Future<void> _sendMediaMessage(File file, String type) async {
    setState(() => _isSending = true);
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.sendMessage(
        chatId: widget.chatId,
        mediaFile: file,
        mediaType: type,
        disappearingDuration: _disappearingDuration,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send media')),
      );
    } finally {
      setState(() => _isSending = false);
    }
  }

  Future<void> _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    final supabase = context.read<SupabaseService>();

    try {
      await supabase.sendMessage(
        chatId: widget.chatId,
        text: text,
        disappearingDuration: _disappearingDuration,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send message')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    final primaryColor = Theme.of(context).primaryColor;

    final messageStream = supabase.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chatId', widget.chatId)
        .order('createdAt', ascending: true);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[950],
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ReelProfilePage(userId: widget.otherUserId),
              ),
            );
          },
          child: Row(
            children: [
              UserAvatar(
                userId: widget.otherUserId,
                radius: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.otherUserName,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      _disappearingDuration == 'off' ? 'tap settings for disappearing' : '⏰ disappearing: $_disappearingDuration',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            color: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (value) {
              if (value == 'off' || value == '24h' || value == '48h') {
                _updateDisappearingSettings(value);
              } else if (value == 'friend') {
                _toggleFollow();
              } else if (value == 'block') {
                _toggleBlock();
              } else if (value == 'report') {
                _reportUser();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'friend',
                child: Row(
                  children: [
                    Icon(_isFollowing ? Icons.person_remove : Icons.person_add, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Text(_isFollowing ? 'Unfollow Friends' : 'Follow Friend', style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'block',
                child: Row(
                  children: [
                    Icon(Icons.block, color: _isBlocked ? Colors.green : Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Text(_isBlocked ? 'Unblock Contact' : 'Block User', style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(Icons.report_problem_outlined, color: Colors.amber, size: 18),
                    const SizedBox(width: 8),
                    Text('Report Abuse', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              const PopupMenuItem(
                value: 'off',
                child: Text('⏰ Disappearing: Off', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: '24h',
                child: Text('⏰ Disappearing: 24 Hours', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: '48h',
                child: Text('⏰ Disappearing: 48 Hours', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBlocked)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: Colors.redAccent.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const Icon(Icons.block, color: Colors.redAccent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You have blocked ${widget.otherUserName}. Unblock them to continue chatting.',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: messageStream,
              builder: (context, snapshot) {
                if (_isLoadingLocal) {
                  return const Center(child: CircularProgressIndicator());
                }

                final streamMessages = snapshot.data ?? [];

                if (streamMessages.isNotEmpty) {
                  _mergeMessages(streamMessages);
                  for (final msg in streamMessages) {
                    final senderId = msg['senderId'] as String;
                    final isReceived = msg['received'] as bool? ?? false;
                    if (senderId != myId && !isReceived) {
                      supabase.markMessageAsReceived(msg['id'] as String);
                    }
                  }
                }

                final displayMessages = _localMessages;

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                  }
                });

                if (displayMessages.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages. Chat is fully encrypted & ephemeral.',
                      style: TextStyle(color: Colors.white30, fontSize: 13),
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  itemCount: displayMessages.length,
                  itemBuilder: (context, index) {
                    final msg = displayMessages[index];
                    final isMe = msg['senderId'] == myId;
                    final text = msg['text'] as String?;
                    final mediaUrl = msg['mediaUrl'] as String?;
                    final mediaType = msg['mediaType'] as String?;
                    final received = msg['received'] as bool? ?? false;
                    final createdAtStr = msg['createdAt'] as String?;

                    String timeStr = '';
                    if (createdAtStr != null) {
                      try {
                        final parsed = DateTime.parse(createdAtStr).toLocal();
                        timeStr = '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
                      } catch (_) {}
                    }

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isMe ? const Color(0xFFFE2C55) : const Color(0xFF262626), // TikTok Red for sender
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(20),
                            topRight: const Radius.circular(20),
                            bottomLeft: isMe ? const Radius.circular(20) : Radius.zero,
                            bottomRight: isMe ? Radius.zero : const Radius.circular(20),
                          ),
                        ),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                        child: IntrinsicWidth(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (mediaUrl != null && mediaType != null) ...[
                                CachedMediaView(url: mediaUrl, mediaType: mediaType),
                                const SizedBox(height: 6),
                              ],
                              if (text != null && text.isNotEmpty)
                                Align(
                                  alignment: Alignment.topLeft,
                                  child: Text(
                                    text,
                                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.3),
                                  ),
                                ),
                              const SizedBox(height: 4),
                              // Micro-timestamp and receipts double ticks (no Spacer to keep bubble size wrap content)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    timeStr,
                                    style: const TextStyle(color: Colors.white38, fontSize: 9),
                                  ),
                                  if (isMe) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.done_all,
                                      size: 13,
                                      color: received ? Colors.lightBlueAccent : Colors.white30,
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_isSending)
            Container(
              color: Colors.black,
              padding: const EdgeInsets.all(8.0),
              child: const LinearProgressIndicator(),
            ),
          // Chat input field
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: const Color(0xFF121212),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _isBlocked ? null : _sendVideo,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.camera_alt, color: Colors.white70, size: 28),
                    ),
                  ),
                  GestureDetector(
                    onTap: _isBlocked ? null : _sendImage,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 4, right: 12),
                      child: Icon(Icons.image, color: Colors.white70, size: 26),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.only(left: 16, right: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              enabled: !_isBlocked,
                              style: const TextStyle(color: Colors.white, fontSize: 15),
                              maxLines: null,
                              decoration: InputDecoration(
                                hintText: _isBlocked ? 'Unblock to chat' : 'Send message...',
                                hintStyle: const TextStyle(color: Colors.white54, fontSize: 15),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: _isBlocked ? null : _sendTextMessage,
                            child: Container(
                              margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4, right: 2),
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFE2C55), // TikTok Pink Send Button
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

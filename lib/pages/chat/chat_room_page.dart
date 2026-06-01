import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/widgets/chat/cached_media_view.dart';
import 'package:reel/pages/chat/forward_message_page.dart';
import 'package:reel/pages/chat/chat_video_viewer_page.dart';
import 'package:swipe_to/swipe_to.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

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

  String? _selectedMessageId;
  Map<String, dynamic>? _replyingToMessage;

  Timer? _offlineRetryTimer;
  bool _wasOffline = false;
  final Set<String> _sendingMessageIds = {};

  // Audio Recording states
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String _recordingDurationStr = '00:00';
  Timer? _recordingTimer;
  DateTime? _recordingStartTime;

  @override
  void initState() {
    super.initState();
    _loadChatSettings();
    _checkFollowingStatus();
    _loadLocalMessages().then((_) {
      _retryPendingMessages();
    });

    _messageController.addListener(() {
      if (mounted) setState(() {});
    });

    _offlineRetryTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _retryPendingMessages();
    });
  }

  @override
  void dispose() {
    _offlineRetryTimer?.cancel();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        final path = '${directory.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path,
        );

        _recordingStartTime = DateTime.now();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_recordingStartTime != null) {
            final elapsed = DateTime.now().difference(_recordingStartTime!);
            final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
            final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
            if (mounted) {
              setState(() {
                _recordingDurationStr = '$minutes:$seconds';
              });
            }
          }
        });

        if (mounted) {
          setState(() {
            _isRecording = true;
            _recordingDurationStr = '00:00';
          });
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required to record audio messages.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error starting audio recording: $e');
    }
  }

  Future<void> _cancelRecording() async {
    try {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordingDurationStr = '00:00';
        });
      }
    } catch (e) {
      debugPrint('Error cancelling audio recording: $e');
    }
  }

  Future<void> _stopAndSendRecording() async {
    try {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordingDurationStr = '00:00';
        });
      }

      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          _sendMediaMessage(file, 'audio');
        }
      }
    } catch (e) {
      debugPrint('Error stopping and sending audio recording: $e');
    }
  }

  Future<void> _attemptSendPendingMessage(Map<String, dynamic> pendingMsg) async {
    final tempId = pendingMsg['id'];
    if (_sendingMessageIds.contains(tempId)) return;
    _sendingMessageIds.add(tempId);

    final supabase = context.read<SupabaseService>();
    try {
      Map<String, dynamic> result;
      if (pendingMsg['mediaFilePath'] != null) {
        final file = File(pendingMsg['mediaFilePath']);
        if (!await file.exists()) {
          _sendingMessageIds.remove(tempId);
          return;
        }
        result = await supabase.sendMessage(
          chatId: widget.chatId,
          mediaFile: file,
          mediaType: pendingMsg['mediaType'],
          disappearingDuration: _disappearingDuration,
          replyToMessageId: pendingMsg['replyToMessageId'],
        );
      } else {
        result = await supabase.sendMessage(
          chatId: widget.chatId,
          text: pendingMsg['text'],
          disappearingDuration: _disappearingDuration,
          replyToMessageId: pendingMsg['replyToMessageId'],
        );
      }

      final index = _localMessages.indexWhere((m) => m['id'] == tempId);
      if (index != -1) {
        setState(() {
          _localMessages[index] = {
            ...result,
            'isPending': false,
          };
        });
        await _saveLocalMessages();
      }

      if (_wasOffline) {
        _wasOffline = false;
        _syncIncomingMessages();
      }
    } catch (e) {
      debugPrint('Failed to send pending message $tempId: $e');
      _wasOffline = true;
    } finally {
      _sendingMessageIds.remove(tempId);
    }
  }

  Future<void> _retryPendingMessages() async {
    final pending = _localMessages.where((m) => m['isPending'] == true).toList();
    if (pending.isEmpty && _wasOffline) {
      _wasOffline = false;
      _syncIncomingMessages();
      return;
    }
    for (final msg in pending) {
      _attemptSendPendingMessage(msg);
    }
  }

  Future<void> _syncIncomingMessages() async {
    final supabase = context.read<SupabaseService>();
    try {
      final serverMessages = await supabase.getChatMessages(widget.chatId);
      if (serverMessages.isNotEmpty) {
        final typedMessages = serverMessages.map((e) => Map<String, dynamic>.from(e)).toList();
        setState(() {
          _mergeMessages(typedMessages);
        });
      }
    } catch (e) {
      debugPrint('Error manual syncing incoming messages: $e');
    }
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
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    final replyId = _replyingToMessage?['id'];
    setState(() {
      _replyingToMessage = null;
    });

    final tempId = 'pending_${myId}_${DateTime.now().millisecondsSinceEpoch}';
    final tempMsg = {
      'id': tempId,
      'chatId': widget.chatId,
      'senderId': myId,
      'mediaFilePath': file.path,
      'mediaType': type,
      'createdAt': DateTime.now().toIso8601String(),
      'received': false,
      'isPending': true,
      if (replyId != null) 'replyToMessageId': replyId,
    };

    setState(() {
      _localMessages.add(tempMsg);
    });
    await _saveLocalMessages();

    // Trigger background attempt
    _attemptSendPendingMessage(tempMsg);
  }

  Future<void> _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    final replyId = _replyingToMessage?['id'];
    setState(() {
      _replyingToMessage = null;
    });

    final tempId = 'pending_${myId}_${DateTime.now().millisecondsSinceEpoch}';
    final tempMsg = {
      'id': tempId,
      'chatId': widget.chatId,
      'senderId': myId,
      'text': text,
      'createdAt': DateTime.now().toIso8601String(),
      'received': false,
      'isPending': true,
      if (replyId != null) 'replyToMessageId': replyId,
    };

    setState(() {
      _localMessages.add(tempMsg);
    });
    await _saveLocalMessages();

    // Trigger background attempt
    _attemptSendPendingMessage(tempMsg);
  }

  void _showDeleteOptions(BuildContext context, Map<String, dynamic> msg, bool isMe) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Delete message?', style: TextStyle(color: Colors.white)),
        content: const Text('This action cannot be undone.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await context.read<SupabaseService>().deleteMessageForMe(msg['id']);
              } catch (_) {}
            },
            child: const Text('DELETE FOR ME', style: TextStyle(color: Colors.redAccent)),
          ),
          if (isMe)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await context.read<SupabaseService>().deleteMessageForEveryone(msg['id']);
                } catch (_) {}
              },
              child: const Text('DELETE FOR EVERYONE', style: TextStyle(color: Colors.redAccent)),
            ),
        ],
      ),
    );
  }

  void _showMessageOptions(BuildContext context, Map<String, dynamic> msg, bool isMe) {
    final isDeleted = msg['isDeleted'] as bool? ?? false;
    if (isDeleted) return; 

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: const Color(0xFF121212),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg['text'] != null && msg['text'].toString().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.white),
                  title: const Text('Copy Text', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: msg['text']));
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.redAccent),
                title: const Text('Delete Message', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteOptions(context, msg, isMe);
                },
              ),
            ],
          ),
        );
      },
    );
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
      appBar: _selectedMessageId != null
          ? AppBar(
              backgroundColor: const Color(0xFF00A884), // WhatsApp green selection color
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _selectedMessageId = null;
                  });
                },
              ),
              title: const Text('1', style: TextStyle(color: Colors.white, fontSize: 18)),
              actions: [
                IconButton(
                  icon: const Icon(Icons.reply, color: Colors.white),
                  onPressed: () {
                    final selectedMsg = _localMessages.firstWhere((m) => m['id'] == _selectedMessageId, orElse: () => {});
                    setState(() {
                      _replyingToMessage = selectedMsg.isNotEmpty ? selectedMsg : null;
                      _selectedMessageId = null;
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.push_pin, color: Colors.white),
                  onPressed: () async {
                    final selectedMsg = _localMessages.firstWhere((m) => m['id'] == _selectedMessageId, orElse: () => {});
                    if (selectedMsg.isEmpty) return;
                    final isPinned = selectedMsg['is_pinned'] == true;
                    try {
                      await supabase.pinMessage(_selectedMessageId!, !isPinned);
                      setState(() {
                        _selectedMessageId = null;
                      });
                    } catch (_) {}
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.white),
                  onPressed: () {
                    final selectedMsg = _localMessages.firstWhere((m) => m['id'] == _selectedMessageId, orElse: () => {});
                    if (selectedMsg.isEmpty) return;
                    final isMe = selectedMsg['senderId'] == myId;
                    setState(() { _selectedMessageId = null; });
                    _showDeleteOptions(context, selectedMsg, isMe);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.white),
                  onPressed: () {
                    final selectedMsg = _localMessages.firstWhere((m) => m['id'] == _selectedMessageId, orElse: () => {});
                    if (selectedMsg.isNotEmpty && selectedMsg['text'] != null) {
                      Clipboard.setData(ClipboardData(text: selectedMsg['text']));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                    }
                    setState(() { _selectedMessageId = null; });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.turn_right, color: Colors.white),
                  onPressed: () {
                    final selectedMsg = _localMessages.firstWhere((m) => m['id'] == _selectedMessageId, orElse: () => {});
                    setState(() { _selectedMessageId = null; });
                    if (selectedMsg.isNotEmpty) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ForwardMessagePage(messageToForward: selectedMsg),
                        ),
                      );
                    }
                  },
                ),
              ],
            )
          : AppBar(
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

                final displayMessages = _localMessages.where((m) {
                  final deletedForList = m['deletedFor'] as List<dynamic>? ?? [];
                  return !deletedForList.contains(myId);
                }).toList();

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

                    final isDeleted = msg['isDeleted'] as bool? ?? false;

                    final isSelected = msg['id'] == _selectedMessageId;

                    return SwipeTo(
                      onRightSwipe: (details) {
                        if (!isDeleted) {
                          setState(() {
                            _replyingToMessage = msg;
                          });
                        }
                      },
                      child: GestureDetector(
                        onLongPress: () {
                          if (!isDeleted) {
                            setState(() {
                              _selectedMessageId = msg['id'];
                            });
                          }
                        },
                        onTap: () {
                          if (_selectedMessageId != null) {
                            setState(() {
                              _selectedMessageId = _selectedMessageId == msg['id'] ? null : msg['id'];
                            });
                          }
                        },
                        child: Container(
                          color: isSelected ? const Color(0xFF00A884).withOpacity(0.3) : Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                          child: Align(
                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isDeleted 
                                    ? Colors.transparent 
                                    : (isMe ? const Color(0xFFFE2C55) : const Color(0xFF262626)),
                                border: isDeleted ? Border.all(color: Colors.white24, width: 1) : null,
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
                                    if (msg['replyToMessageId'] != null)
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        margin: const EdgeInsets.only(bottom: 6),
                                        decoration: BoxDecoration(
                                          color: Colors.black26,
                                          borderRadius: BorderRadius.circular(8),
                                          border: const Border(left: BorderSide(color: Color(0xFF00A884), width: 4)),
                                        ),
                                        child: const Text(
                                          'Replied message',
                                          style: TextStyle(color: Colors.white70, fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    if (isDeleted)
                                      const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.block, color: Colors.white30, size: 16),
                                          SizedBox(width: 6),
                                          Text('This message was deleted', style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
                                        ],
                                      )
                                    else ...[
                                      if ((mediaUrl != null || msg['mediaFilePath'] != null) && mediaType != null) ...[
                                        if (mediaType == 'audio')
                                          AudioMessagePlayer(
                                            url: mediaUrl,
                                            localFilePath: msg['mediaFilePath'],
                                          )
                                        else if (msg['isPending'] == true && msg['mediaFilePath'] != null)
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(16),
                                            child: mediaType == 'image'
                                                ? Image.file(
                                                    File(msg['mediaFilePath']),
                                                    width: 200,
                                                    height: 200,
                                                    fit: BoxFit.cover,
                                                  )
                                                : GestureDetector(
                                                    onTap: () {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (context) => ChatVideoViewerPage(videoPath: msg['mediaFilePath']),
                                                        ),
                                                      );
                                                    },
                                                    child: Stack(
                                                      alignment: Alignment.center,
                                                      children: [
                                                        Container(
                                                          width: 200,
                                                          height: 200,
                                                          color: Colors.white.withOpacity(0.1),
                                                          child: const Icon(Icons.video_library_outlined, color: Colors.white54, size: 40),
                                                        ),
                                                        Container(
                                                          padding: const EdgeInsets.all(8),
                                                          decoration: const BoxDecoration(
                                                            color: Colors.black54,
                                                            shape: BoxShape.circle,
                                                          ),
                                                          child: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                          )
                                        else
                                          CachedMediaView(url: mediaUrl!, mediaType: mediaType),
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
                                    ],
                                    const SizedBox(height: 4),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (msg['is_pinned'] == true)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 4),
                                            child: Icon(Icons.push_pin, size: 12, color: Colors.white70),
                                          ),
                                        Text(
                                          timeStr,
                                          style: const TextStyle(color: Colors.white38, fontSize: 9),
                                        ),
                                        if (isMe) ...[
                                          const SizedBox(width: 4),
                                          Icon(
                                            msg['isPending'] == true ? Icons.access_time : Icons.done_all,
                                            size: 13,
                                            color: msg['isPending'] == true ? Colors.white38 : (received ? Colors.lightBlueAccent : Colors.white30),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
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
            child: Column(
              children: [
                if (_replyingToMessage != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12),
                      border: const Border(left: BorderSide(color: Color(0xFF00A884), width: 4)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Replying to message', style: TextStyle(color: Color(0xFF00A884), fontWeight: FontWeight.bold, fontSize: 13)),
                              const SizedBox(height: 4),
                              Text(
                                _replyingToMessage!['text']?.toString() ?? 'Media message',
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _replyingToMessage = null;
                            });
                          },
                          child: const Icon(Icons.close, color: Colors.white54, size: 20),
                        ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  color: const Color(0xFF121212),
                  child: _isRecording
                      ? Row(
                          children: [
                            const SizedBox(width: 8),
                            const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              'Recording... $_recordingDurationStr',
                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _cancelRecording,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  color: Colors.white10,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                              ),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: _stopAndSendRecording,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFE2C55),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.send, color: Colors.white, size: 20),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                        )
                      : Row(
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
                                    _messageController.text.trim().isNotEmpty
                                        ? GestureDetector(
                                            onTap: _isBlocked ? null : _sendTextMessage,
                                            child: Container(
                                              margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4, right: 2),
                                              padding: const EdgeInsets.all(8),
                                              decoration: const BoxDecoration(
                                                color: Color(0xFFFE2C55),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 18),
                                            ),
                                          )
                                        : GestureDetector(
                                            onTap: _isBlocked ? null : _startRecording,
                                            child: Container(
                                              margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4, right: 2),
                                              padding: const EdgeInsets.all(8),
                                              decoration: const BoxDecoration(
                                                color: Color(0xFFFE2C55),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(Icons.mic, color: Colors.white, size: 18),
                                            ),
                                          ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AudioMessagePlayer extends StatefulWidget {
  final String? url;
  final String? localFilePath;

  const AudioMessagePlayer({
    super.key,
    this.url,
    this.localFilePath,
  });

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _completeSub;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      if (widget.localFilePath != null) {
        await _audioPlayer.setSource(DeviceFileSource(widget.localFilePath!));
      } else if (widget.url != null) {
        await _audioPlayer.setSource(UrlSource(widget.url!));
      }

      _durationSub = _audioPlayer.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      });

      _positionSub = _audioPlayer.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      });

      _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state == PlayerState.playing;
          });
        }
      });

      _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _position = Duration.zero;
            _isPlaying = false;
          });
        }
      });
    } catch (e) {
      debugPrint('Error initializing audio player: $e');
    }
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _completeSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString();
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _togglePlay() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        if (widget.localFilePath != null) {
          await _audioPlayer.play(DeviceFileSource(widget.localFilePath!));
        } else if (widget.url != null) {
          await _audioPlayer.play(UrlSource(widget.url!));
        }
      }
    } catch (e) {
      debugPrint('Error toggling playback: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxVal = _duration.inMilliseconds.toDouble();
    final currentVal = _position.inMilliseconds.toDouble().clamp(0.0, maxVal);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white30,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: currentVal,
                    min: 0.0,
                    max: maxVal > 0.0 ? maxVal : 1.0,
                    onChanged: (val) async {
                      final pos = Duration(milliseconds: val.toInt());
                      await _audioPlayer.seek(pos);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(_position),
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                      Text(
                        _formatDuration(_duration),
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

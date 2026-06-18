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
import 'package:reel/services/websocket_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/widgets/chat/cached_media_view.dart';
import 'package:reel/pages/chat/forward_message_page.dart';
import 'package:reel/pages/chat/chat_video_viewer_page.dart';
import 'package:reel/pages/chat/group_info_page.dart';
import 'package:swipe_to/swipe_to.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:reel/theme/reel_theme.dart';

class ChatRoomPage extends StatefulWidget {
  final String chatId;
  final String otherUserId;
  final String otherUserName;
  final bool isGroup;

  const ChatRoomPage({
    super.key,
    required this.chatId,
    required this.otherUserId,
    required this.otherUserName,
    this.isGroup = false,
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
  StreamSubscription? _wsSubscription;

  // Audio Recording states
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String _recordingDurationStr = '00:00';
  Timer? _recordingTimer;
  DateTime? _recordingStartTime;

  // Group chat details
  String? _groupIcon;
  Map<String, String> _participantNames = {};

  // Global static in-memory cache for all chats to achieve instant load times
  static final Map<String, List<Map<String, dynamic>>> _inMemoryMsgCache = {};

  @override
  void initState() {
    super.initState();
    final supabase = context.read<SupabaseService>();
    supabase.activeChatId = widget.chatId;

    // Try to load from in-memory cache first for instant rendering
    if (_inMemoryMsgCache.containsKey(widget.chatId)) {
      _localMessages = List<Map<String, dynamic>>.from(_inMemoryMsgCache[widget.chatId]!);
      _isLoadingLocal = false;
    }

    _loadChatSettings();
    if (widget.isGroup) {
      _loadGroupDetails();
      _loadGroupParticipants();
    } else {
      _checkFollowingStatus();
    }
    
    // Connect to Go WebSocket backend and listen to the stream
    WebSocketService().connect();
    _wsSubscription = WebSocketService().messageStream.listen((event) {
      _handleWebSocketEvent(event);
    });

    _loadLocalMessages().then((_) {
      _retryPendingMessages();
      _fetchUndeliveredHistory();
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
    final supabase = context.read<SupabaseService>();
    if (supabase.activeChatId == widget.chatId) {
      supabase.activeChatId = null;
    }
    _wsSubscription?.cancel();
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
      String? mediaUrl = pendingMsg['mediaUrl'];
      
      // 1. If it's a media message and has no URL yet, upload it first
      if (pendingMsg['mediaFilePath'] != null && mediaUrl == null) {
        final file = File(pendingMsg['mediaFilePath']);
        if (!await file.exists()) {
          _sendingMessageIds.remove(tempId);
          return;
        }
        
        try {
          mediaUrl = await supabase.uploadToR2(file);
        } catch (r2Error) {
          debugPrint('Chat media R2 upload failed, falling back to Supabase Storage: $r2Error');
          final ext = file.path.split('.').last.toLowerCase();
          final fileName = 'chat_media_${DateTime.now().millisecondsSinceEpoch}.$ext';
          final storagePath = 'chats/${widget.chatId}/$fileName';
          
          await supabase.client.storage.from('media').upload(storagePath, file);
          mediaUrl = supabase.getMediaUrl('media', storagePath);
        }
        
        // Update URL locally
        setState(() {
          final index = _localMessages.indexWhere((m) => m['id'] == tempId);
          if (index != -1) {
            _localMessages[index]['mediaUrl'] = mediaUrl;
          }
        });
        await _saveLocalMessages();
      }

      // 2. Send via WebSocket
      final sent = WebSocketService().sendMessage(
        chatId: widget.chatId,
        recipientId: widget.otherUserId,
        text: pendingMsg['text'] ?? "",
        mediaUrl: mediaUrl,
        mediaType: pendingMsg['mediaType'],
        tempId: tempId,
      );

      if (sent) {
        // WebSocket successfully accepted it, wait for 'ack' event to resolve isPending.
      } else {
        throw Exception('WebSocket client is offline');
      }

      if (_wasOffline) {
        _wasOffline = false;
        _fetchUndeliveredHistory();
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
      _fetchUndeliveredHistory();
      return;
    }
    for (final msg in pending) {
      _attemptSendPendingMessage(msg);
    }
  }

  Future<void> _fetchUndeliveredHistory() async {
    try {
      String? lastMessageId;
      if (_localMessages.isNotEmpty) {
        final nonPending = _localMessages.where((m) => m['isPending'] != true).toList();
        if (nonPending.isNotEmpty) {
          nonPending.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
          lastMessageId = nonPending.last['id'];
        }
      }

      final history = await WebSocketService().fetchHistory(widget.chatId, lastMessageId: lastMessageId);
      if (history.isNotEmpty) {
        setState(() {
          for (final msg in history) {
            final typedMsg = Map<String, dynamic>.from(msg);
            final msgId = typedMsg['messageId'] ?? typedMsg['id'];

            final exists = _localMessages.any((m) => m['id'] == msgId || m['messageId'] == msgId);
            if (!exists) {
              if (_mergeIncomingUserMessage(typedMsg)) {
                continue;
              }
              final localMsg = {
                'id': msgId,
                'messageId': msgId,
                'chatId': typedMsg['chatId'],
                'senderId': typedMsg['senderId'],
                'text': typedMsg['text'],
                'mediaUrl': typedMsg['mediaUrl'],
                'mediaType': typedMsg['mediaType'],
                'createdAt': typedMsg['timestamp'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(typedMsg['timestamp']).toIso8601String()
                    : DateTime.now().toIso8601String(),
                'received': true,
              };
              _localMessages.add(localMsg);
            }
          }

          // Sort chronologically
          _localMessages.sort((a, b) {
            final timeA = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
            final timeB = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
            return timeA.compareTo(timeB);
          });
        });
        await _saveLocalMessages();
      }
    } catch (e) {
      debugPrint('Error manual syncing incoming history: $e');
    }
  }

  void _handleWebSocketEvent(Map<String, dynamic> event) {
    if (!mounted) return;

    final type = event['type'] ?? 'message';
    final eventChatId = event['chatId'];

    if (eventChatId != widget.chatId) return;

    if (type == 'ack') {
      final tempId = event['tempId'];
      final messageId = event['messageId'];
      final timestamp = event['timestamp'] as int?;

      setState(() {
        final index = _localMessages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _localMessages[index]['id'] = messageId;
          _localMessages[index]['messageId'] = messageId;
          _localMessages[index]['isPending'] = false;
          if (timestamp != null) {
            _localMessages[index]['createdAt'] =
                DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String();
          }
        }
      });
      _saveLocalMessages();
    } else if (type == 'status') {
      final messageId = event['messageId'];
      final status = event['status'];

      setState(() {
        final index = _localMessages.indexWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
        if (index != -1) {
          _localMessages[index]['received'] = (status == 'received');
        }
      });
      _saveLocalMessages();
    } else if (type == 'message') {
      final supabase = context.read<SupabaseService>();
      final myId = supabase.currentUser?.id;
      final senderId = event['senderId'];
      final messageId = event['messageId'];

      final exists = _localMessages.any((m) => m['id'] == messageId || m['messageId'] == messageId);
      if (exists) return;

      if (_mergeIncomingUserMessage(event)) return;

      setState(() {
        final localMsg = {
          'id': messageId,
          'messageId': messageId,
          'chatId': event['chatId'],
          'senderId': senderId,
          'text': event['text'],
          'mediaUrl': event['mediaUrl'],
          'mediaType': event['mediaType'],
          'createdAt': event['timestamp'] != null
              ? DateTime.fromMillisecondsSinceEpoch(event['timestamp']).toIso8601String()
              : DateTime.now().toIso8601String(),
          'received': true,
        };
        _localMessages.add(localMsg);
      });
      _saveLocalMessages();

      if (senderId != myId) {
        WebSocketService().sendStatusUpdate(
          chatId: widget.chatId,
          messageId: messageId,
          recipientId: senderId,
          status: 'received',
        );
      }
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
    // Update static in-memory cache
    _inMemoryMsgCache[widget.chatId] = List<Map<String, dynamic>>.from(_localMessages);

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

  bool _mergeIncomingUserMessage(Map<String, dynamic> msg) {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (msg['senderId'] != myId) return false;

    final msgId = msg['messageId'] ?? msg['id'];
    if (msgId == null) return false;

    // Normalize text helper to handle null vs empty string difference
    String normalizeText(dynamic val) {
      if (val == null) return '';
      return val.toString().trim();
    }

    final msgText = normalizeText(msg['text']);
    final msgMediaUrl = msg['mediaUrl']?.toString();

    // Look for a local pending message with matching content
    for (int i = 0; i < _localMessages.length; i++) {
      final local = _localMessages[i];
      if (local['isPending'] == true) {
        final localText = normalizeText(local['text']);
        final localMediaUrl = local['mediaUrl']?.toString();
        final hasLocalFilePath = local['mediaFilePath'] != null;

        bool match = false;
        if (msgMediaUrl != null) {
          // If the incoming message has a media URL, check if local has same media URL or local path
          if (msgMediaUrl == localMediaUrl || hasLocalFilePath) {
            match = true;
          }
        } else {
          // Otherwise compare normalized text content
          if (msgText.isNotEmpty && msgText == localText) {
            match = true;
          }
        }

        if (match) {
          setState(() {
            _localMessages[i]['id'] = msgId;
            _localMessages[i]['messageId'] = msgId;
            _localMessages[i]['isPending'] = false;
            if (msg['timestamp'] != null) {
              _localMessages[i]['createdAt'] =
                  DateTime.fromMillisecondsSinceEpoch(msg['timestamp']).toIso8601String();
            } else if (msg['createdAt'] != null) {
              _localMessages[i]['createdAt'] = msg['createdAt'];
            }
          });
          _saveLocalMessages();
          return true;
        }
      }
    }
    return false;
  }



  Widget _buildReplyBubble(Map<String, dynamic> msg, String? myId) {
    if (msg['replyToMessageId'] == null) return const SizedBox.shrink();

    final replyId = msg['replyToMessageId'];
    final repliedMsg = _localMessages.firstWhere(
      (m) => m['id'] == replyId || m['messageId'] == replyId,
      orElse: () => {},
    );

    final isRepliedEmpty = repliedMsg.isEmpty;
    
    // Sender Name
    String senderName = 'Message';
    if (!isRepliedEmpty) {
      final rSenderId = repliedMsg['senderId'];
      if (rSenderId == myId) {
        senderName = 'You';
      } else if (widget.isGroup) {
        senderName = _participantNames[rSenderId] ?? 'User';
      } else {
        senderName = widget.otherUserName;
      }
    }

    // Left line and text colors
    final bool isRepliedMe = !isRepliedEmpty && repliedMsg['senderId'] == myId;
    final Color themeColor = isRepliedMe
        ? ReelTheme.accentColor
        : ReelTheme.oceanBlue;

    // Content preview
    Widget contentWidget;
    if (isRepliedEmpty) {
      contentWidget = const Text(
        'Replied message',
        style: TextStyle(color: Colors.white60, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      final String? rText = repliedMsg['text'] as String?;
      final String? rMediaUrl = repliedMsg['mediaUrl'] as String?;
      final String? rMediaFilePath = repliedMsg['mediaFilePath'] as String?;
      final String? rMediaType = repliedMsg['mediaType'] as String?;

      if ((rMediaUrl != null || rMediaFilePath != null) && rMediaType != null) {
        IconData iconData = Icons.insert_drive_file;
        String mediaText = 'Media';
        if (rMediaType == 'image') {
          iconData = Icons.photo;
          mediaText = 'Photo';
        } else if (rMediaType == 'video') {
          iconData = Icons.videocam;
          mediaText = 'Video';
        } else if (rMediaType == 'audio') {
          iconData = Icons.mic;
          mediaText = 'Audio';
        }

        contentWidget = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconData, size: 14, color: Colors.white54),
            const SizedBox(width: 4),
            Text(
              mediaText,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (rText != null && rText.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  rText,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        );
      } else {
        contentWidget = Text(
          rText ?? '',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: themeColor.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: themeColor, width: 3.5),
          top: BorderSide(color: themeColor.withOpacity(0.15)),
          right: BorderSide(color: themeColor.withOpacity(0.15)),
          bottom: BorderSide(color: themeColor.withOpacity(0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.reply_rounded, color: themeColor.withOpacity(0.8), size: 14),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  senderName,
                  style: TextStyle(
                    color: themeColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          contentWidget,
        ],
      ),
    );
  }

  Widget _buildReplyComposePreview(String? myId) {
    if (_replyingToMessage == null) return const SizedBox.shrink();

    final msg = _replyingToMessage!;
    final rSenderId = msg['senderId'];
    
    // Sender Name
    String senderName = 'Message';
    if (rSenderId == myId) {
      senderName = 'You';
    } else if (widget.isGroup) {
      senderName = _participantNames[rSenderId] ?? 'User';
    } else {
      senderName = widget.otherUserName;
    }

    final bool isRepliedMe = rSenderId == myId;
    final Color themeColor = isRepliedMe
        ? ReelTheme.accentColor
        : ReelTheme.oceanBlue;

    // Content preview
    Widget contentWidget;
    final String? rText = msg['text'] as String?;
    final String? rMediaUrl = msg['mediaUrl'] as String?;
    final String? rMediaFilePath = msg['mediaFilePath'] as String?;
    final String? rMediaType = msg['mediaType'] as String?;

    if ((rMediaUrl != null || rMediaFilePath != null) && rMediaType != null) {
      IconData iconData = Icons.insert_drive_file;
      String mediaText = 'Media';
      if (rMediaType == 'image') {
        iconData = Icons.photo;
        mediaText = 'Photo';
      } else if (rMediaType == 'video') {
        iconData = Icons.videocam;
        mediaText = 'Video';
      } else if (rMediaType == 'audio') {
        iconData = Icons.mic;
        mediaText = 'Audio';
      }

      contentWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconData, size: 14, color: Colors.white54),
          const SizedBox(width: 4),
          Text(
            mediaText,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (rText != null && rText.trim().isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                rText,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      );
    } else {
      contentWidget = Text(
        rText ?? '',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border(
              left: BorderSide(color: themeColor, width: 4),
              top: BorderSide(color: Colors.white.withOpacity(0.08)),
              right: BorderSide(color: Colors.white.withOpacity(0.08)),
              bottom: BorderSide(color: Colors.white.withOpacity(0.08)),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.reply_rounded, color: themeColor, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'Replying to $senderName',
                          style: TextStyle(
                            color: themeColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    contentWidget,
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _replyingToMessage = null;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white70, size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _loadGroupDetails() async {
    if (!widget.isGroup) return;
    final supabase = context.read<SupabaseService>();
    try {
      final res = await supabase.client
          .from('chats')
          .select('name, groupIcon')
          .eq('id', widget.chatId)
          .maybeSingle();
      if (res != null && mounted) {
        setState(() {
          _groupIcon = res['groupIcon'] as String?;
        });
      }
    } catch (e) {
      debugPrint('Error loading group details: $e');
    }
  }

  Future<void> _loadGroupParticipants() async {
    if (!widget.isGroup) return;
    final supabase = context.read<SupabaseService>();
    try {
      final response = await supabase.client
          .from('chat_participants')
          .select('userId, users(name)')
          .eq('chatId', widget.chatId);
      
      final Map<String, String> names = {};
      for (final row in response) {
        final uid = row['userId'] as String;
        final user = row['users'] as Map<String, dynamic>?;
        if (user != null) {
          names[uid] = user['name'] as String? ?? 'User';
        }
      }
      if (mounted) {
        setState(() {
          _participantNames = names;
        });
      }
    } catch (e) {
      debugPrint('Error loading group participants: $e');
    }
  }

  Future<void> _leaveGroup() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
      );

      await supabase.client
          .from('chat_participants')
          .delete()
          .eq('chatId', widget.chatId)
          .eq('userId', myId);

      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        Navigator.pop(context); // Exit chat room
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('You have left the group ${widget.otherUserName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to leave group: $e')),
        );
      }
    }
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



  void _showLeaveGroupConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Leave Group', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text('Are you sure you want to leave "${widget.otherUserName}"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Pop confirmation dialog
              _leaveGroup();
            },
            child: const Text('Leave', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showGroupMembersDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('${widget.otherUserName} Members', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: _participantNames.entries.map((entry) {
              return ListTile(
                leading: UserAvatar(userId: entry.key, radius: 16),
                title: Text(entry.value, style: const TextStyle(color: Colors.white)),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;

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
            if (widget.isGroup) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => GroupInfoPage(chatId: widget.chatId),
                ),
              ).then((_) {
                _loadGroupDetails();
                _loadGroupParticipants();
                _loadChatSettings();
              });
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ReelProfilePage(userId: widget.otherUserId),
                ),
              );
            }
          },
          child: Row(
            children: [
              widget.isGroup
                  ? CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.indigo.withOpacity(0.3),
                      backgroundImage: _groupIcon != null && _groupIcon!.isNotEmpty
                          ? NetworkImage(_groupIcon!)
                          : null,
                      child: _groupIcon != null && _groupIcon!.isNotEmpty
                          ? null
                          : const Icon(Icons.group, color: Colors.indigoAccent, size: 18),
                    )
                  : UserAvatar(
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
                      widget.isGroup
                          ? '${_participantNames.length} members'
                          : (_disappearingDuration == 'off' ? 'tap settings for disappearing' : '⏰ disappearing: $_disappearingDuration'),
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
            onSelected: (value) async {
              if (value == 'off' || value == '24h' || value == '48h') {
                _updateDisappearingSettings(value);
              } else if (value == 'friend') {
                _toggleFollow();
              } else if (value == 'block') {
                _toggleBlock();
              } else if (value == 'report') {
                _reportUser();
              } else if (value == 'leave') {
                _showLeaveGroupConfirmation();
              } else if (value == 'members' || value == 'info') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => GroupInfoPage(chatId: widget.chatId),
                  ),
                ).then((_) {
                  _loadGroupDetails();
                  _loadGroupParticipants();
                  _loadChatSettings();
                });
              } else if (value == 'mute') {
                await context.read<SupabaseService>().toggleMuteChat(widget.chatId);
                setState(() {});
              }
            },
            itemBuilder: (context) {
              final supabase = context.read<SupabaseService>();
              final isMuted = supabase.isChatMuted(widget.chatId);

              return widget.isGroup
                  ? [
                      const PopupMenuItem(
                        value: 'info',
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.white70, size: 18),
                            SizedBox(width: 8),
                            Text('Group Info', style: TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'mute',
                        child: Row(
                          children: [
                            Icon(isMuted ? Icons.volume_up : Icons.volume_off, color: Colors.white70, size: 18),
                            const SizedBox(width: 8),
                            Text(isMuted ? 'Unmute Notifications' : 'Mute Notifications', style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
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
                      const PopupMenuItem(
                        value: 'leave',
                        child: Row(
                          children: [
                            Icon(Icons.exit_to_app, color: Colors.redAccent, size: 18),
                            SizedBox(width: 8),
                            Text('Leave Group', style: TextStyle(color: Colors.redAccent)),
                          ],
                        ),
                      ),
                    ]
                : [
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
            child: Builder(
              builder: (context) {
                if (_isLoadingLocal) {
                  return const Center(child: CircularProgressIndicator());
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
                                    : (isMe ? const Color(0xFF7E1C31) : const Color(0xFF262626)),
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
                                      _buildReplyBubble(msg, myId),
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
                                      if (widget.isGroup && !isMe)
                                        Align(
                                          alignment: Alignment.topLeft,
                                          child: Padding(
                                            padding: const EdgeInsets.only(bottom: 6),
                                            child: Text(
                                              _participantNames[msg['senderId']] ?? 'User',
                                              style: TextStyle(
                                                color: Colors.cyanAccent.shade400,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
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
                  _buildReplyComposePreview(myId),
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

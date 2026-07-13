import 'dart:io';
import 'dart:ui';
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
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/widgets/chat/cached_media_view.dart';
import 'package:reel/widgets/chat/sticker_picker.dart';
import 'package:reel/pages/chat/forward_message_page.dart';
import 'package:reel/pages/chat/chat_video_viewer_page.dart';
import 'package:reel/pages/chat/group_info_page.dart';
import 'package:swipe_to/swipe_to.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:reel/theme/reel_theme.dart';
import 'package:reel/pages/chat/chat_image_viewer_page.dart';

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

  static void clearCacheFor(String chatId) {
    _ChatRoomPageState._inMemoryMsgCache.remove(chatId);
  }

  static void clearAllCache() {
    _ChatRoomPageState._inMemoryMsgCache.clear();
  }

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

  final Set<String> _selectedMessageIds = {};
  Map<String, dynamic>? _replyingToMessage;
  DateTime? _joinedAt;

  Timer? _offlineRetryTimer;
  bool _wasOffline = false;
  final Set<String> _sendingMessageIds = {};
  Future<void>? _saveQueue;
  StreamSubscription? _wsSubscription;

  // Audio Recording states
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _isPaused = false;
  int _recordingSecondsElapsed = 0;
  String _recordingDurationStr = '00:00';
  Timer? _recordingTimer;
  DateTime? _recordingStartTime;

  // Audio Preview states
  String? _previewAudioPath;
  bool _isPlayingPreview = false;
  Duration _previewPosition = Duration.zero;
  Duration _previewDuration = Duration.zero;
  AudioPlayer? _previewPlayer;
  StreamSubscription? _previewPositionSub;
  StreamSubscription? _previewDurationSub;
  StreamSubscription? _previewStateSub;
  StreamSubscription? _previewCompleteSub;

  // Group chat details
  String? _groupIcon;
  Map<String, String> _participantNames = {};
  
  // Search & Restrictions states
  bool _isSearchActive = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _canSendMessages = true;
  bool _isStickerPickerActive = false;
  Map<String, dynamic> _metadata = {};
  String? _creatorId;
  bool _hasInitialScrolled = false;
  DateTime? _lastSeenTime;

  // Global static in-memory cache for all chats to achieve instant load times
  static final Map<String, List<Map<String, dynamic>>> _inMemoryMsgCache = {};

  String? _wallpaperPath;

  Future<void> _loadWallpaper() async {
    // 1. Specific chat wallpaper
    var path = await LocalStorageService().getString('chat_wallpaper_${widget.chatId}');
    
    // 2. If null, fallback to group-default (for groups) or general-default (for 1-on-1)
    if (path == null || path.isEmpty) {
      if (widget.isGroup) {
        path = await LocalStorageService().getString('chat_wallpaper_group_default');
      } else {
        path = await LocalStorageService().getString('chat_wallpaper_general_default');
      }
    }
    
    // 3. If still null, check if there is a general-default wallpaper as ultimate fallback
    if ((path == null || path.isEmpty) && widget.isGroup) {
      path = await LocalStorageService().getString('chat_wallpaper_general_default');
    }

    if (mounted) {
      setState(() {
        _wallpaperPath = path;
      });
    }
  }

  Future<void> _loadLastSeenTime() async {
    final timeStr = await LocalStorageService().getCachedJson('last_seen_time_${widget.chatId}') as String?;
    if (timeStr != null) {
      if (mounted) {
        setState(() {
          _lastSeenTime = DateTime.tryParse(timeStr);
        });
      }
    }
  }

  Future<void> _saveLastSeenTime() async {
    await LocalStorageService().cacheJson('last_seen_time_${widget.chatId}', DateTime.now().toIso8601String());
  }

  String _getDateHeaderText(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate = DateTime(date.year, date.month, date.day);

    if (msgDate == today) {
      return 'TODAY';
    } else if (msgDate == yesterday) {
      return 'YESTERDAY';
    } else {
      final months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    }
  }

  Widget _buildDateHeader(String dateText, bool isDark) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF182229) : const Color(0xFFE1F5FE),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          dateText,
          style: TextStyle(
            color: isDark ? Colors.white70 : const Color(0xFF546E7A),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final supabase = context.read<SupabaseService>();
    supabase.activeChatId = widget.chatId;
    _loadWallpaper();
    _loadLastSeenTime();

    // Try to load from in-memory cache first for instant rendering
    if (_inMemoryMsgCache.containsKey(widget.chatId)) {
      _localMessages = List<Map<String, dynamic>>.from(_inMemoryMsgCache[widget.chatId]!);
      _isLoadingLocal = false;
    }

    _loadChatSettings();
    if (widget.isGroup) {
      _loadCachedGroupData();
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
    _saveLastSeenTime();
    final supabase = context.read<SupabaseService>();
    if (supabase.activeChatId == widget.chatId) {
      supabase.activeChatId = null;
    }
    _wsSubscription?.cancel();
    _offlineRetryTimer?.cancel();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _previewPlayer?.dispose();
    _previewPositionSub?.cancel();
    _previewDurationSub?.cancel();
    _previewStateSub?.cancel();
    _previewCompleteSub?.cancel();
    _messageController.dispose();
    _searchController.dispose();
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

        if (mounted) {
          setState(() {
            _isRecording = true;
            _isPaused = false;
            _recordingSecondsElapsed = 0;
            _recordingDurationStr = '00:00';
          });
        }

        _recordingTimer?.cancel();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!_isPaused && mounted) {
            setState(() {
              _recordingSecondsElapsed++;
              final minutes = (_recordingSecondsElapsed ~/ 60).toString().padLeft(2, '0');
              final seconds = (_recordingSecondsElapsed % 60).toString().padLeft(2, '0');
              _recordingDurationStr = '$minutes:$seconds';
            });
          }
        });
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

  Future<void> _pauseRecording() async {
    try {
      await _audioRecorder.pause();
      if (mounted) {
        setState(() {
          _isPaused = true;
        });
      }
    } catch (e) {
      debugPrint('Error pausing audio recording: $e');
    }
  }

  Future<void> _resumeRecording() async {
    try {
      await _audioRecorder.resume();
      if (mounted) {
        setState(() {
          _isPaused = false;
        });
      }
    } catch (e) {
      debugPrint('Error resuming audio recording: $e');
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
          _isPaused = false;
          _recordingSecondsElapsed = 0;
          _recordingDurationStr = '00:00';
        });
      }
    } catch (e) {
      debugPrint('Error cancelling audio recording: $e');
    }
  }

  Future<void> _stopRecordingAndShowPreview() async {
    try {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isPaused = false;
          _recordingSecondsElapsed = 0;
          _recordingDurationStr = '00:00';
          _previewAudioPath = path;
        });
      }
      if (path != null) {
        await _initPreviewPlayer(path);
      }
    } catch (e) {
      debugPrint('Error stopping and previewing audio recording: $e');
    }
  }

  Future<void> _stopAndSendRecording() async {
    try {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isPaused = false;
          _recordingSecondsElapsed = 0;
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

  Future<void> _initPreviewPlayer(String path) async {
    _previewPlayer?.dispose();
    _previewPositionSub?.cancel();
    _previewDurationSub?.cancel();
    _previewStateSub?.cancel();
    _previewCompleteSub?.cancel();

    final player = AudioPlayer();
    _previewPlayer = player;
    
    try {
      await player.setSource(DeviceFileSource(path));
      
      _previewDurationSub = player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _previewDuration = d);
      });

      _previewPositionSub = player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _previewPosition = p);
      });

      _previewStateSub = player.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            _isPlayingPreview = state == PlayerState.playing;
          });
        }
      });

      _previewCompleteSub = player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _previewPosition = Duration.zero;
            _isPlayingPreview = false;
          });
        }
      });
    } catch (e) {
      debugPrint('Error initializing preview player: $e');
    }
  }

  Future<void> _togglePreviewPlay() async {
    final player = _previewPlayer;
    if (player == null) return;

    try {
      if (_isPlayingPreview) {
        await player.pause();
      } else {
        await player.resume();
      }
    } catch (e) {
      debugPrint('Error toggling preview playback: $e');
    }
  }

  Future<void> _cancelPreview() async {
    try {
      _previewPlayer?.dispose();
      _previewPlayer = null;
      _previewPositionSub?.cancel();
      _previewDurationSub?.cancel();
      _previewStateSub?.cancel();
      _previewCompleteSub?.cancel();

      if (_previewAudioPath != null) {
        final file = File(_previewAudioPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Error cancelling preview: $e');
    } finally {
      if (mounted) {
        setState(() {
          _previewAudioPath = null;
          _isPlayingPreview = false;
          _previewPosition = Duration.zero;
          _previewDuration = Duration.zero;
        });
      }
    }
  }

  Future<void> _sendPreviewRecording() async {
    final path = _previewAudioPath;
    if (path == null) return;

    try {
      _previewPlayer?.dispose();
      _previewPlayer = null;
      _previewPositionSub?.cancel();
      _previewDurationSub?.cancel();
      _previewStateSub?.cancel();
      _previewCompleteSub?.cancel();

      if (mounted) {
        setState(() {
          _previewAudioPath = null;
          _isPlayingPreview = false;
          _previewPosition = Duration.zero;
          _previewDuration = Duration.zero;
        });
      }

      final file = File(path);
      if (await file.exists()) {
        _sendMediaMessage(file, 'audio');
      }
    } catch (e) {
      debugPrint('Error sending preview recording: $e');
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
        _sendingMessageIds.remove(tempId);
        throw Exception('WebSocket client is offline');
      }

      if (_wasOffline) {
        _wasOffline = false;
        _fetchUndeliveredHistory();
      }
    } catch (e) {
      debugPrint('Failed to send pending message $tempId: $e');
      _wasOffline = true;
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
      final myId = context.read<SupabaseService>().currentUser?.id;
      String? lastMessageId;
      if (_localMessages.isNotEmpty) {
        final nonPending = _localMessages.where((m) => m['isPending'] != true).toList();
        if (nonPending.isNotEmpty) {
          nonPending.sort((a, b) {
            final timeA = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
            final timeB = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
            return timeA.compareTo(timeB);
          });
          lastMessageId = nonPending.last['id'];
        }
      }

      // Fetch participant details for join time filter and fresh install bootstrap
      final details = await context.read<SupabaseService>().getChatParticipantDetails(widget.chatId);
      if (details != null) {
        if (lastMessageId == null) {
          lastMessageId = details['lastReceivedMessageId'] as String?;
        }
        if (details['joinedAt'] != null) {
          final joinedTime = DateTime.tryParse(details['joinedAt']);
          if (joinedTime != null) {
            _joinedAt = joinedTime;
            // Filter out existing local messages sent before the user joined
            _localMessages.removeWhere((m) {
              final msgTime = m['timestamp'] != null
                  ? DateTime.fromMillisecondsSinceEpoch((m['timestamp'] as num).toInt())
                  : DateTime.tryParse(m['createdAt'] ?? '');
              return msgTime != null && msgTime.isBefore(joinedTime);
            });
          }
        }
      }

      final history = await WebSocketService().fetchHistory(widget.chatId, lastMessageId: lastMessageId);
      if (history.isNotEmpty) {
        final clearTimestampStr = await LocalStorageService().getCachedJson('clear_timestamp_${widget.chatId}') as String?;
        final clearTimestamp = clearTimestampStr != null ? DateTime.tryParse(clearTimestampStr) : null;

        setState(() {
          for (final msg in history) {
            final typedMsg = Map<String, dynamic>.from(msg);
            final msgId = typedMsg['messageId'] ?? typedMsg['id'];

            // Skip messages sent before user joined the chat/group
            if (_joinedAt != null) {
              final msgTime = typedMsg['timestamp'] != null
                  ? DateTime.fromMillisecondsSinceEpoch((typedMsg['timestamp'] as num).toInt())
                  : DateTime.tryParse(typedMsg['createdAt'] ?? '');
              if (msgTime != null && msgTime.isBefore(_joinedAt!)) {
                continue;
              }
            }

            // Skip messages sent before clear timestamp
            if (clearTimestamp != null) {
              final msgTime = typedMsg['timestamp'] != null
                  ? DateTime.fromMillisecondsSinceEpoch((typedMsg['timestamp'] as num).toInt())
                  : DateTime.tryParse(typedMsg['createdAt'] ?? '');
              if (msgTime != null && msgTime.isBefore(clearTimestamp)) {
                continue;
              }
            }

            // Do not filter out seen/read messages during history sync to ensure complete scrollable logs

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

              if (typedMsg['senderId'] != myId) {
                // Send 'delivered' status update back to the sender
                if (WebSocketService().isConnected) {
                  WebSocketService().sendStatusUpdate(
                    chatId: widget.chatId,
                    messageId: msgId,
                    recipientId: typedMsg['senderId'],
                    status: 'delivered',
                  );
                }

                final mediaUrl = typedMsg['mediaUrl'] as String?;
                if (mediaUrl != null && mediaUrl.isNotEmpty) {
                  // Pre-cache media file locally first so we don't lose it
                  try {
                    await LocalStorageService().getCachedFile(mediaUrl, ttl: const Duration(days: 30));
                    debugPrint('Pre-cached foreground history media file: $mediaUrl');
                  } catch (e) {
                    debugPrint('Failed to pre-cache foreground history media: $e');
                  }
                  context.read<SupabaseService>().deleteMessageFromServer(msgId, deleteStorage: true);
                } else {
                  context.read<SupabaseService>().deleteMessageFromServer(msgId, deleteStorage: false);
                }
              }
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
        _markAllMessagesAsSeen();

        // Sync the latest received message ID back to Supabase
        final nonPending = _localMessages.where((m) => m['isPending'] != true).toList();
        if (nonPending.isNotEmpty) {
          nonPending.sort((a, b) {
            final timeA = DateTime.tryParse(a['createdAt'] ?? '') ?? DateTime.now();
            final timeB = DateTime.tryParse(b['createdAt'] ?? '') ?? DateTime.now();
            return timeA.compareTo(timeB);
          });
          final latestId = nonPending.last['id'];
          context.read<SupabaseService>().updateLastReceivedMessageId(widget.chatId, latestId);
        }
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
      _sendingMessageIds.remove(tempId);
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
    } else if (type == 'delete') {
      final messageId = event['messageId'];
      setState(() {
        final index = _localMessages.indexWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
        if (index != -1) {
          _localMessages[index]['isDeleted'] = true;
          _localMessages[index]['text'] = 'This message was deleted';
          _localMessages[index]['mediaUrl'] = null;
          _localMessages[index]['mediaType'] = null;
        }
      });
      _saveLocalMessages();
    } else if (type == 'status') {
      final messageId = event['messageId'];
      final status = event['status'];
      final fromUserId = event['senderId'];
      final myId = context.read<SupabaseService>().currentUser?.id;

      setState(() {
        final index = _localMessages.indexWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
        if (index != -1) {
          final msg = _localMessages[index];
          if (!widget.isGroup) {
            msg['received'] = (status == 'received' || status == 'seen');
            msg['seen'] = (status == 'seen');
          } else {
            // Group chat status update tracking
            List<String> receivedList = List<String>.from(msg['receivedParticipants'] ?? []);
            List<String> seenList = List<String>.from(msg['seenParticipants'] ?? []);

            if (fromUserId != null) {
              if (status == 'received') {
                if (!receivedList.contains(fromUserId)) {
                  receivedList.add(fromUserId);
                }
              } else if (status == 'seen') {
                if (!receivedList.contains(fromUserId)) {
                  receivedList.add(fromUserId);
                }
                if (!seenList.contains(fromUserId)) {
                  seenList.add(fromUserId);
                }
              }
            }

            msg['receivedParticipants'] = receivedList;
            msg['seenParticipants'] = seenList;

            final otherMembers = _participantNames.keys.where((uid) => uid != myId).toList();
            if (otherMembers.isNotEmpty) {
              msg['received'] = otherMembers.any((uid) => receivedList.contains(uid));
              msg['seen'] = otherMembers.every((uid) => seenList.contains(uid));
            } else {
              msg['received'] = (status == 'received' || status == 'seen');
              msg['seen'] = (status == 'seen');
            }
          }
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

      // Skip messages sent before user joined the chat/group
      if (_joinedAt != null) {
        final msgTime = event['timestamp'] != null
            ? DateTime.fromMillisecondsSinceEpoch((event['timestamp'] as num).toInt())
            : DateTime.tryParse(event['createdAt'] ?? '');
        if (msgTime != null && msgTime.isBefore(_joinedAt!)) {
          return;
        }
      }

      setState(() {
        final localMsg = {
          'id': messageId,
          'messageId': messageId,
          'chatId': event['chatId'] ?? widget.chatId,
          'senderId': senderId,
          'text': event['text'],
          'mediaUrl': event['mediaUrl'],
          'mediaType': event['mediaType'],
          'createdAt': event['timestamp'] != null
              ? DateTime.fromMillisecondsSinceEpoch((event['timestamp'] as num).toInt()).toIso8601String()
              : DateTime.now().toIso8601String(),
          'received': true,
          'seen': true, // actively in chat room, so it is read immediately
        };
        _localMessages.add(localMsg);
      });
      _saveLocalMessages();

      if (_scrollController.hasClients) {
        final isNearBottom = _scrollController.position.maxScrollExtent - _scrollController.offset < 200;
        if (isNearBottom) {
          _scrollToBottom();
        }
      }

      if (senderId != myId) {
        // Send received status
        WebSocketService().sendStatusUpdate(
          chatId: widget.chatId,
          messageId: messageId,
          recipientId: senderId,
          status: 'received',
        );
        // Send seen status
        WebSocketService().sendStatusUpdate(
          chatId: widget.chatId,
          messageId: messageId,
          recipientId: senderId,
          status: 'seen',
        );
        final mediaUrl = event['mediaUrl'] as String?;
        if (mediaUrl != null && mediaUrl.isNotEmpty) {
          // Pre-cache media file locally first so we don't lose it
          try {
            await LocalStorageService().getCachedFile(mediaUrl, ttl: const Duration(days: 30));
            debugPrint('Pre-cached foreground WebSocket media file: $mediaUrl');
          } catch (e) {
            debugPrint('Failed to pre-cache foreground WebSocket media: $e');
          }
          if (messageId != null) {
            supabase.deleteMessageFromServer(messageId, deleteStorage: true);
          }
        } else {
          if (messageId != null) {
            supabase.deleteMessageFromServer(messageId, deleteStorage: false);
          }
        }
      }

      // Sync last received message ID back to Supabase
      if (messageId != null) {
        supabase.updateLastReceivedMessageId(widget.chatId, messageId);
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
        
        final clearTimestampStr = await LocalStorageService().getCachedJson('clear_timestamp_${widget.chatId}') as String?;
        final clearTimestamp = clearTimestampStr != null ? DateTime.tryParse(clearTimestampStr) : null;

        setState(() {
          _localMessages = decoded.map((e) => Map<String, dynamic>.from(e)).where((m) {
            if (clearTimestamp != null) {
              final createdAtStr = m['createdAt'] as String?;
              if (createdAtStr != null) {
                final parsed = DateTime.tryParse(createdAtStr);
                if (parsed != null && parsed.isBefore(clearTimestamp)) {
                  return false;
                }
              }
            }
            return true;
          }).toList();
          _isLoadingLocal = false;
        });
        _markAllMessagesAsSeen();
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

  void _markAllMessagesAsSeen() {
    final myId = context.read<SupabaseService>().currentUser?.id;
    if (myId == null) return;

    bool hasChanges = false;
    for (int i = 0; i < _localMessages.length; i++) {
      final msg = _localMessages[i];
      if (msg['senderId'] != myId && msg['seen'] != true) {
        msg['seen'] = true;
        msg['received'] = true;
        hasChanges = true;

        final messageId = msg['id'] ?? msg['messageId'];
        final senderId = msg['senderId'];
        if (messageId != null && senderId != null) {
          WebSocketService().sendStatusUpdate(
            chatId: widget.chatId,
            messageId: messageId,
            recipientId: senderId,
            status: 'seen',
          );
        }
      }
    }

    if (hasChanges) {
      setState(() {});
      _saveLocalMessages();
    }
  }

  Future<void> _saveLocalMessages() async {
    // Update static in-memory cache
    _inMemoryMsgCache[widget.chatId] = List<Map<String, dynamic>>.from(_localMessages);

    final completer = Completer<void>();
    final previous = _saveQueue;
    _saveQueue = completer.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final dir = Directory('${directory.path}/chats');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/${widget.chatId}_messages.json');
      await file.writeAsString(jsonEncode(_localMessages));
    } catch (_) {} finally {
      completer.complete();
    }
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          Icon(iconData, size: 14, color: isDark ? Colors.white54 : Colors.black54),
          const SizedBox(width: 4),
          Text(
            mediaText,
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12),
          ),
          if (rText != null && rText.trim().isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                rText,
                style: TextStyle(color: isDark ? Colors.white60 : Colors.black54, fontSize: 12),
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
        style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12),
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
            color: isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border(
              left: BorderSide(color: themeColor, width: 4),
              top: BorderSide(color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08)),
              right: BorderSide(color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08)),
              bottom: BorderSide(color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08)),
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
                    color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.close, color: isDark ? Colors.white70 : Colors.black54, size: 16),
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

  Future<void> _loadCachedGroupData() async {
    if (!widget.isGroup) return;
    try {
      final cachedNames = await LocalStorageService().getCachedJson('group_participants_${widget.chatId}');
      final cachedIcon = await LocalStorageService().getCachedJson('group_icon_${widget.chatId}') as String?;
      final cachedCreator = await LocalStorageService().getCachedJson('group_creator_${widget.chatId}') as String?;
      if (mounted) {
        setState(() {
          if (cachedNames != null && cachedNames is Map) {
            _participantNames = Map<String, String>.from(cachedNames.map((k, v) => MapEntry(k.toString(), v.toString())));
          }
          if (cachedIcon != null) {
            _groupIcon = cachedIcon;
          }
          if (cachedCreator != null) {
            _creatorId = cachedCreator;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _loadGroupDetails() async {
    if (!widget.isGroup) return;
    final supabase = context.read<SupabaseService>();
    try {
      final res = await supabase.client
          .from('chats')
          .select('name, groupIcon, creatorId')
          .eq('id', widget.chatId)
          .maybeSingle();
      if (res != null && mounted) {
        setState(() {
          _groupIcon = res['groupIcon'] as String?;
          _creatorId = res['creatorId'] as String?;
        });
        await LocalStorageService().cacheJson('group_icon_${widget.chatId}', _groupIcon);
        await LocalStorageService().cacheJson('group_creator_${widget.chatId}', _creatorId);
        await _loadGroupMetadata();
      }
    } catch (e) {
      debugPrint('Error loading group details: $e');
    }
  }

  Future<void> _loadGroupMetadata() async {
    if (!widget.isGroup) return;
    final supabase = context.read<SupabaseService>();
    try {
      final metadata = await supabase.getGroupMetadata(widget.chatId);
      if (mounted) {
        setState(() {
          _metadata = metadata;
          final myId = supabase.currentUser?.id;
          final sendMessagesVal = metadata['restrictions']?['sendMessages'] ?? 'all';
          if (sendMessagesVal == 'admins') {
            final creatorId = _creatorId;
            final admins = metadata['admins'] as List<dynamic>? ?? [];
            _canSendMessages = (myId == creatorId || admins.contains(myId));
          } else {
            _canSendMessages = true;
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading group metadata in chat room: $e');
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
        await LocalStorageService().cacheJson('group_participants_${widget.chatId}', names);
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
        backgroundColor: const Color(0xFF121212),
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

  void _showCameraOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Camera Options',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white),
              title: const Text('Take Photo', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickImage(
                  source: ImageSource.camera,
                  imageQuality: 60,
                  maxWidth: 1080,
                );
                if (picked != null) {
                  _sendMediaMessage(File(picked.path), 'image');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white),
              title: const Text('Record Video', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickVideo(
                  source: ImageSource.camera,
                  maxDuration: const Duration(seconds: 30),
                );
                if (picked != null) {
                  _sendMediaMessage(File(picked.path), 'video');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library, color: Colors.white),
              title: const Text('Select Video from Gallery', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                _sendVideo();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
    _scrollToBottom();

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
    _scrollToBottom();

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
                final messageId = msg['id'] ?? msg['messageId'];
                if (messageId != null) {
                  // Delete locally first
                  _localMessages.removeWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
                  await _saveLocalMessages();
                  setState(() {});
                  // Sync to Supabase
                  await context.read<SupabaseService>().deleteMessageForMe(messageId);
                }
              } catch (_) {}
            },
            child: const Text('DELETE FOR ME', style: TextStyle(color: Colors.redAccent)),
          ),
          if (isMe)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  final messageId = msg['id'] ?? msg['messageId'];
                  if (messageId != null) {
                    // Update locally first
                    final index = _localMessages.indexWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
                    if (index != -1) {
                      _localMessages[index]['isDeleted'] = true;
                      _localMessages[index]['text'] = 'This message was deleted';
                      _localMessages[index]['mediaUrl'] = null;
                      _localMessages[index]['mediaType'] = null;
                      await _saveLocalMessages();
                      setState(() {});
                    }

                    // Sync to Supabase
                    await context.read<SupabaseService>().deleteMessageForEveryone(messageId);

                    // Broadcast via WebSocket
                    final recipientId = widget.otherUserId ?? '';
                    WebSocketService().sendDeleteMessage(
                      chatId: widget.chatId,
                      messageId: messageId,
                      recipientId: recipientId,
                    );
                  }
                } catch (_) {}
              },
              child: const Text('DELETE FOR EVERYONE', style: TextStyle(color: Colors.redAccent)),
            ),
        ],
      ),
    );
  }

  void _showMultiDeleteOptions(BuildContext context, Set<String> messageIds, bool allMe) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text('Delete ${messageIds.length} messages?', style: const TextStyle(color: Colors.white)),
        content: const Text('This action cannot be undone.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final supabase = context.read<SupabaseService>();
              for (final messageId in messageIds) {
                _localMessages.removeWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
                try {
                  await supabase.deleteMessageForMe(messageId);
                } catch (e) {
                  debugPrint('Failed to delete message for me on server $messageId: $e');
                }
              }
              await _saveLocalMessages();
              setState(() {});
            },
            child: const Text('DELETE FOR ME', style: TextStyle(color: Colors.redAccent)),
          ),
          if (allMe)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                final supabase = context.read<SupabaseService>();
                for (final messageId in messageIds) {
                  final index = _localMessages.indexWhere((m) => m['id'] == messageId || m['messageId'] == messageId);
                  if (index != -1) {
                    _localMessages[index]['isDeleted'] = true;
                    _localMessages[index]['text'] = 'This message was deleted';
                    _localMessages[index]['mediaUrl'] = null;
                    _localMessages[index]['mediaType'] = null;
                  }
                  try {
                    await supabase.deleteMessageForEveryone(messageId);
                  } catch (e) {
                    debugPrint('Failed to delete message for everyone on server $messageId: $e');
                  }
                  final recipientId = widget.otherUserId ?? '';
                  WebSocketService().sendDeleteMessage(
                    chatId: widget.chatId,
                    messageId: messageId,
                    recipientId: recipientId,
                  );
                }
                await _saveLocalMessages();
                setState(() {});
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
        backgroundColor: const Color(0xFF121212),
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



  void _confirmClearChat() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161618),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white12)),
        title: const Text('Clear Chat?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to clear all messages in this chat? This cannot be undone.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              setState(() {
                _isLoadingLocal = true;
              });
              await context.read<SupabaseService>().clearChatLocally(widget.chatId);
              setState(() {
                _localMessages.clear();
                _isLoadingLocal = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chat cleared successfully!')),
              );
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white54 : Colors.black54;
    final iconColor = isDark ? Colors.white : Colors.black87;
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: _selectedMessageIds.isNotEmpty
          ? AppBar(
              backgroundColor: const Color(0xFF00A884), // WhatsApp green selection color
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _selectedMessageIds.clear();
                  });
                },
              ),
              title: Text('${_selectedMessageIds.length}', style: const TextStyle(color: Colors.white, fontSize: 18)),
              actions: [
                if (_selectedMessageIds.length == 1)
                  Builder(
                    builder: (context) {
                      final singleId = _selectedMessageIds.first;
                      final selectedMsg = _localMessages.firstWhere((m) => m['id'] == singleId, orElse: () => {});
                      final isImage = selectedMsg.isNotEmpty && selectedMsg['mediaType'] == 'image' && selectedMsg['mediaUrl'] != null;
                      if (!isImage) return const SizedBox.shrink();
                      return IconButton(
                        icon: const Icon(Icons.face, color: Colors.white),
                        tooltip: 'Save as Sticker',
                        onPressed: () async {
                          final mediaUrl = selectedMsg['mediaUrl'] as String;
                          setState(() { _selectedMessageIds.clear(); });
                          await _saveReceivedSticker(mediaUrl);
                        },
                      );
                    },
                  ),
                if (_selectedMessageIds.length == 1)
                  IconButton(
                    icon: const Icon(Icons.reply, color: Colors.white),
                    onPressed: () {
                      final singleId = _selectedMessageIds.first;
                      final selectedMsg = _localMessages.firstWhere((m) => m['id'] == singleId, orElse: () => {});
                      setState(() {
                        _replyingToMessage = selectedMsg.isNotEmpty ? selectedMsg : null;
                        _selectedMessageIds.clear();
                      });
                    },
                  ),
                if (_selectedMessageIds.length == 1)
                  IconButton(
                    icon: const Icon(Icons.push_pin, color: Colors.white),
                    onPressed: () async {
                      final singleId = _selectedMessageIds.first;
                      final selectedMsg = _localMessages.firstWhere((m) => m['id'] == singleId, orElse: () => {});
                      if (selectedMsg.isEmpty) return;
                      final isPinned = selectedMsg['is_pinned'] == true;
                      try {
                        await supabase.pinMessage(singleId, !isPinned);
                        setState(() {
                          _selectedMessageIds.clear();
                        });
                      } catch (_) {}
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.white),
                  onPressed: () {
                    final selectedMsgs = _localMessages.where((m) => _selectedMessageIds.contains(m['id'])).toList();
                    final allMe = selectedMsgs.every((m) => m['senderId'] == myId);
                    final idsToDelete = Set<String>.from(_selectedMessageIds);
                    setState(() { _selectedMessageIds.clear(); });
                    _showMultiDeleteOptions(context, idsToDelete, allMe);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.white),
                  onPressed: () {
                    final texts = <String>[];
                    for (final id in _selectedMessageIds) {
                      final msg = _localMessages.firstWhere((m) => m['id'] == id, orElse: () => {});
                      if (msg.isNotEmpty && msg['text'] != null) {
                        texts.add(msg['text'] as String);
                      }
                    }
                    if (texts.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: texts.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${texts.length} messages copied')),
                      );
                    }
                    setState(() { _selectedMessageIds.clear(); });
                  },
                ),
                if (_selectedMessageIds.length == 1)
                  IconButton(
                    icon: const Icon(Icons.turn_right, color: Colors.white),
                    onPressed: () {
                      final singleId = _selectedMessageIds.first;
                      final selectedMsg = _localMessages.firstWhere((m) => m['id'] == singleId, orElse: () => {});
                      setState(() { _selectedMessageIds.clear(); });
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
              backgroundColor: theme.scaffoldBackgroundColor,
        titleSpacing: 0,
        title: _isSearchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: TextStyle(color: textColor, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search messages...',
                  hintStyle: TextStyle(color: subColor),
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
              )
            : GestureDetector(
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
                    ).then((_) {
                      _loadChatSettings();
                    });
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
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor),
                          ),
                          Text(
                            widget.isGroup
                                ? '${_participantNames.length} members'
                                : (_disappearingDuration == 'off' ? 'tap settings for disappearing' : '⏰ disappearing: $_disappearingDuration'),
                            style: TextStyle(fontSize: 11, color: subColor),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        actions: [
          if (_isSearchActive)
            IconButton(
              icon: Icon(Icons.close, color: iconColor),
              onPressed: () {
                setState(() {
                  _isSearchActive = false;
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            )
          else
            IconButton(
              icon: Icon(Icons.search, color: iconColor),
              onPressed: () {
                setState(() {
                  _isSearchActive = true;
                });
              },
            ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: iconColor),
            color: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (value) async {
              if (value == 'wallpaper') {
                _showWallpaperOptions();
              } else if (value == 'off' || value == '24h' || value == '48h') {
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
              } else if (value == 'clear') {
                _confirmClearChat();
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
                      const PopupMenuItem(
                        value: 'wallpaper',
                        child: Row(
                          children: [
                            Icon(Icons.wallpaper, color: Colors.white70, size: 18),
                            SizedBox(width: 8),
                            Text('Wallpaper', style: TextStyle(color: Colors.white)),
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
                        value: 'clear',
                        child: Row(
                          children: [
                            Icon(Icons.delete_sweep_outlined, color: Colors.white70, size: 18),
                            SizedBox(width: 8),
                            Text('Clear Chat', style: TextStyle(color: Colors.white)),
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
                    const PopupMenuItem(
                      value: 'wallpaper',
                      child: Row(
                        children: [
                          Icon(Icons.wallpaper, color: Colors.white70, size: 18),
                          SizedBox(width: 8),
                          Text('Wallpaper', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(height: 1),
                    const PopupMenuItem(
                      value: 'clear',
                      child: Row(
                        children: [
                          Icon(Icons.delete_sweep_outlined, color: Colors.white70, size: 18),
                          SizedBox(width: 8),
                          Text('Clear Chat', style: TextStyle(color: Colors.white)),
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
                  ];
            },
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
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F0F),
                image: _wallpaperPath != null && _wallpaperPath!.isNotEmpty
                    ? DecorationImage(
                        image: FileImage(File(_wallpaperPath!)),
                        fit: BoxFit.cover,
                        opacity: 0.18,
                      )
                    : null,
              ),
              child: Builder(
                builder: (context) {
                  if (_isLoadingLocal) {
                    return const Center(child: CircularProgressIndicator());
                  }

                final displayMessages = _localMessages.where((m) {
                  final deletedForList = m['deletedFor'] as List<dynamic>? ?? [];
                  final isNotDeleted = !deletedForList.contains(myId);
                  if (isNotDeleted && _isSearchActive && _searchQuery.isNotEmpty) {
                    final text = (m['text'] as String?)?.toLowerCase() ?? '';
                    return text.contains(_searchQuery.toLowerCase());
                  }
                  return isNotDeleted;
                }).toList();

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    if (!_hasInitialScrolled) {
                      _hasInitialScrolled = true;
                      
                      int unreadIndex = -1;
                      if (_lastSeenTime != null) {
                        for (int i = 0; i < displayMessages.length; i++) {
                          final msg = displayMessages[i];
                          final createdAtStr = msg['createdAt'] as String?;
                          if (createdAtStr != null) {
                            final parsed = DateTime.tryParse(createdAtStr);
                            if (parsed != null && parsed.isAfter(_lastSeenTime!) && msg['senderId'] != myId) {
                              unreadIndex = i;
                              break;
                            }
                          }
                        }
                      }
                      
                      if (unreadIndex != -1) {
                        final maxScroll = _scrollController.position.maxScrollExtent;
                        final targetOffset = (unreadIndex / displayMessages.length) * maxScroll;
                        _scrollController.jumpTo(targetOffset.clamp(0.0, maxScroll));
                      } else {
                        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                      }
                    }
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

                    DateTime? parsedDate;
                    String timeStr = '';
                    if (createdAtStr != null) {
                      try {
                        parsedDate = DateTime.parse(createdAtStr).toLocal();
                        final hour = parsedDate.hour;
                        final minute = parsedDate.minute.toString().padLeft(2, '0');
                        final period = hour >= 12 ? 'PM' : 'AM';
                        final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
                        timeStr = '$displayHour:$minute $period';
                      } catch (_) {}
                    }

                    bool showDateHeader = false;
                    if (parsedDate != null) {
                      if (index == 0) {
                        showDateHeader = true;
                      } else {
                        final prevMsg = displayMessages[index - 1];
                        final prevCreatedAtStr = prevMsg['createdAt'] as String?;
                        if (prevCreatedAtStr != null) {
                          try {
                            final prevDate = DateTime.parse(prevCreatedAtStr).toLocal();
                            showDateHeader = prevDate.year != parsedDate.year ||
                                prevDate.month != parsedDate.month ||
                                prevDate.day != parsedDate.day;
                          } catch (_) {
                            showDateHeader = true;
                          }
                        } else {
                          showDateHeader = true;
                        }
                      }
                    }

                    final isDeleted = msg['isDeleted'] as bool? ?? false;
                    final isSelected = _selectedMessageIds.contains(msg['id']);

                    Widget messageWidget = SwipeTo(
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
                              _selectedMessageIds.add(msg['id']);
                            });
                          }
                        },
                        onTap: () {
                          if (_selectedMessageIds.isNotEmpty) {
                            setState(() {
                              if (_selectedMessageIds.contains(msg['id'])) {
                                _selectedMessageIds.remove(msg['id']);
                              } else if (!isDeleted) {
                                _selectedMessageIds.add(msg['id']);
                              }
                            });
                          }
                        },
                        child: Container(
                          color: isSelected ? const Color(0xFF00A884).withOpacity(0.3) : Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                          child: Align(
                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: mediaType == 'sticker' && !isDeleted
                                ? _buildStickerMessage(msg, isMe, timeStr, received)
                                : Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: (isDeleted || (text != null && text.trim().isNotEmpty) || (mediaType != 'image' && mediaType != 'video'))
                                          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                                          : EdgeInsets.zero,
                                      decoration: BoxDecoration(
                                        color: isDeleted 
                                            ? Colors.transparent 
                                            : (isMe 
                                                ? (isDark ? const Color(0xFF7E1C31) : const Color(0xFFFFD2D2))
                                                : (isDark ? const Color(0xFF262626) : const Color(0xFFEAEAEA))),
                                        border: isDeleted ? Border.all(color: isDark ? Colors.white24 : Colors.black12, width: 1) : null,
                                        borderRadius: BorderRadius.only(
                                          topLeft: const Radius.circular(16),
                                          topRight: const Radius.circular(16),
                                          bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
                                          bottomRight: isMe ? Radius.zero : const Radius.circular(16),
                                        ),
                                      ),
                                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                               child: IntrinsicWidth(
                                 child: Column(
                                   crossAxisAlignment: CrossAxisAlignment.end,
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                     if (msg['replyToMessageId'] != null)
                                       _buildReplyBubble(msg, myId),
                                     if (isDeleted)
                                       Row(
                                         mainAxisSize: MainAxisSize.min,
                                         children: [
                                           Icon(Icons.block, color: isDark ? Colors.white30 : Colors.black38, size: 16),
                                           const SizedBox(width: 6),
                                           Text('This message was deleted', style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontStyle: FontStyle.italic)),
                                         ],
                                       )
                                     else ...[
                                       if (widget.isGroup && !isMe)
                                         Align(
                                           alignment: Alignment.topLeft,
                                           child: Padding(
                                             padding: EdgeInsets.only(
                                               bottom: 6,
                                               left: (text == null || text.trim().isEmpty) && (mediaType == 'image' || mediaType == 'video') ? 12 : 0,
                                               top: (text == null || text.trim().isEmpty) && (mediaType == 'image' || mediaType == 'video') ? 8 : 0,
                                               right: 12,
                                             ),
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
                                             messageId: msg['id'],
                                             deleteFromServer: false,
                                           )
                                         else if (text == null || text.trim().isEmpty)
                                           Stack(
                                             children: [
                                               ClipRRect(
                                                 borderRadius: BorderRadius.only(
                                                   topLeft: const Radius.circular(20),
                                                   topRight: const Radius.circular(20),
                                                   bottomLeft: isMe ? const Radius.circular(20) : Radius.zero,
                                                   bottomRight: isMe ? Radius.zero : const Radius.circular(20),
                                                 ),
                                                 child: msg['isPending'] == true && msg['mediaFilePath'] != null
                                                     ? (mediaType == 'image'
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
                                                                 VideoThumbnailView(
                                                                   videoPath: msg['mediaFilePath'],
                                                                   width: 200,
                                                                   height: 200,
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
                                                           ))
                                                     : GestureDetector(
                                                          onTap: mediaType == 'image'
                                                              ? () {
                                                                  Navigator.push(
                                                                    context,
                                                                    MaterialPageRoute(
                                                                      builder: (context) => ChatImageViewerPage(
                                                                        url: mediaUrl,
                                                                        localPath: msg['mediaFilePath'],
                                                                      ),
                                                                    ),
                                                                  );
                                                                }
                                                              : null,
                                                          child: CachedMediaView(
                                                            url: mediaUrl!,
                                                            mediaType: mediaType,
                                                            chatId: widget.chatId,
                                                            messageId: msg['id'],
                                                            deleteFromServer: false,
                                                            width: 200,
                                                            height: 200,
                                                          ),
                                                        ),
                                               ),
                                               Positioned(
                                                 bottom: 8,
                                                 right: 8,
                                                 child: Container(
                                                   padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                   decoration: BoxDecoration(
                                                     color: Colors.black.withOpacity(0.5),
                                                     borderRadius: BorderRadius.circular(10),
                                                   ),
                                                   child: Row(
                                                     mainAxisSize: MainAxisSize.min,
                                                     children: [
                                                       if (msg['is_pinned'] == true)
                                                         const Padding(
                                                           padding: EdgeInsets.only(right: 4),
                                                           child: Icon(Icons.push_pin, size: 10, color: Colors.white70),
                                                         ),
                                                       Text(
                                                         timeStr,
                                                         style: const TextStyle(color: Colors.white, fontSize: 9),
                                                       ),
                                                       if (isMe) ...[
                                                         const SizedBox(width: 4),
                                                         Icon(
                                                            msg['isPending'] == true 
                                                                ? Icons.access_time 
                                                                : ((msg['seen'] == true || msg['status'] == 'read' || msg['status'] == 'seen' || msg['received'] == true || msg['status'] == 'delivered' || msg['status'] == 'received') ? Icons.done_all : Icons.done),
                                                            size: 13,
                                                            color: msg['isPending'] == true 
                                                                ? Colors.white38 
                                                                : ((msg['seen'] == true || msg['status'] == 'read' || msg['status'] == 'seen')
                                                                    ? const Color(0xFF53BDEB) 
                                                                    : ((msg['received'] == true || msg['status'] == 'delivered' || msg['status'] == 'received') ? Colors.white70 : Colors.white38)),
                                                          ),
                                                       ],
                                                     ],
                                                   ),
                                                 ),
                                               ),
                                             ],
                                           )
                                         else ...[
                                           if (msg['isPending'] == true && msg['mediaFilePath'] != null)
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
                                              GestureDetector(
                                                onTap: mediaType == 'image'
                                                    ? () {
                                                        Navigator.push(
                                                          context,
                                                          MaterialPageRoute(
                                                            builder: (context) => ChatImageViewerPage(
                                                              url: mediaUrl,
                                                              localPath: msg['mediaFilePath'],
                                                            ),
                                                          ),
                                                        );
                                                      }
                                                    : null,
                                                child: CachedMediaView(
                                                  url: mediaUrl!,
                                                  mediaType: mediaType,
                                                  chatId: widget.chatId,
                                                  messageId: msg['id'],
                                                  deleteFromServer: false,
                                                  width: 200,
                                                  height: 200,
                                                ),
                                              ),
                                           const SizedBox(height: 6),
                                         ],
                                       ],
                                       if (text != null && text.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(left: 6, right: 6, top: 4, bottom: 2),
                                            child: Text(
                                              text,
                                              style: TextStyle(
                                                color: isDark ? Colors.white : Colors.black87,
                                                fontSize: 15,
                                                height: 1.3,
                                              ),
                                            ),
                                          ),
                                     ],
                                     if (isDeleted || (text != null && text.trim().isNotEmpty) || (mediaType != 'image' && mediaType != 'video')) ...[
                                       const SizedBox(height: 2),
                                       Padding(
                                         padding: const EdgeInsets.only(left: 20, right: 4, bottom: 2),
                                         child: Row(
                                           mainAxisAlignment: MainAxisAlignment.end,
                                           mainAxisSize: MainAxisSize.min,
                                           children: [
                                             if (msg['is_pinned'] == true)
                                               Padding(
                                                 padding: const EdgeInsets.only(right: 4),
                                                 child: Icon(Icons.push_pin, size: 10, color: isDark ? Colors.white30 : Colors.black38),
                                               ),
                                             Text(
                                               timeStr,
                                               style: TextStyle(color: isDark ? Colors.white38 : Colors.black45, fontSize: 10),
                                             ),
                                             if (isMe) ...[
                                               const SizedBox(width: 4),
                                               Icon(
                                                 msg['isPending'] == true 
                                                     ? Icons.access_time 
                                                     : (msg['seen'] == true || msg['received'] == true ? Icons.done_all : Icons.done),
                                                 size: 13,
                                                 color: msg['isPending'] == true 
                                                     ? (isDark ? Colors.white38 : const Color(0xFF667781))
                                                     : (msg['seen'] == true 
                                                         ? const Color(0xFF53BDEB) 
                                                         : (msg['received'] == true 
                                                             ? (isDark ? Colors.white60 : const Color(0xFF667781)) 
                                                             : (isDark ? Colors.white24 : const Color(0xFF8696A0)))),
                                               ),
                                             ],
                                           ],
                                         ),
                                       ),
                                     ],
                                   ],
                                 ),
                               ),
                            ),
                          ),
                        ),
                      ),
                    );

                    if (showDateHeader && parsedDate != null) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildDateHeader(_getDateHeaderText(parsedDate), isDark),
                          messageWidget,
                        ],
                      );
                    }

                    return messageWidget;
                  },
                );
              },
            ),
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
                  color: isDark ? const Color(0xFF121212) : Colors.white,
                  child: !_canSendMessages
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: Text(
                              'Only admins can send messages to this group.',
                              style: TextStyle(color: subColor, fontSize: 14, fontStyle: FontStyle.italic),
                            ),
                          ),
                        )
                      : _previewAudioPath != null
                          ? Row(
                              children: [
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: _togglePreviewPlay,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      _isPlayingPreview ? Icons.pause : Icons.play_arrow,
                                      color: const Color(0xFF00BFFF),
                                      size: 24,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: _previewDuration.inMilliseconds > 0
                                          ? _previewPosition.inMilliseconds / _previewDuration.inMilliseconds
                                          : 0.0,
                                      backgroundColor: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
                                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00BFFF)),
                                      minHeight: 6,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _formatDuration(_previewPosition) + ' / ' + _formatDuration(_previewDuration),
                                  style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 13, fontFamily: 'monospace'),
                                ),
                                const SizedBox(width: 12),
                                GestureDetector(
                                  onTap: _cancelPreview,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: _sendPreviewRecording,
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
                      : _isRecording
                          ? Row(
                          children: [
                            const SizedBox(width: 8),
                            Icon(
                              _isPaused ? Icons.pause_circle_filled : Icons.fiber_manual_record,
                              color: _isPaused ? Colors.yellowAccent : Colors.redAccent,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isPaused ? 'Paused... $_recordingDurationStr' : 'Recording... $_recordingDurationStr',
                              style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 15, fontWeight: FontWeight.w500),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _isPaused ? _resumeRecording : _pauseRecording,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _isPaused ? Colors.yellowAccent.withValues(alpha: 0.15) : (isDark ? Colors.white10 : Colors.black.withOpacity(0.05)),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _isPaused ? Colors.yellowAccent : Colors.transparent,
                                    width: 1,
                                  ),
                                ),
                                child: Icon(
                                  _isPaused ? Icons.play_arrow : Icons.pause,
                                  color: _isPaused ? Colors.yellowAccent : (isDark ? Colors.white70 : Colors.black54),
                                  size: 20,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: _cancelRecording,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                              ),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: _stopRecordingAndShowPreview,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFE2C55),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.stop, color: Colors.white, size: 20),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                        )
                      : Row(
                          children: [
                            GestureDetector(
                               onTap: _isBlocked ? null : () => _showCameraOptions(context),
                               child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Icon(Icons.camera_alt, color: isDark ? Colors.white70 : Colors.black54, size: 28),
                              ),
                            ),
                            GestureDetector(
                              onTap: _isBlocked ? null : _sendImage,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 4, right: 12),
                                child: Icon(Icons.image, color: subColor, size: 26),
                              ),
                            ),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.only(left: 16, right: 4),
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _messageController,
                                        enabled: !_isBlocked,
                                        onTap: () {
                                          setState(() {
                                            _isStickerPickerActive = false;
                                          });
                                        },
                                        style: TextStyle(color: textColor, fontSize: 15),
                                        maxLines: null,
                                        decoration: InputDecoration(
                                          hintText: _isBlocked ? 'Unblock to chat' : 'Send message...',
                                          hintStyle: TextStyle(color: subColor, fontSize: 15),
                                          border: InputBorder.none,
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: _isBlocked ? null : () {
                                        setState(() {
                                          _isStickerPickerActive = !_isStickerPickerActive;
                                        });
                                        if (_isStickerPickerActive) {
                                          FocusScope.of(context).unfocus();
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        child: Icon(
                                          _isStickerPickerActive ? Icons.keyboard : Icons.emoji_emotions_outlined,
                                          color: _isStickerPickerActive ? const Color(0xFF00BFFF) : subColor,
                                          size: 24,
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
                if (_isStickerPickerActive)
                  StickerPicker(
                    onStickerSelected: _sendSticker,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickerMessage(Map<String, dynamic> msg, bool isMe, String timeStr, bool received) {
    final mediaUrl = msg['mediaUrl'] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isGroup && !isMe)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4),
              child: Text(
                _participantNames[msg['senderId']] ?? 'User',
                style: TextStyle(
                  color: Colors.cyanAccent.shade400,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          GestureDetector(
            onTap: () => _showStickerOptions(msg),
            child: Stack(
              children: [
                Container(
                  width: 130,
                  height: 130,
                  padding: const EdgeInsets.all(4),
                  child: mediaUrl != null
                      ? (mediaUrl.startsWith('emoji:')
                          ? Center(
                              child: Text(
                                mediaUrl.substring(6),
                                style: const TextStyle(fontSize: 80),
                              ),
                            )
                          : (mediaUrl.startsWith('assets/')
                              ? Image.asset(mediaUrl, fit: BoxFit.contain)
                              : Image.network(
                                  mediaUrl,
                                  fit: BoxFit.contain,
                                  loadingBuilder: (context, child, progress) {
                                    if (progress == null) return child;
                                    return const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF), strokeWidth: 1.5));
                                  },
                                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white24, size: 40),
                                )))
                      : const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF), strokeWidth: 1.5)),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          timeStr,
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                         if (isMe) ...[
                          const SizedBox(width: 4),
                          Icon(
                            msg['isPending'] == true 
                                ? Icons.access_time 
                                : ((msg['seen'] == true || msg['status'] == 'read' || msg['status'] == 'seen' || msg['received'] == true || msg['status'] == 'delivered' || msg['status'] == 'received') ? Icons.done_all : Icons.done),
                            color: msg['isPending'] == true 
                                ? Colors.white38 
                                : ((msg['seen'] == true || msg['status'] == 'read' || msg['status'] == 'seen')
                                    ? const Color(0xFF53BDEB) 
                                    : ((msg['received'] == true || msg['status'] == 'delivered' || msg['status'] == 'received') ? Colors.white70 : Colors.white30)),
                            size: 11,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showStickerOptions(Map<String, dynamic> msg) {
    final mediaUrl = msg['mediaUrl'] as String?;
    if (mediaUrl == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              const Text(
                'Sticker Options',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.star_border, color: Color(0xFF00BFFF)),
                title: const Text('Add to My Stickers', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  await _saveReceivedSticker(mediaUrl);
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveReceivedSticker(String url) async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      final cached = await LocalStorageService().getCachedJson('custom_stickers_$myId');
      final List<String> customList = cached != null ? List<String>.from(cached as List) : [];
      
      if (!customList.contains(url)) {
        customList.insert(0, url);
        await LocalStorageService().cacheJson('custom_stickers_$myId', customList);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sticker saved to My Stickers!')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sticker is already in your list.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save sticker: $e')),
        );
      }
    }
  }

  Future<void> _sendSticker(String url) async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    final tempId = 'pending_${myId}_${DateTime.now().millisecondsSinceEpoch}';
    final tempMsg = {
      'id': tempId,
      'chatId': widget.chatId,
      'senderId': myId,
      'mediaUrl': url,
      'mediaType': 'sticker',
      'createdAt': DateTime.now().toIso8601String(),
      'received': false,
      'isPending': true,
    };

    setState(() {
      _localMessages.add(tempMsg);
      // Keep sticker picker open (TikTok/WhatsApp style)
    });
    await _saveLocalMessages();
    _scrollToBottom();

    _attemptSendStickerPendingMessage(tempMsg);
  }

  Future<void> _attemptSendStickerPendingMessage(Map<String, dynamic> pendingMsg) async {
    final tempId = pendingMsg['id'];
    if (_sendingMessageIds.contains(tempId)) return;
    _sendingMessageIds.add(tempId);

    try {
      final sent = WebSocketService().sendMessage(
        chatId: widget.chatId,
        recipientId: widget.otherUserId,
        text: "",
        mediaUrl: pendingMsg['mediaUrl'],
        mediaType: 'sticker',
        tempId: tempId,
      );

      if (!sent) {
        _sendingMessageIds.remove(tempId);
        throw Exception('WebSocket client is offline');
      }
    } catch (e) {
      debugPrint('Failed to send pending sticker $tempId: $e');
    }
  }

  void _showWallpaperOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final textColor = isDark ? Colors.white : Colors.black87;
        final iconColor = isDark ? Colors.white70 : Colors.black54;

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Chat Wallpaper',
                    style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.photo_library_outlined, color: iconColor),
                  title: Text('Set for This Chat Only', style: TextStyle(color: textColor)),
                  subtitle: Text('Personal custom wallpaper', style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontSize: 12)),
                  onTap: () async {
                    Navigator.pop(context);
                    final picker = ImagePicker();
                    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
                    if (pickedFile != null) {
                      await LocalStorageService().setString('chat_wallpaper_${widget.chatId}', pickedFile.path);
                      _loadWallpaper();
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.wallpaper, color: iconColor),
                  title: Text('Set as General Wallpaper (All Chats)', style: TextStyle(color: textColor)),
                  subtitle: Text('Default wallpaper for all chats', style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontSize: 12)),
                  onTap: () async {
                    Navigator.pop(context);
                    final picker = ImagePicker();
                    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
                    if (pickedFile != null) {
                      await LocalStorageService().setString('chat_wallpaper_general_default', pickedFile.path);
                      _loadWallpaper();
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.group_work_outlined, color: iconColor),
                  title: Text('Set as Group Wallpaper (All Groups)', style: TextStyle(color: textColor)),
                  subtitle: Text('Default wallpaper for all group chats', style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontSize: 12)),
                  onTap: () async {
                    Navigator.pop(context);
                    final picker = ImagePicker();
                    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
                    if (pickedFile != null) {
                      await LocalStorageService().setString('chat_wallpaper_group_default', pickedFile.path);
                      _loadWallpaper();
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Remove Personal Wallpaper (This Chat)', style: TextStyle(color: Colors.redAccent)),
                  onTap: () async {
                    Navigator.pop(context);
                    await LocalStorageService().remove('chat_wallpaper_${widget.chatId}');
                    _loadWallpaper();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
                  title: const Text('Remove General Wallpaper (All Chats)', style: TextStyle(color: Colors.redAccent)),
                  onTap: () async {
                    Navigator.pop(context);
                    await LocalStorageService().remove('chat_wallpaper_general_default');
                    _loadWallpaper();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
                  title: const Text('Remove Group Wallpaper (All Groups)', style: TextStyle(color: Colors.redAccent)),
                  onTap: () async {
                    Navigator.pop(context);
                    await LocalStorageService().remove('chat_wallpaper_group_default');
                    _loadWallpaper();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class AudioMessagePlayer extends StatefulWidget {
  final String? url;
  final String? localFilePath;
  final String? messageId;
  final bool deleteFromServer;

  const AudioMessagePlayer({
    super.key,
    this.url,
    this.localFilePath,
    this.messageId,
    this.deleteFromServer = false,
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
      String? playPath = widget.localFilePath;

      if (playPath == null && widget.url != null) {
        final file = await LocalStorageService().getCachedFile(
          widget.url!,
          ttl: const Duration(hours: 48),
        );
        playPath = file.path;

        if (widget.deleteFromServer && widget.messageId != null && mounted) {
          context.read<SupabaseService>().deleteMessageFromServer(widget.messageId!, deleteStorage: true);
        }
      }

      if (playPath != null) {
        await _audioPlayer.setSource(DeviceFileSource(playPath));
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

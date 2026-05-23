import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:video_player/video_player.dart';
import 'package:reel/pages/updates/add_story_screen.dart';

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  
  List<dynamic> _statuses = [];
  List<dynamic> _channels = [];
  Map<String, bool> _subscribedChannels = {}; // Keep track of channel subscriptions
  bool _loadingStatuses = true;
  bool _loadingChannels = true;
  bool _uploadingStatus = false;

  @override
  void initState() {
    super.initState();
    _loadAllUpdates();
  }

  void _loadAllUpdates() {
    _loadStatuses();
    _loadChannels();
  }

  Future<void> _loadStatuses() async {
    final supabase = context.read<SupabaseService>();
    try {
      final statuses = await supabase.getActiveStatuses();
      if (mounted) {
        setState(() {
          _statuses = statuses;
          _loadingStatuses = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingStatuses = false);
    }
  }

  Future<void> _loadChannels() async {
    final supabase = context.read<SupabaseService>();
    try {
      final channels = await supabase.getChannels();
      
      // Load user subscription status for each channel
      final subscriptions = <String, bool>{};
      for (var chan in channels) {
        final isSub = await supabase.isSubscribedToChannel(chan['id'] as String);
        subscriptions[chan['id'] as String] = isSub;
      }

      if (mounted) {
        setState(() {
          _channels = channels;
          _subscribedChannels = subscriptions;
          _loadingChannels = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  // Helper to choose media source
  void _openStoryPicker() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddStoryScreen()),
    );
    if (result == true) {
      _loadStatuses();
    }
  }

  // Open "Create Channel" input dialog
  void _showCreateChannelDialog() {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Create New Channel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Channel Name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;

              final supabase = context.read<SupabaseService>();
              try {
                await supabase.createChannel(name);
                if (context.mounted) {
                  Navigator.pop(context);
                  _loadChannels(); // Refresh channel feed
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to create channel: ${e.toString()}')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).primaryColor),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  // Toggle channel subscription status
  Future<void> _toggleChannelSubscription(String channelId) async {
    final supabase = context.read<SupabaseService>();
    final currentSub = _subscribedChannels[channelId] ?? false;

    try {
      if (currentSub) {
        await supabase.unfollowChannel(channelId);
      } else {
        await supabase.followChannel(channelId);
      }
      setState(() {
        _subscribedChannels[channelId] = !currentSub;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Updates', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _loadAllUpdates();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 12.0),
                child: Text(
                  'Stories',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                ),
              ),
              // Horizontal TikTok-style Story Bubbles
              SizedBox(
                height: 110,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    // TikTok "Add Story" My Status Bubble
                    GestureDetector(
                      onTap: _uploadingStatus ? null : _openStoryPicker,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Stack(
                              children: [
                                _uploadingStatus
                                    ? Container(
                                        width: 64,
                                        height: 64,
                                        decoration: const BoxDecoration(
                                          color: Colors.white10,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Center(
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                                          ),
                                        ),
                                      )
                                    : Container(
                                        padding: const EdgeInsets.all(3),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white24, width: 2),
                                        ),
                                        child: UserAvatar(
                                          userId: context.read<SupabaseService>().currentUser?.id ?? '',
                                          radius: 27,
                                        ),
                                      ),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF00BFFF),
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    child: const Icon(Icons.add, color: Colors.white, size: 14),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'My Story',
                              style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Recent Statuses
                    if (_loadingStatuses)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20),
                          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF))),
                        ),
                      )
                    else if (_statuses.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Text('No recent updates', style: TextStyle(color: Colors.white38, fontSize: 12)),
                        ),
                      )
                    else
                      ..._statuses.map((status) {
                        final userName = status['userName'] ?? status['username'] ?? 'User';
                        final userId = status['userId'] ?? status['userid'] ?? '';

                        return GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => StatusViewerPage(status: status),
                              ),
                            ).then((_) => _loadStatuses());
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [
                                        Color(0xFFFE2C55), // TikTok Pink
                                        Color(0xFF25F4EE), // TikTok Aqua
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Colors.black,
                                      shape: BoxShape.circle,
                                    ),
                                    child: UserAvatar(
                                      userId: userId,
                                      radius: 25,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: 66,
                                  child: Text(
                                    userName,
                                    style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 40),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Channels',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: Icon(Icons.add, color: primaryColor),
                      onPressed: _showCreateChannelDialog,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Channels Horizontal List
              _loadingChannels
                  ? const Center(child: CircularProgressIndicator())
                  : _channels.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text('No channels created yet. Tap + to build yours!', style: TextStyle(color: Colors.white38)),
                        )
                      : SizedBox(
                          height: 180,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _channels.length,
                            itemBuilder: (context, index) {
                              final chan = _channels[index];
                              final chanId = chan['id'] as String;
                              final name = chan['name'] ?? 'Channel';
                              final isSubscribed = _subscribedChannels[chanId] ?? false;

                              return Container(
                                width: 140,
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      radius: 30,
                                      backgroundColor: Colors.grey[800],
                                      child: const Icon(Icons.people, size: 30, color: Colors.white54),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      name,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton(
                                        onPressed: () => _toggleChannelSubscription(chanId),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isSubscribed
                                              ? Colors.white12
                                              : primaryColor.withOpacity(0.1),
                                          foregroundColor: isSubscribed ? Colors.white70 : primaryColor,
                                          elevation: 0,
                                          padding: EdgeInsets.zero,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                        ),
                                        child: Text(
                                          isSubscribed ? 'Following' : 'Follow',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// Fullscreen Status Viewer Widget
class StatusViewerPage extends StatefulWidget {
  final Map<String, dynamic> status;

  const StatusViewerPage({super.key, required this.status});

  @override
  State<StatusViewerPage> createState() => _StatusViewerPageState();
}

class _StatusViewerPageState extends State<StatusViewerPage> {
  final TextEditingController _replyController = TextEditingController();
  List<dynamic> _viewers = [];
  bool _isPlayingVoice = false;

  // Video playback controller
  VideoPlayerController? _videoController;
  bool _videoInitialized = false;
  bool _videoHasError = false;

  @override
  void initState() {
    super.initState();
    _markAsViewed();
    _loadViewers();
    _initializeVideoIfNeeded();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  void _initializeVideoIfNeeded() {
    final imageUrl = (widget.status['imageUrl'] ?? widget.status['imageurl']) as String?;
    String mediaType = (widget.status['mediaType'] ?? widget.status['mediatype'] ?? 'image') as String;
    if (imageUrl != null && imageUrl.toLowerCase().contains('.mp4')) {
      mediaType = 'video';
    }

    if (imageUrl != null && imageUrl.isNotEmpty && mediaType == 'video') {
      try {
        _videoController = VideoPlayerController.networkUrl(Uri.parse(imageUrl))
          ..initialize().then((_) {
            if (mounted) {
              setState(() {
                _videoInitialized = true;
              });
              _videoController?.play();
              _videoController?.setLooping(true);
            }
          }).catchError((err) {
            debugPrint('Error loading video status: $err');
            if (mounted) {
              setState(() {
                _videoHasError = true;
              });
            }
          });
      } catch (e) {
        debugPrint('Exception initializing video: $e');
        setState(() {
          _videoHasError = true;
        });
      }
    }
  }

  Future<void> _markAsViewed() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    final statusUserId = widget.status['userId'] ?? widget.status['userid'];
    if (myId != null && statusUserId != myId) {
      await supabase.viewStatus((widget.status['id'] ?? '').toString());
    }
  }

  Future<void> _loadViewers() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    final statusUserId = widget.status['userId'] ?? widget.status['userid'];
    if (myId != null && statusUserId == myId) {
      final viewers = await supabase.getStatusViews((widget.status['id'] ?? '').toString());
      setState(() {
        _viewers = viewers;
      });
    }
  }

  void _showViewersBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[950],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  '👁️ ${_viewers.length} Views',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: _viewers.isEmpty
                    ? const Center(
                        child: Text('No views yet', style: TextStyle(color: Colors.white38)),
                      )
                    : ListView.builder(
                        itemCount: _viewers.length,
                        itemBuilder: (context, index) {
                          final viewer = _viewers[index];
                          final userDoc = viewer['users'] as Map<String, dynamic>? ?? {};
                          final viewerName = userDoc['name'] ?? 'User';
                          final viewerId = userDoc['id'] ?? '';

                          return ListTile(
                            leading: UserAvatar(userId: viewerId, radius: 18),
                            title: Text(viewerName, style: const TextStyle(color: Colors.white)),
                            subtitle: const Text('Viewed status', style: TextStyle(color: Colors.white38, fontSize: 12)),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendPrivateReply() async {
    final replyText = _replyController.text.trim();
    if (replyText.isEmpty) return;

    final supabase = context.read<SupabaseService>();
    final otherUserId = (widget.status['userId'] ?? widget.status['userid']) as String;
    final otherUserName = (widget.status['userName'] ?? widget.status['username'] ?? 'User') as String;

    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      final chatId = await supabase.createOrGetChat(otherUserId);
      
      // Send secure text message referring to status
      final fullMsg = "Replied to status: \"$replyText\"";
      await supabase.sendMessage(chatId: chatId, text: fullMsg);

      if (mounted) {
        Navigator.pop(context); // Pop spinner
        _replyController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Private reply sent to $otherUserName!')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Pop spinner
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.grey[950],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Mutual Friends Only', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(
              'Snapchat Rules: Both you and $otherUserName must follow each other to send private message replies.',
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
    final myId = context.read<SupabaseService>().currentUser?.id;
    final statusUserId = widget.status['userId'] ?? widget.status['userid'];
    final isMe = statusUserId == myId;
    final imageUrl = (widget.status['imageUrl'] ?? widget.status['imageurl']) as String?;
    final textContent = widget.status['text'] as String?;
    final voiceUrl = (widget.status['voiceUrl'] ?? widget.status['voiceurl']) as String?;
    final userName = widget.status['userName'] ?? widget.status['username'] ?? 'User';
    String mediaType = (widget.status['mediaType'] ?? widget.status['mediatype'] ?? 'image') as String;
    if (imageUrl != null && imageUrl.toLowerCase().contains('.mp4')) {
      mediaType = 'video';
    }
    final posterId = statusUserId ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            UserAvatar(userId: posterId, radius: 18),
            const SizedBox(width: 10),
            Text(userName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          if (isMe)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onSelected: (value) async {
                if (value == 'delete') {
                  final statusId = (widget.status['id'] ?? '').toString();
                  try {
                    await context.read<SupabaseService>().deleteStatus(statusId);
                    if (mounted) {
                      Navigator.pop(context, true); // Pop the viewer
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Status deleted')));
                    }
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete status')));
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                      SizedBox(width: 8),
                      Text('Delete Status', style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 1. Background image or video if set
                  if (imageUrl != null && imageUrl.isNotEmpty)
                    Positioned.fill(
                      child: mediaType == 'video'
                          ? _videoInitialized
                              ? GestureDetector(
                                  onTap: () {
                                    if (_videoController != null) {
                                      if (_videoController!.value.isPlaying) {
                                        _videoController!.pause();
                                      } else {
                                        _videoController!.play();
                                      }
                                      setState(() {});
                                    }
                                  },
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Positioned.fill(
                                        child: Center(
                                          child: AspectRatio(
                                            aspectRatio: _videoController!.value.aspectRatio,
                                            child: VideoPlayer(_videoController!),
                                          ),
                                        ),
                                      ),
                                      if (_videoController != null && !_videoController!.value.isPlaying)
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: const BoxDecoration(
                                            color: Colors.black45,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
                                        ),
                                    ],
                                  ),
                                )
                              : _videoHasError
                                  ? const Center(
                                      child: Text(
                                        'Error playing video',
                                        style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                                      ),
                                    )
                                  : const Center(
                                      child: CircularProgressIndicator(color: Color(0xFF00BFFF)),
                                    )
                          : Image.network(imageUrl, fit: BoxFit.cover),
                    ),
                  // 2. High-contrast premium text overlay
                  if (textContent != null && textContent.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      color: imageUrl == null ? Colors.deepPurple[900] : Colors.black45,
                      alignment: Alignment.center,
                      child: Text(
                        textContent,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  // 3. Audio/Voice status message player
                  if (voiceUrl != null && voiceUrl.isNotEmpty)
                    Positioned(
                      bottom: 40,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                _isPlayingVoice ? Icons.pause_circle_filled : Icons.play_circle_filled,
                                color: const Color(0xFF00BFFF),
                                size: 36,
                              ),
                              onPressed: () {
                                setState(() {
                                  _isPlayingVoice = !_isPlayingVoice;
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Voice Update',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 12),
                            Row(
                              children: List.generate(5, (index) {
                                return Container(
                                  width: 3,
                                  height: _isPlayingVoice ? (10 + (index * 4)) : 8,
                                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                                  color: const Color(0xFF00BFFF),
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (isMe)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  onPressed: _showViewersBottomSheet,
                  icon: const Icon(Icons.remove_red_eye_outlined),
                  label: Text('Viewed by ${_viewers.length} friends'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                ),
              ),
            )
          else
            SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.grey[950],
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _replyController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Reply to status privately...',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Color(0xFF00BFFF)),
                      onPressed: _sendPrivateReply,
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

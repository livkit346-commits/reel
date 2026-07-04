import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/pages/updates/add_story_screen.dart';
import 'package:reel/widgets/status_ring_painter.dart';
import 'package:reel/pages/updates/status_viewer_screen.dart';
import 'package:reel/pages/updates/text_status_editor_screen.dart';

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  
  List<Map<String, dynamic>> _userStatusGroups = [];
  List<dynamic> _myStatuses = [];
  List<dynamic> _channels = [];
  Map<String, bool> _subscribedChannels = {}; // Keep track of channel subscriptions
  bool _loadingStatuses = true;
  bool _loadingChannels = true;
  bool _uploadingStatus = false;

  @override
  void initState() {
    super.initState();
    _loadAllUpdates();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SupabaseService>().statusUploadProgress.addListener(_onUploadProgressChanged);
    });
  }

  @override
  void dispose() {
    try {
      context.read<SupabaseService>().statusUploadProgress.removeListener(_onUploadProgressChanged);
    } catch (_) {}
    super.dispose();
  }

  void _onUploadProgressChanged() {
    if (mounted) {
      final progress = context.read<SupabaseService>().statusUploadProgress.value;
      setState(() {
        _uploadingStatus = progress != null;
      });
      if (progress == null) {
        _loadStatuses();
      }
    }
  }

  void _loadAllUpdates() {
    _loadStatuses();
    _loadChannels();
    LocalStorageService().runLocalCleanup(); // WhatsApp-style automatic background cleanup of expired files
  }

  Future<void> _loadStatuses() async {
    final supabase = context.read<SupabaseService>();
    try {
      final statuses = await supabase.getActiveStatuses();
      final viewedStatusIds = await supabase.getViewedStatusIds();
      
      final Map<String, List<dynamic>> groupedMap = {};
      final Map<String, String> userNames = {};
      
      for (var status in statuses) {
        final userId = status['userId'] ?? status['userid'];
        if (userId == null) continue;
        
        userNames[userId] = status['userName'] ?? status['username'] ?? 'User';
        
        if (!groupedMap.containsKey(userId)) {
          groupedMap[userId] = [];
        }
        groupedMap[userId]!.add(status);
      }
      
      final List<Map<String, dynamic>> groupedList = [];
      List<dynamic> myStatuses = [];
      final myId = supabase.currentUser?.id;

      for (var entry in groupedMap.entries) {
        final userId = entry.key;
        final userStatuses = entry.value;
        
        // Sort user's statuses from oldest to newest (WhatsApp style play order)
        userStatuses.sort((a, b) {
          final dateA = DateTime.parse(a['createdAt']);
          final dateB = DateTime.parse(b['createdAt']);
          return dateA.compareTo(dateB);
        });

        // Compute viewed count for this user
        int viewedCount = 0;
        for (var status in userStatuses) {
          final statusId = (status['id'] ?? '').toString();
          if (viewedStatusIds.contains(statusId)) {
            viewedCount++;
          }
        }
        
        if (userId == myId) {
          myStatuses = userStatuses;
          continue;
        }

        groupedList.add({
          'userId': userId,
          'userName': userNames[userId],
          'statuses': userStatuses,
          'viewedCount': viewedCount,
          'isFullyViewed': viewedCount == userStatuses.length,
          'latestUpdate': userStatuses.last['createdAt'], // For sorting users
        });
      }
      
      // Sort users by unviewed first, viewed last, then chronological descending
      groupedList.sort((a, b) {
        final isFullyViewedA = a['isFullyViewed'] as bool;
        final isFullyViewedB = b['isFullyViewed'] as bool;

        if (isFullyViewedA != isFullyViewedB) {
          return isFullyViewedA ? 1 : -1; // unviewed (false) comes first
        }

        final dateA = DateTime.parse(a['latestUpdate']);
        final dateB = DateTime.parse(b['latestUpdate']);
        return dateB.compareTo(dateA);
      });

      if (mounted) {
        setState(() {
          _userStatusGroups = groupedList;
          _myStatuses = myStatuses;
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

  void _openTextStatusEditor() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const TextStatusEditorScreen()),
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white38 : Colors.black45;
    final cardBgColor = isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05);
    final borderColor = isDark ? Colors.white12 : Colors.black12;
    final scaffoldBgColor = isDark ? Colors.black : Colors.white;

    return Scaffold(
      backgroundColor: scaffoldBgColor,
      appBar: AppBar(
        backgroundColor: scaffoldBgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: Text('Updates', style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 12.0),
                child: Text(
                  'Stories',
                  style: TextStyle(color: textColor, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5),
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
                      onTap: _uploadingStatus
                          ? null
                          : () {
                              if (_myStatuses.isNotEmpty) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => StatusViewerPage(
                                      statuses: _myStatuses.cast<Map<String, dynamic>>(),
                                    ),
                                  ),
                                ).then((_) => _loadStatuses());
                              } else {
                                _openStoryPicker();
                              }
                            },
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
                                        child: Center(
                                          child: SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 3,
                                              color: const Color(0xFF00BFFF),
                                              value: context.read<SupabaseService>().statusUploadProgress.value,
                                            ),
                                          ),
                                        ),
                                      )
                                    : (_myStatuses.isNotEmpty
                                        ? CustomPaint(
                                            painter: StatusRingPainter(
                                              statusCount: _myStatuses.length,
                                              viewedCount: 0,
                                              unviewedColor: const Color(0xFF00A884), // WhatsApp Green
                                              viewedColor: Colors.grey,
                                            ),
                                            child: Container(
                                              padding: const EdgeInsets.all(5),
                                              child: UserAvatar(
                                                userId: context.read<SupabaseService>().currentUser?.id ?? '',
                                                radius: 25,
                                              ),
                                            ),
                                          )
                                        : Container(
                                            padding: const EdgeInsets.all(3),
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(color: borderColor, width: 2),
                                            ),
                                            child: UserAvatar(
                                              userId: context.read<SupabaseService>().currentUser?.id ?? '',
                                              radius: 27,
                                            ),
                                          )),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: GestureDetector(
                                    onTap: _uploadingStatus ? null : _openStoryPicker,
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF00BFFF),
                                        shape: BoxShape.circle,
                                      ),
                                      padding: const EdgeInsets.all(4),
                                      child: const Icon(Icons.add, color: Colors.white, size: 14),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _uploadingStatus
                                  ? 'Sending (${((context.read<SupabaseService>().statusUploadProgress.value ?? 0.0) * 100).toStringAsFixed(0)}%)'
                                  : 'My Story',
                              style: TextStyle(
                                color: _uploadingStatus ? const Color(0xFF00BFFF) : subtitleColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
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
                    else if (_userStatusGroups.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('No recent updates', style: TextStyle(color: secondaryTextColor, fontSize: 12)),
                        ),
                      )
                    else
                      ..._userStatusGroups.map((group) {
                        final userName = group['userName'];
                        final userId = group['userId'];
                        final List<dynamic> userStatuses = group['statuses'];

                        return GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => StatusViewerPage(
                                  statuses: userStatuses.cast<Map<String, dynamic>>(),
                                ),
                              ),
                            ).then((_) => _loadStatuses());
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                 CustomPaint(
                                  painter: StatusRingPainter(
                                    statusCount: userStatuses.length,
                                    viewedCount: group['viewedCount'] ?? 0,
                                    unviewedColor: const Color(0xFF00A884), // WhatsApp Green
                                    viewedColor: Colors.grey,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(5),
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
                                    style: TextStyle(color: subtitleColor, fontSize: 11, fontWeight: FontWeight.w600),
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
              Divider(color: borderColor, height: 40),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Channels',
                      style: TextStyle(color: textColor, fontSize: 20, fontWeight: FontWeight.bold),
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
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text('No channels created yet. Tap + to build yours!', style: TextStyle(color: secondaryTextColor)),
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
                                  color: cardBgColor,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: borderColor),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      radius: 30,
                                      backgroundColor: isDark ? Colors.grey[800] : Colors.grey[200],
                                      child: Icon(Icons.people, size: 30, color: isDark ? Colors.white54 : Colors.black54),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      name,
                                      style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 13),
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
                                              ? (isDark ? Colors.white12 : Colors.black12)
                                              : primaryColor.withOpacity(0.1),
                                          foregroundColor: isSubscribed ? (isDark ? Colors.white70 : Colors.black87) : primaryColor,
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
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'text_status',
            onPressed: _openTextStatusEditor,
            backgroundColor: isDark ? Colors.grey[800] : Colors.grey[200],
            child: Icon(Icons.edit, color: isDark ? Colors.white70 : Colors.black87),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'media_status',
            onPressed: _openStoryPicker,
            backgroundColor: const Color(0xFF00A884), // WhatsApp Green
            child: const Icon(Icons.camera_alt, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

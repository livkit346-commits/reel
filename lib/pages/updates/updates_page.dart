import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:video_player/video_player.dart';

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  final ImagePicker _picker = ImagePicker();
  
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
  void _showMediaSourcePicker(BuildContext context, StateSetter setModalState, Function(File file, String type) onMediaSelected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[950],
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image, color: Colors.purpleAccent),
                title: const Text('Upload Photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 60);
                  if (picked != null) {
                    onMediaSelected(File(picked.path), 'image');
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: Colors.blueAccent),
                title: const Text('Upload Video', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 30));
                  if (picked != null) {
                    onMediaSelected(File(picked.path), 'video');
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // Upload a new status update
  void _createNewStatus() {
    final textController = TextEditingController();
    File? selectedMedia;
    String? selectedMediaType; // 'image' or 'video'
    File? selectedVoice;
    bool uploadingStatusLocal = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[950],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Add to Story',
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                        ),
                        if (selectedMedia != null || selectedVoice != null)
                          TextButton(
                            onPressed: () => setModalState(() {
                              selectedMedia = null;
                              selectedMediaType = null;
                              selectedVoice = null;
                            }),
                            child: const Text('Reset', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // TikTok style Media Composer Card
                    if (selectedMedia == null && selectedVoice == null)
                      GestureDetector(
                        onTap: () {
                          _showMediaSourcePicker(context, setModalState, (file, type) {
                            setModalState(() {
                              selectedMedia = file;
                              selectedMediaType = type;
                              selectedVoice = null;
                            });
                          });
                        },
                        child: Container(
                          height: 180,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white12, width: 1.5),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00BFFF).withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.add_a_photo_outlined, color: Color(0xFF00BFFF), size: 32),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Tap to add Photos or Videos',
                                style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              const Text('Up to 30 seconds', style: TextStyle(color: Colors.white38, fontSize: 12)),
                            ],
                          ),
                        ),
                      )
                    else if (selectedMedia != null)
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: selectedMediaType == 'video'
                                ? Container(
                                    height: 180,
                                    width: double.infinity,
                                    color: Colors.white.withOpacity(0.04),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFE2C55).withOpacity(0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.video_camera_back, color: Color(0xFFFE2C55), size: 36),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          selectedMedia!.path.split('/').last,
                                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        const Text('Video ready to share', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                      ],
                                    ),
                                  )
                                : Image.file(selectedMedia!, height: 180, width: double.infinity, fit: BoxFit.cover),
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () => setModalState(() {
                                selectedMedia = null;
                                selectedMediaType = null;
                              }),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                child: const Icon(Icons.close, color: Colors.white, size: 18),
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (selectedVoice != null)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: const BoxDecoration(
                                color: Color(0xFF00BFFF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.mic, color: Colors.white, size: 24),
                            ),
                            const SizedBox(width: 16),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Voice story attached',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                  SizedBox(height: 2),
                                  Text('Ready to share', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              onPressed: () => setModalState(() => selectedVoice = null),
                            ),
                          ],
                        ),
                      ),
                    
                    const SizedBox(height: 16),
                    
                    // Stylish Caption field
                    TextField(
                      controller: textController,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: 'Add a caption to your story...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.03),
                        contentPadding: const EdgeInsets.all(16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Quick Actions Row (Voice Story trigger)
                    if (selectedMedia == null && selectedVoice == null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final tempDir = Directory.systemTemp;
                            final voiceFile = File('${tempDir.path}/temp_voice.m4a');
                            await voiceFile.writeAsString('reel_voice_mock_data');
                            setModalState(() {
                              selectedVoice = voiceFile;
                              selectedMedia = null;
                              selectedMediaType = null;
                            });
                          },
                          icon: const Icon(Icons.mic, size: 16),
                          label: const Text('Add Voice Story', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white10,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                        ),
                      ),
                    
                    const SizedBox(height: 24),
                    
                    // TikTok style "Share to Story" gradient button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(25),
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFFFE2C55), // TikTok Pink
                              Color(0xFF25F4EE), // TikTok Aqua
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                        ),
                        child: ElevatedButton(
                          onPressed: uploadingStatusLocal
                              ? null
                              : () async {
                                  final text = textController.text.trim();
                                  if (text.isEmpty && selectedMedia == null && selectedVoice == null) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Please add text, photo, or video for your story.')),
                                    );
                                    return;
                                  }

                                  setModalState(() => uploadingStatusLocal = true);
                                  final supabase = context.read<SupabaseService>();
                                  try {
                                    await supabase.createCustomStatus(
                                      text: text.isNotEmpty ? text : null,
                                      mediaFile: selectedMedia,
                                      mediaType: selectedMediaType,
                                      voiceFile: selectedVoice,
                                    );
                                    _loadStatuses();
                                    if (context.mounted) {
                                      Navigator.pop(context); // Close sheet
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Story posted successfully!')),
                                      );
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Failed to post story: ${e.toString()}')),
                                      );
                                    }
                                  } finally {
                                    setModalState(() => uploadingStatusLocal = false);
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                          ),
                          child: uploadingStatusLocal
                              ? const CircularProgressIndicator(color: Colors.white)
                              : const Text(
                                  'Share to Story',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
                      onTap: _uploadingStatus ? null : _createNewStatus,
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
    final mediaType = (widget.status['mediaType'] ?? widget.status['mediatype'] ?? 'image') as String;

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
    final mediaType = (widget.status['mediaType'] ?? widget.status['mediatype'] ?? 'image') as String;
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

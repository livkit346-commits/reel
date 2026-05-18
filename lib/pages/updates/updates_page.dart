import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';

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

  // Upload a new status update
  Future<void> _createNewStatus() async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 600,
    );

    if (pickedFile != null) {
      setState(() => _uploadingStatus = true);
      final supabase = context.read<SupabaseService>();
      try {
        final profile = await supabase.getUserProfile(supabase.currentUser?.id ?? '');
        final name = profile?['name'] ?? 'User';
        
        await supabase.uploadAndCreateStatus(File(pickedFile.path), name);
        _loadStatuses(); // Reload statuses list
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Status update posted successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to post status: ${e.toString()}')),
          );
        }
      } finally {
        if (mounted) setState(() => _uploadingStatus = false);
      }
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
              } catch (_) {}
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
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Status',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              // My Status Upload Button
              ListTile(
                onTap: _uploadingStatus ? null : _createNewStatus,
                leading: Stack(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.white10,
                      child: _uploadingStatus 
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.person, color: Colors.white54, size: 30),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: primaryColor,
                        child: const Icon(Icons.add, color: Colors.white, size: 14),
                      ),
                    ),
                  ],
                ),
                title: const Text('My status', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text('Tap to add status update', style: TextStyle(color: Colors.white54)),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  'Recent updates',
                  style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              // Recent Status List
              _loadingStatuses
                  ? const Center(child: Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator()))
                  : _statuses.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16.0),
                          child: Text('No active statuses recently', style: TextStyle(color: Colors.white38)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _statuses.length,
                          itemBuilder: (context, index) {
                            final status = _statuses[index];
                            final userName = status['userName'] ?? 'User';
                            final imageUrl = status['imageUrl'] ?? '';
                            final userId = status['userId'] ?? '';

                            return ListTile(
                              onTap: () {
                                // Fullscreen image display for status
                                if (imageUrl.isNotEmpty) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => Scaffold(
                                        backgroundColor: Colors.black,
                                        appBar: AppBar(backgroundColor: Colors.black, elevation: 0),
                                        body: Center(child: Image.network(imageUrl)),
                                      ),
                                    ),
                                  );
                                }
                              },
                              leading: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: primaryColor, width: 2),
                                ),
                                child: CircleAvatar(
                                  radius: 26,
                                  backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=$userId'),
                                ),
                              ),
                              title: Text(userName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              subtitle: const Text('Tap to view update', style: TextStyle(color: Colors.white54)),
                            );
                          },
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
                                      backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=channel_$chanId'),
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

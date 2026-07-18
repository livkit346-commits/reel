import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class CreateVideoPostScreen extends StatefulWidget {
  const CreateVideoPostScreen({super.key});

  @override
  State<CreateVideoPostScreen> createState() => _CreateVideoPostScreenState();
}

class _CreateVideoPostScreenState extends State<CreateVideoPostScreen> {
  final TextEditingController _captionController = TextEditingController();
  File? _videoFile;
  VideoPlayerController? _videoController;
  bool _loading = false;
  Map<String, dynamic>? _userProfile;
  String _selectedCategory = 'Entertainment';

  final List<String> _categories = ['Entertainment', 'Comedy', 'Tech', 'Music', 'Education', 'Gaming'];

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _fetchUserProfile() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId != null) {
      try {
        final profile = await supabase.getUserProfile(myId);
        if (profile != null && mounted) {
          setState(() {
            _userProfile = profile;
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickVideo(source: ImageSource.gallery);
    if (pickedFile != null) {
      final file = File(pickedFile.path);
      
      // Initialize video player
      _videoController?.dispose();
      final controller = VideoPlayerController.file(file);
      try {
        await controller.initialize();
        if (controller.value.duration.inSeconds > 600) {
          await controller.dispose();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Video is too long! The maximum allowed duration is 10 minutes.'),
                backgroundColor: Color(0xFFFE2C55),
              ),
            );
          }
          return;
        }
        controller.setLooping(true);
        controller.play();

        setState(() {
          _videoFile = file;
          _videoController = controller;
        });
      } catch (e) {
        await controller.dispose();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to load video: $e'),
              backgroundColor: const Color(0xFF7E1C31),
            ),
          );
        }
      }
    }
  }

  Future<void> _submitPost() async {
    if (_videoFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a video file first.'),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();

    try {
      // Append category hashtag to caption text internally
      final finalCaption = '${_captionController.text.trim()} #$_selectedCategory';
      await supabase.uploadAndCreateVideoPost(
        finalCaption,
        _videoFile!,
      );

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to publish video post: ${e.toString()}'),
            backgroundColor: const Color(0xFF7E1C31),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBgColor = isDark ? const Color(0xFF0F0F10) : const Color(0xFFF9FBFD);
    final inputBgColor = isDark ? const Color(0xFF161618) : Colors.white;
    final myId = context.read<SupabaseService>().currentUser?.id;

    return Scaffold(
      backgroundColor: scaffoldBgColor,
      appBar: AppBar(
        backgroundColor: scaffoldBgColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: isDark ? Colors.white70 : Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'New Video Post',
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _videoFile != null && !_loading ? const Color(0xFFFE2C55) : Colors.grey.withOpacity(0.2),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              onPressed: _videoFile != null && !_loading ? _submitPost : null,
              child: _loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Share', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (myId != null)
                            UserAvatar(userId: myId, radius: 22)
                          else
                            const CircleAvatar(radius: 22, backgroundColor: Colors.white12, child: Icon(Icons.person)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_userProfile != null)
                                  Text(
                                    _userProfile!['name'] ?? 'User',
                                    style: TextStyle(
                                      color: isDark ? Colors.white : Colors.black87,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                TextField(
                                  controller: _captionController,
                                  style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 16, height: 1.4),
                                  maxLines: null,
                                  decoration: InputDecoration(
                                    hintText: "Add a description to your video...",
                                    hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Select Category',
                        style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.black87,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _categories.map((cat) {
                          final isSel = _selectedCategory == cat;
                          return ChoiceChip(
                            label: Text(cat),
                            selected: isSel,
                            onSelected: (selected) {
                              if (selected) {
                                setState(() {
                                  _selectedCategory = cat;
                                });
                              }
                            },
                            backgroundColor: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
                            selectedColor: const Color(0xFFFE2C55).withOpacity(0.15),
                            labelStyle: TextStyle(
                              color: isSel ? const Color(0xFFFE2C55) : (isDark ? Colors.white70 : Colors.black87),
                              fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                              fontSize: 13,
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 24),
                      if (_videoFile != null && _videoController != null && _videoController!.value.isInitialized)
                        Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    if (_videoController!.value.isPlaying) {
                                      _videoController!.pause();
                                    } else {
                                      _videoController!.play();
                                    }
                                  });
                                },
                                child: Container(
                                  width: 240,
                                  height: 320,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.2),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: AspectRatio(
                                          aspectRatio: _videoController!.value.aspectRatio,
                                          child: VideoPlayer(_videoController!),
                                        ),
                                      ),
                                      if (!_videoController!.value.isPlaying)
                                        Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: const BoxDecoration(
                                            color: Colors.black45,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.play_arrow,
                                            color: Colors.white,
                                            size: 40,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 8,
                                right: 8,
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _videoController?.dispose();
                                      _videoController = null;
                                      _videoFile = null;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close, color: Colors.white, size: 16),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        GestureDetector(
                          onTap: _pickVideo,
                          child: Container(
                            width: double.infinity,
                            height: 200,
                            decoration: BoxDecoration(
                              color: inputBgColor,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05),
                                width: 1.5,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.video_library_outlined, color: isDark ? Colors.white30 : Colors.black26, size: 48),
                                const SizedBox(height: 12),
                                Text(
                                  'Select Video from Gallery',
                                  style: TextStyle(
                                    color: isDark ? Colors.white54 : Colors.black54,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'MP4 format recommended',
                                  style: TextStyle(
                                    color: isDark ? Colors.white30 : Colors.black26,
                                    fontSize: 11,
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
          if (_loading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Card(
                  color: isDark ? const Color(0xFF1E1E24) : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
                    child: ValueListenableBuilder<double?>(
                      valueListenable: context.read<SupabaseService>().statusUploadProgress,
                      builder: (context, progress, _) {
                        final displayPercent = progress != null ? (progress * 100).toInt() : null;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              value: progress,
                              color: const Color(0xFFFE2C55),
                              backgroundColor: isDark ? Colors.white12 : Colors.black12,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              displayPercent != null
                                  ? 'Uploading video ($displayPercent%)...'
                                  : 'Publishing post...',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

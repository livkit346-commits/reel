import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:reel/services/supabase_service.dart';

class StoryPreviewScreen extends StatefulWidget {
  final File? mediaFile;
  final String mediaType; // 'image', 'video', or 'text'

  const StoryPreviewScreen({
    super.key,
    this.mediaFile,
    required this.mediaType,
  });

  @override
  State<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends State<StoryPreviewScreen> {
  final TextEditingController _textController = TextEditingController();
  VideoPlayerController? _videoController;
  bool _isInitialized = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == 'video' && widget.mediaFile != null) {
      _videoController = VideoPlayerController.file(widget.mediaFile!)
        ..initialize().then((_) {
          if (mounted) {
            setState(() => _isInitialized = true);
            _videoController?.play();
            _videoController?.setLooping(true);
          }
        });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _shareStory() async {
    final text = _textController.text.trim();
    if (widget.mediaType == 'text' && text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text for your story.')),
      );
      return;
    }

    setState(() => _isUploading = true);
    final supabase = context.read<SupabaseService>();

    try {
      await supabase.createCustomStatus(
        text: text.isNotEmpty ? text : null,
        mediaFile: widget.mediaFile,
        mediaType: widget.mediaType == 'text' ? null : widget.mediaType,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Story posted successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate success
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to post story: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isText = widget.mediaType == 'text';

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          isText ? 'Create Story' : 'Preview Story',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Content Area
          GestureDetector(
            onTap: () {
              if (_videoController != null) {
                if (_videoController!.value.isPlaying) {
                  _videoController?.pause();
                } else {
                  _videoController?.play();
                }
                setState(() {});
              }
            },
            child: isText
                ? Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF311B92), // Matches Colors.deepPurple[900]
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    alignment: Alignment.center,
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: null,
                      textAlign: TextAlign.center,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Type a status...',
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                      ),
                    ),
                  )
                : widget.mediaType == 'video'
                    ? _isInitialized
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: _videoController!.value.aspectRatio,
                              child: VideoPlayer(_videoController!),
                            ),
                          )
                        : const Center(
                            child: CircularProgressIndicator(color: Colors.white),
                          )
                    : widget.mediaFile != null
                        ? Image.file(
                            widget.mediaFile!,
                            fit: BoxFit.contain,
                          )
                        : Container(color: Colors.black),
          ),

          // 2. Play/Pause overlay for video
          if (widget.mediaType == 'video' && _isInitialized && !_videoController!.value.isPlaying)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
                ),
              ),
            ),

          // 3. Caption field and Share Button (Only for image/video)
          if (!isText)
            Positioned(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white24),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _textController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Add a caption...',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    onPressed: _isUploading ? null : _shareStory,
                    backgroundColor: const Color(0xFF00BFFF),
                    child: const Icon(Icons.send, color: Colors.white),
                  ),
                ],
              ),
            ),

          // 4. Send button overlay for text-only story (Positioned at bottom center/right)
          if (isText)
            Positioned(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              right: 24,
              child: FloatingActionButton.extended(
                onPressed: _isUploading ? null : _shareStory,
                backgroundColor: const Color(0xFF00BFFF),
                icon: const Icon(Icons.send, color: Colors.white),
                label: const Text(
                  'Share',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),

          // 5. Uploading loader overlay
          if (_isUploading)
            Container(
              color: Colors.black87,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF00BFFF)),
                    SizedBox(height: 16),
                    Text(
                      'Sharing to Story...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
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

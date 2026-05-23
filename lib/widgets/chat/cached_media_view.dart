import 'dart:io';
import 'package:flutter/material.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/pages/chat/chat_video_viewer_page.dart';

class CachedMediaView extends StatefulWidget {
  final String url;
  final String mediaType; // 'image', 'video'
  final double? width;
  final double? height;

  const CachedMediaView({
    super.key,
    required this.url,
    required this.mediaType,
    this.width,
    this.height,
  });

  @override
  State<CachedMediaView> createState() => _CachedMediaViewState();
}

class _CachedMediaViewState extends State<CachedMediaView> {
  final LocalStorageService _localStorage = LocalStorageService();
  File? _cachedFile;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    try {
      final file = await _localStorage.getCachedFile(
        widget.url,
        // Chat media gets 48 hours local TTL
        ttl: const Duration(hours: 48),
      );
      if (mounted) {
        setState(() {
          _cachedFile = file;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load media';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: widget.width ?? 200,
        height: widget.height ?? 200,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
        ),
      );
    }

    if (_error != null || _cachedFile == null) {
      return Container(
        width: widget.width ?? 200,
        height: widget.height ?? 200,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white30, size: 32),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: widget.mediaType == 'image'
          ? Image.file(
              _cachedFile!,
              width: widget.width,
              height: widget.height,
              fit: BoxFit.cover,
            )
          : GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ChatVideoViewerPage(videoPath: _cachedFile!.path),
                  ),
                );
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Video Preview Container
                  Container(
                    width: widget.width ?? 200,
                    height: widget.height ?? 200,
                    color: Colors.white.withOpacity(0.1),
                    child: const Icon(Icons.video_library_outlined, color: Colors.white54, size: 40),
                  ),
                  // Play Icon Button overlay
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
    );
  }
}

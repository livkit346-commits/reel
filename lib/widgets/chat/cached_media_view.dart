import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/chat/chat_video_viewer_page.dart';

class CachedMediaView extends StatefulWidget {
  final String url;
  final String mediaType; // 'image', 'video'
  final double? width;
  final double? height;
  final String? chatId;
  final String? messageId;
  final bool deleteFromServer;

  const CachedMediaView({
    super.key,
    required this.url,
    required this.mediaType,
    this.width,
    this.height,
    this.chatId,
    this.messageId,
    this.deleteFromServer = false,
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
        _checkAndSaveToGallery(file);
      }
      if (widget.deleteFromServer && widget.messageId != null && mounted) {
        context.read<SupabaseService>().deleteMessageFromServer(widget.messageId!, deleteStorage: true);
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

  Future<void> _checkAndSaveToGallery(File file) async {
    if (widget.chatId == null) return;

    try {
      // Check if media visibility is enabled for this chat
      // Defaults to true if no value is cached
      final isVisible = await _localStorage.getCachedJson('media_visibility_${widget.chatId}');
      if (isVisible == false) return; // Explicitly disabled

      // Check if already saved
      final isSaved = await _localStorage.getCachedJson('saved_to_gallery_${widget.url}');
      if (isSaved == true) return;

      final ps = await PhotoManager.requestPermissionExtend();
      if (ps.isAuth) {
        if (widget.mediaType == 'image') {
          final bytes = await file.readAsBytes();
          final fileName = 'reel_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await PhotoManager.editor.saveImage(
            bytes,
            title: fileName,
            filename: fileName,
          );
        } else if (widget.mediaType == 'video') {
          await PhotoManager.editor.saveVideo(
            file,
            title: 'reel_${DateTime.now().millisecondsSinceEpoch}',
          );
        }
        await _localStorage.cacheJson('saved_to_gallery_${widget.url}', true);
        debugPrint('Saved media to gallery successfully: ${widget.url}');
      }
    } catch (e) {
      debugPrint('Error saving media to gallery: $e');
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

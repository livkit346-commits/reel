import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:video_player/video_player.dart';

class StatusViewerPage extends StatefulWidget {
  final List<Map<String, dynamic>> statuses;
  final int initialIndex;

  const StatusViewerPage({
    super.key,
    required this.statuses,
    this.initialIndex = 0,
  });

  @override
  State<StatusViewerPage> createState() => _StatusViewerPageState();
}

class _StatusViewerPageState extends State<StatusViewerPage> with SingleTickerProviderStateMixin {
  late int currentIndex;
  late AnimationController _animController;
  VideoPlayerController? _videoController;

  bool _isVideo = false;
  bool _videoInitialized = false;
  bool _videoHasError = false;
  bool _mediaLoading = false;
  File? _localMediaFile;
  double? _trimStart;
  double? _trimEnd;

  final TextEditingController _replyController = TextEditingController();
  List<dynamic> _viewers = [];

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _animController = AnimationController(vsync: this);
    
    _animController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _nextStatus();
      }
    });

    _loadStatus(currentIndex);
  }

  @override
  void dispose() {
    _animController.dispose();
    _videoController?.dispose();
    _replyController.dispose();
    super.dispose();
  }

  void _loadStatus(int index) {
    if (index >= widget.statuses.length || index < 0) return;
    
    _animController.stop();
    _animController.reset();
    _videoController?.dispose();
    _videoController = null;
    _videoInitialized = false;
    _videoHasError = false;
    _mediaLoading = false;
    _localMediaFile = null;
    _trimStart = null;
    _trimEnd = null;

    final status = widget.statuses[index];
    final imageUrl = (status['imageUrl'] ?? status['imageurl']) as String?;
    String mediaType = (status['mediaType'] ?? status['mediatype'] ?? 'image') as String;
    
    // Parse trim start/end from query parameters
    if (imageUrl != null) {
      try {
        final uri = Uri.parse(imageUrl);
        final startParam = uri.queryParameters['trimStart'];
        final endParam = uri.queryParameters['trimEnd'];
        if (startParam != null) _trimStart = double.tryParse(startParam);
        if (endParam != null) _trimEnd = double.tryParse(endParam);
      } catch (_) {}
    }

    if (imageUrl != null && imageUrl.toLowerCase().contains('.mp4')) {
      mediaType = 'video';
    }

    _isVideo = mediaType == 'video';

    if (imageUrl != null && imageUrl.isNotEmpty && !imageUrl.startsWith('color:')) {
      _loadStatusMedia(imageUrl);
    } else {
      // It's a text status
      _animController.duration = const Duration(seconds: 5);
      _animController.forward();
    }

    _markAsViewed(status);
    _loadViewers(status);
    setState(() {});
  }

  Future<void> _loadStatusMedia(String imageUrl) async {
    setState(() {
      _mediaLoading = true;
      _localMediaFile = null;
    });

    try {
      // 1. Try to get it from local cache first (instant)
      final localFile = await LocalStorageService().getLocalIfCached(imageUrl);
      if (localFile != null) {
        if (mounted) {
          setState(() {
            _localMediaFile = localFile;
            _mediaLoading = false;
          });
          _initializeMedia();
        }
        _prefetchNextStatus();
        return;
      }

      // 2. If not cached, download and cache it (while showing loading state)
      final downloadedFile = await LocalStorageService().getCachedFile(imageUrl, ttl: const Duration(hours: 24));
      if (mounted) {
        setState(() {
          _localMediaFile = downloadedFile;
          _mediaLoading = false;
        });
        _initializeMedia();
      }
      _prefetchNextStatus();
    } catch (e) {
      debugPrint('Error loading status media: $e');
      if (mounted) {
        setState(() {
          _mediaLoading = false;
          _videoHasError = _isVideo;
        });
        
        // Show error message and proceed automatically
        if (!_isVideo) {
          _animController.duration = const Duration(seconds: 5);
          _animController.forward();
        } else {
          _animController.duration = const Duration(seconds: 3);
          _animController.forward();
        }
      }
    }
  }

  void _initializeMedia() {
    if (_isVideo && _localMediaFile != null) {
      _videoController = VideoPlayerController.file(_localMediaFile!)
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _videoInitialized = true;
            });
            
            // Seek to trimStart immediately if available
            if (_trimStart != null) {
              _videoController?.seekTo(Duration(milliseconds: (_trimStart! * 1000).toInt()));
            }

            _videoController?.play();
            
            // Loop playback within trimmed duration limits
            _videoController?.addListener(() {
              if (_videoController != null && _videoController!.value.isPlaying && _trimEnd != null && _trimStart != null) {
                final currentPosMs = _videoController!.value.position.inMilliseconds;
                final endMs = (_trimEnd! * 1000).toInt();
                if (currentPosMs >= endMs) {
                  _videoController?.seekTo(Duration(milliseconds: (_trimStart! * 1000).toInt()));
                }
              }
            });

            // Calculate progress bar duration using trimmed range
            final Duration trimDuration;
            if (_trimStart != null && _trimEnd != null) {
              trimDuration = Duration(milliseconds: ((_trimEnd! - _trimStart!) * 1000).toInt());
            } else {
              trimDuration = _videoController?.value.duration ?? const Duration(seconds: 15);
            }

            _animController.duration = trimDuration;
            _animController.forward();
          }
        }).catchError((err) {
          debugPrint('Error initializing local video status: $err');
          if (mounted) {
            setState(() {
              _videoHasError = true;
            });
            _animController.duration = const Duration(seconds: 3);
            _animController.forward();
          }
        });
    } else {
      // It's an image
      if (mounted) {
        _animController.duration = const Duration(seconds: 5);
        _animController.forward();
      }
    }
  }

  void _prefetchNextStatus() {
    final nextIndex = currentIndex + 1;
    if (nextIndex < widget.statuses.length) {
      final nextStatus = widget.statuses[nextIndex];
      final nextUrl = (nextStatus['imageUrl'] ?? nextStatus['imageurl']) as String?;
      if (nextUrl != null && nextUrl.isNotEmpty) {
        // Prefetch next media in the background to make taps instant
        LocalStorageService().getCachedFile(nextUrl, ttl: const Duration(hours: 24)).catchError((_) => File(''));
      }
    }
  }

  void _nextStatus() {
    if (currentIndex < widget.statuses.length - 1) {
      setState(() {
        currentIndex++;
      });
      _loadStatus(currentIndex);
    } else {
      Navigator.pop(context);
    }
  }

  void _previousStatus() {
    if (currentIndex > 0) {
      setState(() {
        currentIndex--;
      });
      _loadStatus(currentIndex);
    } else {
      // If tap left on first status, restart it
      _loadStatus(currentIndex);
    }
  }

  Future<void> _markAsViewed(Map<String, dynamic> status) async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    final statusUserId = status['userId'] ?? status['userid'];
    if (myId != null && statusUserId != myId) {
      await supabase.viewStatus((status['id'] ?? '').toString());
    }
  }

  Future<void> _loadViewers(Map<String, dynamic> status) async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    final statusUserId = status['userId'] ?? status['userid'];
    if (myId != null && statusUserId == myId) {
      final viewers = await supabase.getStatusViews((status['id'] ?? '').toString());
      if (mounted) {
        setState(() {
          _viewers = viewers;
        });
      }
    }
  }

  // Handle taps on the screen
  void _onTapDown(TapDownDetails details) {
    _animController.stop();
    _videoController?.pause();
  }

  void _onTapUp(TapUpDetails details) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double dx = details.globalPosition.dx;
    if (dx < screenWidth / 3) {
      _previousStatus();
    } else {
      _nextStatus();
    }
  }

  void _onLongPressStart(LongPressStartDetails details) {
    _animController.stop();
    _videoController?.pause();
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _animController.forward();
    _videoController?.play();
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
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.remove_red_eye, color: Colors.white70, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Viewed by ${_viewers.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.white10),
              if (_viewers.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text(
                      'No views yet.',
                      style: TextStyle(color: Colors.white30, fontSize: 14),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: _viewers.length,
                    itemBuilder: (context, index) {
                      final viewer = _viewers[index] as Map<String, dynamic>;
                      final user = viewer['users'] as Map<String, dynamic>?;
                      final viewerName = user?['name'] as String? ?? 'User';
                      final viewerId = user?['id'] as String? ?? '';
                      final viewedAt = viewer['createdAt'] as String? ?? '';

                      String formattedTime = '';
                      if (viewedAt.isNotEmpty) {
                        try {
                          final parsedDate = DateTime.tryParse(viewedAt)?.toLocal();
                          if (parsedDate != null) {
                            final hour = parsedDate.hour.toString().padLeft(2, '0');
                            final minute = parsedDate.minute.toString().padLeft(2, '0');
                            formattedTime = 'at $hour:$minute';
                          }
                        } catch (_) {}
                      }

                      return ListTile(
                        leading: UserAvatar(
                          userId: viewerId,
                          radius: 20,
                        ),
                        title: Text(
                          viewerName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          'Viewed $formattedTime',
                          style: const TextStyle(color: Colors.white30, fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    ).then((_) {
      // Resume playback when the bottom sheet is dismissed
      _animController.forward();
      _videoController?.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.statuses.isEmpty) return const Scaffold();

    final status = widget.statuses[currentIndex];
    final myId = context.read<SupabaseService>().currentUser?.id;
    final statusUserId = status['userId'] ?? status['userid'];
    final isMe = statusUserId == myId;
    
    final imageUrl = (status['imageUrl'] ?? status['imageurl']) as String?;
    final textContent = status['text'] as String?;
    final userName = status['userName'] ?? status['username'] ?? 'User';
    final posterId = statusUserId ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onLongPressStart: _onLongPressStart,
        onLongPressEnd: _onLongPressEnd,
        child: Stack(
          children: [
            // Media Layer
            Positioned.fill(
              child: _buildMediaLayer(imageUrl, textContent),
            ),
            
            // Progress Bars & AppBar Overlay
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Column(
                  children: [
                    _buildProgressBars(),
                    const SizedBox(height: 8),
                    _buildHeader(userName, posterId, isMe, status),
                  ],
                ),
              ),
            ),

            // Footer / Reply Input Layer
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: isMe ? _buildViewersButton() : _buildReplyInput(status),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaLayer(String? imageUrl, String? textContent) {
    if (_mediaLoading) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl != null && imageUrl.isNotEmpty)
            Opacity(
              opacity: 0.3,
              child: Image.network(
                imageUrl,
                fit: BoxFit.cover,
              ),
            ),
          const Center(
            child: CircularProgressIndicator(
              color: Color(0xFF00BFFF),
            ),
          ),
        ],
      );
    }

    if (_isVideo) {
      if (_videoInitialized && _videoController != null) {
        return Center(
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          ),
        );
      } else if (_videoHasError) {
        return const Center(child: Text('Error playing video', style: TextStyle(color: Colors.redAccent)));
      } else {
        return const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF)));
      }
    } else if (imageUrl != null && imageUrl.isNotEmpty) {
      if (_localMediaFile != null) {
        return Image.file(
          _localMediaFile!,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return const Center(
              child: Text('Failed to load cached image.', style: TextStyle(color: Colors.white54)),
            );
          },
        );
      } else {
        return Image.network(
          imageUrl,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return const Center(
              child: Text('Failed to load image.', style: TextStyle(color: Colors.white54)),
            );
          },
        );
      }
    } else if (textContent != null && textContent.isNotEmpty) {
      Color bgColor = Colors.deepPurple[900]!;
      if (imageUrl != null && imageUrl.startsWith('color:')) {
        final colorStr = imageUrl.substring(6);
        final val = int.tryParse(colorStr);
        if (val != null) {
          bgColor = Color(val);
        }
      }
      return Container(
        color: bgColor,
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Text(
          textContent,
          style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildProgressBars() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        children: widget.statuses.asMap().entries.map((entry) {
          final i = entry.key;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.0),
              child: AnimatedBuilder(
                animation: _animController,
                builder: (context, child) {
                  double progress = 0.0;
                  if (i < currentIndex) {
                    progress = 1.0;
                  } else if (i == currentIndex) {
                    progress = _animController.value;
                  }
                  return LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white30,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    minHeight: 2,
                  );
                },
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildHeader(String userName, String posterId, bool isMe, Map<String, dynamic> status) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          UserAvatar(userId: posterId, radius: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(userName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          if (isMe)
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onPressed: () {
                _animController.stop();
                _videoController?.pause();
                _showDeleteDialog(status);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildViewersButton() {
    return ElevatedButton.icon(
      onPressed: () {
        _animController.stop();
        _videoController?.pause();
        _showViewersBottomSheet();
      },
      icon: const Icon(Icons.remove_red_eye_outlined),
      label: Text('Viewed by ${_viewers.length} friends'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white24,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    );
  }

  Widget _buildReplyInput(Map<String, dynamic> status) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _replyController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Reply...',
              hintStyle: const TextStyle(color: Colors.white54),
              filled: true,
              fillColor: Colors.black54,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
            ),
            onTap: () {
              _animController.stop();
              _videoController?.pause();
            },
          ),
        ),
        const SizedBox(width: 8),
        CircleAvatar(
          backgroundColor: const Color(0xFF00BFFF),
          radius: 24,
          child: IconButton(
            icon: const Icon(Icons.send, color: Colors.white, size: 20),
            onPressed: () {
              // reply logic
              _replyController.clear();
              FocusScope.of(context).unfocus();
              _animController.forward();
              _videoController?.play();
            },
          ),
        ),
      ],
    );
  }

  void _showDeleteDialog(Map<String, dynamic> status) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Delete Status?', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () {
              Navigator.pop(context);
              _animController.forward();
              _videoController?.play();
            },
          ),
          TextButton(
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
            onPressed: () async {
              Navigator.pop(context);
              await context.read<SupabaseService>().deleteStatus((status['id'] ?? '').toString());
              if (mounted) Navigator.pop(context, true);
            },
          ),
        ],
      ),
    );
  }
}

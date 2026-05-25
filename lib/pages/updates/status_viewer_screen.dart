import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
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

    final status = widget.statuses[index];
    final imageUrl = (status['imageUrl'] ?? status['imageurl']) as String?;
    String mediaType = (status['mediaType'] ?? status['mediatype'] ?? 'image') as String;
    
    if (imageUrl != null && imageUrl.toLowerCase().contains('.mp4')) {
      mediaType = 'video';
    }

    _isVideo = mediaType == 'video';

    if (_isVideo && imageUrl != null && imageUrl.isNotEmpty) {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(imageUrl))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _videoInitialized = true;
            });
            _videoController?.play();
            _animController.duration = _videoController?.value.duration ?? const Duration(seconds: 15);
            _animController.forward();
          }
        }).catchError((err) {
          debugPrint('Error loading video status: $err');
          if (mounted) {
            setState(() {
              _videoHasError = true;
            });
            _animController.duration = const Duration(seconds: 3); // short duration if error
            _animController.forward();
          }
        });
    } else {
      // It's an image or text
      _animController.duration = const Duration(seconds: 5);
      _animController.forward();
    }

    _markAsViewed(status);
    _loadViewers(status);
    setState(() {});
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
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          debugPrint('Image load error: $error');
          return const Center(
            child: Text('Failed to load image.', style: TextStyle(color: Colors.white54)),
          );
        },
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                  : null,
            ),
          );
        },
      );
    } else if (textContent != null && textContent.isNotEmpty) {
      return Container(
        color: Colors.deepPurple[900],
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
        // show viewers bottom sheet
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

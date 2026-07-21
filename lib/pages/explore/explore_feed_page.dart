import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:reel/main.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/explore/create_post_screen.dart';
import 'package:reel/pages/explore/create_video_post_page.dart';
import 'package:reel/widgets/chat/sticker_picker.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/explore/full_screen_image_viewer.dart';
import 'package:reel/pages/updates/status_viewer_screen.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/widgets/status_ring_painter.dart';
import 'package:video_player/video_player.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/pages/explore/explore_search_page.dart';
import 'package:reel/pages/explore/full_screen_video_viewer.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class ExploreFeedPage extends StatefulWidget {
  final bool isActive;
  const ExploreFeedPage({super.key, this.isActive = true});

  @override
  State<ExploreFeedPage> createState() => ExploreFeedPageState();
}

class ExploreFeedPageState extends State<ExploreFeedPage> {
  late Future<List<dynamic>> _feedFuture;
  String _activeTab = 'For You';

  @override
  void initState() {
    super.initState();
    _feedFuture = context.read<SupabaseService>().getExploreFeed();
  }

  Future<void> _refreshFeed() async {
    setState(() {
      _feedFuture = _activeTab == 'For You'
          ? context.read<SupabaseService>().getExploreFeed()
          : context.read<SupabaseService>().getFollowingFeed();
    });
  }

  void reloadPage() {
    _refreshFeed();
    if (_feedMode == 'video') {
      _videoFeedKey.currentState?.loadVideoFeed();
      _videoFeedKey.currentState?.resetToFirstPage();
    }
  }

  Widget _buildTabButton(String tabName, BuildContext context) {
    final isActive = _activeTab == tabName;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return GestureDetector(
      onTap: () {
        if (_activeTab != tabName) {
          setState(() {
            _activeTab = tabName;
            _feedFuture = _activeTab == 'For You'
                ? context.read<SupabaseService>().getExploreFeed()
                : context.read<SupabaseService>().getFollowingFeed();
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tabName,
            style: TextStyle(
              fontSize: isActive ? 16 : 14.5,
              fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
              color: isActive
                  ? (isDark ? Colors.white : Colors.black)
                  : (isDark ? Colors.white54 : Colors.black54),
            ),
          ),
          const SizedBox(height: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 2.5,
            width: isActive ? 24 : 0,
            decoration: BoxDecoration(
              color: const Color(0xFFFE2C55), // TikTok Accent Pink/Red
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  String _feedMode = 'text'; // 'text' or 'video'
  final GlobalKey<ShortVideoFeedViewState> _videoFeedKey = GlobalKey<ShortVideoFeedViewState>();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBgColor = isDark ? Colors.black : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: scaffoldBgColor,
      appBar: AppBar(
        backgroundColor: scaffoldBgColor.withOpacity(0.8),
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            _feedMode == 'text' ? Icons.play_circle_outline : Icons.article_outlined,
            color: textColor,
          ),
          onPressed: () {
            setState(() {
              _feedMode = _feedMode == 'text' ? 'video' : 'text';
            });
          },
          tooltip: _feedMode == 'text' ? 'Switch to Video Feed' : 'Switch to Text Feed',
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTabButton('Following', context),
            const SizedBox(width: 28),
            _buildTabButton('For You', context),
          ],
        ),
        actions: [
          if (_feedMode == 'video')
            IconButton(
              icon: Icon(Icons.add_box_outlined, color: textColor),
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateVideoPostScreen()),
                );
                if (result == true) {
                  _videoFeedKey.currentState?.loadVideoFeed();
                }
              },
              tooltip: 'Publish Short Video',
            ),
          IconButton(
            icon: Icon(Icons.search, color: textColor),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ExploreSearchPage()),
              );
            },
            tooltip: 'Search Reel',
          ),
        ],
      ),
      body: _feedMode == 'video'
          ? ShortVideoFeedView(
              key: _videoFeedKey,
              followingOnly: _activeTab == 'Following',
              isParentActive: widget.isActive,
              onBackToText: () {
                setState(() {
                  _feedMode = 'text';
                });
              },
            )
          : RefreshIndicator(
              onRefresh: _refreshFeed,
              color: Theme.of(context).primaryColor,
              backgroundColor: scaffoldBgColor,
              child: FutureBuilder<List<dynamic>>(
                future: _feedFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.white54)));
                  }
                  
                  final posts = snapshot.data ?? [];

                  return CustomScrollView(
                    slivers: [
                      // Top Row: Active Status Updates
                      SliverToBoxAdapter(
                        child: Container(
                          height: 110,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
                          ),
                          child: FutureBuilder<List<dynamic>>(
                            future: context.read<SupabaseService>().getExploreStatuses(),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.waiting) {
                                return const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)));
                              }
                              final rawStatuses = snapshot.data ?? [];
                              if (rawStatuses.isEmpty) {
                                return const Center(
                                  child: Text(
                                    'No recent active status updates',
                                    style: TextStyle(color: Colors.white38, fontSize: 12),
                                  ),
                                );
                              }

                              // Group statuses by userId
                              final Map<String, List<dynamic>> groupedMap = {};
                              final Map<String, String> userNames = {};
                              
                              for (var status in rawStatuses) {
                                final userId = (status['userId'] ?? status['userid'] ?? '').toString();
                                if (userId.isEmpty) continue;
                                
                                userNames[userId] = status['userName'] ?? status['username'] ?? 'User';
                                
                                if (!groupedMap.containsKey(userId)) {
                                  groupedMap[userId] = [];
                                }
                                groupedMap[userId]!.add(status);
                              }
                              
                              final List<Map<String, dynamic>> userStatusGroups = [];
                              for (var entry in groupedMap.entries) {
                                final userId = entry.key;
                                final userStatuses = entry.value;
                                
                                // Sort user's statuses from oldest to newest (WhatsApp style play order)
                                userStatuses.sort((a, b) {
                                  final dateA = DateTime.parse(a['createdAt'] ?? a['createdat'] ?? '');
                                  final dateB = DateTime.parse(b['createdAt'] ?? b['createdat'] ?? '');
                                  return dateA.compareTo(dateB);
                                });
                                
                                userStatusGroups.add({
                                  'userId': userId,
                                  'userName': userNames[userId] ?? 'User',
                                  'statuses': userStatuses,
                                });
                              }

                              return ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: userStatusGroups.length,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                itemBuilder: (context, index) {
                                  final group = userStatusGroups[index];
                                  final userName = group['userName'];
                                  final userId = group['userId'];
                                  final List<dynamic> userStatuses = group['statuses'];

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    child: Column(
                                      children: [
                                        GestureDetector(
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) => StatusViewerPage(
                                                  statuses: userStatuses.cast<Map<String, dynamic>>(),
                                                ),
                                              ),
                                            );
                                          },
                                          child: CustomPaint(
                                            painter: StatusRingPainter(
                                              statusCount: userStatuses.length,
                                              viewedCount: 0,
                                              unviewedColor: const Color(0xFF00BFFF), // Premium Cyan theme
                                              viewedColor: Colors.grey,
                                            ),
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              child: UserAvatar(
                                                userId: userId,
                                                radius: 24,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          userName,
                                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                      // Feed: X-Style Posts
                      if (posts.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _activeTab == 'Following' ? Icons.people_outline : Icons.post_add_outlined,
                                    color: _activeTab == 'Following' ? const Color(0xFFFE2C55).withOpacity(0.6) : Colors.white30,
                                    size: 72,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _activeTab == 'Following'
                                        ? 'No posts from creators you follow'
                                        : 'No posts available',
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _activeTab == 'Following'
                                        ? 'Follow creators to see their latest updates here, or switch to For You to discover new content.'
                                        : 'Be the first to post something on Reel!',
                                    style: const TextStyle(color: Colors.white38, fontSize: 13, height: 1.3),
                                    textAlign: TextAlign.center,
                                  ),
                                  if (_activeTab == 'Following') ...[
                                    const SizedBox(height: 24),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFFE2C55),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _activeTab = 'For You';
                                          _feedFuture = context.read<SupabaseService>().getExploreFeed();
                                        });
                                      },
                                      child: const Text('Explore For You', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              return ExplorePostItem(
                                post: posts[index],
                                onPostUpdated: _refreshFeed,
                              );
                            },
                            childCount: posts.length,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
      floatingActionButton: _feedMode == 'video'
          ? null
          : FloatingActionButton(
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreatePostScreen()),
                );
                if (result == true) {
                  _refreshFeed();
                }
              },
              backgroundColor: Theme.of(context).primaryColor,
              child: const Icon(Icons.add, color: Colors.white),
            ),
    );
  }
}

class ExplorePostItem extends StatefulWidget {
  final Map<String, dynamic> post;
  final VoidCallback? onPostUpdated;
  const ExplorePostItem({super.key, required this.post, this.onPostUpdated});

  @override
  State<ExplorePostItem> createState() => _ExplorePostItemState();
}



class _ExplorePostItemState extends State<ExplorePostItem> {
  int _commentsCount = 0;
  bool _isLiked = false;
  bool _isSaved = false;
  late int _likesCount;
  late int _repostsCount;
  late int _savesCount;

  Map<String, dynamic>? _quotedPost;
  bool _loadingQuotedPost = false;
  
  // Tracking telemetry
  late DateTime _viewStartTime;

  String? _creatorUsername;
  String? _quotedPostCreatorUsername;

  @override
  void initState() {
    super.initState();
    _viewStartTime = DateTime.now();
    _likesCount = (widget.post['likes'] as num?)?.toInt() ?? 0;
    _repostsCount = (widget.post['reposts'] as num?)?.toInt() ?? 0;
    _savesCount = (widget.post['saves'] as num?)?.toInt() ?? 0;
    final supabase = context.read<SupabaseService>();
    _isLiked = supabase.likedPostIds.contains(widget.post['id']);
    _isSaved = supabase.savedPostIds.contains(widget.post['id']);
    
    final creatorId = widget.post['userId'] ?? widget.post['userid'];
    if (creatorId != null) {
      supabase.getUserProfile(creatorId).then((profile) {
        if (mounted && profile != null) {
          setState(() {
            _creatorUsername = profile['username'] as String?;
          });
        }
      });
    }

    _loadCommentsCount();
    _loadQuotedPost();
  }

  @override
  void dispose() {
    final duration = DateTime.now().difference(_viewStartTime).inSeconds;
    if (duration > 0) {
      final completed = duration >= 8;
      final skipped = duration < 2;
      
      // Report watch metrics in the background
      context.read<SupabaseService>().reportPostMetric(
        postId: widget.post['id'],
        watchedDuration: duration,
        completed: completed,
        skipped: skipped,
      );
    }
    super.dispose();
  }

  Future<void> _loadQuotedPost() async {
    final String text = widget.post['text'] ?? '';
    String? originalPostId;
    if (text.startsWith('[QUOTE:')) {
      final startIndex = text.indexOf('[QUOTE:') + 7;
      final endIndex = text.indexOf(']');
      if (endIndex != -1) {
        originalPostId = text.substring(startIndex, endIndex);
      }
    } else if (text.startsWith('[REPOST:')) {
      final startIndex = text.indexOf('[REPOST:') + 8;
      final endIndex = text.indexOf(']');
      if (endIndex != -1) {
        originalPostId = text.substring(startIndex, endIndex);
      }
    }

    if (originalPostId != null) {
      if (mounted) {
        setState(() {
          _loadingQuotedPost = true;
        });
      }
      final post = await context.read<SupabaseService>().getPostById(originalPostId);
      if (mounted) {
        setState(() {
          _quotedPost = post;
          _loadingQuotedPost = false;
        });
      }
      if (post != null) {
        final qCreatorId = post['userId'] ?? post['userid'];
        if (qCreatorId != null) {
          context.read<SupabaseService>().getUserProfile(qCreatorId).then((profile) {
            if (mounted && profile != null) {
              setState(() {
                _quotedPostCreatorUsername = profile['username'] as String?;
              });
            }
          });
        }
      }
    }
  }

  Future<void> _loadCommentsCount() async {
    try {
      final comments = await context.read<SupabaseService>().getComments(widget.post['id']);
      if (mounted) {
        setState(() {
          _commentsCount = comments.length;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleLike() async {
    final oldLikesCount = widget.post['likes'] ?? 0;
    setState(() {
      _isLiked = !_isLiked;
      _likesCount = _isLiked ? _likesCount + 1 : (_likesCount > 0 ? _likesCount - 1 : 0);
      widget.post['likes'] = _likesCount;
    });
    try {
      await context.read<SupabaseService>().toggleLikePost(widget.post['id'], oldLikesCount, _isLiked);
    } catch (_) {}
  }

  Future<void> _toggleSave() async {
    final increment = !_isSaved;
    setState(() {
      _isSaved = increment;
      _savesCount = increment ? _savesCount + 1 : (_savesCount > 0 ? _savesCount - 1 : 0);
      widget.post['saves'] = _savesCount;
    });
    try {
      await context.read<SupabaseService>().toggleSavePost(widget.post['id'], _savesCount + (increment ? -1 : 1), increment);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(increment ? 'Post saved to Bookmarks' : 'Post removed from Bookmarks'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _repost() async {
    final quoteText = await showDialog<String?>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF161618),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Colors.white12),
          ),
          title: const Text('Repost or Quote?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Add your thoughts (Quote) or leave empty for a normal Repost:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: "What's on your mind?",
                  hintStyle: const TextStyle(color: Colors.white30),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: () {
                Navigator.pop(context, controller.text.trim());
              },
              child: const Text('Share'),
            ),
          ],
        );
      },
    );

    if (quoteText == null) return; // Cancelled

    setState(() {
      _repostsCount++;
    });

    try {
      final supabase = context.read<SupabaseService>();
      final myId = supabase.currentUser?.id;
      if (myId != null) {
        if (quoteText.isEmpty) {
          final userProfile = await supabase.getUserProfile(myId);
          final userName = userProfile?['name'] ?? 'User';
          await supabase.createPost(myId, userName, '[REPOST:${widget.post['id']}]', null);
          await supabase.repostPost(widget.post['id'], widget.post['reposts'] ?? 0);
        } else {
          final userProfile = await supabase.getUserProfile(myId);
          final userName = userProfile?['name'] ?? 'User';
          await supabase.createPost(myId, userName, '[QUOTE:${widget.post['id']}] $quoteText', null);
          await supabase.repostPost(widget.post['id'], widget.post['reposts'] ?? 0);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Shared successfully')),
          );
          if (widget.onPostUpdated != null) {
            widget.onPostUpdated!();
          }
        }
      }
    } catch (_) {}
  }

  void _showCommentsBottomSheet(BuildContext context) {
    final textController = TextEditingController();
    final FocusNode commentFocusNode = FocusNode();
    Map<String, dynamic>? replyTarget; // {'parentId': String, 'userName': String}
    final Map<String, bool> expandedReplies = {};
    bool isStickerPickerActive = false;
    List<dynamic>? localCommentsList;
    bool loadingComments = true;

    String currentSortMode = 'Popular';
    final Set<String> likedCommentIds = {};
    bool loadedLikesCache = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            if (localCommentsList == null && loadingComments) {
              final myId = context.read<SupabaseService>().currentUser?.id;
              if (myId != null && !loadedLikesCache) {
                LocalStorageService().getCachedJson('liked_comments_$myId').then((cached) {
                  if (cached is List) {
                    likedCommentIds.addAll(cached.map((e) => e.toString()));
                  }
                  loadedLikesCache = true;
                });
              }
              context.read<SupabaseService>().getComments(widget.post['id']).then((comments) {
                setSheetState(() {
                  localCommentsList = List.from(comments);
                  loadingComments = false;
                });
              });
            }

            Widget buildCommentItem(Map<String, dynamic> comment, {required bool isReply}) {
              final cId = (comment['id'] ?? '').toString();
              final cUser = comment['userName'] ?? comment['username'] ?? 'User';
              final cText = comment['text'] ?? '';
              final isSticker = cText.startsWith('[STICKER:') && cText.endsWith(']');
              String? stickerUrl;
              if (isSticker) {
                stickerUrl = cText.substring(9, cText.length - 1);
              }
              final cUserId = comment['userId'] ?? comment['userid'] ?? '';
              final cCreatedAtStr = (comment['createdAt'] ?? comment['createdat']) as String?;
              final replyTo = comment['replyToUserName'] ?? comment['replytousername'] as String?;
              
              String cTimeStr = '';
              if (cCreatedAtStr != null) {
                try {
                  final parsed = DateTime.parse(cCreatedAtStr).toLocal();
                  cTimeStr = '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
                } catch (_) {}
              }
              
              final myId = context.read<SupabaseService>().currentUser?.id;
              final isCommentOwner = cUserId == myId;
              final isPostOwner = (widget.post['userId'] ?? widget.post['userid']) == myId;
              final isCreator = cUserId == (widget.post['userId'] ?? widget.post['userid']);
              final isPinned = comment['isPinned'] == true || comment['ispinned'] == true;
              final isLiked = likedCommentIds.contains(cId);
              final likesCount = comment['likes'] ?? 0;

              void showCommentOptions(BuildContext context, StateSetter setSheetState) {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: const Color(0xFF161616),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (context) {
                    return SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          ListTile(
                            leading: const Icon(Icons.copy, color: Colors.white70),
                            title: const Text('Copy Comment', style: TextStyle(color: Colors.white)),
                            onTap: () async {
                              await Clipboard.setData(ClipboardData(text: cText));
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Comment copied to clipboard'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            },
                          ),
                          if (isPostOwner)
                            ListTile(
                              leading: Icon(
                                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                                color: Colors.white70,
                              ),
                              title: Text(
                                isPinned ? 'Unpin Comment' : 'Pin Comment',
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () async {
                                final supabase = context.read<SupabaseService>();
                                final navigator = Navigator.of(context);
                                final scaffoldMessenger = ScaffoldMessenger.of(context);
                                final currentlyPinned = isPinned;

                                navigator.pop(); // Close comment options bottom sheet

                                try {
                                  // Unpin all other comments first to ensure only one is pinned
                                  if (!currentlyPinned) {
                                    for (var c in localCommentsList ?? []) {
                                      if (c['isPinned'] == true || c['ispinned'] == true) {
                                        c['isPinned'] = false;
                                        c['ispinned'] = false;
                                        await supabase.togglePinComment(c['id'].toString(), false);
                                      }
                                    }
                                  }

                                  await supabase.togglePinComment(cId, !currentlyPinned);
                                  setSheetState(() {
                                    comment['isPinned'] = !currentlyPinned;
                                    comment['ispinned'] = !currentlyPinned;
                                  });
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text(currentlyPinned ? 'Comment unpinned' : 'Comment pinned to top'),
                                      backgroundColor: const Color(0xFF00FF7F),
                                    ),
                                  );
                                } catch (e) {
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text('Failed to pin/unpin comment: $e'),
                                      backgroundColor: const Color(0xFF7E1C31),
                                    ),
                                  );
                                }
                              },
                            ),
                          if (isCommentOwner || isPostOwner)
                            ListTile(
                              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              title: const Text('Delete Comment', style: TextStyle(color: Colors.redAccent)),
                              onTap: () async {
                                final supabase = context.read<SupabaseService>();
                                final navigator = Navigator.of(context);
                                final scaffoldMessenger = ScaffoldMessenger.of(context);

                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (dialogCtx) => AlertDialog(
                                    backgroundColor: const Color(0xFF121212),
                                    title: const Text('Delete Comment', style: TextStyle(color: Colors.white)),
                                    content: const Text('Are you sure you want to delete this comment?', style: TextStyle(color: Colors.white70)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(dialogCtx, false),
                                        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(dialogCtx, true),
                                        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  navigator.pop(); // Close comment options bottom sheet safely
                                  try {
                                    await supabase.deleteComment(cId);
                                    setSheetState(() {
                                      localCommentsList?.removeWhere((c) => (c['id'] ?? '').toString() == cId);
                                    });
                                    setState(() {
                                      _commentsCount = (_commentsCount - 1).clamp(0, 999999);
                                    });
                                  } catch (e) {
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to delete comment: $e'),
                                        backgroundColor: const Color(0xFF7E1C31),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          if (!isCommentOwner)
                            ListTile(
                              leading: const Icon(Icons.report_problem_outlined, color: Colors.amber),
                              title: const Text('Report Comment', style: TextStyle(color: Colors.white)),
                              onTap: () {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Comment reported. Thank you for keeping Reel safe!'),
                                    backgroundColor: Color(0xFF7E1C31),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    );
                  },
                );
              }

              return GestureDetector(
                onLongPress: () => showCommentOptions(context, setSheetState),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: 6.0,
                    horizontal: isReply ? 0.0 : 16.0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UserAvatar(userId: cUserId, radius: isReply ? 12 : 16),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  cUser,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: isReply ? 12 : 13,
                                  ),
                                ),
                                if (isCreator) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFE2C55), // TikTok Red
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Creator',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                                if (cTimeStr.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '• $cTimeStr',
                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                                  ),
                                ],
                                if (isPinned) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: Colors.amber.withOpacity(0.5), width: 0.5),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Icon(Icons.push_pin, color: Colors.amber, size: 9),
                                        SizedBox(width: 2),
                                        Text(
                                          'Pinned',
                                          style: TextStyle(color: Colors.amber, fontSize: 9, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (isSticker && stickerUrl != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0, bottom: 4.0),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: stickerUrl.startsWith('emoji:')
                                      ? Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Text(
                                            stickerUrl.substring(6),
                                            style: const TextStyle(fontSize: 54),
                                          ),
                                        )
                                      : (stickerUrl.startsWith('assets/')
                                          ? Image.asset(
                                              stickerUrl,
                                              width: 80,
                                              height: 80,
                                              fit: BoxFit.contain,
                                            )
                                          : Image.network(
                                              stickerUrl,
                                              width: 80,
                                              height: 80,
                                              fit: BoxFit.contain,
                                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white24, size: 24),
                                            )),
                                ),
                              )
                            else
                              RichText(
                                text: TextSpan(
                                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                                  children: [
                                    if (isReply && replyTo != null && replyTo.isNotEmpty) ...[
                                      TextSpan(
                                        text: '@$replyTo ',
                                        style: const TextStyle(
                                          color: Color(0xFF00BFFF),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                    TextSpan(text: cText),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    setSheetState(() {
                                      replyTarget = {
                                        'parentId': comment['parentId'] ?? comment['parentid'] ?? comment['id'],
                                        'userName': cUser,
                                      };
                                    });
                                    commentFocusNode.requestFocus();
                                  },
                                  child: const Text(
                                    'Reply',
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // TikTok-style Comment Like Heart and count on the right
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () async {
                              final supabase = context.read<SupabaseService>();
                              final myId = supabase.currentUser?.id;
                              if (myId == null) return;

                              final isIncrement = !isLiked;
                              setSheetState(() {
                                if (isIncrement) {
                                  likedCommentIds.add(cId);
                                  comment['likes'] = (comment['likes'] ?? 0) + 1;
                                } else {
                                  likedCommentIds.remove(cId);
                                  comment['likes'] = ((comment['likes'] ?? 0) - 1).clamp(0, 999999);
                                }
                              });

                              try {
                                await supabase.toggleLikeComment(cId, likesCount, isIncrement);
                                await LocalStorageService().cacheJson('liked_comments_$myId', likedCommentIds.toList());
                              } catch (_) {}
                            },
                            child: Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              color: isLiked ? const Color(0xFFFE2C55) : Colors.white30,
                              size: 18,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            likesCount > 0 ? '$likesCount' : '0',
                            style: const TextStyle(color: Colors.white30, fontSize: 10),
                          ),
                        ],
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.white30, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => showCommentOptions(context, setSheetState),
                      )
                    ],
                  ),
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            localCommentsList != null
                                ? '${localCommentsList!.where((c) => c['parentId'] == null && c['parentid'] == null).length} comments'
                                : 'Comments',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: currentSortMode,
                              dropdownColor: const Color(0xFF1E1E1E),
                              icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 16),
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                              items: const [
                                DropdownMenuItem(
                                  value: 'Popular',
                                  child: Text('Popular'),
                                ),
                                DropdownMenuItem(
                                  value: 'Latest',
                                  child: Text('Latest'),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setSheetState(() {
                                    currentSortMode = val;
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: loadingComments
                          ? const Center(child: CircularProgressIndicator())
                          : (() {
                              final allComments = localCommentsList ?? [];
                              if (allComments.isEmpty) {
                                return const Center(
                                  child: Text(
                                    'Be the first to reply!',
                                    style: TextStyle(color: Colors.white30, fontSize: 14),
                                  ),
                                );
                              }

                              // Group comments: parents and child replies
                              final parentComments = allComments
                                  .where((c) => c['parentId'] == null && c['parentid'] == null)
                                  .toList();
                              
                              parentComments.sort((a, b) {
                                final aPinned = a['isPinned'] == true || a['ispinned'] == true;
                                final bPinned = b['isPinned'] == true || b['ispinned'] == true;
                                if (aPinned && !bPinned) return -1;
                                if (!aPinned && bPinned) return 1;

                                if (currentSortMode == 'Popular') {
                                  final aLikes = a['likes'] ?? 0;
                                  final bLikes = b['likes'] ?? 0;
                                  if (aLikes != bLikes) {
                                    return bLikes.compareTo(aLikes);
                                  }
                                }

                                final aTime = DateTime.tryParse(a['createdAt'] ?? a['createdat'] ?? '') ?? DateTime.now();
                                final bTime = DateTime.tryParse(b['createdAt'] ?? b['createdat'] ?? '') ?? DateTime.now();
                                return bTime.compareTo(aTime);
                              });

                              final childReplies = <String, List<dynamic>>{};
                              for (var c in allComments) {
                                final parentIdVal = c['parentId'] ?? c['parentid'];
                                if (parentIdVal != null) {
                                  final pIdStr = parentIdVal.toString();
                                  childReplies.putIfAbsent(pIdStr, () => []).add(c);
                                }
                              }

                              return ListView.builder(
                                itemCount: parentComments.length,
                                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                                itemBuilder: (context, idx) {
                                  final parent = parentComments[idx];
                                  final pId = (parent['id'] ?? '').toString();
                                  final replies = childReplies[pId] ?? [];
                                  final isExpanded = expandedReplies[pId] ?? false;

                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      buildCommentItem(parent, isReply: false),
                                      if (replies.isNotEmpty) ...[
                                        Padding(
                                          padding: const EdgeInsets.only(left: 58.0, bottom: 4.0),
                                          child: GestureDetector(
                                            onTap: () {
                                              setSheetState(() {
                                                expandedReplies[pId] = !isExpanded;
                                              });
                                            },
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 24,
                                                  height: 1,
                                                  color: Colors.white24,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  isExpanded
                                                      ? 'Hide replies'
                                                      : 'View replies (${replies.length})',
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (isExpanded)
                                          Padding(
                                            padding: const EdgeInsets.only(left: 40.0),
                                            child: Column(
                                              children: replies
                                                  .map((r) => buildCommentItem(r, isReply: true))
                                                  .toList(),
                                            ),
                                          ),
                                      ],
                                    ],
                                  );
                                },
                              );
                            }()),
                    ),
                    if (replyTarget != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: Colors.white.withOpacity(0.05),
                        child: Row(
                          children: [
                            Text(
                              'Replying to @${replyTarget!['userName']}',
                              style: const TextStyle(color: Color(0xFF00BFFF), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () {
                                setSheetState(() {
                                  replyTarget = null;
                                });
                              },
                              child: const Icon(Icons.close, color: Colors.white54, size: 16),
                            ),
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F1F),
                        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.08))),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              isStickerPickerActive ? Icons.keyboard : Icons.emoji_emotions_outlined,
                              color: isStickerPickerActive ? const Color(0xFF00BFFF) : Colors.white70,
                            ),
                            onPressed: () {
                              setSheetState(() {
                                isStickerPickerActive = !isStickerPickerActive;
                                if (isStickerPickerActive) {
                                  commentFocusNode.unfocus();
                                } else {
                                  commentFocusNode.requestFocus();
                                }
                              });
                            },
                          ),
                          Expanded(
                            child: TextField(
                              controller: textController,
                              focusNode: commentFocusNode,
                              style: const TextStyle(color: Colors.white),
                              onTap: () {
                                if (isStickerPickerActive) {
                                  setSheetState(() {
                                    isStickerPickerActive = false;
                                  });
                                }
                              },
                              decoration: InputDecoration(
                                hintText: replyTarget != null
                                    ? 'Reply to @${replyTarget!['userName']}...'
                                    : 'Post your reply...',
                                hintStyle: const TextStyle(color: Colors.white38),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.send_rounded, color: Color(0xFF00BFFF)),
                            onPressed: () async {
                              final text = textController.text.trim();
                              if (text.isEmpty) return;
                              
                              final targetParentId = replyTarget?['parentId'];
                              final targetReplyToUserName = replyTarget?['userName'];
                              
                              textController.clear();
                              setSheetState(() {
                                replyTarget = null;
                              });

                              try {
                                final newComment = await context.read<SupabaseService>().addComment(
                                  widget.post['id'],
                                  text,
                                  parentId: targetParentId,
                                  replyToUserName: targetReplyToUserName,
                                );

                                setSheetState(() {
                                  localCommentsList ??= [];
                                  localCommentsList!.add(newComment);
                                });

                                setState(() {
                                  _commentsCount++;
                                });
                              } catch (e) {
                                debugPrint('Failed to add comment: $e');
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    if (isStickerPickerActive)
                      StickerPicker(
                        onStickerSelected: (url) async {
                          final stickerTag = '[STICKER:$url]';
                          final targetParentId = replyTarget?['parentId'];
                          final targetReplyToUserName = replyTarget?['userName'];
                          
                          setSheetState(() {
                            replyTarget = null;
                            // Keep isStickerPickerActive true so user can send more stickers (TikTok style)
                          });

                          try {
                            final newComment = await context.read<SupabaseService>().addComment(
                              widget.post['id'],
                              stickerTag,
                              parentId: targetParentId,
                              replyToUserName: targetReplyToUserName,
                            );

                            setSheetState(() {
                              localCommentsList ??= [];
                              localCommentsList!.add(newComment);
                            });

                            setState(() {
                              _commentsCount++;
                            });
                          } catch (e) {
                            debugPrint('Failed to add sticker comment: $e');
                          }
                        },
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      commentFocusNode.dispose();
      textController.dispose();
    });
  }

  Widget _buildQuotedPostWidget(Map<String, dynamic> qPost) {
    final qUserName = qPost['userName'] ?? qPost['username'] ?? 'User';
    final qText = qPost['text'] ?? '';
    final qImageUrl = qPost['imageUrl'] ?? qPost['imageurl'];
    final qUserId = qPost['userId'] ?? qPost['userid'] ?? '';

    String displayQText = qText;
    if (qText.startsWith('[QUOTE:')) {
      final endIndex = qText.indexOf(']');
      if (endIndex != -1 && endIndex + 1 < qText.length) {
        displayQText = qText.substring(endIndex + 1).trim();
      }
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white70 : Colors.black87;
    final subTextColor = isDark ? Colors.white38 : Colors.black45;
    final borderColor = isDark ? Colors.white10 : Colors.black.withOpacity(0.1);
    final cardBgColor = isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.03);

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        color: cardBgColor,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserAvatar(userId: qUserId, radius: 10),
              const SizedBox(width: 6),
              Text(
                qUserName,
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(width: 4),
              Text(
                '@${_quotedPostCreatorUsername ?? qUserName.toLowerCase().replaceAll(' ', '')}',
                style: TextStyle(color: subTextColor, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (qText.startsWith('[REPOST:'))
            TextStyle(color: secondaryTextColor, fontSize: 13, fontStyle: FontStyle.italic) != null
                ? Text('♻️ Repost', style: TextStyle(color: secondaryTextColor, fontSize: 13, fontStyle: FontStyle.italic))
                : const SizedBox()
          else
            Text(
              displayQText,
              style: TextStyle(color: secondaryTextColor, fontSize: 13, height: 1.3),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          if (qImageUrl != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 150),
                width: double.infinity,
                child: Image.network(
                  qImageUrl,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String text = widget.post['text'] ?? '';
    final String userName = widget.post['userName'] ?? widget.post['username'] ?? 'User';
    final String? imageUrl = widget.post['imageUrl'] ?? widget.post['imageurl'];
    final String userId = widget.post['userId'] ?? widget.post['userid'] ?? 'unknown';

    final isRepost = text.startsWith('[REPOST:');
    final isQuote = text.startsWith('[QUOTE:');

    // Extract actual display fields if this is a repost
    String displayText = text;
    String displayUserName = userName;
    String? displayImageUrl = imageUrl;
    String displayUserId = userId;

    if (isRepost && _quotedPost != null) {
      displayText = _quotedPost!['text'] ?? '';
      displayUserName = _quotedPost!['userName'] ?? _quotedPost!['username'] ?? 'User';
      displayImageUrl = _quotedPost!['imageUrl'] ?? _quotedPost!['imageurl'];
      displayUserId = _quotedPost!['userId'] ?? _quotedPost!['userid'] ?? 'unknown';
    } else if (isQuote) {
      final endIndex = text.indexOf(']');
      if (endIndex != -1 && endIndex + 1 < text.length) {
        displayText = text.substring(endIndex + 1).trim();
      } else {
        displayText = '';
      }
    }

    final myId = context.read<SupabaseService>().currentUser?.id;
    final isMe = displayUserId == myId;
    final displayHandle = isRepost 
        ? (_quotedPostCreatorUsername ?? displayUserName.toLowerCase().replaceAll(' ', ''))
        : (_creatorUsername ?? displayUserName.toLowerCase().replaceAll(' ', ''));

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white54 : Colors.black54;
    final subTextColor = isDark ? Colors.white38 : Colors.black38;
    final borderSideColor = isDark ? Colors.white12 : Colors.black.withOpacity(0.08);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderSideColor, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isRepost) ...[
            Padding(
              padding: const EdgeInsets.only(left: 36, bottom: 8),
              child: Row(
                children: [
                  const Icon(Icons.repeat, color: Colors.greenAccent, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    '$userName reposted',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(
                userId: displayUserId,
                radius: 24,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ReelProfilePage(userId: displayUserId),
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ReelProfilePage(userId: displayUserId),
                              ),
                            );
                          },
                          child: Text(
                            displayUserName,
                            style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '@$displayHandle',
                          style: TextStyle(color: secondaryTextColor, fontSize: 14),
                        ),
                        const Spacer(),
                        PopupMenuButton<String>(
                          icon: Icon(Icons.more_horiz, color: secondaryTextColor, size: 20),
                          color: isDark ? Colors.grey[900] : Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          onSelected: (value) async {
                            if (value == 'delete') {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  backgroundColor: isDark ? Colors.grey[900] : Colors.white,
                                  title: Text('Delete Post', style: TextStyle(color: textColor)),
                                  content: Text('Are you sure you want to delete this post?', style: TextStyle(color: secondaryTextColor)),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: Text('Cancel', style: TextStyle(color: subTextColor)),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await context.read<SupabaseService>().deletePost(widget.post['id']);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Post deleted successfully')),
                                );
                                if (widget.onPostUpdated != null) {
                                  widget.onPostUpdated!();
                                }
                              }
                            } else if (value == 'report') {
                              await context.read<SupabaseService>().reportPost(widget.post['id']);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Post reported successfully')),
                              );
                            }
                          },
                          itemBuilder: (context) => [
                            if (isMe)
                              const PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                    SizedBox(width: 8),
                                    Text('Delete Post', style: TextStyle(color: Colors.redAccent)),
                                  ],
                                ),
                              ),
                            PopupMenuItem(
                              value: 'report',
                              child: Row(
                                children: [
                                  const Icon(Icons.report_problem_outlined, color: Colors.amber, size: 18),
                                  const SizedBox(width: 8),
                                  Text('Report Post', style: TextStyle(color: textColor)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (isRepost && _quotedPost == null && _loadingQuotedPost)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: secondaryTextColor)),
                      )
                    else if (isRepost && _quotedPost == null && !_loadingQuotedPost)
                      Text(
                        'This post is unavailable',
                        style: TextStyle(color: subTextColor, fontSize: 14, fontStyle: FontStyle.italic),
                      )
                    else ...[
                      Text(
                        displayText,
                        style: TextStyle(color: textColor, fontSize: 15, height: 1.4),
                      ),
                      if (isQuote && _quotedPost != null)
                        _buildQuotedPostWidget(_quotedPost!),
                      if (isQuote && _quotedPost == null && _loadingQuotedPost)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: secondaryTextColor),
                            ),
                          ),
                        )
                      else if (isQuote && _quotedPost == null && !_loadingQuotedPost)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: borderSideColor),
                            color: isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.02),
                          ),
                          child: Text(
                            'This post is unavailable',
                            style: TextStyle(color: subTextColor, fontSize: 13, fontStyle: FontStyle.italic),
                          ),
                        ),
                      if (displayImageUrl != null)
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => FullScreenImageViewer(
                                  imageUrl: displayImageUrl!,
                                  tag: 'explore_post_${widget.post['id']}',
                                ),
                              ),
                            );
                          },
                          child: Hero(
                            tag: 'explore_post_${widget.post['id']}',
                            child: Container(
                              margin: const EdgeInsets.only(top: 12),
                              width: double.infinity,
                              constraints: const BoxConstraints(
                                maxHeight: 360,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                color: isDark ? const Color(0xFF161616) : Colors.grey[200],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.network(
                                  displayImageUrl!,
                                  fit: BoxFit.cover,
                                  alignment: Alignment.center,
                                  loadingBuilder: (context, child, loadingProgress) {
                                    if (loadingProgress == null) return child;
                                    return Container(
                                      width: double.infinity,
                                      height: 240,
                                      color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
                                    );
                                  },
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      width: double.infinity,
                                      height: 240,
                                      color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (widget.post['mediaType'] == 'video' && widget.post['videoUrl'] != null)
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => FullScreenVideoViewer(
                                  videoUrl: widget.post['videoUrl'],
                                  post: widget.post,
                                ),
                              ),
                            );
                          },
                          child: Container(
                            margin: const EdgeInsets.only(top: 12),
                            width: double.infinity,
                            height: 200,
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: borderSideColor, width: 0.5),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    color: Colors.white.withOpacity(0.05),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.play_arrow, color: Color(0xFFFE2C55), size: 36),
                                ),
                                Positioned(
                                  bottom: 12,
                                  left: 12,
                                  child: Row(
                                    children: [
                                      const Icon(Icons.videocam_outlined, color: Colors.white70, size: 16),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Short Video',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.8),
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTap: () => _showCommentsBottomSheet(context),
                          child: _buildPostAction(Icons.chat_bubble_outline, _commentsCount.toString(), active: _commentsCount > 0),
                        ),
                        GestureDetector(
                          onTap: _repost,
                          child: _buildPostAction(Icons.repeat, _repostsCount.toString(), active: _repostsCount > 0, activeColor: Colors.greenAccent),
                        ),
                        GestureDetector(
                          onTap: _toggleLike,
                          child: _buildPostAction(
                            _isLiked ? Icons.favorite : Icons.favorite_border,
                            _likesCount.toString(),
                            active: _isLiked,
                            activeColor: Colors.redAccent,
                          ),
                        ),
                        GestureDetector(
                          onTap: _toggleSave,
                          child: _buildPostAction(
                            _isSaved ? Icons.bookmark : Icons.bookmark_border,
                            '',
                            active: _isSaved,
                            activeColor: Colors.blueAccent,
                          ),
                        ),
                        _buildPostAction(Icons.share_outlined, ''),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPostAction(IconData icon, String label, {bool active = false, Color? activeColor}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultActiveColor = isDark ? Colors.white : Colors.black87;
    final effectiveActiveColor = activeColor ?? defaultActiveColor;
    final inactiveColor = isDark ? Colors.white54 : Colors.black45;

    return Row(
      children: [
        Icon(icon, color: active ? effectiveActiveColor : inactiveColor, size: 18),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: active ? effectiveActiveColor : inactiveColor, fontSize: 12)),
        ],
      ],
    );
  }
}

// Immersive Vertical Paging Short Video Feed View
class ShortVideoFeedView extends StatefulWidget {
  final bool followingOnly;
  final bool isParentActive;
  final VoidCallback onBackToText;
  const ShortVideoFeedView({
    super.key,
    required this.followingOnly,
    required this.isParentActive,
    required this.onBackToText,
  });

  @override
  State<ShortVideoFeedView> createState() => ShortVideoFeedViewState();
}

class ShortVideoFeedViewState extends State<ShortVideoFeedView> {
  late Future<List<dynamic>> _videoFeedFuture;
  final PageController _pageController = PageController();
  int _focusedIndex = 0;

  @override
  void initState() {
    super.initState();
    loadVideoFeed();
  }

  @override
  void didUpdateWidget(covariant ShortVideoFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.followingOnly != widget.followingOnly) {
      loadVideoFeed();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void loadVideoFeed() {
    setState(() {
      _videoFeedFuture = context.read<SupabaseService>().getVideoFeed(followingOnly: widget.followingOnly);
    });
  }

  void resetToFirstPage() {
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _videoFeedFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: Color(0xFFFE2C55)));
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.white54)));
        }

        final videos = snapshot.data ?? [];

        if (videos.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _preloadNextVideos(videos);
          });
        }

        if (videos.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.video_collection_outlined, color: Colors.white30, size: 72),
                  const SizedBox(height: 16),
                  Text(
                    widget.followingOnly ? 'No videos from creators you follow' : 'No short videos posted yet',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.followingOnly
                        ? 'Follow creators to see their video updates, or discover new videos on For You.'
                        : 'Click the plus button in the top right to upload the first short video!',
                    style: const TextStyle(color: Colors.white38, fontSize: 13, height: 1.3),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        return PageView.builder(
          scrollDirection: Axis.vertical,
          controller: _pageController,
          itemCount: videos.length,
          onPageChanged: (index) {
            setState(() {
              _focusedIndex = index;
            });
            _preloadNextVideos(videos);
          },
          itemBuilder: (context, index) {
            return ShortVideoFeedItem(
              post: videos[index],
              isActive: widget.isParentActive && (index == _focusedIndex),
              onPostUpdated: loadVideoFeed,
            );
          },
        );
      },
    );
  }

  void _preloadNextVideos(List<dynamic> videos) {
    for (int i = 1; i <= 2; i++) {
      final nextIndex = _focusedIndex + i;
      if (nextIndex < videos.length) {
        final nextPost = videos[nextIndex];
        final nextUrl = nextPost['videoUrl'] as String?;
        if (nextUrl != null && nextUrl.isNotEmpty) {
          VideoControllerCache.preloadController(nextUrl);
        }
      }
    }
  }
}

// Stateful short video player and overlay options
class ShortVideoFeedItem extends StatefulWidget {
  final Map<String, dynamic> post;
  final bool isActive;
  final VoidCallback onPostUpdated;
  const ShortVideoFeedItem({
    super.key,
    required this.post,
    required this.isActive,
    required this.onPostUpdated,
  });

  @override
  State<ShortVideoFeedItem> createState() => _ShortVideoFeedItemState();
}

class _ShortVideoFeedItemState extends State<ShortVideoFeedItem> with SingleTickerProviderStateMixin, RouteAware {
  VideoPlayerController? _videoController;
  bool _isControllerFromCache = false;
  late AnimationController _discController;
  bool _isPlaying = false;
  bool _isLiked = false;
  bool _isSaved = false;
  late int _likesCount;
  int _commentsCount = 0;
  bool _showPlayPauseOverlay = false;
  bool _playIconIsPlay = false;

  late int _repostsCount;
  late int _savesCount;
  bool _isReposted = false;
  bool _isFollowing = false;
  String? _creatorUsername;
  BoxFit _fitMode = BoxFit.contain;
  bool _isFastForwarding = false;
  bool _isScrubbing = false;
  double _scrubValue = 0.0;
  Duration? _scrubTime;
  double _initialTouchX = 0.0;
  double _initialScrubProgress = 0.0;
  String? _myUserId;

  // Custom heart pop coordinate list
  final List<Offset> _hearts = [];

  @override
  void initState() {
    super.initState();
    _likesCount = (widget.post['likes'] as num?)?.toInt() ?? 0;
    _repostsCount = (widget.post['reposts'] as num?)?.toInt() ?? 0;
    _savesCount = (widget.post['saves'] as num?)?.toInt() ?? 0;
    final supabase = context.read<SupabaseService>();
    _isLiked = supabase.likedPostIds.contains(widget.post['id']);
    _isSaved = supabase.savedPostIds.contains(widget.post['id']);
    _isReposted = false;

    _myUserId = supabase.currentUser?.id;
    if (_myUserId == null || _myUserId!.isEmpty) {
      LocalStorageService().getString('last_logged_in_user_id').then((uid) {
        if (mounted && uid != null) {
          setState(() {
            _myUserId = uid;
          });
          final creatorId = widget.post['userId'] ?? widget.post['userid'] ?? '';
          if (creatorId.isNotEmpty && creatorId != uid) {
            supabase.isFollowing(creatorId).then((val) {
              if (mounted) {
                setState(() {
                  _isFollowing = val;
                });
              }
            });
          }
        }
      });
    }

    final myId = _myUserId ?? supabase.currentUser?.id;
    final creatorId = widget.post['userId'] ?? widget.post['userid'] ?? '';
    if (creatorId.isNotEmpty) {
      supabase.getUserProfile(creatorId).then((profile) {
        if (mounted && profile != null) {
          setState(() {
            _creatorUsername = profile['username'] as String?;
          });
        }
      });
      if (creatorId != myId) {
        supabase.isFollowing(creatorId).then((val) {
          if (mounted) {
            setState(() {
              _isFollowing = val;
            });
          }
        });
      }
    }

    _discController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );

    _initializeVideo();
    _loadCommentsCount();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void didUpdateWidget(covariant ShortVideoFeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _handlePlaybackState();
    }
  }

  void _handlePlaybackState() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    if (widget.isActive) {
      _replayVideo();
    } else {
      _pauseVideo();
    }
  }

  void _pauseVideo() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    _videoController!.pause();
    if (_isPlaying) {
      setState(() {
        _isPlaying = false;
        _discController.stop();
      });
    }
  }

  void _replayVideo() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    VideoControllerCache.pauseAllExcept(_videoController);
    _videoController!.seekTo(Duration.zero).then((_) {
      _videoController!.play();
      setState(() {
        _isPlaying = true;
        _discController.repeat();
      });
    });
  }

  void _resumeVideo() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    VideoControllerCache.pauseAllExcept(_videoController);
    _videoController!.play();
    setState(() {
      _isPlaying = true;
      _discController.repeat();
    });
  }

  @override
  void didPushNext() {
    _pauseVideo();
  }

  @override
  void didPopNext() {
    if (widget.isActive) {
      _replayVideo();
    }
  }

  Future<void> _loadCommentsCount() async {
    try {
      final comments = await context.read<SupabaseService>().getComments(widget.post['id']);
      if (mounted) {
        setState(() {
          _commentsCount = comments.length;
        });
      }
    } catch (_) {}
  }

  void _initializeVideo() async {
    final videoUrl = widget.post['videoUrl'] as String?;
    if (videoUrl != null && videoUrl.isNotEmpty) {
      try {
        final controller = await VideoControllerCache.getController(videoUrl);
        if (mounted) {
          setState(() {
            _videoController = controller;
            _isControllerFromCache = true;
          });
          _videoController!.setLooping(true);
          _handlePlaybackState();
        }
      } catch (e) {
        debugPrint("Error loading cached video: $e");
      }
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    if (!_isControllerFromCache) {
      _videoController?.dispose();
    } else {
      _videoController?.pause();
    }
    _discController.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    setState(() {
      if (_isPlaying) {
        _videoController!.pause();
        _isPlaying = false;
        _discController.stop();
        _playIconIsPlay = true; // Show play arrow icon when we paused it
      } else {
        VideoControllerCache.pauseAllExcept(_videoController);
        _videoController!.play();
        _isPlaying = true;
        _discController.repeat();
        _playIconIsPlay = false; // Show pause icon when we played it
      }
      _showPlayPauseOverlay = true;
    });

    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _showPlayPauseOverlay = false;
        });
      }
    });
  }

  void _onDoubleTap(TapDownDetails details) async {
    final localOffset = details.localPosition;
    setState(() {
      _hearts.add(localOffset);
    });

    if (!_isLiked) {
      final supabase = context.read<SupabaseService>();
      final myId = supabase.currentUser?.id;
      if (myId != null) {
        setState(() {
          _isLiked = true;
          _likesCount++;
        });
        try {
          await supabase.toggleLikePost(widget.post['id'], _likesCount - 1, true);
        } catch (_) {}
      }
    }

    // Auto-remove heart animation
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _hearts.remove(localOffset);
        });
      }
    });
  }

  void _toggleLike() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    final increment = !_isLiked;
    setState(() {
      _isLiked = increment;
      _likesCount = increment ? _likesCount + 1 : (_likesCount - 1).clamp(0, 999999);
    });

    try {
      await supabase.toggleLikePost(widget.post['id'], _likesCount + (increment ? -1 : 1), increment);
    } catch (_) {}
  }

  void _toggleSave() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    final increment = !_isSaved;
    setState(() {
      _isSaved = increment;
      _savesCount = increment ? _savesCount + 1 : (_savesCount - 1).clamp(0, 999999);
    });

    try {
      await supabase.toggleSavePost(widget.post['id'], _savesCount + (increment ? -1 : 1), increment);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(increment ? 'Video saved to Bookmarks' : 'Video removed from Bookmarks'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {}
  }

  bool _isSavingVideo = false;

  Future<void> _downloadAndWatermarkVideo(String videoUrl, String creatorName) async {
    if (_isSavingVideo) return;
    
    // Show download overlay dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return WillPopScope(
          onWillPop: () async => false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                CircularProgressIndicator(color: Color(0xFFFE2C55)),
                SizedBox(height: 20),
                Text(
                  'Saving video...',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  'Please wait while we download the video',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    );

    try {
      setState(() => _isSavingVideo = true);
      
      // 1. Download original video
      final response = await http.get(Uri.parse(videoUrl));
      if (response.statusCode != 200) {
        throw Exception('Failed to download video file');
      }
      final videoBytes = response.bodyBytes;
      
      final tempDir = await getTemporaryDirectory();
      final videoFile = File('${tempDir.path}/temp_video_${DateTime.now().millisecondsSinceEpoch}.mp4');
      await videoFile.writeAsBytes(videoBytes);
      
      // 2. Request photo manager permission and save to gallery directly
      final ps = await PhotoManager.requestPermissionExtend();
      if (ps.isAuth) {
        await PhotoManager.editor.saveVideo(
          videoFile,
          title: 'reel_${DateTime.now().millisecondsSinceEpoch}',
        );
        
        if (mounted) {
          Navigator.pop(context); // Pop loading dialog
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Video saved to Gallery successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception('Storage permission was denied');
      }
      
      // Cleanup temp files
      try {
        await videoFile.delete();
      } catch (_) {}
      
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save video: $e'),
            backgroundColor: const Color(0xFF7E1C31),
          ),
        );
      }
    } finally {
      setState(() => _isSavingVideo = false);
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<void> _toggleRepost() async {
    final quoteText = await showDialog<String?>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF161618),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Colors.white12),
          ),
          title: const Text('Repost or Quote Video?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Add your thoughts (Quote) or leave empty for a normal Repost:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: "What do you think of this video?",
                  hintStyle: const TextStyle(color: Colors.white30),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: () {
                Navigator.pop(context, controller.text.trim());
              },
              child: const Text('Share'),
            ),
          ],
        );
      },
    );

    if (quoteText == null) return;

    setState(() {
      _isReposted = true;
      _repostsCount++;
    });

    try {
      final supabase = context.read<SupabaseService>();
      final myId = supabase.currentUser?.id;
      if (myId != null) {
        final userProfile = await supabase.getUserProfile(myId);
        final userName = userProfile?['name'] ?? 'User';
        if (quoteText.isEmpty) {
          await supabase.createPost(myId, userName, '[REPOST:${widget.post['id']}]', null);
        } else {
          await supabase.createPost(myId, userName, '[QUOTE:${widget.post['id']}] $quoteText', null);
        }
        await supabase.repostPost(widget.post['id'], widget.post['reposts'] ?? 0);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video reposted successfully')),
          );
          widget.onPostUpdated();
        }
      }
    } catch (e) {
      debugPrint("Error reposting: $e");
    }
  }

  void _showShareSheet() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    final videoUrl = widget.post['videoUrl'] as String? ?? '';
    final caption = widget.post['text'] ?? '';
    final creatorName = widget.post['userName'] ?? widget.post['username'] ?? 'User';

    List<dynamic> activeChats = [];
    bool loadingChats = true;

    if (myId != null) {
      try {
        activeChats = await supabase.getActiveChats();
        loadingChats = false;
      } catch (_) {
        loadingChats = false;
      }
    }

    final Map<String, String> sendStates = {};

    if (mounted) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1E1E24),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return StatefulBuilder(
            builder: (context, setShareState) {
              return SafeArea(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // TikTok drag handle
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      
                      const Text(
                        'Send to',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                      const SizedBox(height: 14),
                      
                      // Direct message sends horizontal list
                      SizedBox(
                        height: 90,
                        child: loadingChats
                            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFE2C55)))
                            : activeChats.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No active chats yet',
                                      style: TextStyle(color: Colors.white38, fontSize: 13),
                                    ),
                                  )
                                : ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    itemCount: activeChats.length,
                                    itemBuilder: (context, index) {
                                      final chat = activeChats[index];
                                      final chatName = chat['chatName'] ?? 'Chat';
                                      final otherUserId = chat['otherUserId'] ?? '';
                                      final chatId = chat['chatId'] ?? '';
                                      final state = sendStates[chatId] ?? 'idle';

                                      return GestureDetector(
                                        onTap: () async {
                                          if (state != 'idle') return;
                                          setShareState(() {
                                            sendStates[chatId] = 'sending';
                                          });
                                          try {
                                            await supabase.sendMessage(
                                              chatId: chatId,
                                              text: caption.isNotEmpty ? caption : 'Shared a video',
                                              mediaUrl: videoUrl,
                                              mediaType: 'video',
                                            );
                                            setShareState(() {
                                              sendStates[chatId] = 'sent';
                                            });
                                          } catch (e) {
                                            setShareState(() {
                                              sendStates[chatId] = 'idle';
                                            });
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed to send: $e')),
                                            );
                                          }
                                        },
                                        child: Container(
                                          width: 72,
                                          margin: const EdgeInsets.symmetric(horizontal: 6),
                                          child: Column(
                                            children: [
                                              Stack(
                                                alignment: Alignment.center,
                                                children: [
                                                  UserAvatar(userId: otherUserId, radius: 24),
                                                  if (state == 'sending')
                                                    Positioned.fill(
                                                      child: Container(
                                                        decoration: const BoxDecoration(
                                                          color: Colors.black54,
                                                          shape: BoxShape.circle,
                                                        ),
                                                        child: const Center(
                                                          child: SizedBox(
                                                            width: 20,
                                                            height: 20,
                                                            child: CircularProgressIndicator(
                                                              color: Colors.white,
                                                              strokeWidth: 2,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  if (state == 'sent')
                                                    Positioned(
                                                      right: 0,
                                                      bottom: 0,
                                                      child: Container(
                                                        padding: const EdgeInsets.all(2),
                                                        decoration: const BoxDecoration(
                                                          color: Color(0xFF25D366),
                                                          shape: BoxShape.circle,
                                                        ),
                                                        child: const Icon(
                                                          Icons.check,
                                                          color: Colors.white,
                                                          size: 11,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                state == 'sent' ? 'Sent' : chatName,
                                                style: TextStyle(
                                                  color: state == 'sent' ? const Color(0xFF25D366) : Colors.white70,
                                                  fontSize: 10.5,
                                                  fontWeight: state == 'sent' ? FontWeight.bold : FontWeight.normal,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                      ),
                      
                      const Divider(color: Colors.white12, height: 16),
                      
                      // Row 2: Share to other apps (Horizontal Scroll List)
                      SizedBox(
                        height: 80,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.chat_bubble_outline, color: const Color(0xFF25D366)),
                              label: 'WhatsApp',
                              onTap: () {
                                Navigator.pop(context);
                                Share.share('Check out this video on Reel: $videoUrl');
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(
                                icon: Icons.camera_alt_outlined, 
                                color: Colors.transparent,
                                gradientColors: [
                                  const Color(0xFFFCAF45),
                                  const Color(0xFFE1306C),
                                  const Color(0xFF833AB4)
                                ],
                              ),
                              label: 'Instagram',
                              onTap: () {
                                Navigator.pop(context);
                                Share.share('Check out this video on Reel: $videoUrl');
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.facebook_outlined, color: const Color(0xFF1877F2)),
                              label: 'Facebook',
                              onTap: () {
                                Navigator.pop(context);
                                Share.share('Check out this video on Reel: $videoUrl');
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.message_outlined, color: const Color(0xFF00C6FF)),
                              label: 'SMS',
                              onTap: () {
                                Navigator.pop(context);
                                Share.share('Check out this video on Reel: $videoUrl');
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.share, color: const Color(0xFF33333F)),
                              label: 'Share...',
                              onTap: () {
                                Navigator.pop(context);
                                Share.share('Check out this video on Reel: $videoUrl');
                              },
                            ),
                          ],
                        ),
                      ),
                      
                      const Divider(color: Colors.white12, height: 16),
                      
                      // Row 3: Utilities options (Horizontal Scroll List)
                      SizedBox(
                        height: 80,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(
                                icon: Icons.repeat, 
                                color: _isReposted ? const Color(0xFFFE2C55) : const Color(0xFF2B2B36),
                                iconColor: _isReposted ? Colors.white : Colors.white70,
                              ),
                              label: 'Repost',
                              onTap: () {
                                Navigator.pop(context);
                                _toggleRepost();
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.link, color: const Color(0xFF2B2B36), iconColor: Colors.white70),
                              label: 'Copy Link',
                              onTap: () {
                                Navigator.pop(context);
                                Clipboard.setData(ClipboardData(text: videoUrl));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Video link copied to clipboard')),
                                );
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.save_alt, color: const Color(0xFF2B2B36), iconColor: Colors.white70),
                              label: 'Save Video',
                              onTap: () {
                                Navigator.pop(context);
                                _downloadAndWatermarkVideo(videoUrl, creatorName);
                              },
                            ),
                            _buildTikTokActionItem(
                              child: _buildCircularIcon(icon: Icons.report_gmailerrorred, color: const Color(0xFF2B2B36), iconColor: Colors.white70),
                              label: 'Report',
                              onTap: () async {
                                Navigator.pop(context);
                                await supabase.reportPost(widget.post['id']);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Video reported successfully')),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      
                      // Cancel Button
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        width: double.infinity,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xFF2B2B36),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 44),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }
  }

  Widget _buildTikTokActionItem({
    required Widget child,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10),
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 10.5),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircularIcon({
    required IconData icon,
    required Color color,
    Color iconColor = Colors.white,
    double size = 44,
    double iconSize = 20,
    List<Color>? gradientColors,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: gradientColors == null ? color : null,
        gradient: gradientColors != null
            ? LinearGradient(
                colors: gradientColors,
                begin: Alignment.bottomLeft,
                end: Alignment.topRight,
              )
            : null,
      ),
      child: Center(
        child: Icon(icon, color: iconColor, size: iconSize),
      ),
    );
  }

  Widget _buildShareAction({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  void _showCommentsSheet() {
    final textController = TextEditingController();
    final FocusNode commentFocusNode = FocusNode();
    Map<String, dynamic>? replyTarget;
    final Map<String, bool> expandedReplies = {};
    bool isStickerPickerActive = false;
    List<dynamic>? localCommentsList;
    bool loadingComments = true;
    String currentSortMode = 'Popular';
    final Set<String> likedCommentIds = {};
    bool loadedLikesCache = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            if (localCommentsList == null && loadingComments) {
              final myId = context.read<SupabaseService>().currentUser?.id;
              if (myId != null && !loadedLikesCache) {
                LocalStorageService().getCachedJson('liked_comments_$myId').then((cached) {
                  if (cached is List) {
                    likedCommentIds.addAll(cached.map((e) => e.toString()));
                  }
                  loadedLikesCache = true;
                });
              }
              context.read<SupabaseService>().getComments(widget.post['id']).then((comments) {
                setSheetState(() {
                  localCommentsList = List.from(comments);
                  loadingComments = false;
                });
              });
            }

            Widget buildCommentItem(Map<String, dynamic> comment, {required bool isReply}) {
              final cId = (comment['id'] ?? '').toString();
              final cUser = comment['userName'] ?? comment['username'] ?? 'User';
              final cText = comment['text'] ?? '';
              final isSticker = cText.startsWith('[STICKER:') && cText.endsWith(']');
              String? stickerUrl;
              if (isSticker) {
                stickerUrl = cText.substring(9, cText.length - 1);
              }
              final cUserId = comment['userId'] ?? comment['userid'] ?? '';
              final cCreatedAtStr = (comment['createdAt'] ?? comment['createdat']) as String?;
              final replyTo = comment['replyToUserName'] ?? comment['replytousername'] as String?;
              
              String cTimeStr = '';
              if (cCreatedAtStr != null) {
                try {
                  final parsed = DateTime.parse(cCreatedAtStr).toLocal();
                  cTimeStr = '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
                } catch (_) {}
              }
              
              final myId = context.read<SupabaseService>().currentUser?.id;
              final isCommentOwner = cUserId == myId;
              final isPostOwner = (widget.post['userId'] ?? widget.post['userid']) == myId;
              final isCreator = cUserId == (widget.post['userId'] ?? widget.post['userid']);
              final isPinned = comment['isPinned'] == true || comment['ispinned'] == true;
              final isLiked = likedCommentIds.contains(cId);
              final likesCount = comment['likes'] ?? 0;

              void showCommentOptions(BuildContext context, StateSetter setSheetState) {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: const Color(0xFF161616),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (context) {
                    return SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          ListTile(
                            leading: const Icon(Icons.copy, color: Colors.white70),
                            title: const Text('Copy Comment', style: TextStyle(color: Colors.white)),
                            onTap: () async {
                              await Clipboard.setData(ClipboardData(text: cText));
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Comment copied to clipboard'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            },
                          ),
                          if (isPostOwner)
                            ListTile(
                              leading: Icon(
                                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                                color: Colors.white70,
                              ),
                              title: Text(
                                isPinned ? 'Unpin Comment' : 'Pin Comment',
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () async {
                                final supabase = context.read<SupabaseService>();
                                final navigator = Navigator.of(context);
                                final scaffoldMessenger = ScaffoldMessenger.of(context);
                                final currentlyPinned = isPinned;

                                navigator.pop(); // Close comment options bottom sheet

                                try {
                                  if (!currentlyPinned) {
                                    for (var c in localCommentsList ?? []) {
                                      if (c['isPinned'] == true || c['ispinned'] == true) {
                                        c['isPinned'] = false;
                                        c['ispinned'] = false;
                                        await supabase.togglePinComment(c['id'].toString(), false);
                                      }
                                    }
                                  }

                                  await supabase.togglePinComment(cId, !currentlyPinned);
                                  setSheetState(() {
                                    comment['isPinned'] = !currentlyPinned;
                                    comment['ispinned'] = !currentlyPinned;
                                  });
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text(currentlyPinned ? 'Comment unpinned' : 'Comment pinned to top'),
                                      backgroundColor: const Color(0xFF00FF7F),
                                    ),
                                  );
                                } catch (e) {
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                      content: Text('Failed to pin/unpin comment: $e'),
                                      backgroundColor: const Color(0xFF7E1C31),
                                    ),
                                  );
                                }
                              },
                            ),
                          if (isCommentOwner || isPostOwner)
                            ListTile(
                              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              title: const Text('Delete Comment', style: TextStyle(color: Colors.redAccent)),
                              onTap: () async {
                                final supabase = context.read<SupabaseService>();
                                final navigator = Navigator.of(context);
                                final scaffoldMessenger = ScaffoldMessenger.of(context);

                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (dialogCtx) => AlertDialog(
                                    backgroundColor: const Color(0xFF121212),
                                    title: const Text('Delete Comment', style: TextStyle(color: Colors.white)),
                                    content: const Text('Are you sure you want to delete this comment?', style: TextStyle(color: Colors.white70)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(dialogCtx, false),
                                        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(dialogCtx, true),
                                        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  navigator.pop(); // Close comment options bottom sheet safely
                                  try {
                                    await supabase.deleteComment(cId);
                                    setSheetState(() {
                                      localCommentsList?.removeWhere((c) => (c['id'] ?? '').toString() == cId);
                                    });
                                  } catch (e) {
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to delete comment: $e'),
                                        backgroundColor: const Color(0xFF7E1C31),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          if (!isCommentOwner)
                            ListTile(
                              leading: const Icon(Icons.report_problem_outlined, color: Colors.amber),
                              title: const Text('Report Comment', style: TextStyle(color: Colors.white)),
                              onTap: () {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Comment reported. Thank you for keeping Reel safe!'),
                                    backgroundColor: Color(0xFF7E1C31),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    );
                  },
                );
              }

              return GestureDetector(
                onLongPress: () => showCommentOptions(context, setSheetState),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: 6.0,
                    horizontal: isReply ? 0.0 : 16.0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UserAvatar(userId: cUserId, radius: isReply ? 12 : 16),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  cUser,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: isReply ? 12 : 13,
                                  ),
                                ),
                                if (isCreator) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFE2C55),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Creator',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                                if (cTimeStr.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '• $cTimeStr',
                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                                  ),
                                ],
                                if (isPinned) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: Colors.amber.withOpacity(0.5), width: 0.5),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Icon(Icons.push_pin, color: Colors.amber, size: 9),
                                        SizedBox(width: 2),
                                        Text(
                                          'Pinned',
                                          style: TextStyle(color: Colors.amber, fontSize: 9, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (isSticker && stickerUrl != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0, bottom: 4.0),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: stickerUrl.startsWith('emoji:')
                                      ? Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Text(
                                            stickerUrl.substring(6),
                                            style: const TextStyle(fontSize: 54),
                                          ),
                                        )
                                      : (stickerUrl.startsWith('assets/')
                                          ? Image.asset(
                                              stickerUrl,
                                              width: 80,
                                              height: 80,
                                              fit: BoxFit.contain,
                                            )
                                          : Image.network(
                                              stickerUrl,
                                              width: 80,
                                              height: 80,
                                              fit: BoxFit.contain,
                                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white24, size: 24),
                                            )),
                                ),
                              )
                            else
                              RichText(
                                text: TextSpan(
                                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                                  children: [
                                    if (isReply && replyTo != null && replyTo.isNotEmpty) ...[
                                      TextSpan(
                                        text: '@$replyTo ',
                                        style: const TextStyle(
                                          color: Color(0xFF00BFFF),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                    TextSpan(text: cText),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    setSheetState(() {
                                      replyTarget = {
                                        'parentId': comment['parentId'] ?? comment['parentid'] ?? comment['id'],
                                        'userName': cUser,
                                      };
                                    });
                                    commentFocusNode.requestFocus();
                                  },
                                  child: const Text(
                                    'Reply',
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () async {
                              final supabase = context.read<SupabaseService>();
                              final myId = supabase.currentUser?.id;
                              if (myId == null) return;

                              final isIncrement = !isLiked;
                              setSheetState(() {
                                if (isIncrement) {
                                  likedCommentIds.add(cId);
                                  comment['likes'] = (comment['likes'] ?? 0) + 1;
                                } else {
                                  likedCommentIds.remove(cId);
                                  comment['likes'] = ((comment['likes'] ?? 0) - 1).clamp(0, 999999);
                                }
                              });

                              try {
                                await supabase.toggleLikeComment(cId, likesCount, isIncrement);
                                await LocalStorageService().cacheJson('liked_comments_$myId', likedCommentIds.toList());
                              } catch (_) {}
                            },
                            child: Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              color: isLiked ? const Color(0xFFFE2C55) : Colors.white30,
                              size: 18,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            likesCount > 0 ? '$likesCount' : '0',
                            style: const TextStyle(color: Colors.white30, fontSize: 10),
                          ),
                        ],
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.white30, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => showCommentOptions(context, setSheetState),
                      )
                    ],
                  ),
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            localCommentsList != null
                                ? '${localCommentsList!.where((c) => c['parentId'] == null && c['parentid'] == null).length} comments'
                                : 'Comments',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: currentSortMode,
                              dropdownColor: const Color(0xFF1E1E1E),
                              icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 16),
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                              items: const [
                                DropdownMenuItem(
                                  value: 'Popular',
                                  child: Text('Popular'),
                                ),
                                DropdownMenuItem(
                                  value: 'Latest',
                                  child: Text('Latest'),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setSheetState(() {
                                    currentSortMode = val;
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: loadingComments
                          ? const Center(child: CircularProgressIndicator())
                          : (() {
                              final allComments = localCommentsList ?? [];
                              if (allComments.isEmpty) {
                                return const Center(
                                  child: Text(
                                    'Be the first to reply!',
                                    style: TextStyle(color: Colors.white30, fontSize: 14),
                                  ),
                                );
                              }

                              final parentComments = allComments
                                  .where((c) => c['parentId'] == null && c['parentid'] == null)
                                  .toList();
                              
                              parentComments.sort((a, b) {
                                final aPinned = a['isPinned'] == true || a['ispinned'] == true;
                                final bPinned = b['isPinned'] == true || b['ispinned'] == true;
                                if (aPinned && !bPinned) return -1;
                                if (!aPinned && bPinned) return 1;

                                if (currentSortMode == 'Popular') {
                                  final aLikes = a['likes'] ?? 0;
                                  final bLikes = b['likes'] ?? 0;
                                  if (aLikes != bLikes) {
                                    return bLikes.compareTo(aLikes);
                                  }
                                }

                                final aTime = DateTime.tryParse(a['createdAt'] ?? a['createdat'] ?? '') ?? DateTime.now();
                                final bTime = DateTime.tryParse(b['createdAt'] ?? b['createdat'] ?? '') ?? DateTime.now();
                                return bTime.compareTo(aTime);
                              });

                              final childReplies = <String, List<dynamic>>{};
                              for (var c in allComments) {
                                final parentIdVal = c['parentId'] ?? c['parentid'];
                                if (parentIdVal != null) {
                                  final pIdStr = parentIdVal.toString();
                                  childReplies.putIfAbsent(pIdStr, () => []).add(c);
                                }
                              }

                              return ListView.builder(
                                itemCount: parentComments.length,
                                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                                itemBuilder: (context, idx) {
                                  final parent = parentComments[idx];
                                  final pId = (parent['id'] ?? '').toString();
                                  final replies = childReplies[pId] ?? [];
                                  final isExpanded = expandedReplies[pId] ?? false;

                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      buildCommentItem(parent, isReply: false),
                                      if (replies.isNotEmpty) ...[
                                        Padding(
                                          padding: const EdgeInsets.only(left: 58.0, bottom: 4.0),
                                          child: GestureDetector(
                                            onTap: () {
                                              setSheetState(() {
                                                expandedReplies[pId] = !isExpanded;
                                              });
                                            },
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 24,
                                                  height: 1,
                                                  color: Colors.white24,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  isExpanded
                                                      ? 'Hide replies'
                                                      : 'View replies (${replies.length})',
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (isExpanded)
                                          Padding(
                                            padding: const EdgeInsets.only(left: 40.0),
                                            child: Column(
                                              children: replies
                                                  .map((r) => buildCommentItem(r, isReply: true))
                                                  .toList(),
                                            ),
                                          ),
                                      ],
                                    ],
                                  );
                                },
                              );
                            }()),
                    ),
                    if (replyTarget != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: Colors.white.withOpacity(0.05),
                        child: Row(
                          children: [
                            Text(
                              'Replying to @${replyTarget!['userName']}',
                              style: const TextStyle(color: Color(0xFF00BFFF), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () {
                                setSheetState(() {
                                    replyTarget = null;
                                });
                              },
                              child: const Icon(Icons.close, color: Colors.white54, size: 16),
                            ),
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F1F),
                        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.08))),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              isStickerPickerActive ? Icons.keyboard : Icons.face,
                              color: Colors.white70,
                            ),
                            onPressed: () {
                              setSheetState(() {
                                isStickerPickerActive = !isStickerPickerActive;
                                if (isStickerPickerActive) {
                                  commentFocusNode.unfocus();
                                } else {
                                  commentFocusNode.requestFocus();
                                }
                              });
                            },
                          ),
                          Expanded(
                            child: TextField(
                              controller: textController,
                              focusNode: commentFocusNode,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: 'Add a comment...',
                                hintStyle: TextStyle(color: Colors.white38),
                                border: InputBorder.none,
                              ),
                              onTap: () {
                                if (isStickerPickerActive) {
                                  setSheetState(() {
                                    isStickerPickerActive = false;
                                  });
                                }
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.send, color: Color(0xFF00BFFF)),
                            onPressed: () async {
                              final text = textController.text.trim();
                              if (text.isEmpty) return;
                              final supabase = context.read<SupabaseService>();
                              final myProfile = await supabase.getUserProfile(supabase.currentUser!.id);
                              final userName = myProfile?['name'] ?? 'User';

                              try {
                                final newComment = await supabase.addComment(
                                  widget.post['id'],
                                  text,
                                  parentId: replyTarget?['parentId'],
                                  replyToUserName: replyTarget?.containsKey('userName') == true ? replyTarget!['userName'] : null,
                                );
                                setSheetState(() {
                                  localCommentsList?.add(newComment);
                                  textController.clear();
                                  replyTarget = null;
                                });
                                setState(() {
                                  _commentsCount++;
                                });
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Failed to post comment: $e'),
                                    backgroundColor: const Color(0xFF7E1C31),
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    if (isStickerPickerActive)
                      SizedBox(
                        height: 250,
                        child: StickerPicker(
                          onStickerSelected: (stickerPath) async {
                            final stickerText = '[STICKER:$stickerPath]';
                            final supabase = context.read<SupabaseService>();
                            final myProfile = await supabase.getUserProfile(supabase.currentUser!.id);
                            final userName = myProfile?['name'] ?? 'User';

                            try {
                              final newComment = await supabase.addComment(
                                widget.post['id'],
                                stickerText,
                                parentId: replyTarget?['parentId'],
                                replyToUserName: replyTarget?.containsKey('userName') == true ? replyTarget!['userName'] : null,
                              );
                              setSheetState(() {
                                localCommentsList?.add(newComment);
                                replyTarget = null;
                                isStickerPickerActive = false;
                              });
                              setState(() {
                                _commentsCount++;
                              });
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to post sticker: $e'),
                                  backgroundColor: const Color(0xFF7E1C31),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final supabase = context.read<SupabaseService>();
    final videoUrl = widget.post['videoUrl'] as String?;
    final caption = widget.post['text'] ?? '';
    final creatorId = widget.post['userId'] ?? widget.post['userid'] ?? '';
    final creatorName = widget.post['userName'] ?? widget.post['username'] ?? 'User';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Video Player
          if (_videoController != null && _videoController!.value.isInitialized)
            GestureDetector(
              onTap: _togglePlayPause,
              onDoubleTap: () {},
              onDoubleTapDown: _onDoubleTap,
              onLongPressStart: (details) {
                if (_videoController == null || !_videoController!.value.isInitialized) return;
                final screenWidth = MediaQuery.of(context).size.width;
                if (details.localPosition.dx > screenWidth / 2) {
                  _videoController!.setPlaybackSpeed(2.0);
                  setState(() {
                    _isFastForwarding = true;
                  });
                }
              },
              onLongPressEnd: (details) {
                if (_videoController == null || !_videoController!.value.isInitialized) return;
                if (_isFastForwarding) {
                  _videoController!.setPlaybackSpeed(1.0);
                  setState(() {
                    _isFastForwarding = false;
                  });
                }
              },
              onLongPressUp: () {
                if (_videoController == null || !_videoController!.value.isInitialized) return;
                if (_isFastForwarding) {
                  _videoController!.setPlaybackSpeed(1.0);
                  setState(() {
                    _isFastForwarding = false;
                  });
                }
              },
              child: SizedBox.expand(
                child: FittedBox(
                  fit: _fitMode,
                  child: SizedBox(
                    width: _videoController!.value.size.width,
                    height: _videoController!.value.size.height,
                    child: VideoPlayer(_videoController!),
                  ),
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFFE2C55)),
            ),

          // Custom Play/Pause Overlay indicator
          if (_showPlayPauseOverlay)
            Center(
              child: AnimatedOpacity(
                opacity: _showPlayPauseOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _playIconIsPlay ? Icons.play_arrow : Icons.pause,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),

          // 2X Speed Indicator Banner Overlay
          if (_isFastForwarding)
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.fast_forward, color: Colors.white, size: 16),
                      SizedBox(width: 6),
                      Text(
                        '2X Speed',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Video Progress Bar (TikTok style scrubbing bar at bottom)
          if (_videoController != null && _videoController!.value.isInitialized)
            ValueListenableBuilder(
              valueListenable: _videoController!,
              builder: (context, VideoPlayerValue value, child) {
                final duration = value.duration.inMilliseconds;
                final position = value.position.inMilliseconds;
                double progress = 0.0;
                if (duration > 0) {
                  progress = (position / duration).clamp(0.0, 1.0);
                }
                final activeProgress = _isScrubbing ? _scrubValue : progress;

                return Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (details) {
                      final durationMs = _videoController!.value.duration.inMilliseconds;
                      final currentMs = _videoController!.value.position.inMilliseconds;
                      double initialProgress = 0.0;
                      if (durationMs > 0) {
                        initialProgress = (currentMs / durationMs).clamp(0.0, 1.0);
                      }
                      setState(() {
                        _isScrubbing = true;
                        _initialTouchX = details.globalPosition.dx;
                        _initialScrubProgress = initialProgress;
                        _scrubValue = initialProgress;
                        _scrubTime = Duration(milliseconds: currentMs);
                        _pauseVideo();
                      });
                    },
                    onHorizontalDragUpdate: (details) {
                      final screenWidth = MediaQuery.of(context).size.width;
                      final deltaX = details.globalPosition.dx - _initialTouchX;
                      final deltaProgress = deltaX / screenWidth;
                      setState(() {
                        _scrubValue = (_initialScrubProgress + deltaProgress).clamp(0.0, 1.0);
                        final durationMs = _videoController!.value.duration.inMilliseconds;
                        _scrubTime = Duration(milliseconds: (_scrubValue * durationMs).toInt());
                      });
                    },
                    onHorizontalDragEnd: (details) {
                      final durationMs = _videoController!.value.duration.inMilliseconds;
                      final seekToMs = (_scrubValue * durationMs).toInt();
                      _videoController!.seekTo(Duration(milliseconds: seekToMs)).then((_) {
                        _resumeVideo();
                      });
                      setState(() {
                        _isScrubbing = false;
                      });
                    },
                    onTapDown: (details) {
                      final screenWidth = MediaQuery.of(context).size.width;
                      final clickX = details.globalPosition.dx;
                      final tapProgress = (clickX / screenWidth).clamp(0.0, 1.0);
                      final durationMs = _videoController!.value.duration.inMilliseconds;
                      _videoController!.seekTo(Duration(milliseconds: (tapProgress * durationMs).toInt()));
                    },
                    child: Container(
                      height: 38, // Expanded hit area to easily grab
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.only(bottom: 4), // Slightly offset from absolute bottom to avoid system bars
                      child: Container(
                        height: _isScrubbing ? 8.0 : 2.5,
                        width: double.infinity,
                        color: Colors.white24,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: activeProgress,
                          child: Container(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // Scrubbing Progress Preview Overlay (center screen overlay just like TikTok)
          if (_isScrubbing && _scrubTime != null && _videoController != null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.linear_scale, color: Colors.white, size: 28),
                    const SizedBox(height: 8),
                    Text(
                      '${_formatDuration(_scrubTime!)} / ${_formatDuration(_videoController!.value.duration)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Heart Coordinate pop animations
          ..._hearts.map((offset) {
            return Positioned(
              left: offset.dx - 40,
              top: offset.dy - 40,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 500),
                curve: Curves.elasticOut,
                builder: (context, scale, child) {
                  return Transform.scale(
                    scale: scale,
                    child: Opacity(
                      opacity: (2.0 - scale * 2.0).clamp(0.0, 1.0),
                      child: const Icon(
                        Icons.favorite,
                        color: Color(0xFFFE2C55),
                        size: 80,
                      ),
                    ),
                  );
                },
              ),
            );
          }),

          // Dark vignette overlays
          IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black54,
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black87,
                  ],
                  stops: [0.0, 0.2, 0.8, 1.0],
                ),
              ),
            ),
          ),

          // Left/Bottom Creator Profile and Description Details
          Positioned(
            left: 16,
            bottom: 30,
            right: 80,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () {
                    if (creatorId.isNotEmpty) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ReelProfilePage(userId: creatorId),
                        ),
                      );
                    }
                  },
                  child: Text(
                    '@${_creatorUsername ?? creatorName.toLowerCase().replaceAll(' ', '')}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  caption,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.music_note, color: Colors.white70, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SizedBox(
                        height: 20,
                        child: Text(
                          'Original Audio - $creatorName',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                
                // Bottom TikTok-Style Add Comment Input Bar Overlay
                GestureDetector(
                  onTap: _showCommentsSheet,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, color: Colors.white.withOpacity(0.6), size: 14),
                        const SizedBox(width: 8),
                        Text(
                          'Add comment...',
                          style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Right Vertical Button Overlay actions
          Positioned(
            right: 16,
            bottom: 96,
            child: Column(
              children: [
                // Avatar with creator badge
                GestureDetector(
                  onTap: () {
                    if (creatorId.isNotEmpty) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ReelProfilePage(userId: creatorId),
                        ),
                      );
                    }
                  },
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: UserAvatar(userId: creatorId, radius: 22),
                      ),
                      if (creatorId.isNotEmpty && creatorId != (_myUserId ?? supabase.currentUser?.id) && !_isFollowing)
                        Positioned(
                          bottom: -8,
                          child: GestureDetector(
                            onTap: () async {
                              try {
                                await supabase.followUser(creatorId);
                                setState(() {
                                  _isFollowing = true;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Followed creator!'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              } catch (e) {
                                debugPrint("Failed to follow: $e");
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFE2C55),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.add,
                                color: Colors.white,
                                size: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Heart/Like
                _buildActionItem(
                  icon: _isLiked ? Icons.favorite : Icons.favorite_border,
                  label: '$_likesCount',
                  color: _isLiked ? const Color(0xFFFE2C55) : Colors.white,
                  onTap: _toggleLike,
                ),
                const SizedBox(height: 14),

                // Comments (TikTok style speech bubble)
                _buildActionItem(
                  icon: Icons.chat_bubble,
                  label: '$_commentsCount',
                  onTap: _showCommentsSheet,
                ),
                const SizedBox(height: 14),

                // Save Post (Bookmark)
                _buildActionItem(
                  icon: _isSaved ? Icons.bookmark : Icons.bookmark_border,
                  label: '$_savesCount',
                  color: _isSaved ? Colors.amber : Colors.white,
                  onTap: _toggleSave,
                ),
                const SizedBox(height: 14),

                // Repost Button
                _buildActionItem(
                  icon: Icons.repeat,
                  label: '$_repostsCount',
                  color: _isReposted ? const Color(0xFF00FF7F) : Colors.white,
                  onTap: _toggleRepost,
                ),
                const SizedBox(height: 14),

                // Share
                _buildActionItem(
                  icon: Icons.reply_outlined,
                  label: 'Share',
                  onTap: _showShareSheet,
                ),
              ],
            ),
          ),

          // Rotating Music Vinyl disc
          Positioned(
            right: 16,
            bottom: 30,
            child: RotationTransition(
              turns: _discController,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color(0xFF272727),
                      Colors.black,
                    ],
                  ),
                ),
                child: const Icon(
                  Icons.album,
                  color: Colors.white30,
                  size: 26,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionItem({
    required IconData icon,
    required String label,
    Color color = Colors.white,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(
            icon,
            color: color,
            size: 30,
            shadows: [
              Shadow(
                color: Colors.black.withOpacity(0.6),
                offset: const Offset(0, 1),
                blurRadius: 3,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              shadows: [
                Shadow(
                  color: Colors.black45,
                  offset: Offset(0, 1),
                  blurRadius: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// LRU Video Controller Cache with progressive background caching via flutter_cache_manager
class VideoControllerCache {
  static final Map<String, VideoPlayerController> _cache = {};
  static final List<String> _keys = [];
  static const int _maxSize = 10;

  static Future<VideoPlayerController> getController(String url) async {
    if (_cache.containsKey(url)) {
      final controller = _cache[url]!;
      _keys.remove(url);
      _keys.add(url);
      return controller;
    }

    VideoPlayerController controller;
    try {
      final fileInfo = await DefaultCacheManager().getFileFromCache(url);
      if (fileInfo != null) {
        // Play directly from offline cache
        controller = VideoPlayerController.file(fileInfo.file);
      } else {
        // Play instantly from network streaming (no delay!)
        controller = VideoPlayerController.networkUrl(Uri.parse(url));
        // Cache in background
        DefaultCacheManager().downloadFile(url);
      }
    } catch (e) {
      debugPrint("Error loading cached video: $e");
      controller = VideoPlayerController.networkUrl(Uri.parse(url));
    }

    await controller.initialize();
    
    _cache[url] = controller;
    _keys.add(url);

    if (_keys.length > _maxSize) {
      final oldestUrl = _keys.removeAt(0);
      final oldestController = _cache.remove(oldestUrl);
      oldestController?.dispose();
    }

    return controller;
  }

  static void preloadController(String url) async {
    if (_cache.containsKey(url)) return;

    try {
      // Trigger download in background
      DefaultCacheManager().downloadFile(url);

      VideoPlayerController controller;
      final fileInfo = await DefaultCacheManager().getFileFromCache(url);
      if (fileInfo != null) {
        controller = VideoPlayerController.file(fileInfo.file);
      } else {
        controller = VideoPlayerController.networkUrl(Uri.parse(url));
      }

      _cache[url] = controller;
      _keys.add(url);

      controller.initialize().then((_) {
        debugPrint('Preloaded video successfully: $url');
      }).catchError((e) {
        debugPrint('Failed to preload video: $e');
        _cache.remove(url);
        _keys.remove(url);
        controller.dispose();
      });

      if (_keys.length > _maxSize) {
        final oldestUrl = _keys.removeAt(0);
        final oldestController = _cache.remove(oldestUrl);
        oldestController?.dispose();
      }
    } catch (e) {
      debugPrint("Preload error: $e");
    }
  }

  static void pauseAllExcept(VideoPlayerController? activeController) {
    for (final controller in _cache.values) {
      if (controller != activeController) {
        try {
          controller.pause();
        } catch (_) {}
      }
    }
  }

  static void clear() {
    for (final controller in _cache.values) {
      controller.dispose();
    }
    _cache.clear();
    _keys.clear();
  }
}

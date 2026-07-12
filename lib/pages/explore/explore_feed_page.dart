import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/explore/create_post_screen.dart';
import 'package:reel/widgets/chat/sticker_picker.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/explore/full_screen_image_viewer.dart';
import 'package:reel/pages/updates/status_viewer_screen.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/widgets/status_ring_painter.dart';

class ExploreFeedPage extends StatefulWidget {
  const ExploreFeedPage({super.key});

  @override
  State<ExploreFeedPage> createState() => _ExploreFeedPageState();
}

class _ExploreFeedPageState extends State<ExploreFeedPage> {
  late Future<List<dynamic>> _feedFuture;

  @override
  void initState() {
    super.initState();
    _feedFuture = context.read<SupabaseService>().getExploreFeed();
  }

  Future<void> _refreshFeed() async {
    setState(() {
      _feedFuture = context.read<SupabaseService>().getExploreFeed();
    });
  }

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
        title: Text('Explore', style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
        centerTitle: false,
      ),
      body: RefreshIndicator(
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
                            'userName': userNames[userId],
                            'statuses': userStatuses,
                            'latestUpdate': userStatuses.last['createdAt'] ?? userStatuses.last['createdat'],
                          });
                        }
                        
                        // Sort user status groups by who has the most recent status (descending)
                        userStatusGroups.sort((a, b) {
                          final dateA = DateTime.parse(a['latestUpdate'] ?? '');
                          final dateB = DateTime.parse(b['latestUpdate'] ?? '');
                          return dateB.compareTo(dateA);
                        });

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
                  const SliverFillRemaining(
                    child: Center(child: Text('No posts yet', style: TextStyle(color: Colors.white54))),
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
      floatingActionButton: FloatingActionButton(
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

  Map<String, dynamic>? _quotedPost;
  bool _loadingQuotedPost = false;
  
  // Tracking telemetry
  late DateTime _viewStartTime;

  @override
  void initState() {
    super.initState();
    _viewStartTime = DateTime.now();
    _likesCount = (widget.post['likes'] as num?)?.toInt() ?? 0;
    _repostsCount = (widget.post['reposts'] as num?)?.toInt() ?? 0;
    final supabase = context.read<SupabaseService>();
    _isLiked = supabase.likedPostIds.contains(widget.post['id']);
    _isSaved = supabase.savedPostIds.contains(widget.post['id']);
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
    setState(() {
      _isSaved = !_isSaved;
    });
    try {
      await context.read<SupabaseService>().toggleSavePost(widget.post['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isSaved ? 'Post saved to Bookmarks' : 'Post removed from Bookmarks'),
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
                          if (isCommentOwner || isPostOwner)
                            ListTile(
                              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              title: const Text('Delete Comment', style: TextStyle(color: Colors.redAccent)),
                              onTap: () async {
                                Navigator.pop(context);
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: const Color(0xFF121212),
                                    title: const Text('Delete Comment', style: TextStyle(color: Colors.white)),
                                    content: const Text('Are you sure you want to delete this comment?', style: TextStyle(color: Colors.white70)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await context.read<SupabaseService>().deleteComment(cId);
                                  setSheetState(() {
                                    localCommentsList?.removeWhere((c) => (c['id'] ?? '').toString() == cId);
                                  });
                                  setState(() {
                                    _commentsCount = (_commentsCount - 1).clamp(0, 999999);
                                  });
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
                                if (cTimeStr.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '• $cTimeStr',
                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
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
                    const Text(
                      'Replies',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 12),
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
                                padding: const EdgeInsets.symmetric(vertical: 8),
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
                '@${qUserName.toLowerCase().replaceAll(' ', '')}',
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
                          '@${displayUserName.toLowerCase().replaceAll(' ', '')}',
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

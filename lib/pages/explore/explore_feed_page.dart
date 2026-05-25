import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/explore/create_post_screen.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/updates/status_viewer_screen.dart';
import 'package:reel/widgets/user_avatar.dart';

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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.8),
        elevation: 0,
        title: const Text('Explore', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: false,
      ),
      body: RefreshIndicator(
        onRefresh: _refreshFeed,
        color: Theme.of(context).primaryColor,
        backgroundColor: Colors.black,
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
                        final statuses = snapshot.data ?? [];
                        if (statuses.isEmpty) {
                          return const Center(
                            child: Text(
                              'No recent active status updates',
                              style: TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                          );
                        }

                        return ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: statuses.length,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemBuilder: (context, index) {
                            final status = statuses[index];
                            final userName = status['userName'] ?? status['username'] ?? 'User';
                            final imageUrl = status['imageUrl'] ?? status['imageurl'] ?? '';
                            final userId = status['userId'] ?? status['userid'] ?? '';

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
                                            statuses: [Map<String, dynamic>.from(status)],
                                          ),
                                        ),
                                      );
                                    },
                                    child: UserAvatar(
                                      userId: userId,
                                      radius: 26,
                                      border: Border.all(color: const Color(0xFF00BFFF), width: 2),
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
  late int _likesCount;
  late int _repostsCount;

  @override
  void initState() {
    super.initState();
    _likesCount = widget.post['likes'] ?? 0;
    _repostsCount = widget.post['reposts'] ?? 0;
    _loadCommentsCount();
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
    setState(() {
      _isLiked = !_isLiked;
      _likesCount = _isLiked ? _likesCount + 1 : (_likesCount > 0 ? _likesCount - 1 : 0);
    });
    try {
      await context.read<SupabaseService>().toggleLikePost(widget.post['id'], widget.post['likes'] ?? 0, _isLiked);
    } catch (_) {}
  }

  Future<void> _repost() async {
    setState(() {
      _repostsCount++;
    });
    try {
      await context.read<SupabaseService>().repostPost(widget.post['id'], widget.post['reposts'] ?? 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post shared successfully')),
      );
    } catch (_) {}
  }

  void _showCommentsBottomSheet(BuildContext context) {
    final textController = TextEditingController();
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
                      child: FutureBuilder<List<dynamic>>(
                        future: context.read<SupabaseService>().getComments(widget.post['id']),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final comments = snapshot.data ?? [];
                          if (comments.isEmpty) {
                            return const Center(
                              child: Text(
                                'Be the first to reply!',
                                style: TextStyle(color: Colors.white30, fontSize: 14),
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: comments.length,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemBuilder: (context, idx) {
                              final comment = comments[idx];
                              final cUser = comment['userName'] ?? 'User';
                              final cText = comment['text'] ?? '';
                              final cUserId = comment['userId'] ?? '';
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    UserAvatar(userId: cUserId, radius: 16),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            cUser,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            cText,
                                            style: const TextStyle(color: Colors.white70, fontSize: 14),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
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
                          Expanded(
                            child: TextField(
                              controller: textController,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: 'Post your reply...',
                                hintStyle: TextStyle(color: Colors.white38),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.send_rounded, color: Color(0xFF00BFFF)),
                            onPressed: () async {
                              final text = textController.text.trim();
                              if (text.isEmpty) return;
                              await context.read<SupabaseService>().addComment(widget.post['id'], text);
                              textController.clear();
                              setSheetState(() {});
                              _loadCommentsCount();
                              if (widget.onPostUpdated != null) {
                                widget.onPostUpdated!();
                              }
                            },
                          ),
                        ],
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
    final String text = widget.post['text'] ?? '';
    final String userName = widget.post['userName'] ?? widget.post['username'] ?? 'User';
    final String? imageUrl = widget.post['imageUrl'] ?? widget.post['imageurl'];
    final String userId = widget.post['userId'] ?? widget.post['userid'] ?? 'unknown';

    final myId = context.read<SupabaseService>().currentUser?.id;
    final isMe = userId == myId;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(
            userId: userId,
            radius: 24,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ReelProfilePage(userId: userId),
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
                            builder: (context) => ReelProfilePage(userId: userId),
                          ),
                        );
                      },
                      child: Text(
                        userName,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '@${userName.toLowerCase().replaceAll(' ', '')}',
                      style: const TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const Spacer(),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, color: Colors.white54, size: 20),
                      color: Colors.grey[900],
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      onSelected: (value) async {
                        if (value == 'delete') {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: Colors.grey[900],
                              title: const Text('Delete Post', style: TextStyle(color: Colors.white)),
                              content: const Text('Are you sure you want to delete this post?', style: TextStyle(color: Colors.white70)),
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
                        const PopupMenuItem(
                          value: 'report',
                          child: Row(
                            children: [
                              Icon(Icons.report_problem_outlined, color: Colors.amber, size: 18),
                              SizedBox(width: 8),
                              Text('Report Post', style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                ),
                if (imageUrl != null)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    height: 200,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      image: DecorationImage(
                        image: NetworkImage(imageUrl),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
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
                    _buildPostAction(Icons.share_outlined, ''),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPostAction(IconData icon, String label, {bool active = false, Color activeColor = Colors.white}) {
    return Row(
      children: [
        Icon(icon, color: active ? activeColor : Colors.white54, size: 18),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: active ? activeColor : Colors.white54, fontSize: 12)),
        ],
      ],
    );
  }
}

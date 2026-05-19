import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/explore/create_post_screen.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/updates/updates_page.dart';
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
                                          builder: (context) => StatusViewerPage(status: status),
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
                        return ExplorePostItem(post: posts[index]);
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

class ExplorePostItem extends StatelessWidget {
  final Map<String, dynamic> post;
  const ExplorePostItem({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final String text = post['text'] ?? '';
    final String userName = post['userName'] ?? post['username'] ?? 'User';
    final String? imageUrl = post['imageUrl'] ?? post['imageurl'];
    final String userId = post['userId'] ?? post['userid'] ?? 'unknown';
    final int likes = post['likes'] ?? 0;

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
                      '@${userName.toLowerCase().replaceAll(' ', '')} • 2h',
                      style: const TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const Spacer(),
                    const Icon(Icons.more_horiz, color: Colors.white54, size: 20),
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
                    _buildPostAction(Icons.chat_bubble_outline, '0'),
                    _buildPostAction(Icons.repeat, '0'),
                    _buildPostAction(Icons.favorite_border, likes.toString()),
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

  Widget _buildPostAction(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 18),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ],
    );
  }
}

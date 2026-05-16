import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/appwrite_service.dart';
import 'package:appwrite/models.dart' as models;
import 'package:reel/pages/explore/create_post_screen.dart';

class ExploreFeedPage extends StatefulWidget {
  const ExploreFeedPage({super.key});

  @override
  State<ExploreFeedPage> createState() => _ExploreFeedPageState();
}

class _ExploreFeedPageState extends State<ExploreFeedPage> {
  late Future<List<models.Document>> _feedFuture;

  @override
  void initState() {
    super.initState();
    _feedFuture = context.read<AppwriteService>().getExploreFeed();
  }

  Future<void> _refreshFeed() async {
    setState(() {
      _feedFuture = context.read<AppwriteService>().getExploreFeed();
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
        child: FutureBuilder<List<models.Document>>(
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
                // Top Row: Nearby Statuses (Keeping as mock for now or fetch later)
                SliverToBoxAdapter(
                  child: Container(
                    height: 110,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
                    ),
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: 10,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemBuilder: (context, index) {
                        return _buildNearbyStatus(index);
                      },
                    ),
                  ),
                ),
                // Feed: X-Style Posts from Appwrite
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

  Widget _buildNearbyStatus(int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF00BFFF), width: 2),
            ),
            child: CircleAvatar(
              radius: 30,
              backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=nearby_$index'),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Nearby',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class ExplorePostItem extends StatelessWidget {
  final models.Document post;
  const ExplorePostItem({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final String text = post.data['text'] ?? '';
    final String userName = post.data['userName'] ?? 'User';
    final String? imageId = post.data['imageId'];
    final String createdAt = post.data['createdAt'] ?? '';
    final int likes = post.data['likes'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=${post.data['userId']}'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      userName,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
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
                if (imageId != null)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    height: 200,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      image: const DecorationImage(
                        image: NetworkImage('https://picsum.photos/600/400'), // Replace with Appwrite storage URL
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:reel/pages/explore/explore_feed_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/explore/full_screen_video_viewer.dart';

class ExploreSearchPage extends StatefulWidget {
  const ExploreSearchPage({super.key});

  @override
  State<ExploreSearchPage> createState() => _ExploreSearchPageState();
}

class _ExploreSearchPageState extends State<ExploreSearchPage> with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  TabController? _tabController;
  
  bool _loading = false;
  String _query = '';
  
  List<dynamic> _users = [];
  List<dynamic> _posts = [];
  List<dynamic> _videos = [];

  final List<String> _trendingSearches = [
    '#entertainment',
    '#comedy',
    '#music',
    '#tech',
    '#gaming',
    '#dance',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return;

    setState(() {
      _loading = true;
      _query = cleanQuery;
    });

    final supabase = context.read<SupabaseService>();
    
    try {
      // 1. Fetch matching users
      final usersResponse = await supabase.client
          .from('users')
          .select()
          .or('name.ilike.%$cleanQuery%,username.ilike.%$cleanQuery%')
          .limit(20);

      // 2. Fetch matching text posts
      final postsResponse = await supabase.client
          .from('posts')
          .select()
          .eq('mediaType', 'text')
          .ilike('text', '%$cleanQuery%')
          .order('createdAt', ascending: false)
          .limit(25);

      // 3. Fetch matching video posts
      final videosResponse = await supabase.client
          .from('posts')
          .select()
          .eq('mediaType', 'video')
          .ilike('text', '%$cleanQuery%')
          .order('createdAt', ascending: false)
          .limit(25);

      if (mounted) {
        setState(() {
          _users = usersResponse as List<dynamic>;
          _posts = postsResponse as List<dynamic>;
          _videos = videosResponse as List<dynamic>;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint("Search error: $e");
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e'), backgroundColor: const Color(0xFF7E1C31)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBgColor = isDark ? const Color(0xFF0F0F12) : const Color(0xFFF8F9FA);
    final cardColor = isDark ? const Color(0xFF1E1E24) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      backgroundColor: scaffoldBgColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF16161C) : Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04),
            borderRadius: BorderRadius.circular(20),
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _focusNode,
            style: TextStyle(color: textColor, fontSize: 14),
            textInputAction: TextInputAction.search,
            onSubmitted: _performSearch,
            decoration: InputDecoration(
              hintText: 'Search Reel...',
              hintStyle: TextStyle(color: isDark ? Colors.white30 : Colors.black30, fontSize: 14),
              prefixIcon: Icon(Icons.search, color: isDark ? Colors.white30 : Colors.black30, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, color: textColor, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _query = '';
                          _users.clear();
                          _posts.clear();
                          _videos.clear();
                        });
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (text) {
              setState(() {});
            },
          ),
        ),
        bottom: _query.isEmpty
            ? null
            : TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFFFE2C55),
                labelColor: textColor,
                unselectedLabelColor: secondaryTextColor,
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                tabs: const [
                  Tab(text: 'Top'),
                  Tab(text: 'Users'),
                  Tab(text: 'Videos'),
                  Tab(text: 'Hashtags'),
                ],
              ),
      ),
      body: _query.isEmpty
          ? _buildTrendingView(cardColor, textColor, secondaryTextColor)
          : _loading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFFE2C55)))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTopTab(textColor, secondaryTextColor),
                    _buildUsersTab(textColor, secondaryTextColor),
                    _buildVideosTab(textColor, secondaryTextColor),
                    _buildHashtagsTab(textColor, secondaryTextColor),
                  ],
                ),
    );
  }

  Widget _buildTrendingView(Color cardColor, Color textColor, Color secondaryTextColor) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.trending_up, color: Color(0xFFFE2C55), size: 20),
              const SizedBox(width: 8),
              Text(
                'Trending Searches',
                style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _trendingSearches.map((tag) {
              return GestureDetector(
                onTap: () {
                  _searchController.text = tag;
                  _performSearch(tag);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white12, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.03),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      )
                    ],
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      color: const Color(0xFFFE2C55),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopTab(Color textColor, Color secondaryTextColor) {
    if (_users.isEmpty && _posts.isEmpty && _videos.isEmpty) {
      return _buildNoResults();
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (_users.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Users', style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          SizedBox(
            height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _users.length > 5 ? 5 : _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final uId = user['id'] ?? '';
                final name = user['name'] ?? 'User';
                return GestureDetector(
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => ReelProfilePage(userId: uId)));
                  },
                  child: Container(
                    width: 90,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        UserAvatar(userId: uId, radius: 24),
                        const SizedBox(height: 8),
                        Text(
                          name,
                          style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.bold),
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
          const Divider(color: Colors.white10),
        ],
        if (_videos.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Videos', style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.75,
            ),
            itemCount: _videos.length > 4 ? 4 : _videos.length,
            itemBuilder: (context, index) {
              return _buildVideoGridItem(_videos[index]);
            },
          ),
          const Divider(color: Colors.white10),
        ],
        if (_posts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Posts', style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          ..._posts.map((post) {
            return ExplorePostItem(
              post: post,
              onPostUpdated: () => _performSearch(_query),
            );
          }),
        ],
      ],
    );
  }

  Widget _buildUsersTab(Color textColor, Color secondaryTextColor) {
    if (_users.isEmpty) return _buildNoResults();

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: _users.length,
      separatorBuilder: (c, i) => const Divider(color: Colors.white10, height: 1),
      itemBuilder: (context, index) {
        final user = _users[index];
        final uId = user['id'] ?? '';
        final name = user['name'] ?? 'User';
        final username = user['username'] ?? 'user';

        return ListTile(
          leading: UserAvatar(userId: uId, radius: 20),
          title: Text(name, style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
          subtitle: Text('@$username', style: const TextStyle(color: Colors.white38, fontSize: 12)),
          onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => ReelProfilePage(userId: uId)));
          },
        );
      },
    );
  }

  Widget _buildVideosTab(Color textColor, Color secondaryTextColor) {
    if (_videos.isEmpty) return _buildNoResults();

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.75,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        return _buildVideoGridItem(_videos[index]);
      },
    );
  }

  Widget _buildHashtagsTab(Color textColor, Color secondaryTextColor) {
    // Show posts containing the hashtag in query
    final matchingPosts = [..._posts, ..._videos]
        .where((post) => (post['text'] ?? '').toString().toLowerCase().contains(_query.toLowerCase()))
        .toList();

    if (matchingPosts.isEmpty) return _buildNoResults();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: matchingPosts.length,
      itemBuilder: (context, index) {
        return ExplorePostItem(
          post: matchingPosts[index],
          onPostUpdated: () => _performSearch(_query),
        );
      },
    );
  }

  Widget _buildVideoGridItem(Map<String, dynamic> videoPost) {
    final videoUrl = videoPost['videoUrl'] as String? ?? '';
    final caption = videoPost['text'] ?? '';
    final name = videoPost['userName'] ?? 'User';

    return GestureDetector(
      onTap: () {
        if (videoUrl.isNotEmpty) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FullScreenVideoViewer(
                videoUrl: videoUrl,
                post: videoPost,
              ),
            ),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Stack(
          children: [
            const Center(
              child: Icon(Icons.play_circle_fill, color: Color(0xFFFE2C55), size: 40),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black87, Colors.transparent],
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                  ),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      caption,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '@$name',
                      style: const TextStyle(color: Colors.white60, fontSize: 10, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off_outlined, color: Colors.white30, size: 64),
          const SizedBox(height: 16),
          Text(
            'No results found for "$_query"',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';

class ReelProfilePage extends StatefulWidget {
  const ReelProfilePage({super.key});

  @override
  State<ReelProfilePage> createState() => _ReelProfilePageState();
}

class _ReelProfilePageState extends State<ReelProfilePage> with SingleTickerProviderStateMixin {
  late Future<Map<String, dynamic>?> _profileFuture;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _loadProfile() {
    final supabase = context.read<SupabaseService>();
    final user = supabase.currentUser;
    if (user != null) {
      _profileFuture = supabase.getUserProfile(user.id);
    } else {
      _profileFuture = Future.value(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          
          final userProfile = snapshot.data;
          final name = userProfile?['name'] ?? 'User';
          final phone = userProfile?['phone'] ?? 'No phone linked';
          final userId = userProfile?['id'] ?? 'unknown';

          return NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar(
                  expandedHeight: 180,
                  pinned: true,
                  floating: false,
                  backgroundColor: Colors.black,
                  elevation: 0,
                  leading: const Icon(Icons.arrow_back, color: Colors.white),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.search, color: Colors.white),
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: const Icon(Icons.more_vert, color: Colors.white),
                      onPressed: () {},
                    ),
                  ],
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Cover Banner Image
                        Image.network(
                          'https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?auto=format&fit=crop&w=800&q=80',
                          fit: BoxFit.cover,
                        ),
                        // Dark overlay for banner text readability if needed
                        Container(
                          color: Colors.black26,
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Overlapping Profile Picture and Edit Button
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const SizedBox(height: 40),
                            Positioned(
                              top: -50,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.black, width: 4),
                                ),
                                child: CircleAvatar(
                                  radius: 42,
                                  backgroundColor: Colors.white10,
                                  backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=$userId'),
                                ),
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton(
                                  onPressed: () {},
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: Colors.white30),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  ),
                                  child: const Text(
                                    'Edit profile',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // User Name and Handle
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.extrabold,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '@${name.toLowerCase().replaceAll(' ', '')}',
                          style: const TextStyle(color: Colors.white54, fontSize: 15),
                        ),
                        const SizedBox(height: 14),
                        // User Bio (Mocked for now)
                        const Text(
                          'Flutter Developer & Designer. Building premium experiences on the Reel App! 🚀✨',
                          style: TextStyle(color: Colors.white90, fontSize: 15, height: 1.3),
                        ),
                        const SizedBox(height: 14),
                        // Location, Link, Joined Date Row
                        Row(
                          flex: 1,
                          children: [
                            const Icon(Icons.location_on_outlined, color: Colors.white54, size: 16),
                            const SizedBox(width: 4),
                            const Text('Nigeria', style: TextStyle(color: Colors.white54, fontSize: 14)),
                            const SizedBox(width: 16),
                            const Icon(Icons.calendar_today_outlined, color: Colors.white54, size: 14),
                            const SizedBox(width: 4),
                            const Text('Joined May 2026', style: TextStyle(color: Colors.white54, fontSize: 14)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Phone Row
                        Row(
                          children: [
                            const Icon(Icons.phone_outlined, color: Colors.white54, size: 16),
                            const SizedBox(width: 4),
                            Text(phone, style: const TextStyle(color: Colors.white54, fontSize: 14)),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // Followers / Following Stats
                        Row(
                          children: [
                            _buildRichStat('124', 'Following'),
                            const SizedBox(width: 20),
                            _buildRichStat('2.5K', 'Followers'),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SliverAppBarDelegate(
                    TabBar(
                      controller: _tabController,
                      indicatorColor: Theme.of(context).primaryColor,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white54,
                      indicatorWeight: 3,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      tabs: const [
                        Tab(text: 'Posts'),
                        Tab(text: 'Replies'),
                        Tab(text: 'Media'),
                        Tab(text: 'Likes'),
                      ],
                    ),
                  ),
                ),
              ];
            },
            body: TabBarView(
              controller: _tabController,
              children: [
                _buildPostsTab(),
                _buildEmptyTab('No replies yet'),
                _buildEmptyTab('No media yet'),
                _buildEmptyTab('No likes yet'),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRichStat(String count, String label) {
    return Row(
      children: [
        Text(
          count,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 15),
        ),
      ],
    );
  }

  Widget _buildPostsTab() {
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: 3,
      itemBuilder: (context, index) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(
                radius: 20,
                backgroundImage: NetworkImage('https://i.pravatar.cc/150?u=user_post'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Text(
                          'You',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '@you • 2h',
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Just launched the new premium UI with Twitter/X design! What do you guys think? 🔥 #ReelApp',
                      style: TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildPostAction(Icons.chat_bubble_outline, '12'),
                        _buildPostAction(Icons.repeat, '4'),
                        _buildPostAction(Icons.favorite_border, '89'),
                        _buildPostAction(Icons.share_outlined, ''),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyTab(String message) {
    return Center(
      child: Text(
        message,
        style: const TextStyle(color: Colors.white38, fontSize: 16),
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

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar _tabBar;

  _SliverAppBarDelegate(this._tabBar);

  @override
  double get minExtent => _tabBar.preferredSize.height;
  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Colors.black,
      child: _tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) {
    return false;
  }
}

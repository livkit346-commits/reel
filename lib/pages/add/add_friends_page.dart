import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';
import 'package:geolocator/geolocator.dart';

class AddFriendsPage extends StatefulWidget {
  const AddFriendsPage({super.key});

  @override
  State<AddFriendsPage> createState() => _AddFriendsPageState();
}

class _AddFriendsPageState extends State<AddFriendsPage> {
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  List<dynamic> _addedMeList = []; // People who added me but I haven't added back
  Set<String> _myFollowing = {}; // User IDs that I am following
  bool _searching = false;
  bool _loading = true;

  // Nearby Discovery & Location States
  bool _locationSharingEnabled = false;
  bool _loadingLocationSetting = true;
  Position? _currentPosition;
  List<dynamic> _nearbyUsers = [];
  bool _fetchingNearby = false;

  // Quick Add Recommendations
  List<dynamic> _quickAddList = [];
  bool _loadingQuickAdd = true;

  @override
  void initState() {
    super.initState();
    _loadSnapchatSocials();
  }

  Future<void> _initLocation() async {
    final supabase = context.read<SupabaseService>();
    try {
      final enabled = await supabase.isLocationSharingEnabled();
      if (mounted) {
        setState(() {
          _locationSharingEnabled = enabled;
          _loadingLocationSetting = false;
        });
      }
      if (enabled) {
        await _fetchLocationAndNearbyUsers();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingLocationSetting = false);
      }
    }
  }

  Future<Position?> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      return Future.error('Location permissions are permanently denied.');
    } 

    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  Future<void> _fetchLocationAndNearbyUsers() async {
    if (!_locationSharingEnabled) return;
    setState(() => _fetchingNearby = true);
    final supabase = context.read<SupabaseService>();
    try {
      final position = await _determinePosition();
      if (position != null) {
        if (mounted) {
          setState(() {
            _currentPosition = position;
          });
        }
        await supabase.updateLocationSharing(
          true,
          lat: position.latitude,
          lng: position.longitude,
        );
        final nearby = await supabase.getNearbyUsers(
          position.latitude,
          position.longitude,
        );
        if (mounted) {
          setState(() {
            _nearbyUsers = nearby;
            _fetchingNearby = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error getting location/nearby users: $e');
      if (mounted) {
        setState(() => _fetchingNearby = false);
      }
    }
  }

  Future<void> _toggleLocationSharing(bool enabled) async {
    final supabase = context.read<SupabaseService>();
    setState(() {
      _locationSharingEnabled = enabled;
      if (!enabled) {
        _nearbyUsers = [];
        _currentPosition = null;
      }
    });

    try {
      if (enabled) {
        await _fetchLocationAndNearbyUsers();
      } else {
        await supabase.updateLocationSharing(false, lat: 0.0, lng: 0.0);
      }
    } catch (e) {
      debugPrint('Error toggling location sharing: $e');
    }
  }

  Future<void> _loadQuickAdd() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      final response = await supabase.client
          .from('users')
          .select()
          .neq('id', myId)
          .limit(30);

      if (mounted) {
        setState(() {
          _quickAddList = (response as List).where((u) {
            return !_myFollowing.contains(u['id']);
          }).toList();
          _loadingQuickAdd = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingQuickAdd = false);
      }
    }
  }

  Future<void> _loadSnapchatSocials() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      // 1. Get all followers (people who added me)
      final followersResponse = await supabase.client
          .from('follows')
          .select('followerId, users!follows_followerId_fkey(id, name, photoUrl)')
          .eq('followingId', myId);

      // 2. Get all people I am following
      final followingResponse = await supabase.client
          .from('follows')
          .select('followingId')
          .eq('followerId', myId);

      final followingIds = (followingResponse as List)
          .map((item) => item['followingId'] as String)
          .toSet();

      // Filter "Added Me" list: people who follow me but I DO NOT follow back yet
      final addedMeFiltered = (followersResponse as List).where((item) {
        final followerId = item['followerId'] as String;
        return !followingIds.contains(followerId);
      }).toList();

      if (mounted) {
        setState(() {
          _addedMeList = addedMeFiltered;
          _myFollowing = followingIds;
          _loading = false;
        });
      }

      // Trigger location initialisation and quick add
      _loadQuickAdd();
      _initLocation();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addFriend(String userId) async {
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.followUser(userId);
      setState(() {
        _myFollowing.add(userId);
      });
      // Refresh to recalculate lists
      _loadSnapchatSocials();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add friend')),
        );
      }
    }
  }

  Future<void> _removeFriend(String userId) async {
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.unfollowUser(userId);
      setState(() {
        _myFollowing.remove(userId);
      });
      _loadSnapchatSocials();
    } catch (_) {}
  }

  Future<void> _startChat(BuildContext context, String otherUserId, String otherUserName) async {
    final supabase = context.read<SupabaseService>();
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      final chatId = await supabase.createOrGetChat(otherUserId);
      
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatRoomPage(
              chatId: chatId,
              otherUserId: otherUserId,
              otherUserName: otherUserName,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.grey[950],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Mutual Friends Only', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(
              'Snapchat Rules: Both you and $otherUserName must add each other as friends before sending private messages!',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK', style: TextStyle(color: Colors.indigoAccent, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _searchUsers(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    setState(() => _searching = true);
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    
    try {
      final response = await supabase.searchUsers(query);
      final filteredResults = response.where((u) => u['id'] != myId).toList();
      setState(() => _searchResults = filteredResults);
    } catch (e) {
      // Ignore
    } finally {
      setState(() => _searching = false);
    }
  }

  Widget _buildLocationSharingCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.white.withOpacity(0.05),
            Colors.white.withOpacity(0.02),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _locationSharingEnabled
              ? Colors.cyanAccent.withOpacity(0.2)
              : Colors.white.withOpacity(0.05),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _locationSharingEnabled
                      ? Colors.cyanAccent.withOpacity(0.15)
                      : Colors.white.withOpacity(0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.location_on,
                  color: _locationSharingEnabled ? Colors.cyanAccent : Colors.white38,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nearby Discovery (50m)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Reciprocal location sharing',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loadingLocationSetting)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
                )
              else
                Switch(
                  value: _locationSharingEnabled,
                  activeColor: Colors.cyanAccent,
                  activeTrackColor: Colors.cyanAccent.withOpacity(0.3),
                  inactiveThumbColor: Colors.white54,
                  inactiveTrackColor: Colors.white12,
                  onChanged: (val) => _toggleLocationSharing(val),
                ),
            ],
          ),
          if (!_locationSharingEnabled) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_outline, color: Colors.white30, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Turn on Location Sharing to find and be found by active users within 50 meters.',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 12),
            if (_fetchingNearby)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
                      SizedBox(height: 8),
                      Text(
                        'Scanning for active users within 50m...',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            else if (_nearbyUsers.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(Icons.radar, color: Colors.white24, size: 36),
                      SizedBox(height: 8),
                      Text(
                        'No active users within 50 meters right now.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                height: 125,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _nearbyUsers.length,
                  itemBuilder: (context, index) {
                    final user = _nearbyUsers[index];
                    final name = user['name'] ?? 'User';
                    final distance = user['distance'] as double?;
                    final isAdded = _myFollowing.contains(user['id']);

                    return Container(
                      width: 110,
                      margin: const EdgeInsets.only(right: 12),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.05), width: 0.8),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          UserAvatar(
                            userId: user['id'],
                            radius: 20,
                            border: Border.all(color: Colors.cyanAccent, width: 1.5),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ReelProfilePage(userId: user['id']),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 4),
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                          if (distance != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              '${distance.toStringAsFixed(1)}m away',
                              style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.w600),
                            ),
                          ],
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 22,
                            child: ElevatedButton(
                              onPressed: () {
                                if (isAdded) {
                                  _removeFriend(user['id']);
                                } else {
                                  _addFriend(user['id']);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isAdded ? Colors.white12 : Colors.indigoAccent,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: Text(
                                isAdded ? 'Added' : '+ Add',
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'Add Friends',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Colors.white),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSnapchatSocials,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // SEARCH BAR (Snapchat style: Rounded, wide, clean)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: TextField(
                        controller: _searchController,
                        onChanged: _searchUsers,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Find Friends',
                          hintStyle: const TextStyle(color: Colors.white38, fontWeight: FontWeight.bold),
                          prefixIcon: const Icon(Icons.search, color: Colors.white54),
                          fillColor: Colors.white.withOpacity(0.08),
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30),
                            borderSide: BorderSide.none,
                          ),
                          suffixIcon: _searching
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // NEARBY DISCOVERY CARD
                    _buildLocationSharingCard(),
                    const SizedBox(height: 12),

                    // SEARCH RESULTS SECTION
                    if (_searchResults.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'SEARCH RESULTS',
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                        ),
                      ),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final user = _searchResults[index];
                          final name = user['name'] ?? 'User';
                          final username = '@${name.toLowerCase().replaceAll(' ', '')}';
                          final isAdded = _myFollowing.contains(user['id']);

                          return _buildSnapchatCard(
                            userId: user['id'],
                            name: name,
                            username: username,
                            subtext: 'In search results',
                            isAdded: isAdded,
                            onActionPressed: () {
                              if (isAdded) {
                                _removeFriend(user['id']);
                              } else {
                                _addFriend(user['id']);
                              }
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ],

                    // "ADDED ME" SECTION (Snapchat style: list of people who added you)
                    if (_addedMeList.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'ADDED ME',
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _addedMeList.length,
                          itemBuilder: (context, index) {
                            final item = _addedMeList[index];
                            final user = item['users'];
                            if (user == null) return const SizedBox.shrink();
                            
                            final name = user['name'] ?? 'User';
                            final username = '@${name.toLowerCase().replaceAll(' ', '')}';

                            return _buildSnapchatCard(
                              userId: user['id'],
                              name: name,
                              username: username,
                              subtext: 'Added you back',
                              isAdded: false,
                              isAddedMeText: 'Accept',
                              onActionPressed: () => _addFriend(user['id']),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // "QUICK ADD" SECTION
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        'QUICK ADD',
                        style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                      ),
                    ),
                    if (_loadingQuickAdd)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16.0),
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.indigoAccent),
                        ),
                      )
                    else if (_quickAddList.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
                        child: Text(
                          'No suggestions currently. Find friends using search above!',
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      )
                    else
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _quickAddList.length,
                          itemBuilder: (context, index) {
                            final user = _quickAddList[index];
                            final name = user['name'] ?? 'Suggested';
                            final username = '@${name.toLowerCase().replaceAll(' ', '')}';

                            return _buildSnapchatCard(
                              userId: user['id'],
                              name: name,
                              username: username,
                              subtext: 'Recently Active',
                              isAdded: false,
                              onActionPressed: () => _addFriend(user['id']),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  // SNAPCHAT STYLE CARD WIDGET
  Widget _buildSnapchatCard({
    required String userId,
    required String name,
    required String username,
    required String subtext,
    required bool isAdded,
    String? isAddedMeText,
    required VoidCallback onActionPressed,
  }) {
    final primaryColor = Theme.of(context).primaryColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Row(
        children: [
          // Circular Avatar (Clean, bordered) - Tapping opens their profile!
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
          const SizedBox(width: 14),
          // User Metadata (Snapchat typography: Bold Name, subtext Username & Mutuals)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ReelProfilePage(userId: userId),
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        username,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 3,
                        height: 3,
                        decoration: const BoxDecoration(color: Colors.white38, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          subtext,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Action Buttons: Pill-shaped purple/primary button or checkmark
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 20),
                onPressed: () => _startChat(context, userId, name),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: onActionPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isAdded
                      ? Colors.white12
                      : (isAddedMeText != null ? primaryColor : Colors.indigoAccent),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: Text(
                  isAdded
                      ? 'Added'
                      : (isAddedMeText ?? '+ Add'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/services/local_storage_service.dart';
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
    // Disk cache fallback
    try {
      final cachedQA = await LocalStorageService().getCachedJson('add_page_quick_add');
      if (mounted && cachedQA is List && cachedQA.isNotEmpty) {
        setState(() {
          _quickAddList = cachedQA;
          _loadingQuickAdd = false;
        });
      }
    } catch (_) {}

    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id ?? await LocalStorageService().getString('last_logged_in_user_id');
    if (myId == null || myId.isEmpty) {
      if (mounted) setState(() => _loadingQuickAdd = false);
      return;
    }

    try {
      final response = await supabase.client
          .from('users')
          .select()
          .neq('id', myId)
          .limit(30);

      final filtered = (response as List).where((u) {
        return !_myFollowing.contains(u['id']);
      }).toList();

      await LocalStorageService().cacheJson('add_page_quick_add', filtered);

      if (mounted) {
        setState(() {
          _quickAddList = filtered;
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
    // Disk cache fallback
    try {
      final cachedAddedMe = await LocalStorageService().getCachedJson('add_page_added_me');
      final cachedFollowing = await LocalStorageService().getCachedJson('add_page_following');
      if (mounted && (cachedAddedMe != null || cachedFollowing != null)) {
        setState(() {
          if (cachedAddedMe is List) _addedMeList = cachedAddedMe;
          if (cachedFollowing is List) _myFollowing = cachedFollowing.map((e) => e.toString()).toSet();
          _loading = false;
        });
      }
    } catch (_) {}

    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id ?? await LocalStorageService().getString('last_logged_in_user_id');
    if (myId == null || myId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

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

      await LocalStorageService().cacheJson('add_page_added_me', addedMeFiltered);
      await LocalStorageService().cacheJson('add_page_following', followingIds.toList());

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
        ).then((_) {
          if (mounted) {
            Navigator.pop(context, true);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Pop loading dialog
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF121212),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Mutual Friends Only', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(
              'Reel Rule: Both you and $otherUserName must add each other as friends before sending private messages!',
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white38 : Colors.black45;
    final cardBgGradient = [
      isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.03),
      isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01),
    ];
    final cardBorder = _locationSharingEnabled
        ? Colors.cyanAccent.withOpacity(0.4)
        : (isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.08));

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: cardBgGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: cardBorder,
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
                      : (isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05)),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.location_on,
                  color: _locationSharingEnabled ? Colors.cyanAccent : secondaryTextColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nearby Discovery (50m)',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Reciprocal location sharing',
                      style: TextStyle(
                        color: secondaryTextColor,
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
                  inactiveThumbColor: isDark ? Colors.white54 : Colors.grey,
                  inactiveTrackColor: isDark ? Colors.white12 : Colors.grey[300],
                  onChanged: (val) => _toggleLocationSharing(val),
                ),
            ],
          ),
          if (!_locationSharingEnabled) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? Colors.black.withOpacity(0.3) : Colors.black.withOpacity(0.04),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: secondaryTextColor, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Turn on Location Sharing to find and be found by active users within 50 meters.',
                      style: TextStyle(
                        color: secondaryTextColor,
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
            Divider(color: isDark ? Colors.white10 : Colors.black.withOpacity(0.08), height: 1),
            const SizedBox(height: 12),
            if (_fetchingNearby)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
                      const SizedBox(height: 8),
                      Text(
                        'Scanning for active users within 50m...',
                        style: TextStyle(color: secondaryTextColor, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            else if (_nearbyUsers.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(Icons.radar, color: secondaryTextColor, size: 36),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? Colors.black : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white54 : Colors.black54;
    final hintColor = isDark ? Colors.white38 : Colors.black38;
    final searchFillColor = isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textColor),
        title: Text(
          'Add Friends',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: textColor),
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
                        style: TextStyle(color: textColor),
                        decoration: InputDecoration(
                          hintText: 'Find Friends',
                          hintStyle: TextStyle(color: hintColor, fontWeight: FontWeight.bold),
                          prefixIcon: Icon(Icons.search, color: secondaryTextColor),
                          fillColor: searchFillColor,
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30),
                            borderSide: BorderSide.none,
                          ),
                          suffixIcon: _searching
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: textColor),
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'SEARCH RESULTS',
                          style: TextStyle(color: secondaryTextColor, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                        ),
                      ),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final user = _searchResults[index];
                          final name = user['name'] ?? 'User';
                          final username = '@${user['username'] ?? name.toLowerCase().replaceAll(' ', '')}';
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'ADDED ME',
                          style: TextStyle(color: secondaryTextColor, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
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
                            final username = '@${user['username'] ?? name.toLowerCase().replaceAll(' ', '')}';

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
                            final username = '@${user['username'] ?? name.toLowerCase().replaceAll(' ', '')}';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryTextColor = isDark ? Colors.white54 : Colors.black54;
    final subTextColor = isDark ? Colors.white38 : Colors.black38;
    final borderSideColor = isDark ? Colors.white10 : Colors.black.withOpacity(0.08);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderSideColor, width: 0.5)),
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
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        username,
                        style: TextStyle(color: secondaryTextColor, fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(color: subTextColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          subtext,
                          style: TextStyle(color: subTextColor, fontSize: 12),
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
                icon: Icon(Icons.chat_bubble_outline, color: secondaryTextColor, size: 20),
                onPressed: () => _startChat(context, userId, name),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: onActionPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isAdded
                      ? (isDark ? Colors.white12 : Colors.black.withOpacity(0.08))
                      : (isAddedMeText != null ? primaryColor : Colors.indigoAccent),
                  foregroundColor: isAdded ? textColor : Colors.white,
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

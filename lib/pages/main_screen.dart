import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/fcm_service.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/pages/chat/chat_list_page.dart';
import 'package:reel/pages/explore/explore_feed_page.dart';
import 'package:reel/pages/updates/updates_page.dart';
import 'package:reel/pages/add/add_friends_page.dart';
import 'package:reel/services/websocket_service.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  final GlobalKey<ExploreFeedPageState> _exploreFeedKey = GlobalKey<ExploreFeedPageState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final supabaseService = context.read<SupabaseService>();
      FcmService().init(supabaseService);
      supabaseService.initializeGlobalRealtime();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      debugPrint('App backgrounded/inactive: disconnecting WebSocket to allow push notifications');
      WebSocketService().disconnect();
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('App resumed/foregrounded: reconnecting WebSocket');
      WebSocketService().connect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBgColor = isDark ? Colors.black : Colors.white;
    final navSelectedColor = isDark ? Colors.white : Colors.black;
    final navUnselectedColor = isDark ? Colors.white38 : Colors.black38;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          const ChatListPage(),
          ExploreFeedPage(
            key: _exploreFeedKey,
            isActive: _selectedIndex == 1,
          ),
          const UpdatesPage(),
          const AddFriendsPage(),
          const ReelProfilePage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          if (index == 1 && _selectedIndex == 1) {
            _exploreFeedKey.currentState?.reloadPage();
          } else {
            setState(() => _selectedIndex = index);
          }
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: navBgColor,
        selectedItemColor: navSelectedColor,
        unselectedItemColor: navUnselectedColor,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        selectedFontSize: 12,
        unselectedFontSize: 12,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.explore_outlined),
            activeIcon: Icon(Icons.explore),
            label: 'Explore',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_awesome_outlined),
            activeIcon: Icon(Icons.auto_awesome),
            label: 'Updates',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_add_outlined),
            activeIcon: Icon(Icons.person_add),
            label: 'Add',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

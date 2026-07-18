import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/auth/reel_auth_page.dart';
import 'package:reel/pages/main_screen.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/theme/reel_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:reel/firebase_options.dart';
import 'package:reel/services/fcm_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  
  await Supabase.initialize(
    url: 'https://zvxrcwgvvubgqlxbcyov.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp2eHJjd2d2dnViZ3FseGJjeW92Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg5NjM4MDgsImV4cCI6MjA5NDUzOTgwOH0.RVrUvHt-fnh7n02ap39-y9gpjvu4x6p0Xaq-CH8qP6w',
    authOptions: const FlutterAuthClientOptions(
      autoRefreshToken: false,
      localStorage: EmptyLocalStorage(),
    ),
  );

  final supabaseService = SupabaseService();
  await supabaseService.initializeSession();
  final hasSession = await supabaseService.hasSavedSession();

  runApp(
    MultiProvider(
      providers: [
        Provider<SupabaseService>(create: (_) => SupabaseService()),
      ],
      child: ReelApp(showMainScreen: hasSession),
    ),
  );
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

class ReelApp extends StatelessWidget {
  final bool showMainScreen;
  const ReelApp({super.key, required this.showMainScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [routeObserver],
      title: 'Reel',
      debugShowCheckedModeBanner: false,
      theme: ReelTheme.lightTheme,
      darkTheme: ReelTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: showMainScreen ? MainScreen() : ReelAuthPage(),
    );
  }
}

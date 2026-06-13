import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/auth/reel_auth_page.dart';
import 'package:reel/pages/main_screen.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/theme/reel_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:reel/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  await Supabase.initialize(
    url: 'https://zvxrcwgvvubgqlxbcyov.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp2eHJjd2d2dnViZ3FseGJjeW92Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg5NjM4MDgsImV4cCI6MjA5NDUzOTgwOH0.RVrUvHt-fnh7n02ap39-y9gpjvu4x6p0Xaq-CH8qP6w',
  );

  final supabaseService = SupabaseService();
  await supabaseService.initializeSession();

  final session = Supabase.instance.client.auth.currentSession;

  runApp(
    MultiProvider(
      providers: [
        Provider<SupabaseService>(create: (_) => SupabaseService()),
      ],
      child: ReelApp(showMainScreen: session != null),
    ),
  );
}

class ReelApp extends StatelessWidget {
  final bool showMainScreen;
  const ReelApp({super.key, required this.showMainScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reel',
      debugShowCheckedModeBanner: false,
      theme: ReelTheme.darkTheme,
      home: showMainScreen ? MainScreen() : ReelAuthPage(),
    );
  }
}


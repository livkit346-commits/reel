import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/auth/reel_auth_page.dart';
import 'package:reel/theme/reel_theme.dart';
import 'package:reel/services/appwrite_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        Provider<AppwriteService>(create: (_) => AppwriteService()),
      ],
      child: const ReelApp(),
    ),
  );
}

class ReelApp extends StatelessWidget {
  const ReelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reel',
      debugShowCheckedModeBanner: false,
      theme: ReelTheme.darkTheme,
      home: const ReelAuthPage(),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/auth/email_auth_view.dart';
import 'package:reel/widgets/auth/profile_setup_view.dart';
import 'package:reel/pages/main_screen.dart';

class ReelAuthPage extends StatefulWidget {
  const ReelAuthPage({super.key});

  @override
  State<ReelAuthPage> createState() => _ReelAuthPageState();
}

class _ReelAuthPageState extends State<ReelAuthPage> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  void _nextStep() {
    setState(() {
      _currentStep++;
    });
    _pageController.nextPage(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutQuart,
    );
  }

  Future<void> _onEmailAuthSubmitted(String email, String password, bool isSignUp) async {
    final supabaseService = context.read<SupabaseService>();
    try {
      if (isSignUp) {
        await supabaseService.signUpWithEmail(email, password);
        _nextStep(); // Go to profile setup
      } else {
        await supabaseService.signInWithEmail(email, password);
        
        // If login successful, check if profile exists
        final user = supabaseService.currentUser;
        if (user != null) {
          final profile = await supabaseService.getUserProfile(user.id);
          if (mounted) {
            if (profile != null && profile['name'] != null) {
              // Profile exists, go to main screen
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const MainScreen()),
                (route) => false,
              );
            } else {
              // No profile, go to profile setup
              _nextStep();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Supabase Auth Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            // Progress Indicator
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: List.generate(2, (index) {
                  return Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: index <= _currentStep
                            ? Theme.of(context).primaryColor
                            : Colors.white12,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 40),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  EmailAuthView(onSubmitted: _onEmailAuthSubmitted),
                  const ProfileSetupView(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pinput/pinput.dart';
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
        // Step 1: Send verification code to email
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
        );

        try {
          await supabaseService.sendVerificationCode(email);
          if (mounted) {
            Navigator.pop(context); // Close loading dialog
          }
        } catch (e) {
          if (mounted) {
            Navigator.pop(context); // Close loading dialog
          }
          rethrow;
        }

        // Step 2: Show OTP bottom sheet
        if (mounted) {
          final verified = await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => OtpVerificationSheet(
              email: email,
              password: password,
              onVerify: (email, password, code) async {
                await supabaseService.signUpWithEmail(email, password, code);
              },
              onResend: () async {
                await supabaseService.sendVerificationCode(email);
              },
            ),
          );

          if (verified == true && mounted) {
            final user = supabaseService.currentUser;
            if (user != null) {
              _nextStep(); // Proceed to profile setup
            }
          }
        }
      } else {
        await supabaseService.signInWithEmail(email, password);
        await supabaseService.clearLocalChatCache();
        
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

class OtpVerificationSheet extends StatefulWidget {
  final String email;
  final String password;
  final Future<void> Function(String email, String password, String code) onVerify;
  final Future<void> Function() onResend;

  const OtpVerificationSheet({
    super.key,
    required this.email,
    required this.password,
    required this.onVerify,
    required this.onResend,
  });

  @override
  State<OtpVerificationSheet> createState() => _OtpVerificationSheetState();
}

class _OtpVerificationSheetState extends State<OtpVerificationSheet> {
  final TextEditingController _pinController = TextEditingController();
  int _secondsRemaining = 60;
  Timer? _timer;
  bool _isVerifying = false;
  bool _isResending = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  void _startTimer() {
    setState(() {
      _secondsRemaining = 60;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() {
          _secondsRemaining--;
        });
      } else {
        _timer?.cancel();
      }
    });
  }

  Future<void> _resendCode() async {
    setState(() {
      _isResending = true;
      _errorMessage = null;
    });
    try {
      await widget.onResend();
      _startTimer();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Verification code resent successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isResending = false;
        });
      }
    }
  }

  Future<void> _verify(String code) async {
    if (code.length < 6) return;
    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });
    try {
      await widget.onVerify(widget.email, widget.password, code);
      if (mounted) {
        Navigator.pop(context, true); // Success, close sheet returning true
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _pinController.clear();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: BoxDecoration(
        color: Colors.grey[950],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Verify Email',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "We've sent a 6-digit verification code to:",
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            widget.email,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: Pinput(
              length: 6,
              controller: _pinController,
              onCompleted: _verify,
              autofocus: true,
              defaultPinTheme: PinTheme(
                width: 48,
                height: 48,
                textStyle: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              focusedPinTheme: PinTheme(
                width: 48,
                height: 48,
                textStyle: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  border: Border.all(color: primaryColor.withOpacity(0.8)),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          if (_isVerifying)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              ),
            )
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _secondsRemaining > 0
                      ? "Resend code in ${_secondsRemaining}s"
                      : "Didn't receive the code? ",
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
                ),
                if (_secondsRemaining == 0)
                  GestureDetector(
                    onTap: _isResending ? null : _resendCode,
                    child: _isResending
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 1.5),
                          )
                        : Text(
                            "Resend",
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

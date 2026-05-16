import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/appwrite_service.dart';
import 'package:reel/widgets/auth/phone_input_view.dart';
import 'package:reel/widgets/auth/otp_verification_view.dart';
import 'package:reel/widgets/auth/profile_setup_view.dart';

class ReelAuthPage extends StatefulWidget {
  const ReelAuthPage({super.key});

  @override
  State<ReelAuthPage> createState() => _ReelAuthPageState();
}

class _ReelAuthPageState extends State<ReelAuthPage> {
  final PageController _pageController = PageController();
  String _phoneNumber = '';
  String _userId = '';
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

  Future<void> _onPhoneSubmitted(String phone) async {
    final appwrite = context.read<AppwriteService>();
    try {
      final userId = await appwrite.createPhoneToken(phone);
      setState(() {
        _phoneNumber = phone;
        _userId = userId;
      });
      _nextStep();
    } catch (e) {
      debugPrint('Appwrite Auth Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Login Error: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _onOtpVerified(String secret) async {
    final appwrite = context.read<AppwriteService>();
    try {
      await appwrite.createSession(_userId, secret);
      _nextStep();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OTP Verification Failed: ${e.toString()}')),
      );
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
                children: List.generate(3, (index) {
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
                  PhoneInputView(onSubmitted: _onPhoneSubmitted),
                  OtpVerificationView(
                    phoneNumber: _phoneNumber,
                    onVerified: (secret) => _onOtpVerified(secret),
                    onBack: () {
                      setState(() => _currentStep--);
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOutQuart,
                      );
                    },
                  ),
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

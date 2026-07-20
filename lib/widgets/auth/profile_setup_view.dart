import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/main_screen.dart';
import 'package:reel/services/supabase_service.dart';

class ProfileSetupView extends StatefulWidget {
  const ProfileSetupView({super.key});

  @override
  State<ProfileSetupView> createState() => _ProfileSetupViewState();
}

class _ProfileSetupViewState extends State<ProfileSetupView> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  
  File? _avatarFile;
  String? _uploadedPhotoUrl;
  bool _loading = false;
  bool _uploadingAvatar = false;

  Future<void> _pickAndUploadAvatar() async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 500,
    );

    if (pickedFile != null) {
      setState(() {
        _avatarFile = File(pickedFile.path);
        _uploadingAvatar = true;
      });

      final supabase = context.read<SupabaseService>();
      try {
        final url = await supabase.uploadAvatar(_avatarFile!);
        setState(() {
          _uploadedPhotoUrl = url;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Avatar uploaded successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to upload avatar: ${e.toString()}')),
          );
        }
      } finally {
        setState(() => _uploadingAvatar = false);
      }
    }
  }

  Future<void> _onFinish() async {
    final name = _nameController.text.trim();
    final username = _usernameController.text.trim().toLowerCase();
    final phone = _phoneController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required.')),
      );
      return;
    }

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username (handle) is required.')),
      );
      return;
    }

    if (username.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username must be at least 3 characters.')),
      );
      return;
    }

    final usernameRegex = RegExp(r'^[a-z0-9_]+$');
    if (!usernameRegex.hasMatch(username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username can only contain lowercase letters, numbers, and underscores.')),
      );
      return;
    }

    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();
    
    try {
      final user = supabase.currentUser;
      if (user == null) throw Exception("User not authenticated.");

      // Check if username is already taken
      final isTaken = await supabase.isUsernameTaken(username);
      if (isTaken) {
        throw Exception("Username is already taken by another user.");
      }

      // Create user document in Supabase
      await supabase.createUserProfile(
        user.id, 
        name, 
        _uploadedPhotoUrl, 
        phone.isNotEmpty ? phone : null,
        username: username,
      );

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const MainScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Profile Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white60 : Colors.black54;
    final hintColor = isDark ? Colors.white38 : Colors.black38;
    final iconColor = isDark ? Colors.white38 : Colors.black45;
    final avatarBgColor = isDark ? const Color(0x1AFFFFFF) : const Color(0x0F000000);

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profile info',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            'Please provide your name and an optional phone number to connect with friends.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: subtextColor,
                ),
          ),
          const SizedBox(height: 32),
          Center(
            child: InkWell(
              onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
              borderRadius: BorderRadius.circular(50),
              child: Stack(
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: avatarBgColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).primaryColor.withOpacity(0.5),
                        width: 2,
                      ),
                      image: _avatarFile != null
                          ? DecorationImage(image: FileImage(_avatarFile!), fit: BoxFit.cover)
                          : null,
                    ),
                    child: _avatarFile == null
                        ? Icon(
                            Icons.add_a_photo_outlined,
                            color: iconColor,
                            size: 32,
                          )
                        : null,
                  ),
                  if (_uploadingAvatar)
                    Positioned.fill(
                      child: Container(
                        decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                        child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _nameController,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              hintText: 'Display Name (Required)',
              hintStyle: TextStyle(color: hintColor),
              prefixIcon: Icon(Icons.person_outline, color: iconColor),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameController,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              hintText: 'Username / Handle (Required)',
              hintStyle: TextStyle(color: hintColor),
              prefixIcon: Icon(Icons.alternate_email_outlined, color: iconColor),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              hintText: 'Phone Number (Optional)',
              hintStyle: TextStyle(color: hintColor),
              prefixIcon: Icon(Icons.phone_outlined, color: iconColor),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading || _uploadingAvatar ? null : _onFinish,
              child: _loading 
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('Finish'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

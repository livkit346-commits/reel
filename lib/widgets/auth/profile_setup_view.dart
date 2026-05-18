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
    if (_nameController.text.trim().isEmpty) return;

    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();
    
    try {
      final user = supabase.currentUser;
      if (user == null) throw Exception("User not authenticated.");

      // Create user document in Supabase
      await supabase.createUserProfile(
        user.id, 
        _nameController.text.trim(), 
        _uploadedPhotoUrl, 
        _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null
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
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profile info',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            'Please provide your name and an optional phone number to connect with friends.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.white60,
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
                      color: const Color(0x1AFFFFFF),
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
                        ? const Icon(
                            Icons.add_a_photo_outlined,
                            color: Colors.white30,
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
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Display Name (Required)',
              prefixIcon: Icon(Icons.person_outline, color: Colors.white38),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Phone Number (Optional)',
              prefixIcon: Icon(Icons.phone_outlined, color: Colors.white38),
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

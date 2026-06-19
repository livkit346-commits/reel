import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/theme/reel_theme.dart';

class EditProfilePage extends StatefulWidget {
  final Map<String, dynamic>? profile;

  const EditProfilePage({
    super.key,
    this.profile,
  });

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late TextEditingController _nameController;
  late TextEditingController _bioController;
  late TextEditingController _phoneController;

  final ImagePicker _picker = ImagePicker();
  bool _uploadingAvatar = false;
  bool _savingProfile = false;
  String? _currentPhotoUrl;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile?['name'] ?? '');
    _bioController = TextEditingController(text: widget.profile?['bio'] ?? '');
    _phoneController = TextEditingController(text: widget.profile?['phone'] ?? '');
    _currentPhotoUrl = widget.profile?['photoUrl'];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadAvatar() async {
    try {
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Gallery permission is required to choose a profile photo.'),
              backgroundColor: ReelTheme.accentColor,
            ),
          );
        }
        return;
      }
    } catch (e) {
      debugPrint('Error requesting photo permission: $e');
    }

    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 50,
        maxWidth: 500,
      );

      if (pickedFile == null) return;

      setState(() {
        _uploadingAvatar = true;
      });

      final supabase = context.read<SupabaseService>();
      final user = supabase.currentUser;
      if (user == null) return;

      await supabase.uploadAvatar(File(pickedFile.path));
      supabase.clearProfileCache(user.id);

      // Fetch fresh profile to display the new image
      final updatedProfile = await supabase.getUserProfile(user.id);
      if (mounted) {
        setState(() {
          _currentPhotoUrl = updatedProfile?['photoUrl'];
          _uploadingAvatar = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile picture updated successfully!'),
            backgroundColor: Color(0xFF00BFFF),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploadingAvatar = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update picture: ${e.toString()}'),
            backgroundColor: ReelTheme.accentColor,
          ),
        );
      }
    }
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final bio = _bioController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Name cannot be empty'),
          backgroundColor: ReelTheme.accentColor,
        ),
      );
      return;
    }

    setState(() {
      _savingProfile = true;
    });

    final supabase = context.read<SupabaseService>();
    final user = supabase.currentUser;
    if (user == null) return;

    try {
      await supabase.client.from('users').update({
        'name': name,
        'phone': phone.isNotEmpty ? phone : null,
        'bio': bio.isNotEmpty ? bio : null,
      }).eq('id', user.id);

      supabase.clearProfileCache(user.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully!'),
            backgroundColor: Color(0xFF00BFFF),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _savingProfile = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update profile: ${e.toString()}'),
            backgroundColor: ReelTheme.accentColor,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: ReelTheme.pitchBlack,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white12),
              ),
              child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
            ),
          ),
        ),
        title: const Text(
          'Edit Profile',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
            letterSpacing: 0.5,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  ReelTheme.accentColor,
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Cyberpunk Background Glows
          Positioned(
            top: -100,
            left: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: ReelTheme.accentColor.withOpacity(0.15),
                    blurRadius: 100,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            right: -50,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00BFFF).withOpacity(0.1),
                    blurRadius: 120,
                  ),
                ],
              ),
            ),
          ),
          // Scrollable Form
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  // Avatar Section with Neon Rings
                  Center(
                    child: Stack(
                      children: [
                        // Outer glowing border
                        Container(
                          width: 130,
                          height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: ReelTheme.accentColor.withOpacity(0.8),
                              width: 3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: ReelTheme.accentColor.withOpacity(0.3),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(3.0),
                            child: ClipOval(
                              child: _currentPhotoUrl != null && _currentPhotoUrl!.isNotEmpty
                                  ? Image.network(
                                      _currentPhotoUrl!,
                                      fit: BoxFit.cover,
                                      loadingBuilder: (context, child, loadingProgress) {
                                        if (loadingProgress == null) return child;
                                        return Container(
                                          color: Colors.white.withOpacity(0.05),
                                          child: const Center(
                                            child: CircularProgressIndicator(
                                              color: ReelTheme.accentColor,
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        );
                                      },
                                    )
                                  : Container(
                                      color: Colors.white10,
                                      child: const Icon(
                                        Icons.person,
                                        color: Colors.white30,
                                        size: 64,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        // Loading overlay
                        if (_uploadingAvatar)
                          Positioned.fill(
                            child: Container(
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black54,
                              ),
                              child: const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFF00BFFF),
                                  strokeWidth: 3,
                                ),
                              ),
                            ),
                          ),
                        // Edit icon overlay
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFF00BFFF),
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF00BFFF).withOpacity(0.4),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.camera_alt_outlined,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _uploadingAvatar ? 'Uploading image...' : 'Tap icon to edit photo',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // Inputs Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.02),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.05),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildInputField(
                          controller: _nameController,
                          label: 'NAME',
                          icon: Icons.person_outline_rounded,
                          hint: 'Enter your name',
                        ),
                        const SizedBox(height: 24),
                        _buildInputField(
                          controller: _bioController,
                          label: 'BIO',
                          icon: Icons.info_outline_rounded,
                          hint: 'Write something about yourself...',
                          maxLines: 3,
                        ),
                        const SizedBox(height: 24),
                        _buildInputField(
                          controller: _phoneController,
                          label: 'PHONE',
                          icon: Icons.phone_outlined,
                          hint: 'Enter your phone number',
                          keyboardType: TextInputType.phone,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 36),

                  // Save Changes button
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: ReelTheme.accentColor.withOpacity(0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _savingProfile ? null : _saveProfile,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ReelTheme.accentColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: _savingProfile
                            ? const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : const Text(
                                'SAVE CHANGES',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  letterSpacing: 1,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String hint,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF00BFFF),
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
          ),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: Colors.white30, size: 20),
            hintText: hint,
            hintStyle: const TextStyle(
              color: Colors.white24,
              fontSize: 14,
            ),
            filled: true,
            fillColor: Colors.white.withOpacity(0.02),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: Colors.white.withOpacity(0.08),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: ReelTheme.accentColor,
                width: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

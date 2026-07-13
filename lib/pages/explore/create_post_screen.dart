import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final TextEditingController _textController = TextEditingController();
  File? _image;
  bool _loading = false;
  Map<String, dynamic>? _userProfile;

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
  }

  Future<void> _fetchUserProfile() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId != null) {
      try {
        final profile = await supabase.getUserProfile(myId);
        if (profile != null && mounted) {
          setState(() {
            _userProfile = profile;
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (pickedFile != null) {
      setState(() => _image = File(pickedFile.path));
    }
  }

  Future<void> _submitPost() async {
    if (_textController.text.trim().isEmpty && _image == null) return;
    if (_textController.text.length > 280) return;

    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();

    try {
      await supabase.uploadAndCreatePost(
        _textController.text,
        _image,
      );

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to post: ${e.toString()}'),
            backgroundColor: const Color(0xFF7E1C31),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBgColor = isDark ? const Color(0xFF0F0F10) : const Color(0xFFF9FBFD);
    final inputBgColor = isDark ? const Color(0xFF161618) : Colors.white;
    final textLength = _textController.text.length;
    final isOverLimit = textLength > 280;
    final progress = (textLength / 280.0).clamp(0.0, 1.0);
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;

    Color progressColor = const Color(0xFF00BFFF); // Sky Blue
    if (textLength >= 250) {
      progressColor = Colors.orangeAccent;
    }
    if (isOverLimit) {
      progressColor = Colors.redAccent;
    }

    final isPostEnabled = (textLength > 0 || _image != null) && !isOverLimit && !_loading;

    return Scaffold(
      backgroundColor: scaffoldBgColor,
      appBar: AppBar(
        backgroundColor: scaffoldBgColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: isDark ? Colors.white70 : Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Create Post',
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isPostEnabled ? const Color(0xFFFE2C55) : Colors.grey.withOpacity(0.2),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                onPressed: isPostEnabled ? _submitPost : null,
                child: _loading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Post', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (myId != null)
                        UserAvatar(userId: myId, radius: 22)
                      else
                        const CircleAvatar(radius: 22, backgroundColor: Colors.white12, child: Icon(Icons.person)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_userProfile != null)
                              Text(
                                _userProfile!['name'] ?? 'User',
                                style: TextStyle(
                                  color: isDark ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            TextField(
                              controller: _textController,
                              style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 17, height: 1.4),
                              maxLines: null,
                              maxLength: null,
                              decoration: InputDecoration(
                                hintText: "Share what's on your mind...",
                                hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (_image != null)
                    Stack(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.file(_image!, maxHeight: 400, width: double.infinity, fit: BoxFit.cover),
                          ),
                        ),
                        Positioned(
                          top: 10,
                          right: 10,
                          child: GestureDetector(
                            onTap: () => setState(() => _image = null),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          // Character count and formatting bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: inputBgColor,
              border: Border(top: BorderSide(color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.05))),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    onPressed: _pickImage,
                    icon: Icon(Icons.image_outlined, color: isDark ? Colors.white70 : Colors.black54),
                    tooltip: 'Add Image',
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: Icon(Icons.emoji_emotions_outlined, color: isDark ? Colors.white70 : Colors.black54),
                    tooltip: 'Emojis',
                  ),
                  const Spacer(),
                  // Circular Progress Indicator for character limit
                  if (textLength > 0) ...[
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 2.5,
                            backgroundColor: isDark ? Colors.white12 : Colors.black12,
                            valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                          ),
                        ),
                        if (textLength >= 260)
                          Text(
                            '${280 - textLength}',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: isOverLimit ? Colors.redAccent : (isDark ? Colors.white70 : Colors.black87),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

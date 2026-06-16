import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final _nameController = TextEditingController();
  final _picker = ImagePicker();
  File? _groupIconFile;

  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selectedFriendIds = {};
  bool _loadingFriends = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _fetchFriends();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _fetchFriends() async {
    final supabase = context.read<SupabaseService>();
    try {
      final friendsList = await supabase.getAddedFriends();
      if (mounted) {
        setState(() {
          _friends = friendsList;
          _loadingFriends = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingFriends = false);
      }
    }
  }

  Future<void> _pickGroupIcon() async {
    try {
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gallery permission is required to choose a group icon.')),
          );
        }
        return;
      }
    } catch (e) {
      debugPrint('Error requesting photo permission: $e');
    }

    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 400,
    );

    if (pickedFile != null) {
      setState(() {
        _groupIconFile = File(pickedFile.path);
      });
    }
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a group name.')),
      );
      return;
    }

    if (_selectedFriendIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one friend to add to the group.')),
      );
      return;
    }

    setState(() => _creating = true);
    final supabase = context.read<SupabaseService>();

    try {
      final chatId = await supabase.createGroupChat(
        name,
        _selectedFriendIds.toList(),
        _groupIconFile,
      );

      if (mounted) {
        // Pop back and open the chat room
        Navigator.pop(context); // Pop CreateGroupPage
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => ChatRoomPage(
              chatId: chatId,
              otherUserId: '',
              otherUserName: name,
              isGroup: true,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create group: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'New Group',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        actions: [
          if (!_creating)
            TextButton(
              onPressed: _createGroup,
              child: const Text(
                'Create',
                style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            )
          else
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: _creating
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Group Icon Picker Bubble
                  GestureDetector(
                    onTap: _pickGroupIcon,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [Colors.cyanAccent, Colors.indigoAccent.shade400],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: CircleAvatar(
                            radius: 54,
                            backgroundColor: Colors.grey[950],
                            backgroundImage: _groupIconFile != null ? FileImage(_groupIconFile!) : null,
                            child: _groupIconFile == null
                                ? Icon(Icons.group, size: 48, color: Colors.indigoAccent.shade100)
                                : null,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: Colors.cyanAccent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.camera_alt, size: 18, color: Colors.black),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Group Name Field
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Group Name',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white10,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Colors.cyanAccent, width: 1.5),
                      ),
                      prefixIcon: const Icon(Icons.edit, color: Colors.cyanAccent),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Friend Selection Header
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'ADD PARTICIPANTS',
                      style: TextStyle(
                        color: Colors.white38,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Friends list checklist
                  _loadingFriends
                      ? const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: Colors.cyanAccent)))
                      : _friends.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Text(
                                'No mutual friends available to add.',
                                style: TextStyle(color: Colors.white38, fontSize: 14),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _friends.length,
                              itemBuilder: (context, index) {
                                final friend = _friends[index];
                                final String id = friend['id'] ?? '';
                                final String name = friend['name'] ?? 'User';
                                final isSelected = _selectedFriendIds.contains(id);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.03),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isSelected ? Colors.cyanAccent.withOpacity(0.3) : Colors.transparent,
                                        width: 1,
                                      ),
                                    ),
                                    child: CheckboxListTile(
                                      activeColor: Colors.cyanAccent,
                                      checkColor: Colors.black,
                                      value: isSelected,
                                      onChanged: (bool? checked) {
                                        setState(() {
                                          if (checked == true) {
                                            _selectedFriendIds.add(id);
                                          } else {
                                            _selectedFriendIds.remove(id);
                                          }
                                        });
                                      },
                                      secondary: UserAvatar(userId: id, radius: 20),
                                      title: Text(
                                        name,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                      ),
                                      checkboxShape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                ],
              ),
            ),
    );
  }
}

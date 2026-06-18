import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/services/local_storage_service.dart';
import 'package:reel/pages/profile/reel_profile_page.dart';
import 'package:reel/pages/chat/chat_room_page.dart';
import 'package:reel/widgets/user_avatar.dart';

class GroupInfoPage extends StatefulWidget {
  final String chatId;

  const GroupInfoPage({super.key, required this.chatId});

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  bool _loading = true;
  Map<String, dynamic>? _groupDetails;
  List<Map<String, dynamic>> _members = [];
  String? _myId;
  bool _isMuted = false;
  String _disappearingDuration = 'off';
  Map<String, dynamic> _metadata = {};
  bool _mediaVisibility = true;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadAllDetails();
  }

  Future<void> _loadAllDetails() async {
    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();
    _myId = supabase.currentUser?.id;
    _isMuted = supabase.isChatMuted(widget.chatId);

    try {
      // 1. Fetch group metadata from Supabase
      final chatRes = await supabase.client
          .from('chats')
          .select('name, groupIcon, creatorId, disappearingDuration')
          .eq('id', widget.chatId)
          .maybeSingle();

      if (chatRes != null) {
        _groupDetails = chatRes;
        _disappearingDuration = chatRes['disappearingDuration'] as String? ?? 'off';
      }

      // 2. Fetch members list with their profiles
      final memberRes = await supabase.client
          .from('chat_participants')
          .select('userId, users(id, name, photoUrl)')
          .eq('chatId', widget.chatId);

      final List<Map<String, dynamic>> loadedMembers = [];
      for (final row in memberRes) {
        final userDetail = row['users'] as Map<String, dynamic>?;
        if (userDetail != null) {
          loadedMembers.add({
            'id': userDetail['id'] as String,
            'name': userDetail['name'] as String? ?? 'User',
            'photoUrl': userDetail['photoUrl'] as String?,
          });
        }
      }

      // 3. Fetch media visibility setting
      final mediaVis = await LocalStorageService().getCachedJson('media_visibility_${widget.chatId}');
      
      // 4. Fetch group metadata JSON from Storage
      final metadata = await supabase.getGroupMetadata(widget.chatId);

      setState(() {
        _members = loadedMembers;
        _mediaVisibility = mediaVis != false;
        _metadata = metadata;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Error loading GroupInfo details: $e');
      setState(() => _loading = false);
    }
  }

  bool get _isCurrentUserAdmin {
    if (_myId == null) return false;
    if (_isCreator) return true;
    final admins = _metadata['admins'] as List<dynamic>? ?? [];
    return admins.contains(_myId);
  }

  bool get _canEditGroupInfo {
    if (_myId == null) return false;
    if (_isCreator) return true;
    final editGroupInfo = _metadata['restrictions']?['editGroupInfo'] ?? 'all';
    if (editGroupInfo == 'all') return true;
    final admins = _metadata['admins'] as List<dynamic>? ?? [];
    return admins.contains(_myId);
  }

  Future<void> _saveMetadata() async {
    setState(() => _loading = true);
    try {
      await context.read<SupabaseService>().saveGroupMetadata(widget.chatId, _metadata);
      await _loadAllDetails();
    } catch (e) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update group settings: $e')));
    }
  }

  void _editDescription() {
    final controller = TextEditingController(text: _metadata['description'] as String? ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161618),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white12)),
        title: const Text('Edit Description', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          maxLines: 4,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter group description',
            hintStyle: const TextStyle(color: Colors.white30),
            filled: true,
            fillColor: Colors.white10,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              final newDesc = controller.text.trim();
              Navigator.pop(context);
              _metadata['description'] = newDesc;
              await _saveMetadata();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionCard() {
    final desc = _metadata['description'] as String? ?? '';
    final canEdit = _canEditGroupInfo;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.06), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'GROUP DESCRIPTION',
                style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.edit, color: Colors.cyanAccent, size: 18),
                  onPressed: _editDescription,
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            desc.isNotEmpty ? desc : 'No description added yet.',
            style: TextStyle(color: desc.isNotEmpty ? Colors.white70 : Colors.white24, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaVisibilityCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.06), width: 1.2),
      ),
      child: SwitchListTile(
        activeColor: Colors.cyanAccent,
        activeTrackColor: Colors.cyanAccent.withOpacity(0.3),
        inactiveTrackColor: Colors.white10,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        title: const Text(
          'Save Media to Gallery',
          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Automatically save downloaded photos and videos to phone gallery.',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.indigoAccent.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.photo_library_outlined, color: Colors.indigoAccent, size: 20),
        ),
        value: _mediaVisibility,
        onChanged: (val) async {
          await LocalStorageService().cacheJson('media_visibility_${widget.chatId}', val);
          setState(() {
            _mediaVisibility = val;
          });
        },
      ),
    );
  }

  Widget _buildInviteLinkCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.06), width: 1.2),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.link_rounded, color: Colors.cyanAccent, size: 20),
        ),
        title: const Text(
          'Share Group Invite Link',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: const Text(
          'Copy invite link to clipboard',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        trailing: const Icon(Icons.content_copy_rounded, size: 16, color: Colors.cyanAccent),
        onTap: () {
          final inviteLink = 'https://reel.app/join/${widget.chatId}';
          Clipboard.setData(ClipboardData(text: inviteLink));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Group invite link copied to clipboard!'),
              backgroundColor: Color(0xFF0D0D10),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGroupControlsCard() {
    if (!_isCurrentUserAdmin) return const SizedBox.shrink();
    final editGroupInfo = _metadata['restrictions']?['editGroupInfo'] ?? 'all';
    final sendMessages = _metadata['restrictions']?['sendMessages'] ?? 'all';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.06), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'GROUP CONTROLS (ADMIN ONLY)',
            style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            activeColor: Colors.cyanAccent,
            activeTrackColor: Colors.cyanAccent.withOpacity(0.3),
            inactiveTrackColor: Colors.white10,
            contentPadding: EdgeInsets.zero,
            title: const Text('Only Admins can Edit Info', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: const Text('Allows editing group name, icon, description, and disappearing messages settings.', style: TextStyle(color: Colors.white38, fontSize: 11)),
            value: editGroupInfo == 'admins',
            onChanged: (val) async {
              _metadata['restrictions'] ??= {};
              _metadata['restrictions']['editGroupInfo'] = val ? 'admins' : 'all';
              await _saveMetadata();
            },
          ),
          const Divider(color: Colors.white10, height: 16),
          SwitchListTile(
            activeColor: Colors.cyanAccent,
            activeTrackColor: Colors.cyanAccent.withOpacity(0.3),
            inactiveTrackColor: Colors.white10,
            contentPadding: EdgeInsets.zero,
            title: const Text('Only Admins can Send Messages', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: const Text('Restricts sending messages in the chat to group admins only.', style: TextStyle(color: Colors.white38, fontSize: 11)),
            value: sendMessages == 'admins',
            onChanged: (val) async {
              _metadata['restrictions'] ??= {};
              _metadata['restrictions']['sendMessages'] = val ? 'admins' : 'all';
              await _saveMetadata();
            },
          ),
        ],
      ),
    );
  }

  bool get _isCreator => _groupDetails != null && _groupDetails!['creatorId'] == _myId;

  Future<void> _changeGroupIcon() async {
    try {
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gallery permission is required to choose a group icon.')),
        );
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
      setState(() => _loading = true);
      try {
        final file = File(pickedFile.path);
        final supabase = context.read<SupabaseService>();
        await supabase.updateGroupIcon(widget.chatId, file);
        await _loadAllDetails();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group icon updated successfully!')),
        );
      } catch (e) {
        debugPrint('Error updating group icon: $e');
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update icon: $e')),
        );
      }
    }
  }

  void _editGroupName() {
    final controller = TextEditingController(text: _groupDetails?['name'] ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161618),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white12)),
        title: const Text('Edit Group Name', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter group name',
            hintStyle: const TextStyle(color: Colors.white30),
            filled: true,
            fillColor: Colors.white10,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                Navigator.pop(context);
                setState(() => _loading = true);
                try {
                  await context.read<SupabaseService>().updateGroupName(widget.chatId, newName);
                  await _loadAllDetails();
                } catch (e) {
                  setState(() => _loading = false);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update name: $e')));
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateDisappearingSettings(String duration) async {
    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();
    try {
      await supabase.client.from('chats').update({'disappearingDuration': duration}).eq('id', widget.chatId);
      await _loadAllDetails();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Disappearing messages set to $duration'),
      ));
    } catch (e) {
      debugPrint('Error updating disappearing duration: $e');
      setState(() => _loading = false);
    }
  }

  void _showDisappearingDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xCC0D0D10),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(32), topRight: Radius.circular(32)),
              border: Border(top: BorderSide(color: Colors.white12, width: 1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Disappearing Messages',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Messages sent in this chat room will automatically disappear for all participants after the set time.',
                  style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: _buildDisappearingCard('off', 'Off', Icons.lock_open_rounded)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildDisappearingCard('24h', '24 Hours', Icons.timer_outlined)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildDisappearingCard('48h', '48 Hours', Icons.hourglass_empty_rounded)),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDisappearingCard(String value, String label, IconData icon) {
    final isSelected = _disappearingDuration == value;
    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        _updateDisappearingSettings(value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyanAccent.withOpacity(0.08) : Colors.white.withOpacity(0.02),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.cyanAccent.withOpacity(0.4) : Colors.white.withOpacity(0.06),
            width: 1.2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.cyanAccent.withOpacity(0.1),
                    blurRadius: 12,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.cyanAccent : Colors.white60,
              size: 24,
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showMemberOptions(Map<String, dynamic> member) {
    if (member['id'] == _myId) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xCC0D0D10),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(32), topRight: Radius.circular(32)),
              border: Border(top: BorderSide(color: Colors.white12, width: 1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    UserAvatar(userId: member['id'], radius: 24),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        member['name'],
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSheetActionTile(
                  icon: Icons.account_circle_outlined,
                  label: 'View Profile',
                  color: Colors.white,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => ReelProfilePage(userId: member['id'])),
                    );
                  },
                ),
                _buildSheetActionTile(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: 'Message ${member['name']}',
                  color: Colors.white,
                  onTap: () async {
                    Navigator.pop(context);
                    final supabase = context.read<SupabaseService>();
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) => const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
                    );
                    try {
                      final dmChatId = await supabase.createOrGetChat(member['id']);
                      if (mounted) {
                        Navigator.pop(context); // Pop loading dialog
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatRoomPage(
                              chatId: dmChatId,
                              otherUserId: member['id'],
                              otherUserName: member['name'],
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        Navigator.pop(context); // Pop loading dialog
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to open chat: $e')),
                        );
                      }
                    }
                  },
                ),
                final creatorId = _groupDetails?['creatorId'];
                final isMeAdmin = _isCurrentUserAdmin;
                final targetIsAdmin = _metadata['admins']?.contains(member['id']) == true;
                final isTargetCreator = member['id'] == creatorId;
                
                final canManageAdmins = isMeAdmin && !isTargetCreator;
                
                final canRemove = _isCreator
                    ? !isTargetCreator
                    : (isMeAdmin && !targetIsAdmin && !isTargetCreator);

                if (canManageAdmins)
                  _buildSheetActionTile(
                    icon: targetIsAdmin ? Icons.admin_panel_settings_outlined : Icons.admin_panel_settings,
                    label: targetIsAdmin ? 'Dismiss as Admin' : 'Make Group Admin',
                    color: Colors.deepPurpleAccent,
                    onTap: () async {
                      Navigator.pop(context);
                      setState(() => _loading = true);
                      try {
                        _metadata['admins'] ??= [];
                        final admins = List<String>.from(_metadata['admins']);
                        if (targetIsAdmin) {
                          admins.remove(member['id']);
                        } else {
                          admins.add(member['id']);
                        }
                        _metadata['admins'] = admins;
                        await context.read<SupabaseService>().saveGroupMetadata(widget.chatId, _metadata);
                        await _loadAllDetails();
                      } catch (e) {
                        setState(() => _loading = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to update admin status: $e')),
                        );
                      }
                    },
                  ),
                if (canRemove)
                  _buildSheetActionTile(
                    icon: Icons.person_remove_outlined,
                    label: 'Remove from Group',
                    color: Colors.redAccent,
                    onTap: () {
                      Navigator.pop(context);
                      _confirmRemoveMember(member);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheetActionTile({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    final isDanger = color == Colors.redAccent;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDanger ? Colors.redAccent.withOpacity(0.2) : Colors.white.withOpacity(0.06),
          width: 1.2,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 15),
        ),
        trailing: Icon(Icons.arrow_forward_ios_rounded, size: 14, color: color.withOpacity(0.4)),
        onTap: onTap,
      ),
    );
  }

  void _confirmRemoveMember(Map<String, dynamic> member) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161618),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white12)),
        title: Text('Remove ${member['name']}?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to remove this participant from the group?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _loading = true);
              try {
                await context.read<SupabaseService>().removeGroupParticipant(widget.chatId, member['id']);
                await _loadAllDetails();
              } catch (e) {
                setState(() => _loading = false);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to remove member: $e')));
              }
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _showAddParticipantsPicker() async {
    setState(() => _loading = true);
    final supabase = context.read<SupabaseService>();
    try {
      final friends = await supabase.getAddedFriends();
      final currentMemberIds = _members.map((m) => m['id']).toSet();
      final addableFriends = friends.where((f) => !currentMemberIds.contains(f['id'])).toList();

      setState(() => _loading = false);

      if (addableFriends.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All your friends are already in this group.')),
          );
        }
        return;
      }

      if (mounted) {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          builder: (context) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: DraggableScrollableSheet(
                initialChildSize: 0.7,
                maxChildSize: 0.9,
                minChildSize: 0.5,
                builder: (_, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Color(0xCC0D0D10),
                      borderRadius: BorderRadius.only(topLeft: Radius.circular(32), topRight: Radius.circular(32)),
                      border: Border(top: BorderSide(color: Colors.white12, width: 1)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                    child: Column(
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Add Members',
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: ListView.builder(
                            controller: scrollController,
                            itemCount: addableFriends.length,
                            itemBuilder: (context, index) {
                              final friend = addableFriends[index];
                              final String fId = friend['id'] ?? '';
                              final String fName = friend['name'] ?? 'User';

                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.02),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withOpacity(0.06), width: 1.2),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                  leading: UserAvatar(userId: fId, radius: 20),
                                  title: Text(fName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.cyanAccent),
                                    onPressed: () async {
                                      Navigator.pop(context);
                                      setState(() => _loading = true);
                                      try {
                                        await supabase.addGroupParticipant(widget.chatId, fId);
                                        await _loadAllDetails();
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Added $fName to the group!')),
                                        );
                                      } catch (e) {
                                        setState(() => _loading = false);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Failed to add participant: $e')),
                                        );
                                      }
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        );
      }
    } catch (e) {
      debugPrint('Error loading addable friends: $e');
      setState(() => _loading = false);
    }
  }

  void _leaveGroupConfirm() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161618),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white12)),
        title: const Text('Leave Group?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('You will no longer receive messages or be a participant in this group.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _loading = true);
              final supabase = context.read<SupabaseService>();
              try {
                await supabase.removeGroupParticipant(widget.chatId, _myId!);
                if (mounted) {
                  Navigator.popUntil(context, (route) => route.isFirst);
                }
              } catch (e) {
                setState(() => _loading = false);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to leave group: $e')));
              }
            },
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  void _deleteGroupConfirm() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161618),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white12)),
        title: const Text('Delete Group?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('This action will delete the entire group and all message history for all members. This cannot be undone.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _loading = true);
              final supabase = context.read<SupabaseService>();
              try {
                for (final member in _members) {
                  await supabase.removeGroupParticipant(widget.chatId, member['id']);
                }
                await supabase.client.from('chats').delete().eq('id', widget.chatId);
                if (mounted) {
                  Navigator.popUntil(context, (route) => route.isFirst);
                }
              } catch (e) {
                setState(() => _loading = false);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete group: $e')));
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String creatorName = 'Creator';
    if (_groupDetails != null && _members.isNotEmpty) {
      final creator = _members.firstWhere(
        (m) => m['id'] == _groupDetails?['creatorId'],
        orElse: () => {},
      );
      if (creator.isNotEmpty) {
        creatorName = creator['name'];
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned(
            top: -120,
            right: -120,
            child: Container(
              width: 380,
              height: 380,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.cyanAccent.withOpacity(0.06),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            left: -150,
            child: Container(
              width: 500,
              height: 500,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.deepPurpleAccent.withOpacity(0.06),
              ),
            ),
          ),
          NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar(
                  expandedHeight: 320,
                  pinned: true,
                  backgroundColor: const Color(0xCC000000),
                  flexibleSpace: FlexibleSpaceBar(
                    collapseMode: CollapseMode.pin,
                    background: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 50),
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 146,
                              height: 146,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  colors: [Colors.cyanAccent, Colors.deepPurpleAccent],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.cyanAccent.withOpacity(0.18),
                                    blurRadius: 35,
                                    spreadRadius: 2,
                                  )
                                ],
                              ),
                            ),
                            Container(
                              width: 140,
                              height: 140,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black,
                              ),
                            ),
                            CircleAvatar(
                              radius: 66,
                              backgroundColor: Colors.indigo.withOpacity(0.15),
                              backgroundImage: _groupDetails?['groupIcon'] != null && _groupDetails!['groupIcon'].toString().isNotEmpty
                                  ? NetworkImage(_groupDetails!['groupIcon'].toString())
                                  : null,
                              child: _groupDetails?['groupIcon'] != null && _groupDetails!['groupIcon'].toString().isNotEmpty
                                  ? null
                                  : const Icon(Icons.group_rounded, size: 55, color: Colors.cyanAccent),
                            ),
                            if (_canEditGroupInfo)
                              Positioned(
                                bottom: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: _changeGroupIcon,
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.cyanAccent,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.cyanAccent.withOpacity(0.3),
                                          blurRadius: 8,
                                          spreadRadius: 1,
                                        )
                                      ],
                                    ),
                                    child: const Icon(Icons.camera_alt_rounded, color: Colors.black, size: 18),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                _groupDetails?['name'] ?? 'Group Name',
                                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_canEditGroupInfo) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.edit, color: Colors.cyanAccent, size: 20),
                                onPressed: _editGroupName,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Created by $creatorName · ${_members.length} members',
                          style: const TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ];
            },
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDescriptionCard(),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _isMuted ? Colors.redAccent.withOpacity(0.15) : Colors.white.withOpacity(0.06),
                              width: 1.2,
                            ),
                          ),
                          child: SwitchListTile(
                            activeColor: Colors.cyanAccent,
                            activeTrackColor: Colors.cyanAccent.withOpacity(0.3),
                            inactiveTrackColor: Colors.white10,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            title: const Text(
                              'Mute',
                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            secondary: Icon(
                              _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                              color: _isMuted ? Colors.redAccent : Colors.cyanAccent,
                              size: 20,
                            ),
                            value: _isMuted,
                            onChanged: (val) async {
                              final supabase = context.read<SupabaseService>();
                              await supabase.toggleMuteChat(widget.chatId);
                              setState(() {
                                _isMuted = val;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _disappearingDuration != 'off' ? Colors.cyanAccent.withOpacity(0.15) : Colors.white.withOpacity(0.06),
                              width: 1.2,
                            ),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: Icon(
                              Icons.timer_outlined,
                              color: _disappearingDuration != 'off' ? Colors.cyanAccent : Colors.white60,
                              size: 20,
                            ),
                            title: const Text(
                              'Disappearing',
                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              _disappearingDuration == 'off' ? 'Off' : _disappearingDuration == '24h' ? '24 Hours' : '48 Hours',
                              style: TextStyle(
                                color: _disappearingDuration != 'off' ? Colors.cyanAccent.withOpacity(0.8) : Colors.white30,
                                fontSize: 11,
                              ),
                            ),
                            onTap: _showDisappearingDialog,
                          ),
                        ),
                      ),
                    ],
                  ),
                  _buildMediaVisibilityCard(),
                  _buildInviteLinkCard(),
                  _buildGroupControlsCard(),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'PARTICIPANTS (${_members.length})',
                          style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                        ),
                        if (_isCurrentUserAdmin)
                          GestureDetector(
                            onTap: _showAddParticipantsPicker,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.cyanAccent.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.cyanAccent.withOpacity(0.25), width: 1),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.add, color: Colors.cyanAccent, size: 14),
                                  SizedBox(width: 4),
                                  Text(
                                    'Add Members',
                                    style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.02),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withOpacity(0.06), width: 1.2),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _members.length,
                      separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1, indent: 70),
                      itemBuilder: (context, index) {
                        final member = _members[index];
                        final isOwner = member['id'] == _groupDetails?['creatorId'];

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: UserAvatar(userId: member['id'], radius: 20),
                          title: Text(
                            member['id'] == _myId ? 'You' : member['name'],
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                          trailing: isOwner
                              ? Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFFFF3B30), Color(0xFFFF9500)],
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.redAccent.withOpacity(0.2),
                                        blurRadius: 10,
                                      )
                                    ],
                                  ),
                                  child: const Text(
                                    'OWNER',
                                    style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                                  ),
                                )
                              : (_metadata['admins']?.contains(member['id']) == true
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: Colors.deepPurpleAccent.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: Colors.deepPurpleAccent.withOpacity(0.3)),
                                      ),
                                      child: const Text(
                                        'ADMIN',
                                        style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                                      ),
                                    )
                                  : (member['id'] == _myId
                                      ? Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: Colors.cyanAccent.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                                          ),
                                          child: const Text(
                                            'YOU',
                                            style: TextStyle(color: Colors.cyanAccent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                                          ),
                                        )
                                      : const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Colors.white24))),
                          onTap: () => _showMemberOptions(member),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.01),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.15), width: 1.2),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                          leading: const Icon(Icons.exit_to_app_rounded, color: Colors.redAccent),
                          title: const Text('Leave Group', style: TextStyle(color: Colors.redAccent, fontSize: 15, fontWeight: FontWeight.bold)),
                          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.redAccent),
                          onTap: _leaveGroupConfirm,
                        ),
                        if (_isCreator) ...[
                          const Divider(color: Colors.white10, height: 1, indent: 56),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                            leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                            title: const Text('Delete Group', style: TextStyle(color: Colors.redAccent, fontSize: 15, fontWeight: FontWeight.bold)),
                            trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.redAccent),
                            onTap: _deleteGroupConfirm,
                          ),
                        ]
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
          if (_loading)
            Container(
              color: Colors.black45,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.cyanAccent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

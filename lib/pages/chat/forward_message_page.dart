import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/widgets/user_avatar.dart';

class ForwardMessagePage extends StatefulWidget {
  final Map<String, dynamic> messageToForward;

  const ForwardMessagePage({super.key, required this.messageToForward});

  @override
  State<ForwardMessagePage> createState() => _ForwardMessagePageState();
}

class _ForwardMessagePageState extends State<ForwardMessagePage> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _contacts = [];
  Set<String> _selectedChatIds = {};

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      // Load recent chats
      final response = await supabase.client
          .from('chats')
          .select('id, user1Id, user2Id')
          .or('user1Id.eq.$myId,user2Id.eq.$myId');

      final List<Map<String, dynamic>> contacts = [];
      for (var chat in response) {
        final otherUserId = chat['user1Id'] == myId ? chat['user2Id'] : chat['user1Id'];
        final userProfile = await supabase.client
            .from('profiles')
            .select('username')
            .eq('id', otherUserId)
            .single();

        contacts.add({
          'chatId': chat['id'],
          'userId': otherUserId,
          'username': userProfile['username'],
        });
      }

      if (mounted) {
        setState(() {
          _contacts = contacts;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _forwardMessage() async {
    if (_selectedChatIds.isEmpty) return;

    final supabase = context.read<SupabaseService>();
    
    // We display a loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final msg = widget.messageToForward;
      
      for (final chatId in _selectedChatIds) {
        await supabase.client.from('messages').insert({
          'chatId': chatId,
          'senderId': supabase.currentUser!.id,
          'text': msg['text'],
          'mediaUrl': msg['mediaUrl'],
          'mediaType': msg['mediaType'],
          'received': false,
        });
      }
      
      if (mounted) {
        Navigator.pop(context); // pop loading
        Navigator.pop(context); // pop to chat page
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message forwarded')));
      }
    } catch (_) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to forward')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[950],
        title: const Text('Forward to...', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _contacts.length,
              itemBuilder: (context, index) {
                final contact = _contacts[index];
                final chatId = contact['chatId'];
                final isSelected = _selectedChatIds.contains(chatId);

                return ListTile(
                  leading: UserAvatar(userId: contact['userId'], radius: 20),
                  title: Text(contact['username'], style: const TextStyle(color: Colors.white)),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle, color: Color(0xFF00A884))
                      : const Icon(Icons.circle_outlined, color: Colors.white54),
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedChatIds.remove(chatId);
                      } else {
                        _selectedChatIds.add(chatId);
                      }
                    });
                  },
                );
              },
            ),
      floatingActionButton: _selectedChatIds.isNotEmpty
          ? FloatingActionButton(
              backgroundColor: const Color(0xFF00A884),
              onPressed: _forwardMessage,
              child: const Icon(Icons.send, color: Colors.white),
            )
          : null,
    );
  }
}

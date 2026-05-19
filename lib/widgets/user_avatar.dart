import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';

class UserAvatar extends StatelessWidget {
  final String userId;
  final double radius;
  final BoxBorder? border;
  final VoidCallback? onTap;

  const UserAvatar({
    super.key,
    required this.userId,
    this.radius = 20,
    this.border,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final supabase = context.read<SupabaseService>();

    // If cache already has the profile, use it instantly without FutureBuilder layout hop
    final cached = supabase.profileCache[userId];
    if (cached != null) {
      return _buildAvatar(cached['photoUrl']);
    }

    return FutureBuilder<Map<String, dynamic>?>(
      future: supabase.getUserProfile(userId),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final photoUrl = profile?['photoUrl'] as String?;
        return _buildAvatar(photoUrl);
      },
    );
  }

  Widget _buildAvatar(String? photoUrl) {
    Widget avatar = CircleAvatar(
      radius: radius,
      backgroundColor: Colors.white10,
      backgroundImage: photoUrl != null && photoUrl.isNotEmpty
          ? NetworkImage(photoUrl)
          : null,
      child: photoUrl != null && photoUrl.isNotEmpty
          ? null
          : Icon(Icons.person, color: Colors.white30, size: radius),
    );

    if (border != null) {
      avatar = Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: border,
        ),
        child: avatar,
      );
    }

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: avatar,
      );
    }

    return avatar;
  }
}

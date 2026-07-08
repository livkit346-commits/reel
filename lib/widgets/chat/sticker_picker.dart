import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';

class StickerPicker extends StatefulWidget {
  final Function(String url) onStickerSelected;

  const StickerPicker({
    super.key,
    required this.onStickerSelected,
  });

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ImagePicker _picker = ImagePicker();
  bool _isUploading = false;
  List<String> _customStickers = [];

  // Optimized webp assets for lightning fast loading
  static const List<String> _defaultStickers = [
    'assets/cyber_neon_smile.webp',
    'assets/cyber_neon_skull.webp',
    'assets/cyber_neon_heart.webp',
  ];

  // A premium selection of large emoji stickers that require zero network downloads
  static const List<String> _emojiStickers = [
    '😂', '😍', '😭', '😎', '👍', '🔥', '🎉', '❤️',
    '💀', '👽', '🤖', '👾', '👑', '🦄', '🍄', '🍕',
    '🍦', '🚀', '💡', '💎', '🔮', '💖', '🌟', '🌈',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadCustomStickers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadCustomStickers() async {
    final supabase = context.read<SupabaseService>();
    try {
      final stickers = await supabase.getCustomStickers();
      if (mounted) {
        setState(() {
          _customStickers = stickers;
        });
      }
    } catch (_) {}
  }

  Future<void> _addCustomSticker() async {
    final supabase = context.read<SupabaseService>();
    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
      );

      if (pickedFile == null) return;

      setState(() {
        _isUploading = true;
      });

      final file = File(pickedFile.path);

      // Upload with server SHA-256 deduplication and association
      final url = await supabase.addCustomSticker(file);

      setState(() {
        _customStickers.remove(url); // avoid duplicates in list
        _customStickers.insert(0, url);
        _isUploading = false;
      });
    } catch (e) {
      setState(() {
        _isUploading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add sticker: $e')),
        );
      }
    }
  }

  Future<void> _removeCustomSticker(String url) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1F1F28) : Colors.white,
        title: Text('Delete Sticker?', style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
        content: Text('Remove this sticker from your custom stickers?', style: TextStyle(color: isDark ? Colors.white70 : Colors.black54)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() {
                _customStickers.remove(url);
              });
              final supabase = context.read<SupabaseService>();
              await supabase.removeCustomSticker(url);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    
    // Premium theme variables
    final pickerBgColor = isDark ? const Color(0xFF0F0F14) : const Color(0xFFF7F7FA);
    final borderColor = isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06);
    final activeTabColor = isDark ? const Color(0xFF00BFFF) : primaryColor;

    return Material(
      color: Colors.transparent,
      child: Container(
        height: 310,
        decoration: BoxDecoration(
          color: pickerBgColor,
          border: Border(
            top: BorderSide(color: borderColor, width: 1.2),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.4 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              // Premium styled Tab Bar
              Container(
                height: 48,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: borderColor, width: 0.8)),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: activeTabColor,
                  labelColor: activeTabColor,
                  unselectedLabelColor: isDark ? Colors.white38 : Colors.black38,
                  indicatorWeight: 2.5,
                  labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  tabs: const [
                    Tab(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.emoji_emotions, size: 16),
                          SizedBox(width: 6),
                          Text('Emojis'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bolt, size: 16),
                          SizedBox(width: 6),
                          Text('Cyberpunk'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_special, size: 16),
                          SizedBox(width: 6),
                          Text('My Stickers'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Tab Content
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // 1. Emoji Stickers Grid
                    _buildEmojiStickersGrid(),
                    // 2. Default Cyberpunk Grid
                    _buildStickersGrid(_defaultStickers, false, isDark),
                    // 3. Custom Stickers Grid
                    _buildStickersGrid(_customStickers, true, isDark),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiStickersGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _emojiStickers.length,
      itemBuilder: (context, index) {
        final emoji = _emojiStickers[index];
        return GestureDetector(
          onTap: () => widget.onStickerSelected('emoji:$emoji'),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              emoji,
              style: const TextStyle(fontSize: 48),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStickersGrid(List<String> urls, bool isCustomTab, bool isDark) {
    final itemBgColor = isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.02);
    final itemBorderColor = isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04);
    final iconColor = isDark ? Colors.white54 : Colors.black54;

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: urls.length + (isCustomTab ? 1 : 0),
      itemBuilder: (context, index) {
        if (isCustomTab && index == 0) {
          // "+" Add button for custom stickers
          return GestureDetector(
            onTap: _isUploading ? null : _addCustomSticker,
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: itemBorderColor),
              ),
              child: Center(
                child: _isUploading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Color(0xFF00BFFF),
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(Icons.add_photo_alternate_outlined, color: iconColor, size: 28),
              ),
            ),
          );
        }

        final actualUrl = urls[isCustomTab ? index - 1 : index];

        return GestureDetector(
          onTap: () => widget.onStickerSelected(actualUrl),
          onLongPress: isCustomTab ? () => _removeCustomSticker(actualUrl) : null,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: itemBgColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: itemBorderColor),
            ),
            child: actualUrl.startsWith('assets/')
                ? Image.asset(
                    actualUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) {
                      // Fallback to PNG version if webp fails (or vice versa)
                      final fallbackUrl = actualUrl.endsWith('.webp')
                          ? actualUrl.replaceAll('.webp', '.png')
                          : actualUrl.replaceAll('.png', '.webp');
                      return Image.asset(
                        fallbackUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(Icons.broken_image, color: iconColor, size: 24),
                      );
                    },
                  )
                : Image.network(
                    actualUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00BFFF),
                          strokeWidth: 1.5,
                        ),
                      );
                    },
                    errorBuilder: (_, __, ___) => Icon(Icons.broken_image, color: iconColor, size: 24),
                  ),
          ),
        );
      },
    );
  }
}

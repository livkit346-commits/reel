import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:reel/services/supabase_service.dart';
import 'package:reel/services/local_storage_service.dart';

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

  static const List<String> _defaultStickers = [
    'https://zvxrcwgvvubgqlxbcyov.supabase.co/storage/v1/object/public/media/default_stickers/smile.png',
    'https://zvxrcwgvvubgqlxbcyov.supabase.co/storage/v1/object/public/media/default_stickers/skull.png',
    'https://zvxrcwgvvubgqlxbcyov.supabase.co/storage/v1/object/public/media/default_stickers/heart.png',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadCustomStickers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadCustomStickers() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      final cached = await LocalStorageService().getCachedJson('custom_stickers_$myId');
      if (cached != null && cached is List) {
        setState(() {
          _customStickers = cached.cast<String>();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveCustomStickers() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

    try {
      await LocalStorageService().cacheJson('custom_stickers_$myId', _customStickers);
    } catch (_) {}
  }

  Future<void> _addCustomSticker() async {
    final supabase = context.read<SupabaseService>();
    final myId = supabase.currentUser?.id;
    if (myId == null) return;

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
      final fileName = 'custom_sticker_${DateTime.now().millisecondsSinceEpoch}.png';
      final storagePath = 'stickers/$myId/$fileName';

      // Upload directly to public media bucket
      await supabase.client.storage.from('media').upload(
        storagePath,
        file,
        fileOptions: const FileOptions(contentType: 'image/png'),
      );

      final url = supabase.client.storage.from('media').getPublicUrl(storagePath);

      setState(() {
        _customStickers.insert(0, url);
        _isUploading = false;
      });

      await _saveCustomStickers();
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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 280,
      decoration: BoxDecoration(
        color: Colors.grey[950]!.withOpacity(0.9),
        border: const Border(
          top: BorderSide(color: Colors.white10),
        ),
      ),
      child: Column(
        children: [
          // Tab Bar with Cyberpunk style
          TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFF00BFFF),
            labelColor: const Color(0xFF00BFFF),
            unselectedLabelColor: Colors.white54,
            tabs: const [
              Tab(
                icon: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.face, size: 18),
                    SizedBox(width: 6),
                    Text('Cyberpunk'),
                  ],
                ),
              ),
              Tab(
                icon: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.star, size: 18),
                    SizedBox(width: 6),
                    Text('My Stickers'),
                  ],
                ),
              ),
            ],
          ),
          // Tab Content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // 1. Default Cyberpunk Grid
                _buildStickersGrid(_defaultStickers, false),
                // 2. Custom Stickers Grid
                _buildStickersGrid(_customStickers, true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickersGrid(List<String> urls, bool isCustomTab) {
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
          // Render the "+" Add button for custom stickers
          return GestureDetector(
            onTap: _isUploading ? null : _addCustomSticker,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10, style: BorderStyle.solid),
              ),
              child: Center(
                child: _isUploading
                    ? const CircularProgressIndicator(
                        color: Color(0xFF00BFFF),
                        strokeWidth: 2,
                      )
                    : const Icon(Icons.add, color: Colors.white54, size: 28),
              ),
            ),
          );
        }

        final actualUrl = urls[isCustomTab ? index - 1 : index];

        return GestureDetector(
          onTap: () => widget.onStickerSelected(actualUrl),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: Image.network(
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
            ),
          ),
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reel/services/supabase_service.dart';

class TextStatusEditorScreen extends StatefulWidget {
  const TextStatusEditorScreen({super.key});

  @override
  State<TextStatusEditorScreen> createState() => _TextStatusEditorScreenState();
}

class _TextStatusEditorScreenState extends State<TextStatusEditorScreen> {
  final TextEditingController _controller = TextEditingController();
  
  final List<Color> _bgColors = [
    const Color(0xFF673AB7), // Purple
    const Color(0xFF00796B), // Teal
    const Color(0xFFC2185B), // Pink
    const Color(0xFFD32F2F), // Red
    const Color(0xFF1976D2), // Blue
    const Color(0xFF388E3C), // Green
    const Color(0xFFF57C00), // Orange
    const Color(0xFF455A64), // Blue Grey
  ];
  
  int _currentColorIndex = 0;
  bool _isUploading = false;

  void _cycleColor() {
    setState(() {
      _currentColorIndex = (_currentColorIndex + 1) % _bgColors.length;
    });
  }

  Future<void> _postStatus() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isUploading = true;
    });

    try {
      final supabase = context.read<SupabaseService>();
      final selectedColorVal = _bgColors[_currentColorIndex].value;

      // We store the selected color in the imageUrl field as 'color:VALUE'
      await supabase.createCustomStatus(
        text: text,
        mediaType: 'text',
        customImageUrl: 'color:$selectedColorVal',
      );
      
      if (mounted) {
        Navigator.pop(context, true); // Return true to refresh status list
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to post status: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentColor = _bgColors[_currentColorIndex];

    return Scaffold(
      backgroundColor: currentColor,
      body: Stack(
        children: [
          // Text Input Field in the center
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: TextField(
                controller: _controller,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textAlign: TextAlign.center,
                autofocus: true,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  hintText: 'Type a status...',
                  hintStyle: TextStyle(color: Colors.white60),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          // Top Buttons
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(context),
                ),
                _isUploading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : IconButton(
                        icon: const Icon(Icons.check, color: Colors.white, size: 28),
                        onPressed: _postStatus,
                      ),
              ],
            ),
          ),
          // Bottom Controls (Background Color cycler)
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            right: 24,
            child: FloatingActionButton(
              heroTag: 'cycle_bg_color',
              onPressed: _cycleColor,
              backgroundColor: Colors.white24,
              elevation: 0,
              child: const Icon(Icons.palette, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

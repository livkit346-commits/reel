import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reel/services/supabase_service.dart';

class StoryPreviewScreen extends StatefulWidget {
  final File? mediaFile;
  final String mediaType; // 'image', 'video', or 'text'

  const StoryPreviewScreen({
    super.key,
    this.mediaFile,
    required this.mediaType,
  });

  @override
  State<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends State<StoryPreviewScreen> {
  final TextEditingController _textController = TextEditingController();
  VideoPlayerController? _videoController;
  bool _isInitialized = false;
  bool _isUploading = false;

  // Video Trimming variables
  double _trimStart = 0.0;
  double _trimEnd = 100.0; // Max 1:40 (100 seconds)
  double _videoDuration = 0.0;

  // Image Editing variables
  String _editMode = 'none'; // 'none', 'draw', 'text'
  final List<Stroke> _strokes = [];
  List<Offset> _currentPoints = [];
  Color _selectedColor = const Color(0xFF00BFFF); // Default Cyan theme
  final double _strokeWidth = 5.0;
  final List<TextOverlay> _textOverlays = [];
  Size _imageRenderSize = Size.zero;

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == 'video' && widget.mediaFile != null) {
      _videoController = VideoPlayerController.file(widget.mediaFile!)
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _isInitialized = true;
              _videoDuration = _videoController!.value.duration.inSeconds.toDouble();
              _trimStart = 0.0;
              // Default to 1:40 minutes or total duration, whichever is shorter
              _trimEnd = _videoDuration > 100.0 ? 100.0 : _videoDuration;
            });
            _videoController?.play();
            _videoController?.setLooping(true);

            // Playback constraints listener to loop only in the trimmed range
            _videoController?.addListener(() {
              if (_videoController != null && _videoController!.value.isPlaying) {
                final currentPosMs = _videoController!.value.position.inMilliseconds;
                final startMs = (_trimStart * 1000).toInt();
                final endMs = (_trimEnd * 1000).toInt();

                if (currentPosMs < startMs) {
                  _videoController?.seekTo(Duration(milliseconds: startMs));
                } else if (currentPosMs >= endMs) {
                  _videoController?.seekTo(Duration(milliseconds: startMs));
                }
              }
            });
          }
        });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _textController.dispose();
    super.dispose();
  }

  String _formatSeconds(double seconds) {
    final int min = (seconds / 60).floor();
    final int sec = (seconds % 60).floor();
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  void _addTextOverlayDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Add Text Overlay', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter text...',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              final txt = textController.text.trim();
              if (txt.isNotEmpty) {
                setState(() {
                  _textOverlays.add(TextOverlay(
                    text: txt,
                    position: const Offset(80, 200), // default position
                    color: _selectedColor,
                  ));
                });
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFFF)),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  // Draw the custom edited strokes and text onto a high-res Canvas and output a new file
  Future<File> _renderEditedImage() async {
    if (_strokes.isEmpty && _textOverlays.isEmpty) {
      return widget.mediaFile!;
    }

    final bytes = await widget.mediaFile!.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final originalImage = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final width = originalImage.width.toDouble();
    final height = originalImage.height.toDouble();

    // 1. Draw original background image
    canvas.drawImage(originalImage, Offset.zero, Paint());

    // 2. Compute scaling factors from screen coords to final asset size
    final double screenWidth = _imageRenderSize.width > 0 ? _imageRenderSize.width : MediaQuery.of(context).size.width;
    final double screenHeight = _imageRenderSize.height > 0 ? _imageRenderSize.height : MediaQuery.of(context).size.height;
    
    final double scaleX = width / screenWidth;
    final double scaleY = height / screenHeight;

    canvas.scale(scaleX, scaleY);

    // 3. Draw drawings
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var stroke in _strokes) {
      paint.color = stroke.color;
      paint.strokeWidth = stroke.strokeWidth;
      for (int i = 0; i < stroke.points.length - 1; i++) {
        canvas.drawLine(stroke.points[i], stroke.points[i + 1], paint);
      }
    }

    // 4. Draw text overlays
    for (var overlay in _textOverlays) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: overlay.text,
          style: TextStyle(
            color: overlay.color,
            fontSize: overlay.fontSize,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, overlay.position);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final buffer = byteData!.buffer.asUint8List();

    final tempDir = await getTemporaryDirectory();
    final editedFile = File('${tempDir.path}/edited_status_${DateTime.now().millisecondsSinceEpoch}.png');
    await editedFile.writeAsBytes(buffer);

    return editedFile;
  }

  Future<void> _shareStory() async {
    final text = _textController.text.trim();
    if (widget.mediaType == 'text' && text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text for your story.')),
      );
      return;
    }

    setState(() => _isUploading = true);
    final supabase = context.read<SupabaseService>();

    try {
      File? finalMediaFile = widget.mediaFile;
      if (widget.mediaType == 'image' && widget.mediaFile != null) {
        finalMediaFile = await _renderEditedImage();
      }

      // Pop immediately back to updates page (returning true to indicate an upload has started)
      if (mounted) {
        Navigator.pop(context, true);
      }

      // Run upload in background
      supabase.createCustomStatus(
        text: text.isNotEmpty ? text : null,
        mediaFile: finalMediaFile,
        mediaType: widget.mediaType,
        trimStart: widget.mediaType == 'video' ? _trimStart : null,
        trimEnd: widget.mediaType == 'video' ? _trimEnd : null,
      ).then((_) {
        // Handled by updates_page listening to the progress notifier
      }).catchError((e) {
        debugPrint('Error uploading story in background: $e');
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to prepare story: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isText = widget.mediaType == 'text';

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          isText ? 'Create Story' : 'Preview Story',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Content Area (Supports interactive gestures for drawing and text positioning)
          GestureDetector(
            onPanStart: (details) {
              if (widget.mediaType == 'image' && _editMode == 'draw') {
                setState(() {
                  _currentPoints = [details.localPosition];
                });
              }
            },
            onPanUpdate: (details) {
              if (widget.mediaType == 'image') {
                if (_editMode == 'draw') {
                  setState(() {
                    _currentPoints.add(details.localPosition);
                  });
                } else if (_editMode == 'text' && _textOverlays.isNotEmpty) {
                  setState(() {
                    _textOverlays.last.position = _textOverlays.last.position + details.delta;
                  });
                }
              }
            },
            onPanEnd: (details) {
              if (widget.mediaType == 'image' && _editMode == 'draw') {
                setState(() {
                  _strokes.add(Stroke(List.from(_currentPoints), _selectedColor, _strokeWidth));
                  _currentPoints = [];
                });
              }
            },
            onTap: () {
              if (_videoController != null) {
                if (_videoController!.value.isPlaying) {
                  _videoController?.pause();
                } else {
                  _videoController?.play();
                }
                setState(() {});
              }
            },
            child: isText
                ? Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF311B92),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    alignment: Alignment.center,
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: null,
                      textAlign: TextAlign.center,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Type a status...',
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                      ),
                    ),
                  )
                : widget.mediaType == 'video'
                    ? _isInitialized
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: _videoController!.value.aspectRatio,
                              child: VideoPlayer(_videoController!),
                            ),
                          )
                        : const Center(
                            child: CircularProgressIndicator(color: Colors.white),
                          )
                    : widget.mediaFile != null
                        ? LayoutBuilder(
                            builder: (context, constraints) {
                              // Compute rendered container bounds for absolute brush path scaling
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  final newSize = Size(constraints.maxWidth, constraints.maxHeight);
                                  if (_imageRenderSize != newSize) {
                                    setState(() {
                                      _imageRenderSize = newSize;
                                    });
                                  }
                                }
                              });

                              return Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(
                                    widget.mediaFile!,
                                    fit: BoxFit.contain,
                                  ),
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: CanvasPainter(
                                        strokes: _strokes,
                                        currentPoints: _currentPoints,
                                        currentColor: _selectedColor,
                                        currentWidth: _strokeWidth,
                                        textOverlays: _textOverlays,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          )
                        : Container(color: Colors.black),
          ),

          // 2. Play/Pause overlay for video
          if (widget.mediaType == 'video' && _isInitialized && !_videoController!.value.isPlaying)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
                ),
              ),
            ),

          // 3. Premium Video Trimming Slider (WhatsApp style)
          if (widget.mediaType == 'video' && _isInitialized)
            Positioned(
              top: kToolbarHeight + MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Trim Video (Max 1:40)',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${_formatSeconds(_trimStart)} - ${_formatSeconds(_trimEnd)} (${_formatSeconds(_trimEnd - _trimStart)})',
                          style: const TextStyle(color: Color(0xFF00BFFF), fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    RangeSlider(
                      values: RangeValues(_trimStart, _trimEnd),
                      min: 0.0,
                      max: _videoDuration > 0.0 ? _videoDuration : 1.0,
                      activeColor: const Color(0xFF00BFFF),
                      inactiveColor: Colors.white24,
                      onChanged: (RangeValues values) {
                        // Enforce maximum status cut of 100 seconds (1:40 mins)
                        if (values.end - values.start <= 100.0) {
                          setState(() {
                            _trimStart = values.start;
                            _trimEnd = values.end;
                          });
                          _videoController?.seekTo(Duration(milliseconds: (_trimStart * 1000).toInt()));
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),

          // 4. Premium Image Editing Toolbar (Draw, Text, Colors, Clear)
          if (widget.mediaType == 'image')
            Positioned(
              top: kToolbarHeight + MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.edit,
                        color: _editMode == 'draw' ? const Color(0xFF00BFFF) : Colors.white,
                      ),
                      onPressed: () {
                        setState(() {
                          _editMode = _editMode == 'draw' ? 'none' : 'draw';
                        });
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.text_fields,
                        color: _editMode == 'text' ? const Color(0xFF00BFFF) : Colors.white,
                      ),
                      onPressed: () {
                        setState(() {
                          _editMode = 'text';
                        });
                        _addTextOverlayDialog();
                      },
                    ),
                    ...[
                      const Color(0xFF00BFFF),
                      const Color(0xFF00A884),
                      const Color(0xFFFFD700),
                      const Color(0xFFEF5350),
                      const Color(0xFFFFFFFF),
                    ].map((col) => GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedColor = col;
                            });
                          },
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: col,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _selectedColor == col ? Colors.white : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        )),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                      onPressed: () {
                        setState(() {
                          _strokes.clear();
                          _textOverlays.clear();
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),

          // 5. Caption field and Share Button (Only for image/video)
          if (!isText)
            Positioned(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white24),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _textController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Add a caption...',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    onPressed: _isUploading ? null : _shareStory,
                    backgroundColor: const Color(0xFF00BFFF),
                    child: const Icon(Icons.send, color: Colors.white),
                  ),
                ],
              ),
            ),

          // 6. Send button overlay for text-only story
          if (isText)
            Positioned(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              right: 24,
              child: FloatingActionButton.extended(
                onPressed: _isUploading ? null : _shareStory,
                backgroundColor: const Color(0xFF00BFFF),
                icon: const Icon(Icons.send, color: Colors.white),
                label: const Text(
                  'Share',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),

          // 7. Uploading loader overlay
          if (_isUploading)
            Container(
              color: Colors.black87,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF00BFFF)),
                    SizedBox(height: 16),
                    Text(
                      'Sharing to Story...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------
// Auxiliary Custom Painter and Data Model Classes
// ----------------------------------------------------

class Stroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  Stroke(this.points, this.color, this.strokeWidth);
}

class TextOverlay {
  String text;
  Offset position;
  Color color;
  double fontSize;
  TextOverlay({required this.text, required this.position, required this.color, this.fontSize = 24.0});
}

class CanvasPainter extends CustomPainter {
  final List<Stroke> strokes;
  final List<Offset> currentPoints;
  final Color currentColor;
  final double currentWidth;
  final List<TextOverlay> textOverlays;

  CanvasPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
    required this.textOverlays,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Draw established strokes
    for (var stroke in strokes) {
      paint.color = stroke.color;
      paint.strokeWidth = stroke.strokeWidth;
      for (int i = 0; i < stroke.points.length - 1; i++) {
        canvas.drawLine(stroke.points[i], stroke.points[i + 1], paint);
      }
    }

    // Draw active drawing path
    if (currentPoints.isNotEmpty) {
      paint.color = currentColor;
      paint.strokeWidth = currentWidth;
      for (int i = 0; i < currentPoints.length - 1; i++) {
        canvas.drawLine(currentPoints[i], currentPoints[i + 1], paint);
      }
    }

    // Draw text overlays
    for (var overlay in textOverlays) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: overlay.text,
          style: TextStyle(
            color: overlay.color,
            fontSize: overlay.fontSize,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, overlay.position);
    }
  }

  @override
  bool shouldRepaint(covariant CanvasPainter oldDelegate) => true;
}

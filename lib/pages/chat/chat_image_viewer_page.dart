import 'dart:io';
import 'package:flutter/material.dart';

class ChatImageViewerPage extends StatelessWidget {
  final String? url;
  final String? localPath;

  const ChatImageViewerPage({
    super.key,
    this.url,
    this.localPath,
  });

  @override
  Widget build(BuildContext context) {
    ImageProvider imageProvider;
    if (localPath != null && File(localPath!).existsSync()) {
      imageProvider = FileImage(File(localPath!));
    } else if (url != null && url!.isNotEmpty) {
      imageProvider = NetworkImage(url!);
    } else {
      imageProvider = const AssetImage('assets/icon.png');
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          panEnabled: true,
          boundaryMargin: const EdgeInsets.all(20),
          minScale: 0.5,
          maxScale: 4.0,
          child: Image(
            image: imageProvider,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return const Center(
                child: CircularProgressIndicator(
                  color: Colors.cyanAccent,
                ),
              );
            },
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
            ),
          ),
        ),
      ),
    );
  }
}

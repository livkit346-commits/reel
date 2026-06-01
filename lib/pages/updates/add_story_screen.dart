import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'story_preview_screen.dart';

class AddStoryScreen extends StatefulWidget {
  const AddStoryScreen({super.key});

  @override
  State<AddStoryScreen> createState() => _AddStoryScreenState();
}

class _AddStoryScreenState extends State<AddStoryScreen> with SingleTickerProviderStateMixin {
  List<AssetEntity> _assets = [];
  bool _isLoading = true;
  late TabController _tabController;
  int _currentTabIndex = 0; // 0 = All, 1 = Photos, 2 = Videos
  PermissionState _permissionState = PermissionState.notDetermined;
  final ImagePicker _picker = ImagePicker();

  // Pagination support for loading all photos/videos incrementally
  int _currentPage = 0;
  bool _hasMore = true;
  bool _isLoadingMore = false;
  AssetPathEntity? _recentAlbum;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != _currentTabIndex) {
        setState(() {
          _currentTabIndex = _tabController.index;
        });
        if (_permissionState.isAuth) {
          _loadAssets();
        }
      }
    });
    _fetchAssets();
  }

  Future<void> _fetchAssets() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    setState(() {
      _permissionState = ps;
    });
    if (ps.isAuth) {
      await _loadAssets();
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _requestPermissionAndFetch() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    setState(() {
      _permissionState = ps;
    });
    if (ps.isAuth) {
      await _loadAssets();
    } else {
      if (ps == PermissionState.denied || ps == PermissionState.restricted) {
        _showPermanentlyDeniedDialog();
      }
    }
  }

  void _showPermanentlyDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[950],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Permission Required',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Reel needs access to your photos and videos. Please enable storage permissions in your device settings to continue.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not Now', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              PhotoManager.openSetting();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00BFFF),
            ),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAssets() async {
    setState(() {
      _isLoading = true;
      _currentPage = 0;
      _hasMore = true;
      _isLoadingMore = false;
      _assets = [];
    });

    RequestType type = RequestType.all;
    if (_currentTabIndex == 1) type = RequestType.image;
    if (_currentTabIndex == 2) type = RequestType.video;

    try {
      final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
        type: type,
        onlyAll: true,
      );

      if (paths.isNotEmpty) {
        // Fetch the Recents album correctly
        final recentAlbum = paths.firstWhere((p) => p.isAll, orElse: () => paths.first);
        _recentAlbum = recentAlbum;

        final List<AssetEntity> entities = await recentAlbum.getAssetListPaged(
          page: 0,
          size: 80,
        );
        
        // Sort in memory by creation date descending (latest/newest first)
        entities.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));

        setState(() {
          _assets = entities;
          _isLoading = false;
          if (entities.length < 80) {
            _hasMore = false;
          }
        });
      } else {
        setState(() {
          _recentAlbum = null;
          _assets = [];
          _isLoading = false;
          _hasMore = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _loadMoreAssets() async {
    if (_isLoadingMore || !_hasMore || _recentAlbum == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final nextPage = _currentPage + 1;
      final List<AssetEntity> entities = await _recentAlbum!.getAssetListPaged(
        page: nextPage,
        size: 80,
      );

      if (entities.isEmpty) {
        setState(() {
          _hasMore = false;
          _isLoadingMore = false;
        });
        return;
      }

      // Sort the new page items
      entities.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));

      setState(() {
        _assets.addAll(entities);
        _assets.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
        _currentPage = nextPage;
        _isLoadingMore = false;
        if (entities.length < 80) {
          _hasMore = false;
        }
      });
    } catch (e) {
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  void _onAssetSelected(AssetEntity asset) async {
    final String type = asset.type == AssetType.video ? 'video' : 'image';
    final File? file = await asset.file;
    if (file != null) {
      _navigateToPreview(file, type);
    }
  }

  void _navigateToPreview(File file, String type) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryPreviewScreen(
          mediaFile: file,
          mediaType: type,
        ),
      ),
    );
    if (result == true && mounted) {
      Navigator.pop(context, true); // Pop back to UpdatesPage with true to trigger reload
    }
  }

  void _navigateToTextComposer() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const StoryPreviewScreen(
          mediaType: 'text',
        ),
      ),
    );
    if (result == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  void _openCameraPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[950],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Create with Camera',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white),
              title: const Text('Take a Photo', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickImage(source: ImageSource.camera);
                if (picked != null) {
                  _navigateToPreview(File(picked.path), 'image');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white),
              title: const Text('Record a Video', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickVideo(source: ImageSource.camera);
                if (picked != null) {
                  _navigateToPreview(File(picked.path), 'video');
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionDeniedView() {
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF00BFFF).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.photo_library_outlined,
                  color: Color(0xFF00BFFF),
                  size: 64,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Reel Needs Gallery Access',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'To view and share photos and videos from your camera roll, please grant gallery permissions.',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _requestPermissionAndFetch,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00BFFF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'Enable Gallery Access',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGalleryView() {
    if (_isLoading) {
      return const Expanded(
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    if (_assets.isEmpty) {
      return const Expanded(
        child: Center(
          child: Text(
            'No photos or videos found',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    return Expanded(
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification scrollInfo) {
          if (scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 200) {
            _loadMoreAssets();
          }
          return false;
        },
        child: GridView.builder(
          padding: const EdgeInsets.only(top: 2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          itemCount: _assets.length + (_isLoadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _assets.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                ),
              );
            }
            final asset = _assets[index];
            return GestureDetector(
              onTap: () => _onAssetSelected(asset),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<Uint8List?>(
                    future: asset.thumbnailDataWithSize(const ThumbnailSize.square(200)),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) return Container(color: Colors.grey[900]);
                      if (snapshot.data == null) return Container(color: Colors.grey[900]);
                      return Image.memory(snapshot.data!, fit: BoxFit.cover);
                    },
                  ),
                  if (asset.type == AssetType.video)
                    Positioned(
                      bottom: 4,
                      right: 6,
                      child: Text(
                        _formatDuration(Duration(seconds: asset.duration)),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPermission = _permissionState.isAuth;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Add to Story',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Top Action Buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _navigateToTextComposer,
                    child: Container(
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF161616),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('Aa', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                          SizedBox(height: 4),
                          Text('Text', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: _openCameraPicker,
                    child: Container(
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF161616),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.flip_camera_ios, color: Colors.white, size: 28),
                          SizedBox(height: 4),
                          Text('Camera', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Filters bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Text('Recents', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    Icon(Icons.keyboard_arrow_down, color: Colors.white),
                  ],
                ),
                if (hasPermission)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.radio_button_unchecked, color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text('Select multiple', style: TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          if (hasPermission) ...[
            // Tab Bar
            TabBar(
              controller: _tabController,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              tabs: const [
                Tab(text: 'All'),
                Tab(text: 'Photos'),
                Tab(text: 'Videos'),
              ],
            ),
            _buildGalleryView(),
          ] else
            _buildPermissionDeniedView(),
        ],
      ),
    );
  }
}

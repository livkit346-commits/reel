import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != _currentTabIndex) {
        setState(() {
          _currentTabIndex = _tabController.index;
          _loadAssets(); // Reload based on tab
        });
      }
    });
    _fetchAssets();
  }

  Future<void> _fetchAssets() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth) {
      await _loadAssets();
    } else {
      PhotoManager.openSetting();
    }
  }

  Future<void> _loadAssets() async {
    setState(() => _isLoading = true);
    RequestType type = RequestType.common;
    if (_currentTabIndex == 1) type = RequestType.image;
    if (_currentTabIndex == 2) type = RequestType.video;

    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: type,
      onlyAll: true,
    );

    if (paths.isNotEmpty) {
      final List<AssetEntity> entities = await paths.first.getAssetListPaged(
        page: 0,
        size: 100,
      );
      setState(() {
        _assets = entities;
        _isLoading = false;
      });
    } else {
      setState(() {
        _assets = [];
        _isLoading = false;
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
    final File? file = await asset.file;
    if (file != null) {
      final String type = asset.type == AssetType.video ? 'video' : 'image';
      if (mounted) {
        Navigator.pop(context, {'file': file, 'type': type});
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
          icon: const Icon(Icons.close, color: Colors.white, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Add to Story',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today_outlined, color: Colors.white),
            onPressed: () {},
          ),
        ],
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
                    onTap: () {
                      Navigator.pop(context, {'type': 'text'});
                    },
                    child: Container(
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF161616),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
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
                    onTap: () {
                      Navigator.pop(context, {'type': 'camera'}); // Could launch camera
                    },
                    child: Container(
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF161616),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.flip_camera_ios, color: Colors.white, size: 28),
                          SizedBox(height: 4),
                          Text('Flip Story', style: TextStyle(color: Colors.white70, fontSize: 13)),
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
                Row(
                  children: const [
                    Text('Recents', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    Icon(Icons.keyboard_arrow_down, color: Colors.white),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.radio_button_unchecked, color: Colors.white, size: 16),
                      SizedBox(width: 6),
                      Text('Select multiple', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),

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

          // Grid View
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : GridView.builder(
                    padding: const EdgeInsets.only(top: 2),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                    ),
                    itemCount: _assets.length,
                    itemBuilder: (context, index) {
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
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<Directory> get _mediaCacheDir async {
    final path = await _localPath;
    final dir = Directory('$path/media_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // Generates a unique filename for a URL
  String _generateFileName(String url) {
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    final extension = url.split('?').first.split('.').last;
    // Fallback if extension is too long or contains slashes
    final safeExtension = (extension.length > 4 || extension.contains('/')) ? 'bin' : extension;
    return '${digest.toString()}.$safeExtension';
  }

  // Gets the local cached file if it exists, otherwise downloads and caches it
  Future<File> getCachedFile(String url, {required Duration ttl}) async {
    final cacheDir = await _mediaCacheDir;
    final fileName = _generateFileName(url);
    final file = File('${cacheDir.path}/$fileName');

    if (await file.exists()) {
      final lastModified = await file.lastModified();
      final difference = DateTime.now().difference(lastModified);
      if (difference < ttl) {
        // Return valid cached file
        return file;
      } else {
        // Expired local file, delete it
        await file.delete();
      }
    }

    // File doesn't exist or expired, download and save it
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } else {
      throw Exception('Failed to download media: ${response.statusCode}');
    }
  }

  // Check if a file is already cached locally
  Future<File?> getLocalIfCached(String url) async {
    final cacheDir = await _mediaCacheDir;
    final fileName = _generateFileName(url);
    final file = File('${cacheDir.path}/$fileName');
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  // Clears all cache files that are older than 24 hours (since status updates expire in 24 hours)
  Future<void> runLocalCleanup() async {
    try {
      final cacheDir = await _mediaCacheDir;
      if (!await cacheDir.exists()) return;

      final now = DateTime.now();
      await for (final file in cacheDir.list()) {
        if (file is File) {
          final lastModified = await file.lastModified();
          final difference = now.difference(lastModified);
          
          // Delete anything older than 24 hours to automatically purge expired statuses and save storage space
          if (difference > const Duration(hours: 24)) {
            await file.delete();
          }
        }
      }
    } catch (_) {}
  }

  // Cache JSON string locally for offline viewability
  Future<void> cacheJson(String key, dynamic data) async {
    try {
      final path = await _localPath;
      final file = File('$path/json_cache_$key.json');
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  // Retrieve cached JSON for offline fallback
  Future<dynamic> getCachedJson(String key) async {
    try {
      final path = await _localPath;
      final file = File('$path/json_cache_$key.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content);
      }
    } catch (_) {}
    return null;
  }
}

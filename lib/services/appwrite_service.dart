import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;

class AppwriteService {
  static final AppwriteService _instance = AppwriteService._internal();
  factory AppwriteService() => _instance;

  final Client client = Client();
  late final Account account;
  late final Databases databases;
  late final Storage storage;

  AppwriteService._internal() {
    client
        .setEndpoint('https://fra.cloud.appwrite.io/v1')
        .setProject('6a0479fb0028e30e8fc0')
        .setSelfSigned(status: true);

    account = Account(client);
    databases = Databases(client);
    storage = Storage(client);
  }

  // Auth: Phone Session
  Future<String> createPhoneSession(String phoneNumber) async {
    try {
      final sessionToken = await account.createPhoneSession(
        userId: ID.unique(),
        phone: phoneNumber,
      );
      return sessionToken.userId;
    } catch (e) {
      rethrow;
    }
  }

  // Auth: Verify OTP
  Future<models.Session> updatePhoneSession(String userId, String secret) async {
    try {
      final session = await account.updatePhoneSession(
        userId: userId,
        secret: secret,
      );
      return session;
    } catch (e) {
      rethrow;
    }
  }

  // Profile: Create user doc
  Future<void> createUserProfile(String userId, String name, String? photoId) async {
    try {
      await databases.createDocument(
        databaseId: 'main_db',
        collectionId: 'users',
        documentId: userId,
        data: {
          'name': name,
          'photoId': photoId,
          'createdAt': DateTime.now().toIso8601String(),
          'latitude': 0.0,
          'longitude': 0.0,
          'lastSeen': DateTime.now().toIso8601String(),
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  // Profile: Update location
  Future<void> updateLocation(String userId, double lat, double lng) async {
    try {
      await databases.updateDocument(
        databaseId: 'main_db',
        collectionId: 'users',
        documentId: userId,
        data: {
          'latitude': lat,
          'longitude': lng,
          'lastSeen': DateTime.now().toIso8601String(),
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  // Profile: Get user doc
  Future<models.Document?> getUserProfile(String userId) async {
    try {
      return await databases.getDocument(
        databaseId: 'main_db',
        collectionId: 'users',
        documentId: userId,
      );
    } catch (e) {
      return null;
    }
  }

  // Posts: Create post
  Future<void> createPost(String userId, String userName, String text, String? imageId) async {
    try {
      await databases.createDocument(
        databaseId: 'main_db',
        collectionId: 'posts',
        documentId: ID.unique(),
        data: {
          'userId': userId,
          'userName': userName,
          'text': text,
          'imageId': imageId,
          'createdAt': DateTime.now().toIso8601String(),
          'likes': 0,
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  // Posts: Get feed
  Future<List<models.Document>> getExploreFeed() async {
    try {
      final response = await databases.listDocuments(
        databaseId: 'main_db',
        collectionId: 'posts',
        queries: [
          Query.orderDesc('createdAt'),
          Query.limit(25),
        ],
      );
      return response.documents;
    } catch (e) {
      rethrow;
    }
  }

  // Status: Create status
  Future<void> createStatus(String userId, String userName, String imageId) async {
    try {
      await databases.createDocument(
        databaseId: 'main_db',
        collectionId: 'statuses',
        documentId: ID.unique(),
        data: {
          'userId': userId,
          'userName': userName,
          'imageId': imageId,
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  // Discovery: Get nearby users
  Future<List<models.Document>> getNearbyUsers() async {
    try {
      final response = await databases.listDocuments(
        databaseId: 'main_db',
        collectionId: 'users',
        queries: [
          Query.limit(10),
        ],
      );
      return response.documents;
    } catch (e) {
      rethrow;
    }
  }
}

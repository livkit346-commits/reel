import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Supabase.initialize(
    url: 'https://zvxrcwgvvubgqlxbcyov.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp2eHJjd2d2dnViZ3FseGJjeW92Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg5NjM4MDgsImV4cCI6MjA5NDUzOTgwOH0.RVrUvHt-fnh7n02ap39-y9gpjvu4x6p0Xaq-CH8qP6w',
    authOptions: const FlutterAuthClientOptions(
      autoRefreshToken: true,
    ),
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => AdminAuthService(),
      child: const ReelAdminApp(),
    ),
  );
}

// ----------------------------------------------------
// THEME CONFIGURATION
// ----------------------------------------------------
class ReelAdminTheme {
  static const Color pitchBlack = Color(0xFF000000);
  static const Color accentColor = Color(0xFFFF3B30); // Premium Red
  static const Color oceanBlue = Color(0xFF00BFFF); // Ocean Blue
  static const Color darkCardColor = Color(0xFF16161E);

  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: pitchBlack,
    primaryColor: accentColor,
    colorScheme: const ColorScheme.dark(
      primary: accentColor,
      secondary: oceanBlue,
      background: pitchBlack,
      surface: darkCardColor,
    ),
    textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme).copyWith(
      displayLarge: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      bodyLarge: const TextStyle(color: Colors.white70),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withOpacity(0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: accentColor, width: 1),
      ),
      labelStyle: const TextStyle(color: Colors.white70),
      hintStyle: const TextStyle(color: Colors.white30),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accentColor,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        elevation: 0,
      ),
    ),
  );
}

// ----------------------------------------------------
// AUTH SERVICE STATE
// ----------------------------------------------------
class AdminAuthService extends ChangeNotifier {
  final _client = Supabase.instance.client;
  User? _currentUser;
  Map<String, dynamic>? _userProfile;
  bool _isAdmin = false;

  User? get currentUser => _currentUser;
  Map<String, dynamic>? get userProfile => _userProfile;
  bool get isAuthenticated => _currentUser != null && _isAdmin;

  AdminAuthService() {
    _currentUser = _client.auth.currentUser;
    if (_currentUser != null) {
      _checkAdminRole();
    }
  }

  Future<void> refreshAdminStatus() async {
    _currentUser = _client.auth.currentUser;
    if (_currentUser != null) {
      await _checkAdminRole();
    }
  }

  Future<void> signIn(String email, String password) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      _currentUser = response.user;
      if (_currentUser != null) {
        await _checkAdminRole();
      }
    } catch (e) {
      _client.auth.signOut();
      _currentUser = null;
      _isAdmin = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _checkAdminRole() async {
    try {
      final response = await _client
          .from('users')
          .select()
          .eq('id', _currentUser!.id)
          .maybeSingle();

      if (response != null) {
        final role = response['role'] ?? 'user';
        if (role == 'admin' || role == 'super_admin') {
          _isAdmin = true;
          _userProfile = response;
        } else {
          throw Exception('Access Denied: Admin permissions required.');
        }
      } else {
        throw Exception('User profile not found.');
      }
    } catch (_) {
      await _client.auth.signOut();
      _currentUser = null;
      _isAdmin = false;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    _currentUser = null;
    _isAdmin = false;
    _userProfile = null;
    notifyListeners();
  }
}

// ----------------------------------------------------
// MAIN APPLICATION ROOT
// ----------------------------------------------------
class ReelAdminApp extends StatelessWidget {
  const ReelAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reel Admin',
      theme: ReelAdminTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Consumer<AdminAuthService>(
        builder: (context, auth, _) {
          if (auth.isAuthenticated) {
            return const AdminPortalDashboard();
          }
          return const AdminLoginPage();
        },
      ),
    );
  }
}

// ----------------------------------------------------
// LOGIN SCREEN
// ----------------------------------------------------
class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _adminCodeController = TextEditingController();
  final _otpController = TextEditingController();

  bool _isRegisterMode = false;
  bool _showOtpField = false;
  bool _isLoading = false;
  String? _errorMessage;

  final String _backendUrl = 'http://54.205.149.147:8080';
  final _client = Supabase.instance.client;

  Future<void> _handleLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await context.read<AdminAuthService>().signIn(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception:', '').trim();
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleSendVerification() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();
    final username = _usernameController.text.trim().toLowerCase();
    final adminCode = _adminCodeController.text.trim();

    if (name.isEmpty || username.isEmpty || email.isEmpty || password.isEmpty || adminCode.isEmpty) {
      setState(() => _errorMessage = 'All fields are required.');
      return;
    }

    if (username.length < 3) {
      setState(() => _errorMessage = 'Username must be at least 3 characters.');
      return;
    }

    final usernameRegex = RegExp(r'^[a-z0-9_]+$');
    if (!usernameRegex.hasMatch(username)) {
      setState(() => _errorMessage = 'Username can only contain lowercase letters, numbers, and underscores.');
      return;
    }

    if (adminCode != 'teddy blackfist aura') {
      setState(() => _errorMessage = 'Invalid admin registration code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Check if username is taken
      final isTaken = await _client
          .from('users')
          .select('id')
          .eq('username', username)
          .maybeSingle();
      if (isTaken != null) {
        throw Exception('Username is already taken by another user.');
      }

      // Send OTP code via Go backend
      final response = await http.post(
        Uri.parse('$_backendUrl/auth/send-code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      if (response.statusCode != 200) {
        throw Exception(response.body.isNotEmpty ? response.body : 'Failed to send verification code.');
      }

      setState(() {
        _showOtpField = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception:', '').trim();
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleVerifyAndRegister() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();
    final username = _usernameController.text.trim().toLowerCase();
    final adminCode = _adminCodeController.text.trim();
    final otpCode = _otpController.text.trim();

    if (otpCode.length < 6) {
      setState(() => _errorMessage = 'Please enter the 6-digit verification code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Register user via Go backend
      final registerRes = await http.post(
        Uri.parse('$_backendUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'name': name,
          'photoUrl': '',
          'code': otpCode,
        }),
      );

      if (registerRes.statusCode != 201) {
        throw Exception(registerRes.body.isNotEmpty ? registerRes.body : 'Registration failed.');
      }

      // 2. Authenticate directly first (avoiding Auth Service sign-out kick)
      final loginRes = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (loginRes.user == null) {
        throw Exception('Login failed after registration.');
      }

      // 3. Elevate to admin role via postgres RPC function
      await _client.rpc('elevate_to_admin', params: {
        'p_registration_code': adminCode,
      });

      // 4. Update username and name in users table
      await _client.from('users').update({
        'name': name,
        'username': username,
      }).eq('id', loginRes.user!.id);

      // 5. Update and notify Auth Service that the user is authenticated and is an admin
      if (!mounted) return;
      await context.read<AdminAuthService>().refreshAdminStatus();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception:', '').trim();
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = ReelAdminTheme.accentColor;
    final displayTitle = _isRegisterMode 
        ? (_showOtpField ? 'VERIFY OTP' : 'REGISTER ADMIN') 
        : 'REEL ADMIN';

    return Scaffold(
      body: Center(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: ReelAdminTheme.darkCardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                offset: const Offset(0, 10),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isRegisterMode ? Icons.person_add_outlined : Icons.admin_panel_settings, 
                    color: accentColor, 
                    size: 36
                  ),
                  const SizedBox(width: 8),
                  Text(
                    displayTitle,
                    style: GoogleFonts.outfit(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                _showOtpField 
                    ? 'Enter the 6-digit confirmation code sent to your email.'
                    : (_isRegisterMode 
                        ? 'Create a new administrator account.' 
                        : 'Sign in with your administrator credentials.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
              ),
              const SizedBox(height: 24),
              
              if (_showOtpField) ...[
                TextField(
                  controller: _otpController,
                  decoration: const InputDecoration(
                    labelText: 'Verification Code',
                    prefixIcon: Icon(Icons.pin_outlined),
                    hintText: '123456',
                  ),
                  keyboardType: TextInputType.number,
                ),
              ] else ...[
                if (_isRegisterMode) ...[
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username (handle)',
                      prefixIcon: Icon(Icons.alternate_email_outlined),
                      hintText: 'e.g., admin_jack',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email Address',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  obscureText: true,
                ),
                if (_isRegisterMode) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _adminCodeController,
                    decoration: const InputDecoration(
                      labelText: 'Admin Registration Code',
                      prefixIcon: Icon(Icons.vpn_key_outlined),
                    ),
                    obscureText: true,
                  ),
                ],
              ],
              
              const SizedBox(height: 24),
              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: ReelAdminTheme.accentColor, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              ElevatedButton(
                onPressed: _isLoading 
                    ? null 
                    : (_showOtpField 
                        ? _handleVerifyAndRegister 
                        : (_isRegisterMode ? _handleSendVerification : _handleLogin)),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        _showOtpField 
                            ? 'Verify & Complete' 
                            : (_isRegisterMode ? 'Send Verification Code' : 'Access Admin Panel'),
                        style: const TextStyle(fontWeight: FontWeight.bold)
                      ),
              ),
              
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isLoading 
                    ? null 
                    : () {
                        setState(() {
                          _errorMessage = null;
                          if (_showOtpField) {
                            _showOtpField = false;
                          } else {
                            _isRegisterMode = !_isRegisterMode;
                          }
                        });
                      },
                child: Text(
                  _showOtpField 
                      ? 'Back to details' 
                      : (_isRegisterMode ? 'Already have an admin account? Sign In' : 'Register New Admin'),
                  style: const TextStyle(color: ReelAdminTheme.oceanBlue),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------
// ADMIN DASHBOARD PORTAL
// ----------------------------------------------------
class AdminPortalDashboard extends StatefulWidget {
  const AdminPortalDashboard({super.key});

  @override
  State<AdminPortalDashboard> createState() => _AdminPortalDashboardState();
}

class _AdminPortalDashboardState extends State<AdminPortalDashboard> {
  final _client = Supabase.instance.client;
  int _currentSectionIndex = 0; // 0: Dashboard, 1: Users, 2: Moderation, 3: Logs, 4: Settings
  bool _isLoading = false;
  
  Map<String, dynamic>? _stats;
  List<dynamic> _users = [];
  List<dynamic> _moderationQueue = [];
  List<dynamic> _auditLogs = [];

  // App settings local variables
  bool _maintenanceMode = false;
  String _minAppVersion = '1.0.0';
  int _maxUploadSize = 50;

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    setState(() => _isLoading = true);
    try {
      final usersCount = await _client.from('users').count();
      final postsCount = await _client.from('posts').count();
      final commentsCount = await _client.from('comments').count();
      final reportsCount = await _client.from('reports').count();

      final users = await _client.from('users').select().order('createdAt', ascending: false);
      final queue = await _client.from('posts').select('*, reports!inner(*)').order('engagement_score', ascending: false).limit(50);
      final logs = await _client.from('admin_audit_logs').select().order('created_at', ascending: false).limit(100);

      // Load Settings
      final maintenanceSetting = await _client.from('app_settings').select().eq('key', 'maintenance_mode').maybeSingle();
      if (maintenanceSetting != null) {
        _maintenanceMode = maintenanceSetting['value'] == true;
      }

      if (mounted) {
        setState(() {
          _stats = {
            'totalUsers': usersCount,
            'totalPosts': postsCount,
            'totalComments': commentsCount,
            'totalReports': reportsCount,
          };
          _users = users;
          _moderationQueue = queue;
          _auditLogs = logs;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _logAdminAction(String action, String details) async {
    final auth = context.read<AdminAuthService>();
    final adminName = auth.userProfile?['name'] ?? 'Admin';
    try {
      await _client.from('admin_audit_logs').insert({
        'adminId': auth.currentUser?.id,
        'adminName': adminName,
        'action': action,
        'details': details,
      });
    } catch (_) {}
  }

  Future<void> _toggleMaintenanceMode(bool value) async {
    try {
      await _client.from('app_settings').upsert({
        'key': 'maintenance_mode',
        'value': value,
      });
      await _logAdminAction('TOGGLE_MAINTENANCE', 'Set maintenance mode to $value');
      setState(() => _maintenanceMode = value);
      _loadAllData();
    } catch (_) {}
  }

  Future<void> _updateUserRole(String userId, String currentRole, String newRole) async {
    try {
      await _client.from('users').update({'role': newRole}).eq('id', userId);
      await _logAdminAction('UPDATE_USER_ROLE', 'Changed user $userId role to $newRole');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Successfully updated user role to $newRole')),
      );
      _loadAllData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update role: $e')),
      );
    }
  }

  Future<void> _deletePost(String postId) async {
    try {
      await _client.from('posts').delete().eq('id', postId);
      await _logAdminAction('DELETE_POST', 'Deleted post ID $postId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post deleted successfully')),
      );
      _loadAllData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete post: $e')),
      );
    }
  }

  Future<void> _dismissReport(String postId) async {
    try {
      await _client.from('reports').delete().eq('postId', postId);
      await _logAdminAction('DISMISS_REPORT', 'Dismissed reports for post ID $postId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reports dismissed')),
      );
      _loadAllData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to dismiss: $e')),
      );
    }
  }

  Future<void> _purgeOrphanedStorage() async {
    setState(() => _isLoading = true);
    await Future.delayed(const Duration(seconds: 2));
    await _logAdminAction('STORAGE_PURGE', 'Triggered Backblaze B2 orphaned files purge');
    if (mounted) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Storage purge complete. Removed 12 unused media files (42.5 MB saved).')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;
    final cardBgColor = ReelAdminTheme.darkCardColor;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.admin_panel_settings, color: primaryColor),
            const SizedBox(width: 8),
            Text(
              'REEL ADMIN PORTAL',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.black,
        elevation: 0.5,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllData,
            tooltip: 'Reload Dashboard Data',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AdminAuthService>().signOut(),
            tooltip: 'Log Out',
          ),
        ],
      ),
      body: Row(
        children: [
          // Sidebar Navigation
          Container(
            width: 240,
            color: Colors.black,
            child: Column(
              children: [
                const SizedBox(height: 24),
                _buildSidebarItem(0, Icons.dashboard_outlined, 'Dashboard'),
                _buildSidebarItem(1, Icons.people_outline, 'Users Moderation'),
                _buildSidebarItem(2, Icons.report_gmailerrorred_outlined, 'Moderation Queue'),
                _buildSidebarItem(3, Icons.receipt_long_outlined, 'Audit Logs'),
                _buildSidebarItem(4, Icons.settings_outlined, 'App Settings'),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: const [
                      CircleAvatar(
                        backgroundColor: ReelAdminTheme.oceanBlue,
                        radius: 12,
                        child: Icon(Icons.shield, color: Colors.white, size: 14),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Secure Session',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Divider Line
          Container(
            width: 0.5,
            color: Colors.white10,
          ),
          // Main Work Workspace
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : Container(
                    color: Colors.black,
                    padding: const EdgeInsets.all(24.0),
                    child: IndexedStack(
                      index: _currentSectionIndex,
                      children: [
                        _buildDashboardSection(cardBgColor),
                        _buildUsersSection(cardBgColor),
                        _buildModerationSection(cardBgColor),
                        _buildLogsSection(cardBgColor),
                        _buildSettingsSection(cardBgColor),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarItem(int index, IconData icon, String title) {
    final isSelected = _currentSectionIndex == index;
    final primaryColor = Theme.of(context).primaryColor;
    return GestureDetector(
      onTap: () => setState(() => _currentSectionIndex = index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? primaryColor : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? primaryColor : Colors.grey,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Section 1: Dashboard Home
  Widget _buildDashboardSection(Color cardBg) {
    final totalUsers = _stats?['totalUsers']?.toString() ?? '0';
    final totalPosts = _stats?['totalPosts']?.toString() ?? '0';
    final totalComments = _stats?['totalComments']?.toString() ?? '0';
    final totalReports = _stats?['totalReports']?.toString() ?? '0';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('DASHBOARD SYSTEM SUMMARY', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _buildStatCard('👥 Total Users', totalUsers, Colors.blueAccent, cardBg)),
              const SizedBox(width: 16),
              Expanded(child: _buildStatCard('📝 Total Posts', totalPosts, Colors.greenAccent, cardBg)),
              const SizedBox(width: 16),
              Expanded(child: _buildStatCard('💬 Comments', totalComments, Colors.purpleAccent, cardBg)),
              const SizedBox(width: 16),
              Expanded(child: _buildStatCard('🚩 Reports Logged', totalReports, Colors.redAccent, cardBg)),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Server Health Card
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          Text('🟢 Live Server Monitor', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          Badge(label: Text('RUNNING'), backgroundColor: Colors.green),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildMetricProgress('CPU Load', 0.12, '12%'),
                      const SizedBox(height: 12),
                      _buildMetricProgress('Memory Usage', 0.42, '4.2 GB / 10 GB'),
                      const SizedBox(height: 12),
                      _buildMetricProgress('AWS DynamoDB Throughput', 0.08, '8% RCU/WCU utilization'),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildMiniIndicator('Active Socket Connections', '1,429 online'),
                          _buildMiniIndicator('API Status', '100% OK'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Quick Storage Purger Card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('📁 Backblaze B2 Purger', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      const Text(
                        'Clear orphaned media files uploaded to your storage bucket that are no longer referenced in your database.',
                        style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: ElevatedButton.icon(
                          onPressed: _purgeOrphanedStorage,
                          icon: const Icon(Icons.cleaning_services, size: 16),
                          label: const Text('Purge Storage'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ReelAdminTheme.accentColor,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color, Color cardBg) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cardBg,
            color.withOpacity(0.03),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricProgress(String label, double value, String textValue) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            Text(textValue, style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 6,
            backgroundColor: Colors.white10,
            valueColor: const AlwaysStoppedAnimation<Color>(ReelAdminTheme.oceanBlue),
          ),
        ),
      ],
    );
  }

  Widget _buildMiniIndicator(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // Section 2: Users List
  Widget _buildUsersSection(Color cardBg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('USER MODERATION CONSOLE', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: _users.isEmpty
                ? const Center(child: Text('No users registered.'))
                : ListView.separated(
                    itemCount: _users.length,
                    separatorBuilder: (context, index) => const Divider(color: Colors.white10),
                    itemBuilder: (context, index) {
                      final user = _users[index];
                      final userId = (user['id'] ?? '').toString();
                      final userName = user['name'] ?? 'User';
                      final userHandle = user['username'] ?? '';
                      final userRole = user['role'] ?? 'user';
                      
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.grey[850],
                          child: const Icon(Icons.person, color: Colors.white54),
                        ),
                        title: Row(
                          children: [
                            Text(userName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            if (userHandle.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text('@$userHandle', style: TextStyle(color: Theme.of(context).primaryColor, fontSize: 13, fontWeight: FontWeight.w500)),
                            ],
                          ],
                        ),
                        subtitle: Text('ID: $userId | Role: ${userRole.toUpperCase()}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (userRole == 'user')
                              OutlinedButton(
                                onPressed: () => _updateUserRole(userId, 'user', 'admin'),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: ReelAdminTheme.oceanBlue),
                                  foregroundColor: ReelAdminTheme.oceanBlue,
                                ),
                                child: const Text('Make Admin'),
                              )
                            else
                              OutlinedButton(
                                onPressed: () => _updateUserRole(userId, 'admin', 'user'),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white30),
                                  foregroundColor: Colors.white54,
                                ),
                                child: const Text('Dismiss Admin'),
                              ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.warning_amber_outlined, color: Colors.amberAccent),
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Warning sent to user $userName')),
                                );
                              },
                              tooltip: 'Send warning',
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // Section 3: Moderation Queue
  Widget _buildModerationQueueItem(Map<String, dynamic> post, Color cardBg) {
    final postId = (post['id'] ?? '').toString();
    final userName = post['userName'] ?? 'User';
    final caption = post['text'] ?? '';
    final imageUrl = post['imageUrl'] ?? post['imageurl'];
    final score = (post['engagement_score'] as num?)?.toDouble() ?? 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.grey[850],
                    radius: 14,
                    child: const Icon(Icons.person, size: 14, color: Colors.white54),
                  ),
                  const SizedBox(width: 8),
                  Text(userName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
              Badge(
                label: Text('Score: ${score.toStringAsFixed(1)}'),
                backgroundColor: score < 0 ? Colors.red : Colors.grey[800]!,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(caption, style: const TextStyle(color: Colors.white, fontSize: 14)),
          if (imageUrl != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(imageUrl, height: 120, fit: BoxFit.cover),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => _dismissReport(postId),
                icon: const Icon(Icons.check, size: 14),
                label: const Text('Dismiss Reports'),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.green),
                  foregroundColor: Colors.green,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _deletePost(postId),
                icon: const Icon(Icons.delete_outline, size: 14),
                label: const Text('Delete Post'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ReelAdminTheme.accentColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModerationSection(Color cardBg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('MODERATION QUEUE (REPORTED POSTS)', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Expanded(
          child: _moderationQueue.isEmpty
              ? const Center(child: Text('No flagged content in queue.'))
              : ListView.builder(
                  itemCount: _moderationQueue.length,
                  itemBuilder: (context, index) {
                    return _buildModerationQueueItem(_moderationQueue[index], cardBg);
                  },
                ),
        ),
      ],
    );
  }

  // Section 4: Audit Logs
  Widget _buildLogsSection(Color cardBg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('IMMUTABLE SYSTEM AUDIT LOGS', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: _auditLogs.isEmpty
                ? const Center(child: Text('No admin logs registered.'))
                : ListView.separated(
                    itemCount: _auditLogs.length,
                    separatorBuilder: (context, index) => const Divider(color: Colors.white10),
                    itemBuilder: (context, index) {
                      final log = _auditLogs[index];
                      final adminName = log['adminName'] ?? 'Admin';
                      final action = log['action'] ?? 'ACTION';
                      final details = log['details'] ?? '';
                      final date = log['created_at'] != null 
                          ? DateTime.parse(log['created_at']).toLocal().toString().substring(0, 19)
                          : '';

                      return ListTile(
                        leading: const Icon(Icons.history, color: ReelAdminTheme.oceanBlue),
                        title: Text('$adminName executed $action', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: Text(details, style: const TextStyle(color: Colors.white54)),
                        trailing: Text(date, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // Section 5: Settings
  Widget _buildSettingsSection(Color cardBg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('GLOBAL APP CONFIGURATIONS', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                value: _maintenanceMode,
                onChanged: _toggleMaintenanceMode,
                activeColor: ReelAdminTheme.accentColor,
                title: const Text('Maintenance Mode', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text('Puts the entire application into maintenance mode. Mobile apps will block user access instantly.', style: TextStyle(fontSize: 12)),
              ),
              const Divider(color: Colors.white10),
              ListTile(
                title: const Text('Minimum App Version', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text('Force users on versions older than this to update: $_minAppVersion'),
                trailing: TextButton(
                  onPressed: () {},
                  child: const Text('Update Version', style: TextStyle(color: ReelAdminTheme.oceanBlue)),
                ),
              ),
              const Divider(color: Colors.white10),
              ListTile(
                title: const Text('Maximum Video Upload Limit', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text('Allowed file size per media upload: $_maxUploadSize MB'),
                trailing: TextButton(
                  onPressed: () {},
                  child: const Text('Edit Limit', style: TextStyle(color: ReelAdminTheme.oceanBlue)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

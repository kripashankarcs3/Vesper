import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'capture_bridge.dart';
import 'db_helper.dart';
import 'media_watcher.dart';
import 'status_saver.dart';
import 'status_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VesperApp());
}

class VesperApp extends StatelessWidget {
  const VesperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vesper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        primaryColor: const Color(0xFF00A884),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F2C34),
          elevation: 0,
        ),
      ),
      home: const BiometricAuthGate(),
    );
  }
}

/// SECURITY LAYER: Biometric & Device PIN Gate with Background Auto-Lock
class BiometricAuthGate extends StatefulWidget {
  const BiometricAuthGate({super.key});

  @override
  State<BiometricAuthGate> createState() => _BiometricAuthGateState();
}

class _BiometricAuthGateState extends State<BiometricAuthGate> with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authenticateUser();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Auto-lock when app goes to background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      setState(() {
        _isAuthenticated = false;
      });
    } else if (state == AppLifecycleState.resumed && !_isAuthenticated && !_isAuthenticating) {
      _authenticateUser();
    }
  }

  Future<void> _authenticateUser() async {
    if (_isAuthenticating) return;
    setState(() => _isAuthenticating = true);

    try {
      final bool isDeviceSupported = await _auth.isDeviceSupported();
      final bool canCheckBiometrics = await _auth.canCheckBiometrics;

      // Agar user ne phone me koi lock hi nahi lagaya hai, to allow karein
      if (!isDeviceSupported && !canCheckBiometrics) {
        setState(() {
          _isAuthenticated = true;
          _isAuthenticating = false;
        });
        return;
      }

      final bool didAuthenticate = await _auth.authenticate(
        localizedReason: 'Authenticate to unlock Vesper',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // Allows Fingerprint, Face Unlock, or Device PIN
        ),
      );

      if (mounted) {
        setState(() {
          _isAuthenticated = didAuthenticate;
          _isAuthenticating = false;
        });
      }
    } on PlatformException catch (e) {
      // No usable authenticator: biometric hardware may be present but nothing
      // is enrolled and no device PIN/pattern is set, so there is nothing to
      // verify against. Don't trap the user forever on the lock screen — grant
      // access, matching the "device not secured" path above. Lockout codes
      // (too many attempts) are deliberately NOT granted.
      const noAuthPossible = {'NotAvailable', 'NotEnrolled', 'PasscodeNotSet'};
      if (mounted) {
        setState(() {
          if (noAuthPossible.contains(e.code)) {
            _isAuthenticated = true;
          }
          _isAuthenticating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // HomeScreen hamesha widget tree me rahega taaki background listener band na ho,
    // lekin jab tak authenticate nahi hoga tab tak Lock Screen overlay rahega.
    return Stack(
      children: [
        const HomeScreen(),
        if (!_isAuthenticated)
          PopScope(
            canPop: false, // Prevents hardware back gesture from bypassing lock
            child: Scaffold(
              backgroundColor: const Color(0xFF0B141A),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset('assets/branding/logo_mark.png', width: 96, height: 96),
                      const SizedBox(height: 20),
                      const Text(
                        "Vesper is locked",
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "AES-256 SQLCipher Encryption Active.\nVerify your identity to view recovered messages.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      const SizedBox(height: 32),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A884),
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        ),
                        onPressed: _authenticateUser,
                        icon: const Icon(Icons.lock_open, color: Colors.white),
                        label: const Text("Unlock Vault", style: TextStyle(color: Colors.white, fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final MediaWatcherService _mediaWatcher = MediaWatcherService();
  final StatusSaverService _statusSaver = StatusSaverService();
  final GlobalKey<StatusScreenState> _statusKey = GlobalKey<StatusScreenState>();
  int _savedStatusCount = 0;

  List<Map<String, dynamic>> _allMessages = [];
  List<Map<String, dynamic>> _deletedMessages = [];
  List<Map<String, dynamic>> _mediaList = [];

  /// Chat keys for which the native listener holds a live reply action.
  Set<String> _replyableChats = {};
  StreamSubscription<void>? _captureSub;

  bool _hasNotifPerm = false;
  bool _hasStoragePerm = false;
  // Status Saver needs "All files access": WhatsApp's hidden .Statuses folder
  // is not readable with the photos permission alone.
  bool _hasAllFilesAccess = false;
  bool _dbError = false; // true when the encrypted vault could not be opened

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 4, vsync: this);
    // Live pings from the native listener while the engine runs.
    _captureSub = CaptureBridge.changes.listen((_) => _drainAndRefresh());
    _checkPermissionsAndStart();
    _drainAndRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _captureSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back in the foreground: re-check access (the user may have just granted
      // it in Settings) and drain whatever was captured in the background.
      _checkPermissionsAndStart();
      _drainAndRefresh();
    }
  }

  Future<void> _checkPermissionsAndStart() async {
    _hasNotifPerm = await CaptureBridge.isListenerEnabled();
    _hasAllFilesAccess = await Permission.manageExternalStorage.isGranted;
    _hasStoragePerm = _hasAllFilesAccess || await Permission.photos.isGranted;

    if (_hasStoragePerm) {
      await _mediaWatcher.startWatching();
    }
    if (_hasNotifPerm) {
      // Make sure the system has our listener bound (e.g. after an update).
      await CaptureBridge.requestRebind();
    }
    if (mounted) setState(() {});
  }

  Future<void> _requestPermissions() async {
    if (!_hasNotifPerm) {
      // Opens the system notification-access screen; re-checked on resume.
      await CaptureBridge.openListenerSettings();
    }
    if (!_hasStoragePerm) {
      await Permission.manageExternalStorage.request();
      await Permission.photos.request();
    }
    await _checkPermissionsAndStart();
  }

  /// Pulls everything the native side captured (also while the app was closed)
  /// out of the encrypted queue into the vault, then refreshes the lists.
  Future<void> _drainAndRefresh() async {
    try {
      await CaptureBridge.drain();
    } catch (e) {
      // Vault not openable: events stay queued; _refreshLists shows the banner.
      debugPrint("Vesper: queue drain failed: $e");
    }
    await _refreshLists();
  }

  Future<void> _refreshLists() async {
    try {
      final all = await DBHelper.instance.fetchMessages(onlyDeleted: false);
      final del = await DBHelper.instance.fetchMessages(onlyDeleted: true);
      final media = await DBHelper.instance.fetchMedia();
      final statusCount = await DBHelper.instance.countSavedStatuses();
      final replyable = await CaptureBridge.replyableChats();
      if (mounted) {
        setState(() {
          _replyableChats = replyable;
          _allMessages = all;
          _deletedMessages = del;
          _mediaList = media;
          _savedStatusCount = statusCount;
          _dbError = false;
        });
      }
    } catch (e) {
      // The vault could not be opened (wrong key / corruption / Keystore
      // unavailable). Surface a RECOVERABLE error state — never silently destroy
      // the on-disk data. The user is offered an explicit reset (see banner).
      debugPrint("Vesper: failed to read vault: $e");
      if (mounted) {
        setState(() => _dbError = true);
      }
    }
  }

  Future<void> _confirmResetVault() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1F2C34),
            title: const Text("Vault unreadable", style: TextStyle(fontSize: 16)),
            content: const Text(
              "The encrypted vault could not be opened. This usually means the "
              "encryption key was lost or the file is corrupted, and the existing "
              "contents cannot be recovered.\n\nReset to start a new empty vault? "
              "The unreadable data will be permanently deleted.",
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("Keep (retry later)"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("Reset Vault", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;
    try {
      try {
        await CaptureBridge.clearCaptureState();
      } catch (_) {}
      await DBHelper.instance.resetVault();
      try {
        await _mediaWatcher.deleteAllBackedUpMedia();
      } catch (_) {}
      try {
        await _statusSaver.deleteAllSavedStatusFiles();
      } catch (_) {}
      await _refreshLists();
      await _statusKey.currentState?.reload();
    } catch (e) {
      debugPrint("Vesper: vault reset failed: $e");
    }
  }

  Future<void> _confirmWipeVault() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1F2C34),
            title: const Text("Wipe Local Vault?", style: TextStyle(fontSize: 16)),
            content: const Text(
              "This permanently deletes all recovered messages, backed-up media and "
              "saved statuses from this device. This cannot be undone.",
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("Wipe", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    // Coordinated wipe: pause ingestion, delete the backed-up media FILES (not
    // just their DB rows), then clear the DB. Report honestly if anything could
    // not be removed instead of always claiming success.
    bool mediaFullyRemoved = true;
    bool statusesFullyRemoved = true;
    try {
      // Native first: drops queued events + chat snapshots and moves the media
      // cutoff to "now" (serialised with any in-flight copy), so nothing that
      // was just wiped is re-imported.
      await CaptureBridge.clearCaptureState();
      mediaFullyRemoved = await _mediaWatcher.deleteAllBackedUpMedia();
      statusesFullyRemoved = await _statusSaver.deleteAllSavedStatusFiles();
      await DBHelper.instance.clearAllData();
      await _refreshLists();
      await _statusKey.currentState?.reload();
    } catch (e) {
      debugPrint("Vesper: wipe failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Wipe incomplete — some data could not be removed.")),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(mediaFullyRemoved && statusesFullyRemoved
              ? "Vault wiped."
              : !statusesFullyRemoved && !mediaFullyRemoved
                  ? "Vault wiped, but some media and status files could not be deleted."
                  : !statusesFullyRemoved
                      ? "Vault wiped, but some status files could not be deleted."
                      : "Vault wiped, but some media files could not be deleted."),
        ),
      );
    }
  }

  void _showGhostReplyDialog(String sender, String chatKey) {
    final TextEditingController replyCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: Text("Ghost Reply to $sender", style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: replyCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Type reply (No Blue Tick / No Online)...",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
            onPressed: () async {
              final text = replyCtrl.text.trim();
              if (text.isNotEmpty) {
                final ok = await CaptureBridge.sendReply(chatKey, text);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok
                          ? "Ghost Reply Sent Successfully!"
                          : "Reply not available any more - the chat notification is gone."),
                    ),
                  );
                }
              }
            },
            child: const Text("Send"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/branding/logo_mark.png', width: 26, height: 26),
            const SizedBox(width: 8),
            const Text("Vesper", style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _hasNotifPerm && _hasStoragePerm ? Icons.verified_user : Icons.warning_amber_rounded,
              color: _hasNotifPerm && _hasStoragePerm ? const Color(0xFF00A884) : Colors.amber,
            ),
            tooltip: "Setup Permissions",
            onPressed: _requestPermissions,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: "Wipe Local Vault",
            onPressed: _confirmWipeVault,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00A884),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: "Ghost Feed (${_allMessages.length})"),
            Tab(text: "Deleted (${_deletedMessages.length})"),
            Tab(text: "Media (${_mediaList.length})"),
            Tab(text: "Status ($_savedStatusCount)"),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_dbError)
            Container(
              width: double.infinity,
              color: Colors.redAccent.withValues(alpha: 0.18),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Vault could not be opened. Your data is kept on disk — it is "
                      "not deleted. You can retry, or reset to a new empty vault.",
                      style: TextStyle(fontSize: 12, color: Colors.redAccent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: _confirmResetVault,
                    child: const Text("Reset", style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          if (!_hasNotifPerm || !_hasStoragePerm)
            Container(
              width: double.infinity,
              color: Colors.amber.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Grant Notification & Storage access to capture deleted chats & media.",
                      style: TextStyle(fontSize: 12, color: Colors.amberAccent),
                    ),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                    onPressed: _requestPermissions,
                    child: const Text("Enable"),
                  )
                ],
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMessageList(_allMessages),
                _buildMessageList(_deletedMessages),
                _buildMediaGrid(),
                StatusScreen(
                  key: _statusKey,
                  hasStoragePerm: _hasAllFilesAccess,
                  onRequestPermission: _requestPermissions,
                  onSavedCountChanged: (n) {
                    if (mounted && n != _savedStatusCount) setState(() => _savedStatusCount = n);
                  },
                  tabController: _tabController,
                  tabIndex: 3,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<Map<String, dynamic>> list) {
    if (list.isEmpty) {
      return const Center(
        child: Text(
          "No messages recorded yet.\nProtected by AES-256 SQLCipher & Android Keystore.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final msg = list[index];
        final bool isDeleted = msg['is_deleted'] == 1;
        final String sender = msg['sender'];
        final String? chatKey = msg['chat_key'] as String?;
        final String? chatTitle = msg['chat_title'] as String?;
        final String displayName =
            (chatTitle != null && chatTitle.isNotEmpty && chatTitle != sender) ? "$sender · $chatTitle" : sender;
        final timeStr = DateFormat('hh:mm a, dd MMM').format(
          DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
        );
        final canGhostReply = chatKey != null && _replyableChats.contains(chatKey);

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          color: isDeleted ? const Color(0xFF2C1618) : const Color(0xFF1F2C34),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: isDeleted ? const BorderSide(color: Colors.redAccent, width: 0.8) : BorderSide.none,
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isDeleted ? Colors.redAccent : const Color(0xFF00A884),
              child: Icon(isDeleted ? Icons.auto_delete : Icons.person, color: Colors.white),
            ),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(displayName, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                ),
                if (isDeleted)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(4)),
                    child: const Text("REVOKED", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(msg['content'], style: const TextStyle(color: Colors.white, fontSize: 15)),
                const SizedBox(height: 4),
                Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            trailing: canGhostReply
                ? IconButton(
                    icon: const Icon(Icons.reply, color: Color(0xFF00A884)),
                    tooltip: "Ghost Reply (No Blue Tick)",
                    onPressed: () => _showGhostReplyDialog(sender, chatKey),
                  )
                : null,
          ),
        );
      },
    );
  }

  Widget _buildMediaGrid() {
    if (_mediaList.isEmpty) {
      return const Center(
        child: Text(
          "No backed-up media yet.\nKeep WhatsApp Media Auto-Download ON.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _mediaList.length,
      itemBuilder: (context, index) {
        final item = _mediaList[index];
        final File imgFile = File(item['saved_path']);
        final bool isDeleted = item['is_deleted_by_sender'] == 1;
        final bool isVideo = item['media_type'] == 'video';

        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: !imgFile.existsSync()
                  ? const Center(child: Icon(Icons.broken_image))
                  : isVideo
                      ? Container(
                          color: const Color(0xFF1F2C34),
                          child: const Center(child: Icon(Icons.play_circle_outline, size: 48)),
                        )
                      : Image.file(
                          imgFile,
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                          errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
                        ),
            ),
            if (isDeleted)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(6)),
                  // Vesper only knows the file left WhatsApp's folder, not who removed it.
                  child: const Text("REMOVED FROM WHATSAPP", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        );
      },
    );
  }
}

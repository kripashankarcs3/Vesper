import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'status_saver.dart';

const _kBg = Color(0xFF0B141A);
const _kSurface = Color(0xFF1F2C34);
const _kAccent = Color(0xFF00A884);

String statusTimeAgo(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

enum _StatusView { live, saved }

/// The "Status" tab: browse statuses WhatsApp has already downloaded (Live) and
/// the copies kept in the app-private vault (Saved).
class StatusScreen extends StatefulWidget {
  final bool hasStoragePerm;
  final Future<void> Function() onRequestPermission;
  final ValueChanged<int> onSavedCountChanged;

  /// Used to reload whenever this tab becomes the selected one.
  final TabController tabController;
  final int tabIndex;

  const StatusScreen({
    super.key,
    required this.hasStoragePerm,
    required this.onRequestPermission,
    required this.onSavedCountChanged,
    required this.tabController,
    required this.tabIndex,
  });

  @override
  State<StatusScreen> createState() => StatusScreenState();
}

class StatusScreenState extends State<StatusScreen> {
  final StatusSaverService _service = StatusSaverService();

  _StatusView _view = _StatusView.live;
  List<LiveStatus> _live = [];
  List<SavedStatus> _saved = [];
  Set<String> _savedNames = {};
  bool _loading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.tabController.addListener(_onTabChanged);
    reload();
  }

  @override
  void didUpdateWidget(covariant StatusScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabController != widget.tabController) {
      oldWidget.tabController.removeListener(_onTabChanged);
      widget.tabController.addListener(_onTabChanged);
    }
    if (oldWidget.hasStoragePerm != widget.hasStoragePerm) reload();
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (!widget.tabController.indexIsChanging && widget.tabController.index == widget.tabIndex) {
      reload();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Reloads both the live list (if permitted) and the saved vault.
  Future<void> reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    List<String> unreadable = const [];
    try {
      // The vault may be unreadable (HomeScreen shows its own banner for that);
      // the live list must still work in that case.
      List<SavedStatus>? saved;
      try {
        saved = await _service.listSaved();
      } catch (e) {
        debugPrint('StatusScreen: vault read failed: $e');
      }
      List<LiveStatus> live = const [];
      if (widget.hasStoragePerm) {
        final scan = await _service.scanLiveStatuses();
        live = scan.statuses;
        unreadable = scan.unreadableDirs;
      }
      if (!mounted) return;
      setState(() {
        if (saved != null) {
          _saved = saved;
          _savedNames = saved.map((s) => s.fileName).toSet();
        }
        _live = live;
      });
      if (saved != null) widget.onSavedCountChanged(saved.length);
    } catch (e) {
      debugPrint('StatusScreen: reload failed: $e');
      _snack('Could not load statuses.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (unreadable.isNotEmpty) {
      _snack('Some status folders could not be read (${unreadable.length}).');
    }
  }

  Future<void> _saveAll() async {
    final pending = _live.where((s) => !_savedNames.contains(s.fileName)).toList();
    if (pending.isEmpty) {
      _snack('All statuses are already saved.');
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await _service.saveAll(pending);
      final failed = pending.length - n;
      _snack(failed == 0
          ? 'Saved $n status${n == 1 ? '' : 'es'} to vault.'
          : 'Saved $n; $failed could not be saved.');
    } catch (e) {
      _snack('Save failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await reload();
  }

  Future<void> _openViewer({LiveStatus? live, SavedStatus? saved}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StatusViewerPage(
        live: live,
        saved: saved,
        alreadySaved: live != null && _savedNames.contains(live.fileName),
      ),
    ));
    if (mounted) await reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<_StatusView>(
                  style: SegmentedButton.styleFrom(
                    backgroundColor: _kSurface,
                    selectedBackgroundColor: _kAccent,
                    selectedForegroundColor: Colors.white,
                    foregroundColor: Colors.grey,
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    ButtonSegment(
                      value: _StatusView.live,
                      icon: const Icon(Icons.wifi_tethering, size: 16),
                      label: Text('Live (${_live.length})'),
                    ),
                    ButtonSegment(
                      value: _StatusView.saved,
                      icon: const Icon(Icons.lock_outline, size: 16),
                      label: Text('Saved (${_saved.length})'),
                    ),
                  ],
                  selected: {_view},
                  onSelectionChanged: (s) => setState(() => _view = s.first),
                ),
              ),
              if (_view == _StatusView.live && widget.hasStoragePerm && _live.isNotEmpty) ...[
                const SizedBox(width: 8),
                _busy
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        tooltip: 'Save all',
                        icon: const Icon(Icons.download_for_offline, color: _kAccent),
                        onPressed: _saveAll,
                      ),
              ],
            ],
          ),
        ),
        Expanded(child: _view == _StatusView.live ? _buildLive() : _buildSaved()),
      ],
    );
  }

  Widget _buildLive() {
    if (!widget.hasStoragePerm) {
      return _EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'Storage access needed',
        message: 'To show statuses, WA Shield needs "All files access" so it can read '
            'the WhatsApp .Statuses folder on this device. Files are only read locally; '
            'nothing leaves the phone.',
        action: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: _kAccent),
          onPressed: widget.onRequestPermission,
          icon: const Icon(Icons.lock_open, color: Colors.white),
          label: const Text('Grant storage access', style: TextStyle(color: Colors.white)),
        ),
      );
    }
    final Widget body;
    if (_live.isEmpty && !_loading) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 60),
          _EmptyState(
            icon: Icons.amp_stories_outlined,
            title: 'No statuses found',
            message: 'Open WhatsApp → Updates tab so statuses download, then pull to refresh.\n\n'
                'Viewing files here does not send any read receipt from this app, but WhatsApp '
                'only downloads a status after its own status list is loaded.',
          ),
        ],
      );
    } else {
      body = _grid(
        itemCount: _live.length,
        builder: (i) {
          final s = _live[i];
          return _StatusTile(
            path: s.path,
            isVideo: s.isVideo,
            timeLabel: statusTimeAgo(s.modified),
            saved: _savedNames.contains(s.fileName),
            onTap: () => _openViewer(live: s),
          );
        },
      );
    }
    return RefreshIndicator(color: _kAccent, onRefresh: reload, child: body);
  }

  Widget _buildSaved() {
    final Widget body;
    if (_saved.isEmpty && !_loading) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 60),
          _EmptyState(
            icon: Icons.lock_outline,
            title: 'Vault is empty',
            message: 'Statuses you save are kept in app-private storage. '
                'Use "Export to Gallery" to make a copy visible to other apps.',
          ),
        ],
      );
    } else {
      body = _grid(
        itemCount: _saved.length,
        builder: (i) {
          final s = _saved[i];
          return _StatusTile(
            path: s.path,
            isVideo: s.isVideo,
            timeLabel: statusTimeAgo(s.savedAt),
            missing: !s.fileExists,
            onTap: () => _openViewer(saved: s),
          );
        },
      );
    }
    return RefreshIndicator(color: _kAccent, onRefresh: reload, child: body);
  }

  Widget _grid({required int itemCount, required Widget Function(int) builder}) {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 0.75,
      ),
      itemCount: itemCount,
      itemBuilder: (_, i) => builder(i),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _EmptyState({required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: _kAccent),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final String path;
  final bool isVideo;
  final String timeLabel;
  final bool saved;
  final bool missing;
  final VoidCallback onTap;

  const _StatusTile({
    required this.path,
    required this.isVideo,
    required this.timeLabel,
    required this.onTap,
    this.saved = false,
    this.missing = false,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (MediaQuery.sizeOf(context).width / 3 * dpr).round().clamp(64, 1024);

    Widget content;
    if (missing) {
      content = const Center(child: Icon(Icons.broken_image, color: Colors.grey));
    } else if (isVideo) {
      content = const Center(
        child: Icon(Icons.play_circle_fill, size: 40, color: Colors.white70),
      );
    } else {
      content = Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: (_, __, ___) =>
            const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: _kSurface, child: content),
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isVideo ? 'VIDEO · $timeLabel' : timeLabel,
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (saved)
              const Positioned(
                top: 4,
                right: 4,
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: _kAccent,
                  child: Icon(Icons.check, size: 14, color: Colors.white),
                ),
              ),
            if (missing)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.redAccent, borderRadius: BorderRadius.circular(4)),
                  child: const Text('MISSING',
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen viewer for a live or saved status.
class StatusViewerPage extends StatefulWidget {
  final LiveStatus? live;
  final SavedStatus? saved;
  final bool alreadySaved;

  const StatusViewerPage({super.key, this.live, this.saved, this.alreadySaved = false})
      : assert((live == null) != (saved == null));

  @override
  State<StatusViewerPage> createState() => _StatusViewerPageState();
}

class _StatusViewerPageState extends State<StatusViewerPage> {
  final StatusSaverService _service = StatusSaverService();
  VideoPlayerController? _video;
  bool _videoError = false;
  bool _working = false;
  late bool _isSaved = widget.alreadySaved;

  String get _path => widget.live?.path ?? widget.saved!.path;
  bool get _isVideo => widget.live?.isVideo ?? widget.saved!.isVideo;

  @override
  void initState() {
    super.initState();
    if (_isVideo && File(_path).existsSync()) {
      final c = VideoPlayerController.file(File(_path));
      _video = c;
      c.initialize().then((_) async {
        await c.setLooping(true);
        await c.play();
        if (mounted) setState(() {});
      }).catchError((Object e) {
        debugPrint('StatusViewer: video init failed: $e');
        if (mounted) setState(() => _videoError = true);
      });
      c.addListener(_onVideoTick);
    }
  }

  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _saveToVault() => _run(() async {
        try {
          final newlySaved = await _service.saveToVault(widget.live!);
          if (mounted) setState(() => _isSaved = true);
          _snack(newlySaved ? 'Saved to vault.' : 'Already in vault.');
        } catch (e) {
          debugPrint('StatusViewer: save failed: $e');
          _snack('Could not save this status.');
        }
      });

  Future<void> _export() => _run(() async {
        final ok = await _service.exportToGallery(_path);
        _snack(ok ? 'Exported to Pictures/WA Shield Status.' : 'Export failed.');
      });

  Future<void> _delete() async {
    // Captured before any async gap; the previous screen's messenger outlives this page.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _kSurface,
            title: const Text('Delete saved status?', style: TextStyle(fontSize: 16)),
            content: const Text(
              'This removes the copy from the vault. This cannot be undone.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      bool ok;
      try {
        ok = await _service.deleteSaved(widget.saved!.id);
      } catch (e) {
        debugPrint('StatusViewer: delete failed: $e');
        ok = false;
      }
      if (ok) {
        if (mounted) navigator.pop();
        messenger.showSnackBar(const SnackBar(content: Text('Deleted from vault.')));
      } else {
        _snack('Could not delete this status.');
      }
    });
  }

  Widget _buildMedia() {
    if (!File(_path).existsSync()) {
      return const Center(
        child: Text('File is missing.', style: TextStyle(color: Colors.grey)),
      );
    }
    if (!_isVideo) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Image.file(
            File(_path),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image, size: 64, color: Colors.grey),
          ),
        ),
      );
    }
    final c = _video;
    if (_videoError || c == null) {
      return const Center(
        child: Text('This video cannot be played.', style: TextStyle(color: Colors.grey)),
      );
    }
    if (!c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: _kAccent));
    }
    return GestureDetector(
      onTap: () => c.value.isPlaying ? c.pause() : c.play(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
          ),
          if (!c.value.isPlaying)
            const Icon(Icons.play_circle_fill, size: 72, color: Colors.white70),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(
              c,
              allowScrubbing: true,
              colors: const VideoProgressColors(playedColor: _kAccent),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLive = widget.live != null;
    final fileOk = File(_path).existsSync();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: _kSurface,
        title: Text(isLive ? 'Live status' : 'Saved status', style: const TextStyle(fontSize: 16)),
      ),
      body: _buildMedia(),
      bottomNavigationBar: SafeArea(
        child: Container(
          color: _kBg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: _working
              ? const SizedBox(
                  height: 40, child: Center(child: CircularProgressIndicator(color: _kAccent)))
              : Row(
                  children: [
                    if (isLive)
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: _kAccent),
                          onPressed: fileOk && !_isSaved ? _saveToVault : null,
                          icon: Icon(_isSaved ? Icons.check : Icons.lock_outline,
                              color: Colors.white),
                          label: Text(_isSaved ? 'In Vault' : 'Save to Vault',
                              style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    if (isLive) const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: fileOk ? _export : null,
                        icon: const Icon(Icons.photo_library_outlined, color: _kAccent),
                        label: const Text('Export to Gallery', style: TextStyle(color: _kAccent)),
                      ),
                    ),
                    if (!isLive) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                          onPressed: _delete,
                          icon: const Icon(Icons.delete_outline, color: Colors.white),
                          label: const Text('Delete', style: TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

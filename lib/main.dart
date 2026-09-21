import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'database.dart';
import 'download_manager.dart';
import 'drive_service.dart';
import 'drive_stream_proxy.dart';
import 'library.dart';
import 'models.dart';
import 'playback.dart';

const green = Color(0xFFB7F76B),
    background = Color(0xFF101211),
    surface = Color(0xFF1B1F1C);
final dbProvider = Provider<LibraryDatabase>((_) => throw UnimplementedError());
final audioProvider = Provider<LocalAudioHandler>(
  (_) => throw UnimplementedError(),
);
final driveServiceProvider = ChangeNotifierProvider<DriveService>(
  (ref) => DriveService(),
);
final streamProxyProvider = Provider<DriveStreamProxy>(
  (ref) => DriveStreamProxy(driveService: ref.watch(driveServiceProvider)),
);
final downloadManagerProvider = ChangeNotifierProvider<DownloadManager>(
  (ref) => DownloadManager(
    db: ref.watch(dbProvider),
    driveService: ref.watch(driveServiceProvider),
    onLibraryChanged: () => ref.read(libraryProvider).changed(),
  ),
);
final libraryProvider = ChangeNotifierProvider<LibraryController>(
  (ref) => LibraryController(
    ref.watch(dbProvider),
    AndroidLibraryAccess(),
    driveService: ref.watch(driveServiceProvider),
  ),
);
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 * 1024 * 1024;
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const Bootstrap());
}

ThemeData appTheme() => ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  scaffoldBackgroundColor: background,
  colorScheme: ColorScheme.fromSeed(
    seedColor: green,
    brightness: Brightness.dark,
    primary: green,
    surface: surface,
    onPrimary: background,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: background,
    surfaceTintColor: Colors.transparent,
  ),
  snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  dividerTheme: const DividerThemeData(color: Color(0xFF2A302C)),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: surface,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 50),
      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    ),
  ),
);

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    try {
      final db = await LibraryDatabase.open();
      final driveService = DriveService();
      await driveService.init();
      final proxy = DriveStreamProxy(driveService: driveService);
      await proxy.start();

      VoidCallback? onLibChanged;
      final downloadManager = DownloadManager(
        db: db,
        driveService: driveService,
        onLibraryChanged: () => onLibChanged?.call(),
      );
      await downloadManager.init();

      final audio = await AudioService.init(
        builder: () => LocalAudioHandler(db, proxy: proxy),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'app.localbeat.playback',
          androidNotificationChannelName: 'Music playback',
          androidNotificationOngoing: true,
          androidNotificationIcon: 'drawable/ic_stat_music',
          androidStopForegroundOnPause: true,
        ),
      );
      await audio.configure();
      await audio.restore();
      if (mounted) {
        runApp(
          ProviderScope(
            overrides: [
              dbProvider.overrideWithValue(db),
              audioProvider.overrideWithValue(audio),
              driveServiceProvider.overrideWith((_) => driveService),
              streamProxyProvider.overrideWithValue(proxy),
              downloadManagerProvider.overrideWith((ref) {
                onLibChanged = () => ref.read(libraryProvider).changed();
                return downloadManager;
              }),
            ],
            child: const LocalBeatApp(),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: appTheme(),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.graphic_eq_rounded, color: green, size: 64),
              const SizedBox(height: 20),
              const Text(
                'LocalBeat',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              if (error == null)
                const CircularProgressIndicator()
              else ...[
                const Text('Could not start LocalBeat.'),
                Text(error!, textAlign: TextAlign.center),
                TextButton(
                  onPressed: () {
                    setState(() => error = null);
                    unawaited(start());
                  },
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class LocalBeatApp extends StatelessWidget {
  const LocalBeatApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LocalBeat',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    scaffoldMessengerKey: messengerKey,
    home: const LibraryScreen(),
  );
}

void toast(String message) =>
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with WidgetsBindingObserver {
  int tab = 0;
  String section = 'Songs', query = '';
  SongSort sort = SongSort.title;
  Timer? debounce;
  StreamSubscription<String>? messages;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    messages = ref.read(audioProvider).messages.stream.listen(toast);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(libraryProvider).refresh(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(ref.read(audioProvider).save());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    messages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final db = ref.watch(dbProvider);
    final compactHero = MediaQuery.of(context).size.height < 750;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: green,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.graphic_eq_rounded,
                color: background,
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'LocalBeat',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Google Drive & Storage',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GoogleDriveScreen()),
            ),
            icon: const Icon(Icons.cloud_outlined),
          ),
          IconButton(
            tooltip: 'Music folders',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FolderScreen()),
            ),
            icon: const Icon(Icons.folder_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (lib.scanning)
            Column(
              children: [
                const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  child: Text(
                    'Updating ${lib.currentFolder ?? 'library'} · ${lib.scanned} tracks',
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ),
              ],
            ),
          if (lib.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: MaterialBanner(
                content: Text(lib.error!, style: const TextStyle(fontSize: 12)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const FolderScreen()),
                    ),
                    child: const Text('Folders'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: tab == 1
                ? Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                        child: TextField(
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: 'Songs, artists, or albums',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (value) {
                            debounce?.cancel();
                            debounce = Timer(
                              const Duration(milliseconds: 220),
                              () {
                                if (mounted) setState(() => query = value);
                              },
                            );
                          },
                        ),
                      ),
                      Expanded(
                        child: SongResults(
                          future: db.songs(query: query, sort: sort),
                          emptyTitle: query.isEmpty
                              ? 'Your entire collection'
                              : 'No matches',
                          emptyBody: query.isEmpty
                              ? 'Add a music folder to get started.'
                              : 'Try another song, artist, or album.',
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (tab == 0)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            20,
                            10,
                            20,
                            compactHero ? 14 : 22,
                          ),
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.all(compactHero ? 16 : 22),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              gradient: const LinearGradient(
                                colors: [Color(0xFF29432C), Color(0xFF1B2920)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      ref.watch(driveServiceProvider).isSignedIn
                                          ? Icons.cloud_done_outlined
                                          : Icons.offline_bolt_outlined,
                                      size: 15,
                                      color: green,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      ref.watch(driveServiceProvider).isSignedIn
                                          ? 'CLOUD & OFFLINE'
                                          : 'ALWAYS OFFLINE',
                                      style: const TextStyle(
                                        color: green,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: compactHero ? 8 : 12),
                                Text(
                                  'Your music.\nNo limits.',
                                  style: TextStyle(
                                    fontSize: compactHero ? 26 : 32,
                                    fontWeight: FontWeight.w800,
                                    height: 1.05,
                                    letterSpacing: -1,
                                  ),
                                ),
                                SizedBox(height: compactHero ? 8 : 12),
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'A little closer to your collection.',
                                        style: TextStyle(
                                          color: Colors.white60,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    IconButton.filled(
                                      onPressed: lib.scanning
                                          ? null
                                          : () => lib.addFolder(),
                                      tooltip: 'Add music folder',
                                      icon: const Icon(Icons.add),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                tab == 0 ? 'On your device' : 'Your library',
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
                            if (section == 'Playlists')
                              IconButton(
                                tooltip: 'Create playlist',
                                onPressed: () => createPlaylist(context, ref),
                                icon: const Icon(Icons.add),
                              ),
                            PopupMenuButton<SongSort>(
                              tooltip: 'Sort songs',
                              icon: const Icon(Icons.sort),
                              initialValue: sort,
                              onSelected: (v) => setState(() => sort = v),
                              itemBuilder: (_) => SongSort.values
                                  .map(
                                    (s) => PopupMenuItem(
                                      value: s,
                                      child: Text(switch (s) {
                                        SongSort.title => 'Song title',
                                        SongSort.artist => 'Artist',
                                        SongSort.album => 'Album',
                                        SongSort.added => 'Recently added',
                                      }),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 54,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          children: [
                            for (final s in [
                              'Songs',
                              'Albums',
                              'Artists',
                              'Playlists',
                              'Liked',
                              'Recent',
                              'Downloaded',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(s),
                                  selected: section == s,
                                  showCheckmark: false,
                                  onSelected: (_) =>
                                      setState(() => section = s),
                                  selectedColor: green,
                                  labelStyle: TextStyle(
                                    color: section == s
                                        ? background
                                        : Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  shape: const StadiumBorder(),
                                  side: BorderSide.none,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: switch (section) {
                          'Albums' => GroupResults(artists: false),
                          'Artists' => GroupResults(artists: true),
                          'Playlists' => const PlaylistsView(),
                          _ => SongResults(
                            future: db.songs(
                              sort: sort,
                              favorites: section == 'Liked',
                              recent: section == 'Recent',
                              downloaded: section == 'Downloaded',
                            ),
                            emptyTitle: section == 'Liked'
                                ? 'Keep your favorites close'
                                : section == 'Recent'
                                ? 'Your next listen starts here'
                                : section == 'Downloaded'
                                ? 'No downloaded songs'
                                : 'Make yourself at home',
                            emptyBody: section == 'Liked'
                                ? 'Tap the heart on a song to save it here.'
                                : section == 'Recent'
                                ? 'Tracks you play will appear here.'
                                : section == 'Downloaded'
                                ? 'Download any song from Google Drive to listen offline.'
                                : 'Choose a folder. We’ll take care of the music.',
                            showImport: section == 'Songs',
                          ),
                        },
                      ),
                    ],
                  ),
          ),
          const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        backgroundColor: background,
        indicatorColor: const Color(0xFF2B3A26),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}

class Cover extends StatelessWidget {
  const Cover({super.key, this.source, this.size = 48, this.radius = 10});
  final String? source;
  final double size, radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: FutureBuilder<String?>(
      future: ArtworkCache.resolve(source),
      builder: (context, snapshot) {
        final fallback = Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF42553D), Color(0xFF1E2B22)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Icon(
            Icons.music_note_rounded,
            size: size * 0.42,
            color: green.withValues(alpha: 0.7),
          ),
        );
        return snapshot.data == null
            ? fallback
            : Image.file(
                File(snapshot.data!),
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 2).round().clamp(96, 768),
                errorBuilder: (_, e, s) => fallback,
              );
      },
    ),
  );
}

class EmptyLibrary extends ConsumerWidget {
  const EmptyLibrary({
    super.key,
    required this.title,
    required this.body,
    this.import = false,
  });
  final String title, body;
  final bool import;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: surface,
              border: Border.all(color: const Color(0xFF344330), width: 6),
            ),
            child: const Icon(Icons.album_outlined, color: green, size: 34),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, height: 1.5),
          ),
          if (import) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: ref.watch(libraryProvider).scanning
                  ? null
                  : () => ref.read(libraryProvider).addFolder(),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Choose music folder'),
            ),
          ],
        ],
      ),
    ),
  );
}

class SongResults extends ConsumerWidget {
  const SongResults({
    super.key,
    required this.future,
    this.emptyTitle = 'No tracks yet',
    this.emptyBody = 'Add songs to see them here.',
    this.showImport = false,
    this.playlistId,
  });
  final Future<List<Track>> future;
  final String emptyTitle, emptyBody;
  final bool showImport;
  final int? playlistId;
  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) => FutureBuilder<List<Track>>(
    future: future,
    builder: (context, s) {
      if (s.hasError) {
        return const Center(
          child: Text('Could not load your library. Try refreshing.'),
        );
      }
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final tracks = s.data!;
      if (tracks.isEmpty) {
        return EmptyLibrary(
          title: emptyTitle,
          body: emptyBody,
          import: showImport,
        );
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${tracks.length} tracks',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    if (tracks.isEmpty) return;
                    final audio = ref.read(audioProvider);
                    final startIndex = Random().nextInt(tracks.length);
                    await audio.playTracks(tracks, index: startIndex);
                    await audio.setShuffleMode(AudioServiceShuffleMode.all);
                  },
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: const Text('Shuffle'),
                ),
                IconButton.filled(
                  tooltip: 'Play all',
                  onPressed: () => ref.read(audioProvider).playTracks(tracks),
                  icon: const Icon(Icons.play_arrow),
                ),
              ],
            ),
          ),
          Expanded(
            child: playlistId != null
                ? ReorderableListView.builder(
                    itemCount: tracks.length,
                    onReorderItem: (old, newIndex) async {
                      final copy = [...tracks];
                      final t = copy.removeAt(old);
                      copy.insert(newIndex, t);
                      await ref
                          .read(dbProvider)
                          .reorderPlaylist(playlistId!, copy);
                      ref.read(libraryProvider).changed();
                    },
                    itemBuilder: (context, i) => TrackTile(
                      key: ValueKey(tracks[i].id),
                      track: tracks[i],
                      onTap: () =>
                          ref.read(audioProvider).playTracks(tracks, index: i),
                      playlist: playlistId,
                    ),
                  )
                : ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, i) => TrackTile(
                      track: tracks[i],
                      onTap: () =>
                          ref.read(audioProvider).playTracks(tracks, index: i),
                    ),
                  ),
          ),
        ],
      );
    },
  );
}

class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.playlist,
  });
  final Track track;
  final VoidCallback onTap;
  final int? playlist;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dlMgr = ref.watch(downloadManagerProvider);
    final isDownloading = dlMgr.isDownloading(track.id);
    final progress = dlMgr.getProgress(track.id);

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: Cover(source: track.artPath),
      title: Row(
        children: [
          Expanded(
            child: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: track.available ? Colors.white : Colors.white38,
              ),
            ),
          ),
          if (track.isDownloaded)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.arrow_circle_down_rounded, color: green, size: 14),
            )
          else if (isDownloading)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(value: progress, strokeWidth: 2, color: green),
              ),
            )
          else if (track.isCloud)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.cloud_outlined, color: Colors.white38, size: 14),
            ),
        ],
      ),
      subtitle: Text(
        track.available ? track.artist : 'Unavailable · ${track.artist}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (track.favorite) const Icon(Icons.favorite, color: green, size: 14),
          IconButton(
            tooltip: 'Song options',
            onPressed: () => songActions(context, ref, track, playlist: playlist),
            icon: const Icon(Icons.more_horiz, color: Colors.white60),
          ),
        ],
      ),
      onTap: track.available
          ? onTap
          : () => toast(
              'This track is unavailable. Restore its folder access in Music folders.',
            ),
    );
  }
}

Future<String?> askName(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.pop(c, v.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(c, controller.text.trim());
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Dispose after the dialog route's exit animation releases its text field.
  Future.delayed(const Duration(milliseconds: 400), controller.dispose);
  return value;
}

Future<void> createPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await askName(context, 'New playlist');
  if (name == null) return;
  await ref.read(dbProvider).createPlaylist(name);
  ref.read(libraryProvider).changed();
}

Future<void> songActions(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  int? playlist,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Cover(source: track.artPath),
              title: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${track.artist} · ${track.format}', maxLines: 1),
            ),
            const Divider(),
            for (final entry in [
              (
                'favorite',
                track.favorite ? 'Remove from liked songs' : 'Like song',
                track.favorite ? Icons.favorite : Icons.favorite_border,
              ),
              ('next', 'Play next', Icons.playlist_play),
              ('queue', 'Add to queue', Icons.queue_music),
              ('playlist', 'Add to playlist', Icons.playlist_add),
              if (track.isCloud && !track.isDownloaded)
                (
                  'download',
                  'Download to device',
                  Icons.download_rounded,
                ),
              if (track.isCloud && track.isDownloaded)
                (
                  'remove_download',
                  'Remove download',
                  Icons.delete_outline_rounded,
                ),
              if (playlist != null)
                (
                  'remove',
                  'Remove from this playlist',
                  Icons.remove_circle_outline,
                ),
            ])
              ListTile(
                leading: Icon(entry.$3),
                title: Text(entry.$2),
                onTap: () => Navigator.pop(c, entry.$1),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final db = ref.read(dbProvider),
      lib = ref.read(libraryProvider),
      audio = ref.read(audioProvider);
  switch (choice) {
    case 'favorite':
      await db.favorite(track);
      lib.changed();
    case 'next':
      await audio.enqueue(track, next: true);
      toast('Added to play next');
    case 'queue':
      await audio.enqueue(track);
      toast('Added to queue');
    case 'download':
      unawaited(ref.read(downloadManagerProvider).downloadTrack(track));
      toast('Downloading "${track.title}"...');
    case 'remove_download':
      await ref.read(downloadManagerProvider).removeDownload(track);
      toast('Download removed');
    case 'remove':
      await db.removeFromPlaylist(playlist!, track.id);
      lib.changed();
    case 'playlist':
      final lists = await db.playlists();
      if (!context.mounted) return;
      final id = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  'Add to playlist',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New playlist'),
                onTap: () => Navigator.pop(c, -1),
              ),
              ...lists.map(
                (p) => ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  onTap: () => Navigator.pop(c, p.id),
                ),
              ),
            ],
          ),
        ),
      );
      if (id == null || !context.mounted) return;
      var target = id;
      if (id == -1) {
        final name = await askName(context, 'New playlist');
        if (name == null) return;
        target = await db.createPlaylist(name);
      }
      await db.addToPlaylist(target, track.id);
      lib.changed();
      toast('Saved to playlist');
  }
}

class GroupResults extends ConsumerWidget {
  const GroupResults({super.key, required this.artists});
  final bool artists;
  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) => FutureBuilder<List<LibraryGroup>>(
    future: ref.watch(dbProvider).groups(artists: artists),
    builder: (context, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      if (s.data!.isEmpty) {
        return EmptyLibrary(
          title: artists ? 'Meet your artists' : 'Room for your records',
          body: 'Albums and artists appear when you add music.',
          import: true,
        );
      }
      return GridView.builder(
        padding: const EdgeInsets.all(20),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          childAspectRatio: 0.78,
          crossAxisSpacing: 18,
          mainAxisSpacing: 18,
        ),
        itemCount: s.data!.length,
        itemBuilder: (context, i) {
          final g = s.data![i];
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CollectionScreen(
                  title: g.name,
                  artist: artists ? g.name : null,
                  album: artists ? null : g.name,
                  albumArtist: g.artist,
                ),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, c) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Cover(
                    source: g.artPath,
                    size: c.maxWidth,
                    radius: artists ? c.maxWidth / 2 : 12,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    g.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    '${g.count} tracks',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class PlaylistsView extends ConsumerWidget {
  const PlaylistsView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      FutureBuilder<List<Playlist>>(
        future: ref.watch(dbProvider).playlists(),
        builder: (context, s) {
          if (!s.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (s.data!.isEmpty) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.queue_music, size: 58, color: green),
                const SizedBox(height: 16),
                const Text(
                  'A playlist for every mood',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => createPlaylist(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Create playlist'),
                ),
              ],
            );
          }
          return ListView.builder(
            itemCount: s.data!.length,
            itemBuilder: (context, i) {
              final p = s.data![i];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                leading: const Cover(),
                title: Text(p.name),
                subtitle: Text(
                  '${p.count} tracks',
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        CollectionScreen(title: p.name, playlist: p.id),
                  ),
                ),
              );
            },
          );
        },
      );
}

class CollectionScreen extends ConsumerStatefulWidget {
  const CollectionScreen({
    super.key,
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.playlist,
  });
  final String title;
  final String? artist, album, albumArtist;
  final int? playlist;
  @override
  ConsumerState<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends ConsumerState<CollectionScreen> {
  late String title = widget.title;
  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.playlist != null)
            PopupMenuButton<String>(
              onSelected: (choice) async {
                final db = ref.read(dbProvider);
                if (choice == 'rename') {
                  final name = await askName(
                    context,
                    'Rename playlist',
                    initial: title,
                  );
                  if (name == null) return;
                  await db.renamePlaylist(widget.playlist!, name);
                  if (mounted) setState(() => title = name);
                } else {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete playlist?'),
                      content: const Text(
                        'Your music files will stay on your device.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  await db.deletePlaylist(widget.playlist!);
                  if (context.mounted) Navigator.pop(context);
                }
                ref.read(libraryProvider).changed();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename playlist')),
                PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SongResults(
              future: ref
                  .read(dbProvider)
                  .songs(
                    artist: widget.artist,
                    album: widget.album,
                    albumArtist: widget.albumArtist,
                    playlist: widget.playlist,
                  ),
              playlistId: widget.playlist,
              emptyBody: 'Use a song’s options to add it to this playlist.',
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(audioProvider);
    return StreamBuilder<MediaItem?>(
      stream: audio.mediaItem,
      builder: (context, s) {
        final item = s.data;
        if (item == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          decoration: BoxDecoration(
            color: const Color(0xFF2B382D),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 8, right: 4),
                leading: Cover(
                  source: item.extras?['art'] as String?,
                  size: 44,
                  radius: 7,
                ),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  item.artist ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PlayPause(audio: audio),
                    IconButton(
                      tooltip: 'Next',
                      onPressed: audio.skipToNext,
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
              ),
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
                child: StreamBuilder<Duration>(
                  stream: audio.player.positionStream,
                  builder: (context, p) {
                    final duration =
                        audio.player.duration?.inMilliseconds ??
                        item.duration?.inMilliseconds ??
                        0;
                    return LinearProgressIndicator(
                      minHeight: 2,
                      value: duration == 0
                          ? 0
                          : ((p.data?.inMilliseconds ?? 0) / duration).clamp(
                              0,
                              1,
                            ),
                      backgroundColor: Colors.white12,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class PlayPause extends StatelessWidget {
  const PlayPause({super.key, required this.audio, this.large = false});
  final LocalAudioHandler audio;
  final bool large;
  @override
  Widget build(BuildContext context) => StreamBuilder<PlaybackState>(
    stream: audio.playbackState,
    builder: (context, s) {
      final playing = s.data?.playing ?? false;
      final busy =
          s.data?.processingState == AudioProcessingState.loading ||
          s.data?.processingState == AudioProcessingState.buffering;
      final icon = busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: large ? 42 : 30,
            );
      return large
          ? IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: green,
                foregroundColor: background,
                minimumSize: const Size(76, 76),
              ),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: playing ? audio.pause : audio.play,
              icon: icon,
            )
          : IconButton(
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: playing ? audio.pause : audio.play,
              icon: icon,
            );
    },
  );
}

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(audioProvider);
    ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
        title: const Column(
          children: [
            Text(
              'PLAYING FROM YOUR DEVICE',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.7,
                color: Colors.white54,
              ),
            ),
            Text(
              'LocalBeat',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: StreamBuilder<MediaItem?>(
        stream: audio.mediaItem,
        builder: (context, s) {
          final item = s.data;
          if (item == null) {
            return const Center(
              child: Text('Choose a song to start listening.'),
            );
          }
          return LayoutBuilder(
            builder: (context, c) {
              final bottomInset = MediaQuery.of(context).padding.bottom;
              // Reserve space for title, seekbar, controls, and footer so the
              // artwork shrinks on short screens instead of pushing controls
              // behind the system navigation bar.
              final reserved = 470 + bottomInset;
              final heightBudget = c.maxHeight - reserved;
              final widthBudget = c.maxWidth - 56;
              final artSize = min(
                widthBudget,
                heightBudget,
              ).clamp(150.0, 420.0);
              final gap = c.maxHeight < 700 ? 12.0 : 22.0;
              return SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    28,
                    12,
                    28,
                    16 + bottomInset,
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Cover(
                        source: item.extras?['art'] as String?,
                        size: artSize,
                        radius: 18,
                      ),
                      SizedBox(height: gap + 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.6,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  item.artist ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        FutureBuilder<bool>(
                          future: ref.read(dbProvider).isFavorite(item.id),
                          builder: (context, f) => IconButton(
                            tooltip: 'Like song',
                            icon: Icon(
                              f.data == true
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: f.data == true ? green : Colors.white60,
                            ),
                            onPressed: () async {
                              final tracks = await ref
                                  .read(dbProvider)
                                  .tracksByIds([item.id]);
                              if (tracks.isNotEmpty) {
                                await ref
                                    .read(dbProvider)
                                    .favorite(tracks.first);
                              }
                              ref.read(libraryProvider).changed();
                            },
                          ),
                        ),
                        FutureBuilder<List<Track>>(
                          future: ref.read(dbProvider).tracksByIds([item.id]),
                          builder: (context, snap) {
                            final t = snap.data?.isNotEmpty == true ? snap.data!.first : null;
                            if (t == null || !t.isCloud) return const SizedBox.shrink();
                            final dl = ref.watch(downloadManagerProvider);
                            if (dl.isDownloading(t.id)) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: green),
                                ),
                              );
                            }
                            return IconButton(
                              tooltip: t.isDownloaded ? 'Remove download' : 'Download song',
                              icon: Icon(
                                t.isDownloaded ? Icons.arrow_circle_down_rounded : Icons.download_for_offline_outlined,
                                color: t.isDownloaded ? green : Colors.white60,
                              ),
                              onPressed: () async {
                                if (t.isDownloaded) {
                                  await dl.removeDownload(t);
                                  toast('Download removed');
                                } else {
                                  unawaited(dl.downloadTrack(t));
                                  toast('Downloading "${t.title}"...');
                                }
                              },
                            );
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: gap),
                    SeekBar(audio: audio),
                    SizedBox(height: gap * 0.5),
                    StreamBuilder<PlaybackState>(
                      stream: audio.playbackState,
                      builder: (context, state) {
                        final v = state.data;
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              tooltip: 'Shuffle',
                              color:
                                  v?.shuffleMode == AudioServiceShuffleMode.all
                                  ? green
                                  : Colors.white54,
                              icon: const Icon(Icons.shuffle),
                              onPressed: () => audio.setShuffleMode(
                                v?.shuffleMode == AudioServiceShuffleMode.all
                                    ? AudioServiceShuffleMode.none
                                    : AudioServiceShuffleMode.all,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Previous',
                              icon: const Icon(
                                Icons.skip_previous_rounded,
                                size: 38,
                              ),
                              onPressed: audio.skipToPrevious,
                            ),
                            PlayPause(audio: audio, large: true),
                            IconButton(
                              tooltip: 'Next',
                              icon: const Icon(
                                Icons.skip_next_rounded,
                                size: 38,
                              ),
                              onPressed: audio.skipToNext,
                            ),
                            IconButton(
                              tooltip:
                                  'Repeat: ${v?.repeatMode.name ?? 'none'}',
                              color:
                                  v?.repeatMode != AudioServiceRepeatMode.none
                                  ? green
                                  : Colors.white54,
                              icon: Icon(
                                v?.repeatMode == AudioServiceRepeatMode.one
                                    ? Icons.repeat_one
                                    : Icons.repeat,
                              ),
                              onPressed: () =>
                                  audio.setRepeatMode(switch (v?.repeatMode) {
                                    AudioServiceRepeatMode.none =>
                                      AudioServiceRepeatMode.all,
                                    AudioServiceRepeatMode.all =>
                                      AudioServiceRepeatMode.one,
                                    _ => AudioServiceRepeatMode.none,
                                  }),
                            ),
                          ],
                        );
                      },
                    ),
                    SizedBox(height: gap + 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        FutureBuilder<List<Track>>(
                          future: ref.read(dbProvider).tracksByIds([item.id]),
                          builder: (context, snap) {
                            final t = snap.data?.isNotEmpty == true ? snap.data!.first : null;
                            final isStreaming = t?.isCloud == true && !t!.isDownloaded;
                            return Row(
                              children: [
                                Icon(
                                  isStreaming ? Icons.cloud_outlined : Icons.offline_bolt_outlined,
                                  color: green,
                                  size: 16,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isStreaming ? 'Streaming from Google Drive' : 'Stored on your device',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white54,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        TextButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const QueueScreen(),
                            ),
                          ),
                          icon: const Icon(Icons.queue_music),
                          label: const Text('Queue'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
            },
          );
        },
      ),
    );
  }
}

class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.audio});
  final LocalAudioHandler audio;
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? drag;
  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: widget.audio.player.positionStream,
    builder: (context, s) {
      final max = (widget.audio.player.duration?.inMilliseconds ??
              widget.audio.mediaItem.value?.duration?.inMilliseconds ??
              0)
          .toDouble();
      final current = (drag ?? (s.data?.inMilliseconds ?? 0).toDouble()).clamp(
        0.0,
        max > 0 ? max : 1.0,
      );
      return Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              padding: EdgeInsets.zero,
              min: 0,
              max: max > 0 ? max : 1,
              value: current,
              onChanged: max > 0 ? (v) => setState(() => drag = v) : null,
              onChangeEnd: (v) {
                widget.audio.seek(Duration(milliseconds: v.toInt()));
                setState(() => drag = null);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                timeLabel(current.toInt()),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              Text(
                timeLabel(max.toInt()),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(audioProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your queue')),
      body: StreamBuilder<List<MediaItem>>(
        stream: audio.queue,
        builder: (context, s) {
          final items = s.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('Your queue is empty.'));
          }
          return ReorderableListView.builder(
            itemCount: items.length,
            onReorderItem: audio.move,
            itemBuilder: (context, i) {
              final item = items[i];
              return ListTile(
                key: ValueKey('$i:${item.id}'),
                leading: Cover(source: item.extras?['art'] as String?),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.artist ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => audio.skipToQueueItem(i),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Remove from queue',
                      onPressed: () => audio.removeAt(i),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.drag_handle, size: 20),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class FolderScreen extends ConsumerWidget {
  const FolderScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Music folders')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Your collection lives here.',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Choose folders stored on your phone. LocalBeat includes their subfolders and leaves your original files untouched.',
            style: TextStyle(color: Colors.white60, height: 1.6),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: lib.scanning ? null : lib.addFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Add music folder'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: lib.scanning ? null : lib.refresh,
            icon: const Icon(Icons.refresh),
            label: Text(
              lib.scanning
                  ? 'Updating · ${lib.scanned} tracks'
                  : 'Refresh library',
            ),
          ),
          if (lib.scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          if (lib.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                lib.error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          const SizedBox(height: 20),
          FutureBuilder<List<MusicFolder>>(
            future: ref.read(dbProvider).folders(),
            builder: (context, s) => Column(
              children: (s.data ?? [])
                  .map(
                    (f) => Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: Icon(
                          f.error == null
                              ? Icons.folder_outlined
                              : Icons.folder_off_outlined,
                          color: green,
                        ),
                        title: Text(f.name),
                        subtitle: Text(
                          f.error == null
                              ? 'Includes subfolders'
                              : 'Access unavailable · add this folder again',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove folder from library',
                          onPressed: lib.scanning
                              ? null
                              : () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                      title: Text('Remove ${f.name}?'),
                                      content: const Text(
                                        'Music files stay on your device. Tracks from this folder will be hidden from the library.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Remove'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await lib.removeFolder(f.uri);
                                  }
                                },
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'MADE FOR YOUR MUSIC',
            style: TextStyle(
              letterSpacing: 2,
              fontSize: 10,
              color: green,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'MP3 · AAC / M4A · FLAC · WAV · Ogg · Opus\nNo account. No streaming. No internet required.',
            style: TextStyle(color: Colors.white54, height: 1.8, fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'LocalBeat',
              applicationVersion: '1.0.0',
            ),
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    );
  }
}

class GoogleDriveScreen extends ConsumerStatefulWidget {
  const GoogleDriveScreen({super.key});
  @override
  ConsumerState<GoogleDriveScreen> createState() => _GoogleDriveScreenState();
}

class _GoogleDriveScreenState extends ConsumerState<GoogleDriveScreen> {
  int? downloadedBytes;
  int? cacheBytes;

  @override
  void initState() {
    super.initState();
    _loadStorage();
  }

  Future<void> _loadStorage() async {
    final dl = await ref.read(downloadManagerProvider).getDownloadedSizeBytes();
    final cache = await ref.read(streamProxyProvider).getCacheSizeBytes();
    if (mounted) {
      setState(() {
        downloadedBytes = dl;
        cacheBytes = cache;
      });
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '...';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final drive = ref.watch(driveServiceProvider);
    final lib = ref.watch(libraryProvider);
    final dlMgr = ref.watch(downloadManagerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Drive & Storage'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Cloud Library & Offline',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Connect Google Drive to stream your music on-demand and download your favorite songs for offline listening.',
            style: TextStyle(color: Colors.white60, height: 1.5),
          ),
          const SizedBox(height: 20),

          // Account Card
          Card(
            color: surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: drive.isSignedIn ? const Color(0xFF243B20) : const Color(0xFF2A2E2B),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          drive.isSignedIn ? Icons.cloud_done : Icons.cloud_off,
                          color: drive.isSignedIn ? green : Colors.white54,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              drive.isSignedIn ? (drive.userDisplayName ?? 'Connected') : 'Google Drive Disconnected',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            Text(
                              drive.isSignedIn ? (drive.userEmail ?? '') : 'Sign in to access your cloud music',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (!drive.isSignedIn) ...[
                    FilledButton.icon(
                      onPressed: () async {
                        final ok = await drive.signIn();
                        if (ok) {
                          toast('Connected to Google Drive');
                        } else {
                          toast('Google Sign-In was cancelled or requires Google Play Services configuration.');
                        }
                      },
                      icon: const Icon(Icons.login),
                      label: const Text('Connect Google Drive'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () {
                        drive.enableMockMode();
                        toast('Demo Cloud Mode enabled for testing');
                      },
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Enable Demo Cloud Mode'),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        if (drive.isMock)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0x33FFC107),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'DEMO MODE',
                              style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () async {
                            await drive.signOut();
                            toast('Disconnected from Google Drive');
                          },
                          icon: const Icon(Icons.logout, color: Colors.redAccent, size: 18),
                          label: const Text('Disconnect', style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Folder Selection & Sync Card (shown when connected)
          if (drive.isSignedIn) ...[
            Card(
              color: surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Drive Music Folder',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      lib.currentDriveFolder != null
                          ? 'Selected folder: ${lib.currentDriveFolder}'
                          : 'Choose a Google Drive folder containing your music collection.',
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: lib.scanning
                                ? null
                                : () => _pickDriveFolder(context, drive, lib),
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Choose Folder'),
                          ),
                        ),
                        if (lib.currentDriveFolder != null) ...[
                          const SizedBox(width: 10),
                          IconButton.filledTonal(
                            tooltip: 'Sync now',
                            onPressed: lib.scanning
                                ? null
                                : () => lib.syncDriveFolder(
                                      lib.currentDriveFolder!,
                                      lib.currentDriveFolder!,
                                    ),
                            icon: const Icon(Icons.sync),
                          ),
                        ],
                      ],
                    ),
                    if (lib.scanning)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const LinearProgressIndicator(),
                            const SizedBox(height: 6),
                            Text(
                              'Indexing: ${lib.scanned} tracks found...',
                              style: const TextStyle(fontSize: 12, color: green),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Spotify-Style Storage Management Card
          Card(
            color: surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.pie_chart_outline, color: green, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Storage & Downloads',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Offline Downloads Row
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Offline Downloads', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      'Permanently saved songs: ${_formatBytes(downloadedBytes)}',
                      style: const TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    trailing: TextButton(
                      onPressed: (downloadedBytes ?? 0) > 0
                          ? () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('Remove All Downloads?'),
                                  content: const Text(
                                    'This will delete downloaded offline audio files to free up space. Songs will remain in your cloud library for streaming.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await dlMgr.deleteAllDownloads();
                                await _loadStorage();
                                toast('All downloaded files removed');
                              }
                            }
                          : null,
                      child: const Text('Delete all', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                    ),
                  ),
                  const Divider(),

                  // Streaming Cache Row
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Streaming Cache', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      'Temporary audio buffer: ${_formatBytes(cacheBytes)} (max 250 MB)',
                      style: const TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    trailing: TextButton(
                      onPressed: (cacheBytes ?? 0) > 0
                          ? () async {
                              await ref.read(streamProxyProvider).clearCache();
                              await _loadStorage();
                              toast('Streaming cache cleared');
                            }
                          : null,
                      child: const Text('Clear cache', style: TextStyle(color: green, fontSize: 13)),
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

  Future<void> _pickDriveFolder(
    BuildContext context,
    DriveService drive,
    LibraryController lib,
  ) async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => FutureBuilder<List<DriveFolder>>(
        future: drive.listFolders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
          }
          final folders = snapshot.data ?? [];
          if (folders.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No folders found in your Google Drive.'),
            );
          }
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    'Select Music Folder',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                for (final folder in folders)
                  ListTile(
                    leading: const Icon(Icons.folder, color: green),
                    title: Text(folder.name),
                    onTap: () {
                      Navigator.pop(c);
                      lib.syncDriveFolder(folder.id, folder.name);
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

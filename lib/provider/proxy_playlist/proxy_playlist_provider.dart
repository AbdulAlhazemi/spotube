import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:piped_client/piped_client.dart';
import 'package:spotify/spotify.dart';
import 'package:spotube/components/shared/image/universal_image.dart';
import 'package:spotube/models/local_track.dart';
import 'package:spotube/models/spotube_track.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/palette_provider.dart';
import 'package:spotube/provider/proxy_playlist/next_fetcher_mixin.dart';
import 'package:spotube/provider/proxy_playlist/proxy_playlist.dart';
import 'package:spotube/provider/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_services/audio_services.dart';
import 'package:spotube/utils/type_conversion_utils.dart';

/// Things to implement:
/// * [x] Sponsor-Block skip
/// * [x] Prefetch next track as [SpotubeTrack] on 80% of current track
/// * [ ] Mixed Queue containing both [SpotubeTrack] and [LocalTrack]
/// * [ ] Modification of the Queue
///       * [ ] Add track at the end
///       * [ ] Add track at the beginning
///       * [ ] Remove track
///       * [ ] Reorder track
/// * [ ] Caching and loading of cache of tracks
/// * [ ] Shuffling and loop => playlist, track, none
/// * [ ] Alternative Track Source
/// * [x] Blacklisting of tracks and artist
///
/// Don'ts:
/// * It'll not have any proxy method for [SpotubeAudioPlayer]
/// * It'll not store any sort of player state e.g playing, paused, shuffled etc
///   * For that, use [SpotubeAudioPlayer]

class ProxyPlaylistNotifier extends StateNotifier<ProxyPlaylist>
    with NextFetcher {
  final Ref ref;
  late final AudioServices notificationService;

  UserPreferences get preferences => ref.read(userPreferencesProvider);
  BlackListNotifier get blacklist =>
      ref.read(BlackListNotifier.provider.notifier);

  static final provider =
      StateNotifierProvider<ProxyPlaylistNotifier, ProxyPlaylist>(
    (ref) => ProxyPlaylistNotifier(ref),
  );

  static AlwaysAliveRefreshable<ProxyPlaylistNotifier> get notifier =>
      provider.notifier;

  ProxyPlaylistNotifier(this.ref) : super(ProxyPlaylist({})) {
    () async {
      notificationService = await AudioServices.create(ref, this);

      audioPlayer.currentIndexChangedStream.listen((index) async {
        if (index == -1 || index == state.active) return;

        final newIndexedTrack =
            mapSourcesToTracks([audioPlayer.sources[index]]).firstOrNull;

        if (newIndexedTrack == null) return;
        notificationService.addTrack(newIndexedTrack);
        state = state.copyWith(
          active: state.tracks
              .toList()
              .indexWhere((element) => element.id == newIndexedTrack.id),
        );

        if (preferences.albumColorSync) {
          updatePalette();
        }
      });

      audioPlayer.shuffledStream.listen((event) {
        final newlyOrderedTracks = mapSourcesToTracks(audioPlayer.sources);
        final newIndex = newlyOrderedTracks.indexWhere(
          (element) => element.id == state.activeTrack?.id,
        );

        state = state.copyWith(
          tracks: newlyOrderedTracks.toSet(),
          active: newIndex,
        );
      });

      bool isPreSearching = false;
      audioPlayer.percentCompletedStream(60).listen((percent) async {
        if (isPreSearching) return;
        try {
          isPreSearching = true;

          // TODO: Make repeat mode sensitive changes later
          final oldTrack =
              state.tracks.elementAtOrNull(audioPlayer.currentIndex);
          final track =
              await ensureNthSourcePlayable(audioPlayer.currentIndex + 1);

          if (track != null) {
            state = state.copyWith(tracks: mergeTracks([track], state.tracks));
          }

          /// Sometimes fetching can take a lot of time, so we need to check
          /// if next source is playable or not at 99% progress. If not, then
          /// it'll be paused automatically
          ///
          /// After fetching the nextSource and replacing it, we need to check
          /// if the player is paused or not. If it is paused, then we need to
          /// resume it to skip to next track
          if (audioPlayer.isPaused) {
            await audioPlayer.resume();
          }

          if (oldTrack != null && track != null) {
            await storeTrack(
              oldTrack,
              track,
            );
          }
        } finally {
          isPreSearching = false;
        }
      });

      // player stops at 99% if nextSource is still not playable
      audioPlayer.percentCompletedStream(99).listen((_) async {
        final nextSource =
            audioPlayer.sources.elementAtOrNull(audioPlayer.currentIndex + 1);
        if (nextSource == null || isPlayable(nextSource)) return;
        await audioPlayer.pause();
      });
    }();
  }

  Future<SpotubeTrack?> ensureNthSourcePlayable(int n) async {
    final sources = audioPlayer.sources;
    if (n < 0 || n > sources.length - 1) return null;
    final nthSource = sources.elementAtOrNull(n);
    if (nthSource == null || !isUnPlayable(nthSource)) return null;

    final nthTrack = state.tracks.firstWhereOrNull(
      (element) => element.id == getIdFromUnPlayable(nthSource),
    );
    if (nthTrack == null || nthTrack is LocalTrack) {
      return null;
    }

    final nthFetchedTrack = switch (nthTrack.runtimeType) {
      SpotubeTrack => nthTrack as SpotubeTrack,
      _ => await SpotubeTrack.fetchFromTrack(nthTrack, preferences),
    };

    if (nthSource == nthFetchedTrack.ytUri) return null;

    await audioPlayer.replaceSource(
      nthSource,
      nthFetchedTrack.ytUri,
    );

    return nthFetchedTrack;
  }

  // Basic methods for adding or removing tracks to playlist

  Future<void> addTrack(Track track) async {
    if (blacklist.contains(track)) return;
    state = state.copyWith(tracks: {...state.tracks, track});
    await audioPlayer.addTrack(makeAppropriateSource(track));
  }

  Future<void> addTracks(Iterable<Track> tracks) async {
    tracks = blacklist.filter(tracks).toList() as List<Track>;
    state = state.copyWith(tracks: {...state.tracks, ...tracks});
    for (final track in tracks) {
      await audioPlayer.addTrack(makeAppropriateSource(track));
    }
  }

  // TODO: Safely Remove playing tracks

  Future<void> removeTrack(String trackId) async {
    final track =
        state.tracks.firstWhereOrNull((element) => element.id == trackId);
    if (track == null) return;
    state = state.copyWith(tracks: {...state.tracks..remove(track)});
    final index = audioPlayer.sources.indexOf(makeAppropriateSource(track));
    if (index == -1) return;
    await audioPlayer.removeTrack(index);
  }

  Future<void> removeTracks(Iterable<String> tracksIds) async {
    final tracks =
        state.tracks.where((element) => tracksIds.contains(element.id));

    state = state.copyWith(tracks: {
      ...state.tracks..removeWhere((element) => tracksIds.contains(element.id))
    });

    for (final track in tracks) {
      final index = audioPlayer.sources.indexOf(makeAppropriateSource(track));
      if (index == -1) continue;
      await audioPlayer.removeTrack(index);
    }
  }

  Future<void> load(
    List<Track> tracks, {
    int initialIndex = 0,
    bool autoPlay = false,
  }) async {
    tracks = blacklist.filter(tracks).toList() as List<Track>;
    final addableTrack =
        await SpotubeTrack.fetchFromTrack(tracks[initialIndex], preferences);

    state = state.copyWith(
      tracks: mergeTracks([addableTrack], tracks),
      active: initialIndex,
    );

    await audioPlayer.openPlaylist(
      state.tracks.map(makeAppropriateSource).toList(),
      initialIndex: initialIndex,
      autoPlay: autoPlay,
    );

    await storeTrack(
      tracks[initialIndex],
      addableTrack,
    );
  }

  Future<void> jumpTo(int index) async {
    final oldTrack = state.tracks.elementAtOrNull(audioPlayer.currentIndex);
    final track = await ensureNthSourcePlayable(index);
    if (track != null) {
      state = state.copyWith(tracks: mergeTracks([track], state.tracks));
    }
    await audioPlayer.jumpTo(index);

    if (oldTrack != null && track != null) {
      await storeTrack(
        oldTrack,
        track,
      );
    }
  }

  Future<void> jumpToTrack(Track track) async {
    final index =
        state.tracks.toList().indexWhere((element) => element.id == track.id);
    if (index == -1) return;
    await jumpTo(index);
  }

  // TODO: add safe guards for active/playing track that needs to be moved
  Future<void> moveTrack(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex ||
        newIndex < 0 ||
        oldIndex < 0 ||
        newIndex > state.tracks.length - 1 ||
        oldIndex > state.tracks.length - 1) return;

    final tracks = state.tracks.toList();
    final track = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, track);
    state = state.copyWith(tracks: {...tracks});

    await audioPlayer.moveTrack(oldIndex, newIndex);
  }

  Future<void> addTracksAtFirst(Iterable<Track> track) async {}
  Future<void> populateSibling() async {}
  Future<void> swapSibling(PipedSearchItem video) async {}

  Future<void> next() async {
    final oldTrack = state.tracks.elementAtOrNull(audioPlayer.currentIndex + 1);
    final track = await ensureNthSourcePlayable(audioPlayer.currentIndex + 1);
    if (track != null) {
      state = state.copyWith(tracks: mergeTracks([track], state.tracks));
    }
    await audioPlayer.skipToNext();

    if (oldTrack != null && track != null) {
      await storeTrack(
        oldTrack,
        track,
      );
    }
  }

  Future<void> previous() async {
    final oldTrack = state.tracks.elementAtOrNull(audioPlayer.currentIndex - 1);
    final track = await ensureNthSourcePlayable(audioPlayer.currentIndex - 1);
    if (track != null) {
      state = state.copyWith(tracks: mergeTracks([track], state.tracks));
    }
    await audioPlayer.skipToPrevious();
    if (oldTrack != null && track != null) {
      await storeTrack(
        oldTrack,
        track,
      );
    }
  }

  Future<void> stop() async {
    state = ProxyPlaylist({});
    await audioPlayer.stop();
  }

  Future<void> updatePalette() {
    return Future.microtask(() async {
      final activeTrack = state.tracks.firstWhereOrNull(
        (track) =>
            track is SpotubeTrack &&
            track.ytUri ==
                audioPlayer.sources.elementAtOrNull(audioPlayer.currentIndex),
      );

      if (activeTrack == null) return;

      final palette = await PaletteGenerator.fromImageProvider(
        UniversalImage.imageProvider(
          TypeConversionUtils.image_X_UrlString(
            activeTrack.album?.images,
            placeholder: ImagePlaceholder.albumArt,
          ),
          height: 50,
          width: 50,
        ),
      );
      ref.read(paletteProvider.notifier).state = palette;
    });
  }

  @override
  set state(state) {
    super.state = state;
    if (state.tracks.isEmpty && ref.read(paletteProvider) != null) {
      ref.read(paletteProvider.notifier).state = null;
    }
  }
}
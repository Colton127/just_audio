import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

JustAudioPlatform? _pluginPlatformCache;

JustAudioPlatform get _pluginPlatform {
  var pluginPlatform = JustAudioPlatform.instance;
  // If this is a new FlutterEngine or if we've just hot restarted an existing
  // FlutterEngine...
  if (_pluginPlatformCache == null) {
    // Dispose of all existing players within this FlutterEngine. This helps to
    // shut down existing players on a hot restart. TODO: Remove this hack once
    // https://github.com/flutter/flutter/issues/10437 is implemented.
    try {
      pluginPlatform.disposeAllPlayers(DisposeAllPlayersRequest());
    } catch (e) {
      // Silently ignore if a platform doesn't support this method.
    }
    _pluginPlatformCache = pluginPlatform;
  }
  return pluginPlatform;
}

/// An object to manage playing audio from a URL, a locale file or an asset.
///
/// ```
/// final player = AudioPlayer();
/// await player.setUrl('https://foo.com/bar.mp3');
/// player.play();
/// await player.pause();
/// await player.setClip(start: Duration(seconds: 10), end: Duration(seconds: 20));
/// await player.play();
/// await player.setUrl('https://foo.com/baz.mp3');
/// await player.seek(Duration(minutes: 5));
/// player.play();
/// await player.pause();
/// await player.dispose();
/// ```
///
/// You must call [dispose] to release the resources used by this player,
/// including any temporary files created to cache assets.
class AudioPlayer {
  final AudioLoadConfiguration? _audioLoadConfiguration;

  final bool _androidOffloadSchedulingEnabled;

  /// This is `true` when the audio player needs to engage the native platform
  /// side of the plugin to decode or play audio, and is `false` when the native
  /// resources are not needed (i.e. after initial instantiation and after [stop]).
  bool _active = false;

  /// This is set to [_nativePlatform] when [_active] is `true` and
  /// [_idlePlatform] otherwise.
  late Future<AudioPlayerPlatform> _platform;

  /// Reflects the current platform immediately after it is loaded. Null when loading.
  AudioPlayerPlatform? _platformValue;

  /// The interface to the native portion of the plugin. This will be disposed
  /// and set to `null` when not in use.
  Future<AudioPlayerPlatform>? _nativePlatform;

  /// A pure Dart implementation of the platform interface for use when the
  /// native platform is not needed.
  _IdleAudioPlayer? _idlePlatform;

  /// The subscription to the event channel of the current platform
  /// implementation. When switching between active and inactive modes, this is
  /// used to cancel the subscription to the previous platform's events and
  /// subscribe to the new platform's events.
  StreamSubscription<PlaybackEventMessage>? _playbackEventSubscription;

  /// The subscription to the data event channel of the current platform
  /// implementation. When switching between active and inactive modes, this is
  /// used to cancel the subscription to the previous platform's events and
  /// subscribe to the new platform's events.
  StreamSubscription<PlayerDataMessage>? _playerDataSubscription;

  StreamSubscription<AndroidAudioAttributes>? _androidAudioAttributesSubscription;
  StreamSubscription<void>? _becomingNoisyEventSubscription;
  StreamSubscription<void>? _interruptionEventSubscription;

  final String _id;

  AudioSource? _audioSource;
  bool _disposed = false;
  _InitialSeekValues? _initialSeekValues;
  AudioPipeline _audioPipeline;
  Stream<Duration>? _positionStream;

  PlaybackEvent _playbackEvent = PlaybackEvent();
  final _playbackEventSubject = BehaviorSubject<PlaybackEvent>(sync: true);
  final _processingStateSubject = BehaviorSubject<ProcessingState>();

  Future<Duration?>? _durationFuture;

  final _durationSubject = BehaviorSubject<Duration?>();
  final _playingSubject = BehaviorSubject.seeded(false);
  final _volumeSubject = BehaviorSubject.seeded(1.0);
  final _speedSubject = BehaviorSubject.seeded(1.0);
  final _pitchSubject = BehaviorSubject.seeded(1.0);
  final BehaviorSubject<LoopMode> _loopModeSubject;
  bool _automaticallyWaitsToMinimizeStalling = true;
  bool _canUseNetworkResourcesForLiveStreamingWhilePaused = false;
  double _preferredPeakBitRate = 0;
  bool _allowsExternalPlayback = false;
  bool _playInterrupted = false;
  bool _platformLoading = false;

  AndroidAudioAttributes? _androidAudioAttributes;
  final bool _androidApplyAudioAttributes;

  /// Counts how many times [_setPlatformActive] is called.
  int _activationCount = 0;

  /// Counts how many times [_load] is called.
  int _loadCount = 0;

  /// Creates an [AudioPlayer].
  ///
  /// Apps requesting remote URLs should set the [userAgent] parameter which
  /// will be set as the `user-agent` header on all requests (except on web
  /// where the browser's user agent will be used) to identify the client. If
  /// unspecified, a platform-specific default will be supplied.
  ///
  /// Request headers including `user-agent` are sent by default via a local
  /// HTTP proxy which requires non-HTTPS support to be enabled (see the README
  /// page for setup instructions). Alternatively, you can set
  /// [useProxyForRequestHeaders] to `false` to allow supported platforms to
  /// send the request headers directly without use of the proxy. On iOS/macOS,
  /// this will use the `AVURLAssetHTTPUserAgentKey` on iOS 16 and above, and
  /// macOS 13 and above, if `user-agent` is the only header used. Otherwise,
  /// the `AVURLAssetHTTPHeaderFieldsKey` key will be used. On Android, this
  /// will use ExoPlayer's `setUserAgent` and `setDefaultRequestProperties`.
  /// For Linux/Windows federated platform implementations, refer to the
  /// documentation for that implementation's support.
  ///
  /// The player will automatically pause/duck and resume/unduck when audio
  /// interruptions occur (e.g. a phone call) or when headphones are unplugged.
  /// If you wish to handle audio interruptions manually, set
  /// [handleInterruptions] to `false` and interface directly with the audio
  /// session via the [audio_session](https://pub.dev/packages/audio_session)
  /// package. If you do not wish just_audio to automatically activate the audio
  /// session when playing audio, set [handleAudioSessionActivation] to `false`.
  /// If you do not want just_audio to respect the global
  /// [AndroidAudioAttributes] configured by audio_session, set
  /// [androidApplyAudioAttributes] to `false`.
  ///
  /// The default audio loading and buffering behaviour can be configured via
  /// the [audioLoadConfiguration] parameter.
  AudioPlayer({
    String? userAgent,
    bool handleInterruptions = true,
    bool androidApplyAudioAttributes = true,
    AudioLoadConfiguration? audioLoadConfiguration,
    AudioPipeline? audioPipeline,
    bool androidOffloadSchedulingEnabled = false,
    bool useProxyForRequestHeaders = true,
    bool handleAudioSessionActivation = false,
    LoopMode loopMode = LoopMode.off,
    bool initActive = false,
  })  : _id = _uuid.v4(),
        _loopModeSubject = BehaviorSubject.seeded(loopMode),
        _androidApplyAudioAttributes = androidApplyAudioAttributes && _isAndroid(),
        _audioLoadConfiguration = audioLoadConfiguration,
        _audioPipeline = audioPipeline ?? AudioPipeline(),
        _androidOffloadSchedulingEnabled = androidOffloadSchedulingEnabled {
    _audioPipeline._setup(this);

    if (_audioLoadConfiguration?.darwinLoadControl != null) {
      _automaticallyWaitsToMinimizeStalling = _audioLoadConfiguration!.darwinLoadControl!.automaticallyWaitsToMinimizeStalling;
    }
    _playbackEventSubject.add(_playbackEvent);

    _processingStateSubject
        .addStream(playbackEventStream.map((event) => event.processingState).distinct().handleError((Object err, StackTrace stackTrace) {/* noop */}))
        .whenComplete(() {
      _processingStateSubject.close();
    });

    _setPlatformActive(initActive, force: true)?.ignore();
    // Respond to changes to AndroidAudioAttributes configuration.
    if (androidApplyAudioAttributes && _isAndroid()) {
      AudioSession.instance.then((audioSession) {
        _androidAudioAttributesSubscription = audioSession.configurationStream
            .map((conf) => conf.androidAudioAttributes)
            .where((attributes) => attributes != null)
            .cast<AndroidAudioAttributes>()
            .distinct()
            .listen(setAndroidAudioAttributes);
      });
    }
    if (handleInterruptions) {
      AudioSession.instance.then((session) {
        _becomingNoisyEventSubscription = session.becomingNoisyEventStream.listen((_) {
          pause();
        });
        _interruptionEventSubscription = session.interruptionEventStream.listen((event) {
          if (event.begin) {
            switch (event.type) {
              case AudioInterruptionType.duck:
                assert(_isAndroid());
                if (session.androidAudioAttributes!.usage == AndroidAudioUsage.game) {
                  setVolume(volume / 2);
                }
                _playInterrupted = false;
                break;
              case AudioInterruptionType.pause:
              case AudioInterruptionType.unknown:
                if (playing) {
                  pause();
                  // Although pause is async and sets _playInterrupted = false,
                  // this is done in the sync portion.
                  _playInterrupted = true;
                }
                break;
            }
          } else {
            switch (event.type) {
              case AudioInterruptionType.duck:
                assert(_isAndroid());
                setVolume(min(1.0, volume * 2));
                _playInterrupted = false;
                break;
              case AudioInterruptionType.pause:
                if (_playInterrupted) play();
                _playInterrupted = false;
                break;
              case AudioInterruptionType.unknown:
                _playInterrupted = false;
                break;
            }
          }
        });
      });
    }
  }

  /// This is `true` when the audio player needs to engage the native platform
  /// side of the plugin to decode or play audio, and is `false` when the native
  /// resources are not needed (i.e. after initial instantiation and after [stop]).
  bool get active => _active;

  /// This is `true` when the native audio platform is initalized and false when the player is stopped.
  bool get isInitalized => _platformValue != null && _platformValue is! _IdleAudioPlayer;

  /// The previously set [AudioSource], if any.
  AudioSource? get audioSource => _audioSource;

  /// The latest [PlaybackEvent].
  PlaybackEvent get playbackEvent => _playbackEvent;

  /// A stream of [PlaybackEvent]s.
  Stream<PlaybackEvent> get playbackEventStream => _playbackEventSubject.stream;

  /// The duration of the current audio or `null` if unknown.
  Duration? get duration => _playbackEvent.duration;

  /// The duration of the current audio or `null` if unknown.
  Future<Duration?>? get durationFuture => _durationFuture;

  /// The duration of the current audio.
  Stream<Duration?> get durationStream => _durationSubject.stream;

  /// The current [ProcessingState].
  ProcessingState get processingState => _playbackEvent.processingState;

  /// A stream of [ProcessingState]s.
  Stream<ProcessingState> get processingStateStream => _processingStateSubject.stream;

  /// Whether the player is playing.
  bool get playing => _playingSubject.nvalue!;

  /// A stream of changing [playing] states.
  Stream<bool> get playingStream => _playingSubject.stream;

  /// The current volume of the player.
  double get volume => _volumeSubject.nvalue!;

  /// A stream of [volume] changes.
  Stream<double> get volumeStream => _volumeSubject.stream;

  /// The current speed of the player.
  double get speed => _speedSubject.nvalue!;

  /// A stream of current speed values.
  Stream<double> get speedStream => _speedSubject.stream;

  /// The current pitch factor of the player.
  double get pitch => _pitchSubject.nvalue!;

  /// A stream of current pitch factor values.
  Stream<double> get pitchStream => _pitchSubject.stream;

  /// The current [AudioPipeline]
  AudioPipeline get audioPipeline => _audioPipeline;

  /// The position up to which buffered audio is available.
  Duration get bufferedPosition => _playbackEvent.bufferedPosition;

  /// The current loop mode.
  LoopMode get loopMode => _loopModeSubject.nvalue!;

  /// A stream of [LoopMode]s.
  Stream<LoopMode> get loopModeStream => _loopModeSubject.stream;

  /// The current Android AudioSession ID or `null` if not set.
  int? get androidAudioSessionId => _playbackEvent.androidAudioSessionId;

  /// Whether the player should automatically delay playback in order to
  /// minimize stalling. (iOS 10.0 or later only)
  bool get automaticallyWaitsToMinimizeStalling => _automaticallyWaitsToMinimizeStalling;

  /// Whether the player can use the network for live streaming while paused on
  /// iOS/macOS.
  bool get canUseNetworkResourcesForLiveStreamingWhilePaused => _canUseNetworkResourcesForLiveStreamingWhilePaused;

  /// The preferred peak bit rate (in bits per second) of bandwidth usage on iOS/macOS.
  double get preferredPeakBitRate => _preferredPeakBitRate;

  /// Whether the player allows external playback on iOS/macOS, defaults to
  /// false.
  bool get allowsExternalPlayback => _allowsExternalPlayback;

  /// The current position of the player.
  Duration get position => _getPositionFor(_playbackEvent);

  Duration _getPositionFor(PlaybackEvent playbackEvent) {
    if (playing && processingState == ProcessingState.ready) {
      final result = playbackEvent.updatePosition + (DateTime.now().difference(playbackEvent.updateTime)) * speed;
      return playbackEvent.duration == null || result <= playbackEvent.duration! ? result : playbackEvent.duration!;
    } else {
      return playbackEvent.updatePosition;
    }
  }

  Future<void> setAudioPipeline(AudioPipeline audioPipeline) async {
    if (_disposed) return;
    _audioPipeline = audioPipeline;
    _audioPipeline._setup(this);
    if (_active) {
      final platform = _platformValue ?? await _platform;
      for (var audioEffect in _audioPipeline._audioEffects) {
        await audioEffect._activate(platform);
      }
      await platform.setAudioPipeline(SetAudioPipelineRequest(
        audioEffects: _audioPipeline._platformAudioEffectsMessage().map((audioEffect) => audioEffect.toMap()).toList(),
      ));
    }
    // if (_active) {
    //   //Reinitialize the platform with the new audio pipeline
    //   await _setPlatformActive(false);
    //   await _setPlatformActive(true);
    // }
  }

  /// A stream tracking the current position of this player, suitable for
  /// animating a seek bar. To ensure a smooth animation, this stream emits
  /// values more frequently on short items where the seek bar moves more
  /// quickly, and less frequenly on long items where the seek bar moves more
  /// slowly. The interval between each update will be no quicker than once
  /// every 16ms and no slower than once every 200ms.
  ///
  /// See [createPositionStream] for more control over the stream parameters.
  Stream<Duration> get positionStream {
    return _positionStream ??= createPositionStream(steps: 800, minPeriod: const Duration(milliseconds: 16), maxPeriod: const Duration(milliseconds: 200));
  }

  /// Creates a new stream periodically tracking the current position of this
  /// player. The stream will aim to emit [steps] position updates from the
  /// beginning to the end of the current audio source, at intervals of
  /// [duration] / [steps]. This interval will be clipped between [minPeriod]
  /// and [maxPeriod]. This stream will not emit values while audio playback is
  /// paused or stalled.
  ///
  /// Note: each time this method is called, a new stream is created. If you
  /// intend to use this stream multiple times, you should hold a reference to
  /// the returned stream and close it once you are done.
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    assert(minPeriod <= maxPeriod);
    assert(minPeriod > Duration.zero);
    if (_disposed) return const Stream.empty();
    final positionSubject = BehaviorSubject<Duration>();

    Duration duration() => this.duration ?? Duration.zero;
    Duration step() {
      var s = duration() ~/ steps;
      if (s < minPeriod) s = minPeriod;
      if (s > maxPeriod) s = maxPeriod;
      return s;
    }

    Timer? currentTimer;
    StreamSubscription<Duration?>? durationSubscription;
    StreamSubscription<PlaybackEvent>? playbackEventSubscription;

    void stop() {
      durationSubscription?.cancel();
      playbackEventSubscription?.cancel();
      currentTimer?.cancel();
      durationSubscription = null;
      playbackEventSubscription = null;
      currentTimer = null;
    }

    void yieldPosition(Timer timer) {
      if (positionSubject.isClosed) {
        stop();
        return;
      }
      if (_durationSubject.isClosed) {
        stop();
        positionSubject.close();
        return;
      }
      if (playing) {
        positionSubject.add(position);
      }
    }

    positionSubject.onListen = () {
      durationSubscription ??= durationStream.listen(
        (duration) {
          currentTimer?.cancel();
          currentTimer = Timer.periodic(step(), yieldPosition);
        },
        onError: (Object e, StackTrace stackTrace) {},
        onDone: () {
          stop();
          positionSubject.close();
        },
      );
      playbackEventSubscription ??= playbackEventStream.listen((event) {
        positionSubject.add(position);
      }, onError: (Object e, StackTrace stackTrace) {});
    };

    positionSubject.onCancel = () {
      stop();
    };

    return positionSubject.stream.distinct();
  }

  /// Convenience method to set the audio source to a URL with optional headers,
  /// preloaded by default, with an initial position of zero by default.
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers, tag: tag),
  ///     initialPosition: Duration.zero, preload: true);
  /// ```
  ///
  /// See [setAudioSource] for a detailed explanation of the options.
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) =>
      setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers, tag: tag), initialPosition: initialPosition, preload: preload);

  /// Convenience method to set the audio source to a file, preloaded by
  /// default, with an initial position of zero by default.
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// setAudioSource(AudioSource.uri(Uri.file(filePath), tag: tag),
  ///     initialPosition: Duration.zero, preload: true);
  /// ```
  ///
  /// See [setAudioSource] for a detailed explanation of the options.
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) =>
      setAudioSource(AudioSource.file(filePath, tag: tag), initialPosition: initialPosition, preload: preload);

  /// Sets the source from which this audio player should fetch audio.
  ///
  /// By default, this method will immediately start loading audio and return
  /// its duration as soon as it is known, or `null` if that information is
  /// unavailable. Set [preload] to `false` if you would prefer to delay loading
  /// until some later point, either via an explicit call to [load] or via a
  /// call to [play] which implicitly loads the audio. If [preload] is `false`,
  /// a `null` duration will be returned. Note that the [preload] option will
  /// automatically be assumed as `true` if `playing` is currently `true`.
  ///
  /// Optionally specify [initialPosition] and [initialIndex] to seek to an
  /// initial position within a particular item (defaulting to position zero of
  /// the first item).
  ///
  /// When [preload] is `true`, this method may throw:
  ///
  /// * [Exception] if no audio source has been previously set.
  /// * [PlayerException] if the audio source was unable to be loaded.
  /// * [PlayerInterruptedException] if another audio source was loaded before
  /// this call completed or the player was stopped or disposed of before the
  /// call completed.
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    if (_disposed) return null;
    _audioSource?.dispose();
    _audioSource = source;
    _initialSeekValues = _InitialSeekValues(position: initialPosition, index: initialIndex);
    _playbackEventSubject.add(_playbackEvent = PlaybackEvent(currentIndex: initialIndex ?? 0, updatePosition: initialPosition ?? Duration.zero));
    if (preload || playing) {
      return load();
    } else {
      return _setPlatformActive(false)?.catchError((dynamic e) async => null);
    }
  }

  /// Starts loading the current audio source and returns the audio duration as
  /// soon as it is known, or `null` if unavailable.
  ///
  /// This method throws:
  ///
  /// * [Exception] if no audio source has been previously set.
  /// * [PlayerException] if the audio source was unable to be loaded.
  /// * [PlayerInterruptedException] if another call to [load] happened before
  /// this call completed or the player was stopped or disposed of before the
  /// call could complete.
  Future<Duration?> load() async {
    if (_disposed) return null;
    if (_audioSource == null) {
      throw Exception('Must set AudioSource before loading');
    }
    if (_active) {
      final initialSeekValues = _initialSeekValues;
      _initialSeekValues = null;
      final loadNumber = ++_loadCount;
      final platform = _platformValue ?? await _platform;
      //Potential race condition here if audioSource changes while awaiting platform.
      return await _load(platform, _audioSource!, loadNumber, initialSeekValues: initialSeekValues);
    } else {
      // This will implicitly load the current audio source.
      return await _setPlatformActive(true);
    }
  }

  Future<Duration?> _load(AudioPlayerPlatform platform, AudioSource source, int loadNumber, {_InitialSeekValues? initialSeekValues}) async {
    final activationNumber = _activationCount;
    void checkInterruption() {
      if (_activationCount != activationNumber) {
        // the platform has changed since we started loading, so abort.
        throw PlatformException(code: 'abort', message: 'Loading interrupted (Platform changed)');
      }
      if (_loadCount != loadNumber) {
        // the platform has changed since we started loading, so abort.
        throw PlatformException(code: 'abort', message: 'Loading interrupted (Load changed)');
      }
    }

    try {
      checkInterruption();
      await source.setup(this);
      checkInterruption();
      _durationFuture = platform
          .load(LoadRequest(
            audioSourceMessage: source._toMessage(),
            initialPosition: initialSeekValues?.position,
            initialIndex: initialSeekValues?.index,
          ))
          .then((response) => response.duration);
      final duration = await _durationFuture;
      checkInterruption();
      _durationSubject.add(duration);
      if (platform != _platformValue) {
        // the platform has changed since we started loading, so abort.
        throw PlatformException(code: 'abort', message: 'Loading interrupted (PlatformValue updated)');
      }
      // Wait for loading state to pass.

      // If no such element is found before this stream is done, and an [orElse] function is provided, the result of calling [orElse] becomes the value of the future. If [orElse] throws, the returned future is completed with that error.

      await processingStateStream.firstWhere((state) => state != ProcessingState.loading, orElse: () {
        // If the stream is closed, we can assume that the player has been disposed of.
        throw PlatformException(code: 'abort', message: 'Loading interrupted (Player disposed)');
      });
      checkInterruption();
      return duration;
    } on PlatformException catch (e) {
      try {
        throw PlayerException(int.parse(e.code), e.message, (e.details as Map<dynamic, dynamic>?)?.cast<String, dynamic>());
      } on FormatException catch (_) {
        if (e.code == 'abort') {
          throw PlayerInterruptedException(e.message);
        } else {
          throw PlayerException(9999999, e.message);
        }
      }
    }
  }

  /// Tells the player to play audio at the current [speed] and [volume] as soon
  /// as an audio source is loaded and ready to play. If an audio source has
  /// been set but not preloaded, this method will also initiate the loading.
  /// The [Future] returned by this method completes when the playback completes
  /// or is paused or stopped. If the player is already playing, this method
  /// completes immediately.
  ///
  /// This method causes [playing] to become true, and it will remain true
  /// until [pause] or [stop] is called. This means that if playback completes,
  /// and then you [seek] to an earlier position in the audio, playback will
  /// continue playing from that position. If you instead wish to [pause] or
  /// [stop] playback on completion, you can call either method as soon as
  /// [processingState] becomes [ProcessingState.completed] by listening to
  /// [processingStateStream].
  ///
  /// This method activates the audio session before playback, and will do
  /// nothing if activation of the audio session fails for any reason.
  Future<void> play() async {
    if (_disposed) return;
    if (playing) return;
    _playInterrupted = false;
    // Broadcast to clients immediately, but revert to false if we fail to
    // activate the audio session. This allows setAudioSource to be aware of a
    // prior play request.
    _playbackEvent = _playbackEvent.copyWith(
      updatePosition: position,
      updateTime: DateTime.now(),
    );
    _playingSubject.add(true);
    _playbackEventSubject.add(_playbackEvent);
    final playCompleter = Completer<dynamic>();

    final requireActive = _audioSource != null;
    if (requireActive) {
      if (_active) {
        _sendPlayRequest((_platformValue ?? await _platform), playCompleter);
      } else {
        _setPlatformActive(true, playCompleter: playCompleter)?.ignore();
      }
    }
    return playCompleter.future;
  }

  /// Pauses the currently playing media. This method does nothing if
  /// ![playing].
  Future<void> pause() async {
    if (_disposed) return;
    if (!playing) return;
    //_setPlatformActive(true);
    _playInterrupted = false;
    // Update local state immediately so that queries aren't surprised.
    _playbackEvent = _playbackEvent.copyWith(
      updatePosition: position,
      updateTime: DateTime.now(),
    );
    _playingSubject.add(false);
    _playbackEventSubject.add(_playbackEvent);
    // TODO: perhaps modify platform side to ensure new state is broadcast
    // before this method returns.
    await (_platformValue ?? await _platform).pause(PauseRequest());
  }

  Future<void> _sendPlayRequest(AudioPlayerPlatform platform, Completer<void>? playCompleter) async {
    try {
      if (!playing) return; // defensive
      await platform.play(PlayRequest());
      playCompleter?.complete();
    } catch (e, stackTrace) {
      playCompleter?.completeError(e, stackTrace);
    }
  }

  /// Stops playing audio and releases decoders and other native platform
  /// resources needed to play audio. The current audio source state will be
  /// retained and playback can be resumed at a later point in time.
  ///
  /// Use [stop] if the app is done playing audio for now but may need still
  /// want to resume playback later. Use [dispose] when the app is completely
  /// finished playing audio. Use [pause] instead if you would like to keep the
  /// decoders alive so that the app can quickly resume audio playback.
  Future<void> stop() async {
    if (_disposed) return;
    final future = _setPlatformActive(false)?.catchError((dynamic e) async => null);

    _playInterrupted = false;
    // Update local state immediately so that queries aren't surprised.
    _playingSubject.add(false);
    await future;
  }

  /// Sets the volume of this player, where 1.0 is normal volume.
  Future<void> setVolume(final double volume) async {
    if (_disposed) return;
    _volumeSubject.add(volume);
    await (_platformValue ?? await _platform).setVolume(SetVolumeRequest(volume: volume));
  }

  /// Sets the playback speed to use when [playing] is `true`, where 1.0 is
  /// normal speed. Note that values in excess of 1.0 may result in stalls if
  /// the playback speed is faster than the player is able to downloaded the
  /// audio.
  Future<void> setSpeed(final double speed) async {
    if (_disposed) return;
    _playbackEvent = _playbackEvent.copyWith(
      updatePosition: position,
      updateTime: DateTime.now(),
    );
    _playbackEventSubject.add(_playbackEvent);
    _speedSubject.add(speed);
    await (_platformValue ?? await _platform).setSpeed(SetSpeedRequest(speed: speed));
  }

  /// Sets the factor by which pitch will be shifted.
  Future<void> setPitch(final double pitch) async {
    if (_disposed) return;
    _playbackEvent = _playbackEvent.copyWith(
      updatePosition: position,
      updateTime: DateTime.now(),
    );
    _playbackEventSubject.add(_playbackEvent);
    _pitchSubject.add(pitch);
    await (_platformValue ?? await _platform).setPitch(SetPitchRequest(pitch: pitch));
  }

  /// Sets the [LoopMode]. Looping will be gapless on Android, iOS and macOS. On
  /// web, there will be a slight gap at the loop point.
  Future<void> setLoopMode(LoopMode mode) async {
    if (_disposed) return;
    _loopModeSubject.add(mode);
    await (_platformValue ?? await _platform).setLoopMode(SetLoopModeRequest(loopMode: LoopModeMessage.values[mode.index]));
  }

  /// Sets automaticallyWaitsToMinimizeStalling for AVPlayer in iOS 10.0 or later, defaults to true.
  /// Has no effect on Android clients
  Future<void> setAutomaticallyWaitsToMinimizeStalling(final bool automaticallyWaitsToMinimizeStalling) async {
    if (_disposed) return;
    _automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
    await (_platformValue ?? await _platform)
        .setAutomaticallyWaitsToMinimizeStalling(SetAutomaticallyWaitsToMinimizeStallingRequest(enabled: automaticallyWaitsToMinimizeStalling));
  }

  /// Sets canUseNetworkResourcesForLiveStreamingWhilePaused on iOS/macOS,
  /// defaults to false.
  Future<void> setCanUseNetworkResourcesForLiveStreamingWhilePaused(final bool canUseNetworkResourcesForLiveStreamingWhilePaused) async {
    if (_disposed) return;
    _canUseNetworkResourcesForLiveStreamingWhilePaused = canUseNetworkResourcesForLiveStreamingWhilePaused;
    await (_platformValue ?? await _platform).setCanUseNetworkResourcesForLiveStreamingWhilePaused(
        SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest(enabled: canUseNetworkResourcesForLiveStreamingWhilePaused));
  }

  /// Sets preferredPeakBitRate on iOS/macOS, defaults to true.
  Future<void> setPreferredPeakBitRate(final double preferredPeakBitRate) async {
    if (_disposed) return;
    _preferredPeakBitRate = preferredPeakBitRate;
    await (_platformValue ?? await _platform).setPreferredPeakBitRate(SetPreferredPeakBitRateRequest(bitRate: preferredPeakBitRate));
  }

  /// Sets allowsExternalPlayback on iOS/macOS, defaults to false.
  Future<void> setAllowsExternalPlayback(final bool allowsExternalPlayback) async {
    if (_disposed) return;
    _allowsExternalPlayback = allowsExternalPlayback;
    await (_platformValue ?? await _platform).setAllowsExternalPlayback(SetAllowsExternalPlaybackRequest(allowsExternalPlayback: allowsExternalPlayback));
  }

  /// Seeks to a particular [position]. If a composition of multiple
  /// [AudioSource]s has been loaded, you may also specify [index] to seek to a
  /// particular item within that sequence. This method has no effect unless
  /// an audio source has been loaded.
  ///
  /// A `null` [position] seeks to the head of a live stream.
  Future<void> seek(final Duration? position, {int? index}) async {
    if (_disposed) return;
    _initialSeekValues = null;
    switch (processingState) {
      case ProcessingState.loading:
        return;
      default:
        final prevPlaybackEvent = _playbackEvent;
        _playbackEvent = prevPlaybackEvent.copyWith(
          updatePosition: position,
          updateTime: DateTime.now(),
        );
        _playbackEventSubject.add(_playbackEvent);
        await (_platformValue ?? await _platform).seek(SeekRequest(position: position, index: index));
    }
  }

  /// Set the Android audio attributes for this player. Has no effect on other
  /// platforms. This will cause a new Android AudioSession ID to be generated.
  Future<void> setAndroidAudioAttributes(AndroidAudioAttributes audioAttributes) async {
    if (_disposed) return;
    if (!_isAndroid() && !_isUnitTest()) return;
    if (audioAttributes == _androidAudioAttributes) return;
    _androidAudioAttributes = audioAttributes;
    await _internalSetAndroidAudioAttributes(await _platform, audioAttributes);
  }

  Future<void> _internalSetAndroidAudioAttributes(AudioPlayerPlatform platform, AndroidAudioAttributes audioAttributes) async {
    if (!_isAndroid() && !_isUnitTest()) return;
    await platform.setAndroidAudioAttributes(SetAndroidAudioAttributesRequest(
        contentType: audioAttributes.contentType.index, flags: audioAttributes.flags.value, usage: audioAttributes.usage.value));
  }

  /// Release all resources associated with this player. You must invoke this
  /// after you are done with the player.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _playbackEventSubscription?.cancel();
      _playerDataSubscription?.cancel();
      if (_nativePlatform != null) {
        await _disposePlatform(await _nativePlatform!);
        _nativePlatform = null;
      }
      if (_idlePlatform != null) {
        await _disposePlatform(_idlePlatform!);
        _idlePlatform = null;
      }
    } finally {
      _platformValue = null;
      _audioSource?.dispose();
      _audioSource = null;
      if (_androidAudioAttributesSubscription != null) {
        await _androidAudioAttributesSubscription!.cancel();
      }
      if (_becomingNoisyEventSubscription != null) {
        await _becomingNoisyEventSubscription!.cancel();
      }
      if (_interruptionEventSubscription != null) {
        await _interruptionEventSubscription!.cancel();
      }
      await _durationSubject.close();
      await _loopModeSubject.close();
      await _playingSubject.close();
      await _volumeSubject.close();
      await _speedSubject.close();
      await _pitchSubject.close();
      await _playbackEventSubject.close();
    }
  }

  /// Switch to using the native platform when [active] is `true` and using the
  /// idle platform when [active] is `false`. If an audio source has been set,
  /// the returned future completes with its duration if known, or `null`
  /// otherwise.
  ///
  /// The platform will not switch if [active] == [_active] unless [force] is
  /// `true`.
  Future<Duration?>? _setPlatformActive(final bool active, {Completer<void>? playCompleter, bool force = false}) {
    if (_disposed) return null;
    if (!force && (active == _active)) return _durationFuture;
    _active = active;
    _platformLoading = active;

    // Warning! Tricky async code lies ahead.
    // (This should definitely be made less tricky)
    // This method itself is not asynchronous, and guarantees that _platform
    // will be set in this cycle to a Future. The platform returned by that
    // future takes time to initialise and so we need to handle the case where
    // that initialisation was interrupted by another call to
    // _setPlatformActive.

    // Store the current activation sequence number. activationNumber should
    // equal _activationCount for the duration of this call, unless it is
    // interrupted by another simultaneous call.
    final activationNumber = ++_activationCount;

    final loadNumber = active ? ++_loadCount : -1;

    /// Tells whether we've been interrupted.
    bool wasInterrupted() => _activationCount != activationNumber;

    final durationCompleter = Completer<Duration?>();

    // Checks if we were interrupted and aborts the current activation. If we
    // are interrupted, there are two cases:
    // 1. If we were activating the native platform, abort with an exception.
    // 2. If we were activating the idle dummy, abort silently.
    //
    // We should call this after each awaited call since those are opportunities
    // for other coroutines to run and interrupt this one.
    bool checkInterruption() {
      if (_disposed) return true;
      // No interruption.
      if (!wasInterrupted()) return false;
      // If loading idle platform was interrupted, silently return.
      if (!active) return true;
      // An interruption that should throw
      throw PlatformException(code: 'abort', message: 'Loading interrupted');
    }

    // This method updates _active and _platform before yielding to the next
    // task in the event loop.
    final position = this.position;

    void subscribeToEvents(AudioPlayerPlatform platform) {
      _playerDataSubscription = platform.playerDataMessageStream.listen((message) {
        if (message.playing != null && message.playing != playing) {
          _playingSubject.add(message.playing!);
        }
        if (message.volume != null) {
          _volumeSubject.add(message.volume!);
        }
        if (message.speed != null) {
          _speedSubject.add(message.speed!);
        }
        if (message.pitch != null) {
          _pitchSubject.add(message.pitch!);
        }
        if (message.loopMode != null) {
          _loopModeSubject.add(LoopMode.values[message.loopMode!.index]);
        }
      });
      _playbackEventSubscription = platform.playbackEventMessageStream.listen((message) {
        var duration = message.duration;
        if (_platformLoading && message.processingState != ProcessingStateMessage.idle) {
          _platformLoading = false;
        }
        final playbackEvent = PlaybackEvent(
          // The platform may emit an idle state while it's starting up which we
          // override here.
          processingState: _platformLoading ? ProcessingState.loading : ProcessingState.values[message.processingState.index],
          updateTime: message.updateTime,
          updatePosition: message.updatePosition,
          bufferedPosition: message.bufferedPosition,
          duration: duration,
          currentIndex: null,
          androidAudioSessionId: message.androidAudioSessionId,
        );
        _durationFuture = Future.value(playbackEvent.duration);
        if (playbackEvent == _playbackEvent) {
          return;
        }
        if (playbackEvent.duration != _playbackEvent.duration) {
          _durationSubject.add(playbackEvent.duration);
        }
        final oldPlaybackEvent = _playbackEvent;
        _playbackEventSubject.add(_playbackEvent = playbackEvent);
        if (_playbackEvent.processingState != oldPlaybackEvent.processingState && _playbackEvent.processingState == ProcessingState.idle) {
          _setPlatformActive(false)?.catchError((dynamic e) async => null);
        }
      }, onError: _playbackEventSubject.addError);
    }

    Future<AudioPlayerPlatform> setPlatform() async {
      _playbackEventSubscription?.cancel();
      _playerDataSubscription?.cancel();
      final oldPlatform = _platformValue;
      _platformValue = null; // Reset the platform value to null while we wait for the new one.
      if (oldPlatform != null && oldPlatform is! _IdleAudioPlayer) {
        await _disposePlatform(oldPlatform); // Dispose of the old  native platform. (This also sets _nativePlatform to null)
      }

      if (checkInterruption()) {
        //If loading was interrupted before we could set the platform, throw an exception.
        throw PlatformException(code: 'abort', message: _disposed ? 'Player disposed' : 'Loading interrupted');
      }

      // During initialisation, we must only use this platform reference in case
      // _platform is updated again during initialisation.
      final platform = active
          ? await (_nativePlatform ??= _pluginPlatform.init(InitRequest(
              id: _id,
              audioLoadConfiguration: _audioLoadConfiguration?._toMessage(),
              androidAudioEffects: _audioPipeline._androidAudioEffectsMessage(),
              darwinAudioEffects: _audioPipeline._darwinAudioEffectsMessage(),
              androidOffloadSchedulingEnabled: _androidOffloadSchedulingEnabled,
            )))
          : (_idlePlatform ??= _IdleAudioPlayer(id: _id));

      if (checkInterruption()) return platform;
      _platformValue = platform;

      if (active) {
        final playing = this.playing;
        // To avoid a glitch in ExoPlayer, ensure that any requested audio
        // attributes are set before loading the audio source.

        if (_androidApplyAudioAttributes && (_isAndroid() || _isUnitTest())) {
          if (_androidAudioAttributes == null) {
            _androidAudioAttributes = (await AudioSession.instance).configuration?.androidAudioAttributes;
            if (checkInterruption()) return platform;
          }
          if (_androidAudioAttributes != null) {
            await _internalSetAndroidAudioAttributes(platform, _androidAudioAttributes!);
            if (checkInterruption()) return platform;
          }
        }

        if (!automaticallyWaitsToMinimizeStalling) {
          await platform.setAutomaticallyWaitsToMinimizeStalling(SetAutomaticallyWaitsToMinimizeStallingRequest(enabled: automaticallyWaitsToMinimizeStalling));
          if (checkInterruption()) return platform;
        }
        if (volume != 1.0) {
          await platform.setVolume(SetVolumeRequest(volume: volume));
          if (checkInterruption()) return platform;
        }
        if (speed != 1.0) {
          await platform.setSpeed(SetSpeedRequest(speed: speed));
          if (checkInterruption()) return platform;
        }
        if (pitch != 1.0 && _isAndroid()) {
          try {
            await platform.setPitch(SetPitchRequest(pitch: pitch));
          } catch (e) {
            // setPitch not supported on this platform.
          }
          if (checkInterruption()) return platform;
        }

        if (loopMode != LoopMode.off) {
          await platform.setLoopMode(SetLoopModeRequest(loopMode: LoopModeMessage.values[loopMode.index]));
          if (checkInterruption()) return platform;
        }

        for (var audioEffect in _audioPipeline._audioEffects) {
          await audioEffect._activate(platform);
          if (checkInterruption()) return platform;
        }
        if (playing) {
          _sendPlayRequest(platform, playCompleter);
        }
      } else {
        await Future<void>.delayed(Duration.zero); //Prevents the idle platform from subscribing to events if a load request is made.
      }

      if (checkInterruption()) return platform;
      subscribeToEvents(platform);

      if (active && _audioSource != null && loadNumber == _loadCount) {
        try {
          final initialSeekValues = _initialSeekValues ?? _InitialSeekValues(position: position, index: null);
          _initialSeekValues = null;

          final duration = await _load(platform, _audioSource!, loadNumber, initialSeekValues: initialSeekValues);
          if (checkInterruption()) return platform;
          durationCompleter.complete(duration);
        } catch (e, stackTrace) {
          if (loadNumber != _loadCount) {
            durationCompleter.complete(null); // Another load request happened.
          } else {
            durationCompleter.completeError(e, stackTrace);
          }
        }
      } else {
        durationCompleter.complete(null);
      }

      return platform;
    }

    _platform = setPlatform();
    return _platform.then((_) => durationCompleter.future);
  }

  /// Dispose of the given platform.
  Future<void> _disposePlatform(AudioPlayerPlatform platform) async {
    if (platform is _IdleAudioPlayer) {
      _idlePlatform = null;
      await platform.dispose(DisposeRequest());
    } else {
      _nativePlatform = null;
      try {
        await _pluginPlatform.disposePlayer(DisposePlayerRequest(id: _id));
      } catch (e) {
        // Fallback if disposePlayer hasn't been implemented.
        await platform.dispose(DisposeRequest());
      }
    }
  }

  /// Clears the plugin's internal asset cache directory. Call this when the
  /// app's assets have changed to force assets to be re-fetched from the asset
  /// bundle.
  static Future<void> clearAssetCache() async {
    if (kIsWeb) return;
    await for (var file in (await _getCacheDir()).list()) {
      await file.delete(recursive: true);
    }
  }
}

/// Captures the details of any error accessing, loading or playing an audio
/// source, including an invalid or inaccessible URL, or an audio encoding that
/// could not be understood.
class PlayerException implements Exception {
  /// On iOS and macOS, maps to `NSError.code`. On Android, maps to
  /// `ExoPlaybackException.type`. On Web, maps to `MediaError.code`.
  final int code;

  /// On iOS and macOS, maps to `NSError.localizedDescription`. On Android,
  /// maps to `ExoPlaybackException.getMessage()`. On Web, a generic message
  /// is provided.
  final String? message;

  /// On Android/iOS/macOS, contains details of the error. For errors associated
  /// with a particular audio source, the `"index"` key maps to the index of the
  /// audio source in the sequence.
  final Map<String, dynamic> details;

  PlayerException(this.code, this.message, [Map<String, dynamic>? details]) : details = details ?? <String, dynamic>{};

  @override
  String toString() => "($code) $message";
}

/// An error that occurs when one operation on the player has been interrupted
/// (e.g. by another simultaneous operation).
class PlayerInterruptedException implements Exception {
  final String? message;

  PlayerInterruptedException(this.message);

  @override
  String toString() => "$message";
}

/// Encapsulates the playback state and current position of the player.
class PlaybackEvent {
  /// The current processing state.
  final ProcessingState processingState;

  /// When the last time a position discontinuity happened, as measured in time
  /// since the epoch.
  final DateTime updateTime;

  /// The position at [updateTime].
  final Duration updatePosition;

  /// The buffer position.
  final Duration bufferedPosition;

  /// The media duration, or `null` if unknown.
  final Duration? duration;

  /// The index of the currently playing item, or `null` if no item is selected.
  final int? currentIndex;

  /// The current Android AudioSession ID if set.
  final int? androidAudioSessionId;

  PlaybackEvent({
    this.processingState = ProcessingState.idle,
    DateTime? updateTime,
    this.updatePosition = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration,
    this.currentIndex,
    this.androidAudioSessionId,
  }) : updateTime = updateTime ?? DateTime.now();

  /// Returns a copy of this event with given properties replaced.
  PlaybackEvent copyWith({
    ProcessingState? processingState,
    DateTime? updateTime,
    Duration? updatePosition,
    Duration? bufferedPosition,
    Duration? duration,
    int? currentIndex,
    int? androidAudioSessionId,
  }) =>
      PlaybackEvent(
        processingState: processingState ?? this.processingState,
        updateTime: updateTime ?? this.updateTime,
        updatePosition: updatePosition ?? this.updatePosition,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        duration: duration ?? this.duration,
        currentIndex: currentIndex ?? this.currentIndex,
        androidAudioSessionId: androidAudioSessionId ?? this.androidAudioSessionId,
      );

  @override
  int get hashCode => Object.hash(
        processingState,
        updateTime,
        updatePosition,
        bufferedPosition,
        duration,
        currentIndex,
        androidAudioSessionId,
      );

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is PlaybackEvent &&
      processingState == other.processingState &&
      updateTime == other.updateTime &&
      updatePosition == other.updatePosition &&
      bufferedPosition == other.bufferedPosition &&
      duration == other.duration &&
      currentIndex == other.currentIndex &&
      androidAudioSessionId == other.androidAudioSessionId;

  @override
  String toString() =>
      "{processingState=$processingState, updateTime=$updateTime, updatePosition=$updatePosition, bufferedPosition=$bufferedPosition, duration=$duration, currentIndex=$currentIndex}";
}

/// Enumerates the different processing states of a player.
enum ProcessingState {
  /// The player has not loaded an [AudioSource].
  idle,

  /// The player is loading an [AudioSource].
  loading,

  /// The player is buffering audio and unable to play.
  buffering,

  /// The player is has enough audio buffered and is able to play.
  ready,

  /// The player has reached the end of the audio.
  completed,
}

/// Encapsulates the playing and processing states. These two states vary
/// orthogonally, and so if [processingState] is [ProcessingState.buffering],
/// you can check [playing] to determine whether the buffering occurred while
/// the player was playing or while the player was paused.
class PlayerState {
  /// Whether the player will play when [processingState] is
  /// [ProcessingState.ready].
  final bool playing;

  /// The current processing state of the player.
  final ProcessingState processingState;

  PlayerState(this.playing, this.processingState);

  @override
  String toString() => 'playing=$playing,processingState=$processingState';

  @override
  int get hashCode => Object.hash(playing, processingState);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && other is PlayerState && other.playing == playing && other.processingState == processingState;
}

// /// Encapsulates the [sequence] and [currentIndex] state and ensures
/// consistency such that [currentIndex] is within the range of
/// `sequence.length`. If `sequence.length` is 0, then [currentIndex] is also
/// 0.
class SequenceState {
  /// The sequence of the current [AudioSource].
  final List<IndexedAudioSource> sequence;

  /// The index of the current source in the sequence.
  final int currentIndex;

  /// The current shuffle order
  final List<int> shuffleIndices;

  /// Whether shuffle mode is enabled.
  final bool shuffleModeEnabled;

  /// The current loop mode.
  final LoopMode loopMode;

  SequenceState(this.sequence, this.currentIndex, this.shuffleIndices, this.shuffleModeEnabled, this.loopMode);

  /// The current source in the sequence.
  IndexedAudioSource? get currentSource => sequence.isEmpty ? null : sequence[currentIndex];

  /// The effective sequence. This is equivalent to [sequence]. If
  /// [shuffleModeEnabled] is true, this is modulated by [shuffleIndices].
  List<IndexedAudioSource> get effectiveSequence => shuffleModeEnabled ? shuffleIndices.map((i) => sequence[i]).toList() : sequence;
}

/// Configuration options to use when loading audio from a source.
class AudioLoadConfiguration {
  /// Bufferring and loading options for iOS/macOS.
  final DarwinLoadControl? darwinLoadControl;

  /// Buffering and loading options for Android.
  final AndroidLoadControl? androidLoadControl;

  /// Speed control for live streams on Android.
  final AndroidLivePlaybackSpeedControl? androidLivePlaybackSpeedControl;

  const AudioLoadConfiguration({
    this.darwinLoadControl,
    this.androidLoadControl,
    this.androidLivePlaybackSpeedControl,
  });

  AudioLoadConfigurationMessage _toMessage() => AudioLoadConfigurationMessage(
        darwinLoadControl: darwinLoadControl?._toMessage(),
        androidLoadControl: androidLoadControl?._toMessage(),
        androidLivePlaybackSpeedControl: androidLivePlaybackSpeedControl?._toMessage(),
      );
}

/// Buffering and loading options for iOS/macOS.
class DarwinLoadControl {
  /// (iOS/macOS) Whether the player will wait for sufficient data to be
  /// buffered before starting playback to avoid the likelihood of stalling.
  final bool automaticallyWaitsToMinimizeStalling;

  /// (iOS/macOS) The duration of audio that should be buffered ahead of the
  /// current position. If not set or `null`, the system will try to set an
  /// appropriate buffer duration.
  final Duration? preferredForwardBufferDuration;

  /// (iOS/macOS) Whether the player can continue downloading while paused to
  /// keep the state up to date with the live stream.
  final bool canUseNetworkResourcesForLiveStreamingWhilePaused;

  /// (iOS/macOS) If specified, limits the download bandwidth in bits per
  /// second.
  final double? preferredPeakBitRate;

  const DarwinLoadControl({
    this.automaticallyWaitsToMinimizeStalling = true,
    this.preferredForwardBufferDuration,
    this.canUseNetworkResourcesForLiveStreamingWhilePaused = false,
    this.preferredPeakBitRate,
  });

  DarwinLoadControlMessage _toMessage() => DarwinLoadControlMessage(
        automaticallyWaitsToMinimizeStalling: automaticallyWaitsToMinimizeStalling,
        preferredForwardBufferDuration: preferredForwardBufferDuration,
        canUseNetworkResourcesForLiveStreamingWhilePaused: canUseNetworkResourcesForLiveStreamingWhilePaused,
        preferredPeakBitRate: preferredPeakBitRate,
      );
}

/// Buffering and loading options for Android.
class AndroidLoadControl {
  /// (Android) The minimum duration of audio that should be buffered ahead of
  /// the current position.
  final Duration minBufferDuration;

  /// (Android) The maximum duration of audio that should be buffered ahead of
  /// the current position.
  final Duration maxBufferDuration;

  /// (Android) The duration of audio that must be buffered before starting
  /// playback after a user action.
  final Duration bufferForPlaybackDuration;

  /// (Android) The duration of audio that must be buffered before starting
  /// playback after a buffer depletion.
  final Duration bufferForPlaybackAfterRebufferDuration;

  /// (Android) The target buffer size in bytes.
  final int? targetBufferBytes;

  /// (Android) Whether to prioritize buffer time constraints over buffer size
  /// constraints.
  final bool prioritizeTimeOverSizeThresholds;

  /// (Android) The back buffer duration.
  final Duration backBufferDuration;

  const AndroidLoadControl({
    this.minBufferDuration = const Duration(seconds: 50),
    this.maxBufferDuration = const Duration(seconds: 50),
    this.bufferForPlaybackDuration = const Duration(milliseconds: 2500),
    this.bufferForPlaybackAfterRebufferDuration = const Duration(seconds: 5),
    this.targetBufferBytes,
    this.prioritizeTimeOverSizeThresholds = false,
    this.backBufferDuration = Duration.zero,
  });

  AndroidLoadControlMessage _toMessage() => AndroidLoadControlMessage(
        minBufferDuration: minBufferDuration,
        maxBufferDuration: maxBufferDuration,
        bufferForPlaybackDuration: bufferForPlaybackDuration,
        bufferForPlaybackAfterRebufferDuration: bufferForPlaybackAfterRebufferDuration,
        targetBufferBytes: targetBufferBytes,
        prioritizeTimeOverSizeThresholds: prioritizeTimeOverSizeThresholds,
        backBufferDuration: backBufferDuration,
      );
}

/// Speed control for live streams on Android.
class AndroidLivePlaybackSpeedControl {
  /// (Android) The minimum playback speed to use when adjusting playback speed
  /// to approach the target live offset, if none is defined by the media.
  final double fallbackMinPlaybackSpeed;

  /// (Android) The maximum playback speed to use when adjusting playback speed
  /// to approach the target live offset, if none is defined by the media.
  final double fallbackMaxPlaybackSpeed;

  /// (Android) The minimum interval between playback speed changes on a live
  /// stream.
  final Duration minUpdateInterval;

  /// (Android) The proportional control factor used to adjust playback speed on
  /// a live stream. The adjusted speed is calculated as: `1.0 +
  /// proportionalControlFactor * (currentLiveOffsetSec - targetLiveOffsetSec)`.
  final double proportionalControlFactor;

  /// (Android) The maximum difference between the current live offset and the
  /// target live offset within which the speed 1.0 is used.
  final Duration maxLiveOffsetErrorForUnitSpeed;

  /// (Android) The increment applied to the target live offset whenever the
  /// player rebuffers.
  final Duration targetLiveOffsetIncrementOnRebuffer;

  /// (Android) The factor for smoothing the minimum possible live offset
  /// achievable during playback.
  final double minPossibleLiveOffsetSmoothingFactor;

  const AndroidLivePlaybackSpeedControl({
    this.fallbackMinPlaybackSpeed = 0.97,
    this.fallbackMaxPlaybackSpeed = 1.03,
    this.minUpdateInterval = const Duration(seconds: 1),
    this.proportionalControlFactor = 1.0,
    this.maxLiveOffsetErrorForUnitSpeed = const Duration(milliseconds: 20),
    this.targetLiveOffsetIncrementOnRebuffer = const Duration(milliseconds: 500),
    this.minPossibleLiveOffsetSmoothingFactor = 0.999,
  });

  AndroidLivePlaybackSpeedControlMessage _toMessage() => AndroidLivePlaybackSpeedControlMessage(
        fallbackMinPlaybackSpeed: fallbackMinPlaybackSpeed,
        fallbackMaxPlaybackSpeed: fallbackMaxPlaybackSpeed,
        minUpdateInterval: minUpdateInterval,
        proportionalControlFactor: proportionalControlFactor,
        maxLiveOffsetErrorForUnitSpeed: maxLiveOffsetErrorForUnitSpeed,
        targetLiveOffsetIncrementOnRebuffer: targetLiveOffsetIncrementOnRebuffer,
        minPossibleLiveOffsetSmoothingFactor: minPossibleLiveOffsetSmoothingFactor,
      );
}

class ProgressiveAudioSourceOptions {
  final AndroidExtractorOptions? androidExtractorOptions;
  final DarwinAssetOptions? darwinAssetOptions;

  const ProgressiveAudioSourceOptions({
    this.androidExtractorOptions,
    this.darwinAssetOptions,
  });

  ProgressiveAudioSourceOptionsMessage _toMessage() => ProgressiveAudioSourceOptionsMessage(
        androidExtractorOptions: androidExtractorOptions?._toMessage(),
        darwinAssetOptions: darwinAssetOptions?._toMessage(),
      );
}

class DarwinAssetOptions {
  final bool preferPreciseDurationAndTiming;

  const DarwinAssetOptions({this.preferPreciseDurationAndTiming = false});

  DarwinAssetOptionsMessage _toMessage() => DarwinAssetOptionsMessage(
        preferPreciseDurationAndTiming: preferPreciseDurationAndTiming,
      );
}

class AndroidExtractorOptions {
  static const flagMp3EnableIndexSeeking = 1 << 2;
  static const flagMp3DisableId3Metadata = 1 << 3;

  final bool constantBitrateSeekingEnabled;
  final bool constantBitrateSeekingAlwaysEnabled;
  final int mp3Flags;

  const AndroidExtractorOptions({
    this.constantBitrateSeekingEnabled = true,
    this.constantBitrateSeekingAlwaysEnabled = false,
    this.mp3Flags = 0,
  });

  AndroidExtractorOptionsMessage _toMessage() => AndroidExtractorOptionsMessage(
        constantBitrateSeekingEnabled: constantBitrateSeekingEnabled,
        constantBitrateSeekingAlwaysEnabled: constantBitrateSeekingAlwaysEnabled,
        mp3Flags: mp3Flags,
      );
}

// /// A local proxy HTTP server for making remote GET requests with headers.
// class _ProxyHttpServer {
//   late HttpServer _server;
//   bool _running = false;

//   /// Maps request keys to [_ProxyHandler]s.
//   final Map<String, _ProxyHandler> _handlerMap = {};

//   /// The port this server is bound to on localhost. This is set only after
//   /// [start] has completed.
//   int get port => _server.port;

//   /// Register a [UriAudioSource] to be served through this proxy. This may be
//   /// called only after [start] has completed.
//   Uri addUriAudioSource(UriAudioSource source) {
//     final uri = source.uri;
//     final headers = <String, String>{};
//     if (source.headers != null) {
//       headers.addAll(source.headers!.cast<String, String>());
//     }
//     final path = _requestKey(uri);
//     _handlerMap[path] = _proxyHandlerForUri(
//       uri,
//       headers: headers,
//       userAgent: source._player?._userAgent,
//     );
//     return uri.replace(
//       scheme: 'http',
//       host: InternetAddress.loopbackIPv4.address,
//       port: port,
//     );
//   }

//   /// Register a [StreamAudioSource] to be served through this proxy. This may
//   /// be called only after [start] has completed.
//   Uri addStreamAudioSource(StreamAudioSource source) {
//     final uri = _sourceUri(source);
//     final path = _requestKey(uri);
//     _handlerMap[path] = _proxyHandlerForSource(source);
//     return uri;
//   }

//   void removeAudioSource(Uri uri) {
//     if (!_running) return;
//     final path = _requestKey(uri);
//     _handlerMap.remove(path);
//   }

//   Uri _sourceUri(StreamAudioSource source) => Uri.http('${InternetAddress.loopbackIPv4.address}:$port', '/id/${source._id}');

//   /// A unique key for each request that can be processed by this proxy,
//   /// made up of the URL path and query string. It is not possible to
//   /// simultaneously track requests that have the same URL path and query
//   /// but differ in other respects such as the port or headers.
//   String _requestKey(Uri uri) => '${uri.path}?${uri.query}';

//   /// Start the server if it is not already running.
//   Future<dynamic> ensureRunning() async {
//     if (_running) return;
//     await runZonedGuarded(() async {
//       await start();
//     }, (e, stackTrace) {
//       print('Proxy exception: $e');
//     });
//   }

//   /// Starts the server.
//   Future<dynamic> start() async {
//     _running = true;
//     _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
//     _server.listen(
//       (request) async {
//         if (request.method == 'GET') {
//           final uriPath = _requestKey(request.uri);
//           final handler = _handlerMap[uriPath];
//           if (handler == null) {
//             request.response.statusCode = HttpStatus.clientClosedRequest;
//             request.response.close();
//           } else {
//             handler(this, request);
//           }
//         }
//       },
//       onDone: () {
//         _running = false;
//       },
//       onError: (Object e, StackTrace st) async {
//         await stop(force: true);
//       },
//       cancelOnError: true,
//     );
//   }

//   /// Stops the server
//   Future<dynamic> stop({bool force = false}) async {
//     if (!_running) return;
//     _running = false;
//     try {
//       await _server.close(force: force);
//     } catch (_) {
//       // ignore
//     }
//   }
// }

// /// Encapsulates the start and end of an HTTP range request.
// class _HttpRangeRequest {
//   /// The starting byte position of the range request.
//   final int start;

//   /// The last byte position of the range request, or `null` if requesting
//   /// until the end of the media.
//   final int? end;

//   /// The end byte position (exclusive), defaulting to `null`.
//   int? get endEx => end == null ? null : end! + 1;

//   _HttpRangeRequest(this.start, this.end);

//   /// Format a range header for this request.
//   String get header => 'bytes=$start-${end != null ? (end! - 1).toString() : ""}';

//   /// Creates an [_HttpRangeRequest] from [header].
//   static _HttpRangeRequest? parse(List<String>? header) {
//     if (header == null || header.isEmpty) return null;
//     final match = RegExp(r'^bytes=(\d+)(-(\d+)?)?').firstMatch(header.first);
//     if (match == null) return null;
//     int? intGroup(int i) => match[i] != null ? int.parse(match[i]!) : null;
//     return _HttpRangeRequest(intGroup(1)!, intGroup(3));
//   }
// }

// /// Encapsulates the range information in an HTTP range response.
// class _HttpRangeResponse {
//   /// The starting byte position of the range.
//   final int start;

//   /// The last byte position of the range.
//   final int end;

//   /// The total number of bytes in the entire media.
//   final int? fullLength;

//   _HttpRangeResponse(this.start, this.end, this.fullLength);

//   /// The end byte position (exclusive).
//   int? get endEx => end + 1;

//   /// The number of bytes requested.
//   int? get length => endEx == null ? null : endEx! - start;

//   /// The content-range header value to use in HTTP responses.
//   String get header => 'bytes $start-$end/${fullLength?.toString() ?? "*"}';
// }

/// Specifies a source of audio to be played. Audio sources are composable
/// using the subclasses of this class. The same [AudioSource] instance should
/// not be used simultaneously by more than one [AudioPlayer].
abstract class AudioSource {
  final String _id;
  AudioPlayer? _player;

  /// Creates an [AudioSource] from a [Uri] with optional headers by
  /// attempting to guess the type of stream. On iOS, this uses Apple's SDK to
  /// automatically detect the stream type. On Android, the type of stream will
  /// be guessed from the extension.
  ///
  /// If you are loading DASH or HLS streams that do not have standard "mpd" or
  /// "m3u8" extensions in their URIs, this method will fail to detect the
  /// stream type on Android. If you know in advance what type of audio stream
  /// it is, you should instantiate [DashAudioSource] or [HlsAudioSource]
  /// directly.
  ///
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  ///
  /// The [tag] is for associating your app's own data with each audio source,
  /// e.g. title, cover art, a primary key for your DB. Such data can be
  /// conveniently retrieved from the tag while rendering the UI.
  ///
  /// When using just_audio_background, [tag] must be a MediaItem, a class
  /// provided by that package. If you wish to have more control over the tag
  /// for background audio purposes, consider using the plugin audio_service
  /// instead of just_audio_background.
  static UriAudioSource uri(Uri uri, {Map<String, String>? headers, dynamic tag}) {
    bool hasExtension(Uri uri, String extension) => uri.path.toLowerCase().endsWith('.$extension') || uri.fragment.toLowerCase().endsWith('.$extension');
    if (hasExtension(uri, 'mpd')) {
      return DashAudioSource(uri, headers: headers, tag: tag);
    } else if (hasExtension(uri, 'm3u8')) {
      return HlsAudioSource(uri, headers: headers, tag: tag);
    } else {
      return ProgressiveAudioSource(uri, headers: headers, tag: tag);
    }
  }

  /// Convenience method to create an audio source for a file.
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// AudioSource.uri(Uri.file(filePath), tag: tag);
  /// ```
  static UriAudioSource file(String filePath, {dynamic tag}) {
    return AudioSource.uri(Uri.file(filePath), tag: tag);
  }

  AudioSource() : _id = _uuid.v4();

  @mustCallSuper
  Future<void> setup(AudioPlayer player) async {
    _player = player;
  }

  @mustCallSuper
  void dispose() {
    // Without this we might make _player "late".
    _player = null;
  }

  AudioSourceMessage _toMessage();

  List<IndexedAudioSource> get sequence;

  List<int> get shuffleIndices;
  AudioPlayer? get player => _player;

  @override
  int get hashCode => _id.hashCode;

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType && other is AudioSource && other._id == _id;
}

/// An [AudioSource] that can appear in a sequence.
abstract class IndexedAudioSource extends AudioSource {
  final dynamic tag;
  Duration? duration;

  IndexedAudioSource({this.tag, this.duration});

  @override
  List<IndexedAudioSource> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];
}

/// An abstract class representing audio sources that are loaded from a URI.
abstract class UriAudioSource extends IndexedAudioSource {
  final Uri uri;
  final Map<String, String>? headers;

  UriAudioSource(this.uri, {this.headers, dynamic tag, Duration? duration}) : super(tag: tag, duration: duration);
}

/// An [AudioSource] representing a regular media file such as an MP3 or M4A
/// file. The following URI schemes are supported:
///
/// * file: loads from a local file (provided you give your app permission to
/// access that file).
/// * asset: loads from a Flutter asset (not supported on Web).
/// * http(s): loads from an HTTP(S) resource.
///
/// On platforms except for the web, the supplied [headers] will be passed with
/// the HTTP(S) request.
///
/// If headers are set, just_audio will create a cleartext local HTTP proxy on
/// your device to forward HTTP requests with headers included.
class ProgressiveAudioSource extends UriAudioSource {
  final ProgressiveAudioSourceOptions? options;

  ProgressiveAudioSource(
    super.uri, {
    super.headers,
    super.tag,
    super.duration,
    this.options,
  });

  @override
  AudioSourceMessage _toMessage() => ProgressiveAudioSourceMessage(
        id: _id,
        uri: uri.toString(),
        headers: null,
        tag: tag,
        options: options?._toMessage(),
      );
}

/// An [AudioSource] representing a DASH stream. The following URI schemes are
/// supported:
///
/// * file: loads from a local file (provided you give your app permission to
/// access that file).
/// * asset: loads from a Flutter asset (not supported on Web).
/// * http(s): loads from an HTTP(S) resource.
///
/// On platforms except for the web, the supplied [headers] will be passed with
/// the HTTP(S) request. Currently headers are not recursively applied to items
/// the HTTP(S) request. Currently headers are not applied recursively.
///
/// If headers are set, just_audio will create a cleartext local HTTP proxy on
/// your device to forward HTTP requests with headers included.
class DashAudioSource extends UriAudioSource {
  DashAudioSource(Uri uri, {Map<String, String>? headers, dynamic tag, Duration? duration}) : super(uri, headers: headers, tag: tag, duration: duration);

  @override
  AudioSourceMessage _toMessage() => DashAudioSourceMessage(
        id: _id,
        uri: uri.toString(),
        headers: null,
        tag: tag,
      );
}

/// An [AudioSource] representing an HLS stream. The following URI schemes are
/// supported:
///
/// * file: loads from a local file (provided you give your app permission to
/// access that file).
/// * asset: loads from a Flutter asset (not supported on Web).
/// * http(s): loads from an HTTP(S) resource.
///
/// On platforms except for the web, the supplied [headers] will be passed with
/// the HTTP(S) request. Currently headers are not applied recursively.
///
/// If headers are set, just_audio will create a cleartext local HTTP proxy on
/// your device to forward HTTP requests with headers included.
class HlsAudioSource extends UriAudioSource {
  HlsAudioSource(Uri uri, {Map<String, String>? headers, dynamic tag, Duration? duration}) : super(uri, headers: headers, tag: tag, duration: duration);

  @override
  AudioSourceMessage _toMessage() => HlsAudioSourceMessage(
        id: _id,
        uri: uri.toString(),
        headers: null,
        tag: tag,
      );
}

Future<Directory> _getCacheDir() async => Directory(p.join((await getTemporaryDirectory()).path, 'just_audio_cache'));

/// Defines the algorithm for shuffling the order of a
/// [ConcatenatingAudioSource]. See [DefaultShuffleOrder] for a default
/// implementation.
abstract class ShuffleOrder {
  /// The shuffled list of indices of [AudioSource]s to play. For example,
  /// [2,0,1] specifies to play the 3rd, then the 1st, then the 2nd item.
  List<int> get indices;

  /// Shuffles the [indices]. If the current item in the player falls within the
  /// [ConcatenatingAudioSource] being shuffled, [initialIndex] will point to
  /// that item. Subclasses may use this information as a hint, for example, to
  /// make [initialIndex] the first item in the shuffle order.
  void shuffle({int? initialIndex});

  /// Inserts [count] new consecutive indices starting from [index] into
  /// [indices], at random positions.
  void insert(int index, int count);

  /// Removes the indices that are `>= start` and `< end`.
  void removeRange(int start, int end);

  /// Removes all indices.
  void clear();
}

/// The default implementation of [ShuffleOrder] which shuffles items with the
/// currently playing item at the head of the order.
class DefaultShuffleOrder extends ShuffleOrder {
  final Random _random;
  @override
  final indices = <int>[];

  DefaultShuffleOrder({Random? random}) : _random = random ?? Random();

  @override
  void shuffle({int? initialIndex}) {
    assert(initialIndex == null || indices.contains(initialIndex));
    if (indices.length <= 1) return;
    indices.shuffle(_random);
    if (initialIndex == null) return;

    const initialPos = 0;
    final swapPos = indices.indexOf(initialIndex);
    // Swap the indices at initialPos and swapPos.
    final swapIndex = indices[initialPos];
    indices[initialPos] = initialIndex;
    indices[swapPos] = swapIndex;
  }

  @override
  void insert(int index, int count) {
    // Offset indices after insertion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) {
        indices[i] += count;
      }
    }
    // Insert new indices at random positions after currentIndex.
    final newIndices = List.generate(count, (i) => index + i);
    for (var newIndex in newIndices) {
      final insertionIndex = _random.nextInt(indices.length + 1);
      indices.insert(insertionIndex, newIndex);
    }
  }

  @override
  void removeRange(int start, int end) {
    final count = end - start;
    // Remove old indices.
    final oldIndices = List.generate(count, (i) => start + i).toSet();
    indices.removeWhere(oldIndices.contains);
    // Offset indices after deletion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) {
        indices[i] -= count;
      }
    }
  }

  @override
  void clear() {
    indices.clear();
  }
}

/// An enumeration of modes that can be passed to [AudioPlayer.setLoopMode].
enum LoopMode { off, one, all }

/// Possible values that can be passed to [AudioPlayer.setWebCrossOrigin].
enum WebCrossOrigin { anonymous, useCredentials }

/// The stand-in platform implementation to use when the player is in the idle
/// state and the native platform is deallocated.
class _IdleAudioPlayer extends AudioPlayerPlatform {
  final _eventSubject = BehaviorSubject<PlaybackEventMessage>();
  late Duration _position;
  int? _index;

  /// Holds a pending request.
  SetAndroidAudioAttributesRequest? setAndroidAudioAttributesRequest;

  _IdleAudioPlayer({
    required String id,
  }) : super(id);

  void _broadcastPlaybackEvent() {
    var updateTime = DateTime.now();
    _eventSubject.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.idle,
      updatePosition: _position,
      updateTime: updateTime,
      bufferedPosition: Duration.zero,
      icyMetadata: null,
      duration: null,
      currentIndex: _index,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _eventSubject.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _index = request.initialIndex ?? 0;
    _position = request.initialPosition ?? Duration.zero;
    _broadcastPlaybackEvent();
    return LoadResponse(duration: null);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    return SetPitchResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async {
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async {
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async {
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(SetWebCrossOriginRequest request) async {
    return SetWebCrossOriginResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
      SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse> setCanUseNetworkResourcesForLiveStreamingWhilePaused(
      SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) async {
    return SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  }

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) async {
    return SetPreferredPeakBitRateResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _position = request.position ?? Duration.zero;
    _index = request.index ?? _index;
    _broadcastPlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) async {
    setAndroidAudioAttributesRequest = request;
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    _eventSubject.close();
    return DisposeResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) async {
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) async {
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) async {
    return ConcatenatingMoveResponse();
  }

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(AudioEffectSetEnabledRequest request) async {
    return AudioEffectSetEnabledResponse();
  }

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse> androidLoudnessEnhancerSetTargetGain(AndroidLoudnessEnhancerSetTargetGainRequest request) async {
    return AndroidLoudnessEnhancerSetTargetGainResponse();
  }

  @override
  Future<SetAudioPipelineResponse> setAudioPipeline(SetAudioPipelineRequest request) async {
    throw UnimplementedError('setAudioPipeline() has not been implemented.');
  }
}

/// Holds the initial requested position and index for a newly loaded audio
/// source.
class _InitialSeekValues {
  final Duration? position;
  final int? index;

  _InitialSeekValues({required this.position, required this.index});
}

class AudioPipeline {
  final List<AndroidAudioEffect> androidAudioEffects;
  final List<DarwinAudioEffect> darwinAudioEffects;

  AudioPipeline({
    List<AndroidAudioEffect>? androidAudioEffects,
    List<DarwinAudioEffect>? darwinAudioEffects,
  })  : assert(androidAudioEffects == null || androidAudioEffects.toSet().length == androidAudioEffects.length),
        assert(darwinAudioEffects == null || darwinAudioEffects.toSet().length == darwinAudioEffects.length),
        androidAudioEffects = androidAudioEffects ?? const [],
        darwinAudioEffects = darwinAudioEffects ?? const [];

  List<AudioEffect> get _audioEffects => <AudioEffect>[...androidAudioEffects, ...darwinAudioEffects];

  void _setup(AudioPlayer player) {
    for (var effect in _audioEffects) {
      effect.setup(player);
    }
  }

  List<AudioEffectMessage> _androidAudioEffectsMessage() {
    if (androidAudioEffects.isNotEmpty && (_isAndroid() || _isUnitTest())) {
      return androidAudioEffects.map((audioEffect) => audioEffect._toMessage()).toList();
    }
    return const [];
  }

  List<AudioEffectMessage> _darwinAudioEffectsMessage() {
    if (darwinAudioEffects.isNotEmpty && (_isDarwin() || _isUnitTest())) {
      return darwinAudioEffects.map((audioEffect) => audioEffect._toMessage()).toList();
    }
    return const [];
  }

  List<AudioEffectMessage> _platformAudioEffectsMessage() {
    if (_isAndroid()) {
      return _androidAudioEffectsMessage();
    } else if (_isDarwin()) {
      return _darwinAudioEffectsMessage();
    } else {
      return const [];
    }
  }
}

/// Subclasses of [AudioEffect] can be inserted into an [AudioPipeline] to
/// modify the audio signal outputted by an [AudioPlayer]. The same audio effect
/// instance cannot be set on multiple players at the same time.
///
/// An [AudioEffect] is disabled by default. For an [AudioEffect] to take
/// effect, in addition to being part of an [AudioPipeline] attached to an
/// [AudioPlayer] you must also enable the effect via [setEnabled].
abstract class AudioEffect {
  AudioPlayer? _player;
  final _enabledSubject = BehaviorSubject.seeded(false);

  AudioEffect();

  /// Called when an [AudioEffect] is attached to an [AudioPlayer].
  void setup(AudioPlayer player) {
    assert(_player == null);
    _player = player;
  }

  /// Called when [_player] is connected to the platform.
  Future<void> _activate(AudioPlayerPlatform platform) async {}

  /// Whether the effect is enabled. When `true`, and if the effect is part
  /// of an [AudioPipeline] attached to an [AudioPlayer], the effect will modify
  /// the audio player's output. When `false`, the audio pipeline will still
  /// reserve platform resources for the effect but the effect will be bypassed.
  bool get enabled => _enabledSubject.nvalue!;

  /// A stream of the current [enabled] value.
  Stream<bool> get enabledStream => _enabledSubject.stream;

  bool get _active => _player?._active ?? false;

  String get _type;

  /// Set the [enabled] status of this audio effect.
  Future<void> setEnabled(bool enabled) async {
    _enabledSubject.add(enabled);
    if (_active) {
      await (await _player!._platform).audioEffectSetEnabled(AudioEffectSetEnabledRequest(type: _type, enabled: enabled));
    }
  }

  AudioEffectMessage _toMessage();
}

/// An [AudioEffect] that supports Android.
mixin AndroidAudioEffect on AudioEffect {}

/// An [AudioEffect] that supports iOS and macOS.
mixin DarwinAudioEffect on AudioEffect {}

/// An Android [AudioEffect] that boosts the volume of the audio signal to a
/// target gain, which defaults to zero.
class AndroidLoudnessEnhancer extends AudioEffect with AndroidAudioEffect {
  final _targetGainSubject = BehaviorSubject.seeded(0.0);

  @override
  String get _type => 'AndroidLoudnessEnhancer';

  /// The target gain in decibels.
  double get targetGain => _targetGainSubject.nvalue!;

  /// A stream of the current target gain in decibels.
  Stream<double> get targetGainStream => _targetGainSubject.stream;

  /// Sets the target gain to a value in decibels.
  Future<void> setTargetGain(double targetGain) async {
    _targetGainSubject.add(targetGain);
    if (_active) {
      await (await _player!._platform).androidLoudnessEnhancerSetTargetGain(AndroidLoudnessEnhancerSetTargetGainRequest(targetGain: targetGain));
    }
  }

  @override
  AudioEffectMessage _toMessage() => AndroidLoudnessEnhancerMessage(
        enabled: enabled,
        targetGain: targetGain,
      );
}

/// A frequency band within an [AndroidEqualizer].
class AndroidEqualizerBand {
  final AudioPlayer _player;

  /// A zero-based index of the position of this band within its [AndroidEqualizer].
  final int index;

  /// The lower frequency of this band in hertz.
  final double lowerFrequency;

  /// The upper frequency of this band in hertz.
  final double upperFrequency;

  /// The center frequency of this band in hertz.
  final double centerFrequency;
  final _gainSubject = BehaviorSubject<double>();

  AndroidEqualizerBand._({
    required AudioPlayer player,
    required this.index,
    required this.lowerFrequency,
    required this.upperFrequency,
    required this.centerFrequency,
    required double gain,
  }) : _player = player {
    _gainSubject.add(gain);
  }

  /// The gain for this band in decibels.
  double get gain => _gainSubject.nvalue!;

  /// A stream of the current gain for this band in decibels.
  Stream<double> get gainStream => _gainSubject.stream;

  /// Sets the gain for this band in decibels.
  Future<void> setGain(double gain) async {
    _gainSubject.add(gain);
    if (_player._active) {
      await (await _player._platform).androidEqualizerBandSetGain(AndroidEqualizerBandSetGainRequest(bandIndex: index, gain: gain));
    }
  }

  /// Restores the gain after reactivating.
  Future<void> _restore(AudioPlayerPlatform platform) async {
    await (platform).androidEqualizerBandSetGain(AndroidEqualizerBandSetGainRequest(bandIndex: index, gain: gain));
  }

  static AndroidEqualizerBand _fromMessage(AudioPlayer player, AndroidEqualizerBandMessage message) => AndroidEqualizerBand._(
        player: player,
        index: message.index,
        lowerFrequency: message.lowerFrequency,
        upperFrequency: message.upperFrequency,
        centerFrequency: message.centerFrequency,
        gain: message.gain,
      );
}

/// The parameter values of an [AndroidEqualizer].
class AndroidEqualizerParameters {
  /// The minimum gain value supported by the equalizer.
  final double minDecibels;

  /// The maximum gain value supported by the equalizer.
  final double maxDecibels;

  /// The frequency bands of the equalizer.
  final List<AndroidEqualizerBand> bands;

  AndroidEqualizerParameters({
    required this.minDecibels,
    required this.maxDecibels,
    required this.bands,
  });

  /// Restore platform state after reactivating.
  Future<void> _restore(AudioPlayerPlatform platform) async {
    for (var band in bands) {
      await band._restore(platform);
    }
  }

  static AndroidEqualizerParameters _fromMessage(AudioPlayer player, AndroidEqualizerParametersMessage message) => AndroidEqualizerParameters(
        minDecibels: message.minDecibels,
        maxDecibels: message.maxDecibels,
        bands: message.bands.map((bandMessage) => AndroidEqualizerBand._fromMessage(player, bandMessage)).toList(),
      );
}

/// An [AudioEffect] for Android that can adjust the gain for different
/// frequency bands of an [AudioPlayer]'s audio signal.
class AndroidEqualizer extends AudioEffect with AndroidAudioEffect {
  final Completer<AndroidEqualizerParameters> _parametersCompleter = Completer<AndroidEqualizerParameters>();

  @override
  String get _type => 'AndroidEqualizer';

  @override
  Future<void> _activate(AudioPlayerPlatform platform) async {
    await super._activate(platform);
    if (_parametersCompleter.isCompleted) {
      await (await parameters)._restore(platform);
      return;
    }
    final response = await platform.androidEqualizerGetParameters(AndroidEqualizerGetParametersRequest());
    final receivedParameters = AndroidEqualizerParameters._fromMessage(_player!, response.parameters);
    _parametersCompleter.complete(receivedParameters);
  }

  /// The parameter values of this equalizer.
  Future<AndroidEqualizerParameters> get parameters => _parametersCompleter.future;

  @override
  AudioEffectMessage _toMessage() => AndroidEqualizerMessage(
        enabled: enabled,
        // Parameters are only communicated from the platform.
        parameters: null,
      );
}

bool _isAndroid() => !kIsWeb && Platform.isAndroid;
bool _isDarwin() => !kIsWeb && (Platform.isIOS || Platform.isMacOS);
bool _isUnitTest() => !kIsWeb && Platform.environment['FLUTTER_TEST'] == 'true';

/// Backwards compatible extensions on rxdart's ValueStream
extension _ValueStreamExtension<T> on ValueStream<T> {
  /// Backwards compatible version of valueOrNull.
  T? get nvalue => hasValue ? value : null;
}

/// Information collected when a position discontinuity occurs.
class PositionDiscontinuity {
  /// The reason for the position discontinuity.
  final PositionDiscontinuityReason reason;

  /// The previous event before the position discontinuity.
  final PlaybackEvent previousEvent;

  /// The event that caused the position discontinuity.
  final PlaybackEvent event;

  const PositionDiscontinuity(this.reason, this.previousEvent, this.event);
}

/// The reasons for position discontinuities.
enum PositionDiscontinuityReason {
  /// The position discontinuity was initiated by a seek.
  seek,

  /// The position discontinuity occurred because the player reached the end of
  /// the current item and auto-advanced to the next item.
  autoAdvance,
}

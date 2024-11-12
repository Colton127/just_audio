// This is a minimal example demonstrating a play/pause button and a seek bar.
// More advanced examples demonstrating other features can be found in the same
// directory as this example in the GitHub repository.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_example/common.dart';
import 'package:just_audio_example/etc/extensions.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

import 'audio_source/caching_audio_source_works.dart';

void main() => runApp(const MyApp());

enum AudioSourceStatus {
  error,
  loading,
  buffering,
  completed,
}

late final Directory kJustAudioCacheDir;

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
//  final _player =
//    AudioPlayer(audioLoadConfiguration: const AudioLoadConfiguration(androidLoadControl: AndroidLoadControl(prioritizeTimeOverSizeThresholds: true)));
  final _player = AudioPlayer(
      audioLoadConfiguration: const AudioLoadConfiguration(
    // darwinLoadControl: DarwinLoadControl(
    //   preferredForwardBufferDuration
    // ),
    androidLoadControl: AndroidLoadControl(
      prioritizeTimeOverSizeThresholds: true,
    ),
  ));

  @override
  void initState() {
    super.initState();
    ambiguate(WidgetsBinding.instance)!.addObserver(this);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
    ));
    _init();
  }

  Future<void> _init() async {
    kJustAudioCacheDir = Directory(p.join((await getTemporaryDirectory()).path, 'just_audio_cache'));

    // Inform the operating system of our app's audio attributes etc.
    // We pick a reasonable default for an app that plays speech.
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    // Listen to errors during playback.
    _player.playbackEventStream.listen((event) {
      print('playbackEvent: $event | Position: ${_player.position}');
    }, onError: (Object e, StackTrace stackTrace) {
      print('playbackEventStream: A stream error occurred: $e');
    });
  }

  final _k100MbMp3 = 'https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3';
  final k10MbMp3 = 'http://192.168.1.8/audio/music/psychedelic.mp3';

  String? _loadedUrl;
  Future<void> _loadLockCacheAudioSource() async {
    try {
      final loadUrl = _loadedUrl == _k100MbMp3 ? k10MbMp3 : _k100MbMp3;
      _loadedUrl = loadUrl;
      final cachingAudioSource = await _cachingFileAudioSource(loadUrl);
      _player.setSpeed(2.0);
      _player.play();
      await _player.setAudioSource(cachingAudioSource, preload: true);
    } catch (e) {
      if (e is PlayerException) {
        print('PlayerException Error loadLockCacheAudioSource audio source: Code: ${e.code}. Error ${e.message} Details: ${e.details}');
      } else {
        print('Error loadLockCacheAudioSource audio source: errorType: ${e.runtimeType}. Error ${e.toString()}');
      }
    }
    return;
  }

  Future<AudioSource> _cachingFileAudioSource(String url) async {
    print('cachingFileAudioSource: url: $url');
    // final lockCachingAudioSource = LockCachingAudioSource(Uri.parse(url));
    // await lockCachingAudioSource.clearCache();
    // lockCachingAudioSource.downloadProgressStream.listen((event) {
    //   print('lockCachingAudioSource: downloadProgressStream: $event');
    // });
    // return lockCachingAudioSource;

    final cacheFile = _getCacheFile(url);
    cacheFile.deleteSafe();
    return CacheStreamAudioSource(Uri.parse(url), cacheFile);
  }

  Future<void> _loadLoudnessEnhancer() async {
    if (_player.audioPipeline.androidAudioEffects.isNotEmpty) {
      print('Audio effects already added');
    } else {
      final loudnessEnhancer = AndroidLoudnessEnhancer();
      final audioPipeline = AudioPipeline(
        androidAudioEffects: [loudnessEnhancer],
      );
      await _player.setAudioPipeline(audioPipeline);
      await loudnessEnhancer.setEnabled(true);
      await loudnessEnhancer.setTargetGain(10);
    }
  }

  File _getCacheFile(String url) {
    final fileName = sha256.convert(utf8.encode(url)).toString();
    final fileExtension = p.extension(url);
    final cacheFile = p.join(kJustAudioCacheDir.path, '$fileName$fileExtension');
    return File(cacheFile);
  }

  @override
  void dispose() {
    ambiguate(WidgetsBinding.instance)!.removeObserver(this);
    // Release decoders and buffers back to the operating system making them
    // available for other apps to use.
    _player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Release the player's resources when not in use. We use "stop" so that
      // if the app resumes later, it will still remember what position to
      // resume from.
      _player.stop();
    }
  }

  /// Collects the data useful for displaying in a seek bar, using a handy
  /// feature of rx_dart to combine the 3 streams of interest into one.
  Stream<PositionData> get _positionDataStream => Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
      _player.positionStream,
      _player.bufferedPositionStream,
      _player.durationStream,
      (position, bufferedPosition, duration) => PositionData(position, bufferedPosition, duration ?? Duration.zero));

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () {
                  _loadLockCacheAudioSource();
                },
                child: const Text('Load Lock Cache Audio Source'),
              ),
              OutlinedButton(
                onPressed: () {
                  return;
                  _loadLoudnessEnhancer();
                },
                child: const Text('Load Loudness Enhancer'),
              ),

              // Display play/pause button and volume/speed sliders.
              ControlButtons(_player),
              // Display seek bar. Using StreamBuilder, this widget rebuilds
              // each time the position, buffered position or duration changes.
              StreamBuilder<PositionData>(
                stream: _positionDataStream,
                builder: (context, snapshot) {
                  final positionData = snapshot.data;
                  return SeekBar(
                    duration: positionData?.duration ?? Duration.zero,
                    position: positionData?.position ?? Duration.zero,
                    bufferedPosition: positionData?.bufferedPosition ?? Duration.zero,
                    onChangeEnd: _player.seek,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Displays the play/pause button and volume/speed sliders.
class ControlButtons extends StatelessWidget {
  final AudioPlayer player;

  const ControlButtons(this.player, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Opens volume slider dialog
        IconButton(
          icon: const Icon(Icons.volume_up),
          onPressed: () {
            showSliderDialog(
              context: context,
              title: "Adjust volume",
              divisions: 10,
              min: 0.0,
              max: 1.0,
              value: player.volume,
              stream: player.volumeStream,
              onChanged: player.setVolume,
            );
          },
        ),

        /// This StreamBuilder rebuilds whenever the player state changes, which
        /// includes the playing/paused state and also the
        /// loading/buffering/ready state. Depending on the state we show the
        /// appropriate button or loading indicator.
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snapshot) {
            final playerState = snapshot.data;
            final processingState = playerState?.processingState;
            final playing = playerState?.playing;
            if (processingState == ProcessingState.loading || processingState == ProcessingState.buffering) {
              return Container(
                margin: const EdgeInsets.all(8.0),
                width: 64.0,
                height: 64.0,
                child: const CircularProgressIndicator(),
              );
            } else if (playing != true) {
              return IconButton(
                icon: const Icon(Icons.play_arrow),
                iconSize: 64.0,
                onPressed: player.play,
              );
            } else if (processingState != ProcessingState.completed) {
              return IconButton(
                icon: const Icon(Icons.pause),
                iconSize: 64.0,
                onPressed: player.pause,
              );
            } else {
              return IconButton(
                icon: const Icon(Icons.replay),
                iconSize: 64.0,
                onPressed: () => player.seek(Duration.zero),
              );
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.cancel),
          onPressed: () async {
            await player.stop();
            await player.setAsset('audio/nature.mp3');
          },
        ),

        // Opens speed slider dialog
        StreamBuilder<double>(
          stream: player.speedStream,
          builder: (context, snapshot) => IconButton(
            icon: Text("${snapshot.data?.toStringAsFixed(1)}x", style: const TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              showSliderDialog(
                context: context,
                title: "Adjust speed",
                divisions: 10,
                min: 0.5,
                max: 1.5,
                value: player.speed,
                stream: player.speedStream,
                onChanged: player.setSpeed,
              );
            },
          ),
        ),
      ],
    );
  }
}

// class CustomStreamAudioSource extends StreamAudioSource {
//   final String url;
//   final File cacheFile;
//   late final StreamController<Uint8List> _controller;
//   late final Stream<Uint8List> _stream;
//   bool _isDownloading = false;
//   bool _isPlaybackStarted = false;
//   int _downloadedBytes = 0;
//   int _totalBytes = 0;
//   final int _bufferSize = 64 * 1024; // Buffer size of 64KB

//   CustomStreamAudioSource(this.url, this.cacheFile) {
//     _controller = StreamController<Uint8List>();
//     _stream = _controller.stream.asBroadcastStream();
//   }

//   @override
//   Future<StreamAudioResponse> request([int? start, int? end]) async {
//     if (!_isDownloading) {
//       _isDownloading = true;
//       _downloadAudio();
//     }

//     // Wait until the requested range is available
//     print('request: getting streamAudioRequest: start: $start, end: $end. Total bytes: $_totalBytes. _downloadedBytes: $_downloadedBytes');

//     while (_totalBytes == 0 || _downloadedBytes < (start ?? 0) || _totalBytes < (end ?? 0)) {
//       await Future.delayed(const Duration(milliseconds: 100));
//     }
//     print('request: returning streamAudioRequest: start: $start, end: $end. Total bytes: $_totalBytes. _downloadedBytes: $_downloadedBytes');
//     return StreamAudioResponse(
//       sourceLength: _totalBytes,
//       contentLength: (end ?? _totalBytes) - (start ?? 0),
//       offset: start ?? 0,
//       stream: _stream,
//       contentType: 'audio/mpeg',
//     );
//   }

//   Future<void> _downloadAudio() async {
//     final request = http.Request('GET', Uri.parse(url));
//     final response = await request.send();

//     if (response.statusCode != 200) {
//       throw PlatformException(
//         code: response.statusCode.toString(),
//         message: 'Failed to download audio',
//       );
//     }

//     _totalBytes = response.contentLength ?? 0;
//     if (_totalBytes == 0) {
//       throw PlatformException(
//         code: '0',
//         message: 'Content length is zero or missing',
//       );
//     }

//     final fileStream = cacheFile.openWrite();

//     response.stream.listen((chunk) {
//       final uint8ListChunk = Uint8List.fromList(chunk);
//       _controller.add(uint8ListChunk);
//       _downloadedBytes += chunk.length;
//       fileStream.add(chunk);

//       if (!_isPlaybackStarted && _downloadedBytes >= _bufferSize) {
//         _isPlaybackStarted = true;
//       }
//     }, onDone: () async {
//       await fileStream.close();
//       _controller.close();
//     }, onError: (error) async {
//       await fileStream.close();
//       _controller.addError(error);
//       _controller.close();
//     });
//   }
// }

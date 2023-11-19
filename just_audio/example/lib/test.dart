import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class Test extends StatefulWidget {
  const Test({Key? key}) : super(key: key);

  @override
  State<Test> createState() => _TestState();
}

class _TestState extends State<Test> {
  final audioSource = LockCachingAudioSource(Uri.parse("https://cdn.coltongrubbs.com/audio/largeaudiofile.wav"));
  final audioPlayer = AudioPlayer();
  @override
  void initState() {
    audioSource.downloadProgressStream.listen((event) {
      print('downloadProgress: $event');
    });

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        OutlinedButton(
            onPressed: () async {
              await audioSource.clearCache();
              print('cache cleared');
            },
            child: const Text('Clear it')),
        OutlinedButton(
            onPressed: () async {
              final player = AudioPlayer();
              try {
                await audioSource.request();

                // await for (List<int> bytes in response.stream) {
                //   final length = bytes.length;
                //   print('Received: $length bytes');
                // }
                print('Finished prefetching');
              } catch (e) {
                print('caught error $e');
                return;
              }
            },
            child: const Text('test it'))
      ],
    );
  }
}

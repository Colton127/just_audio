import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class Test extends StatefulWidget {
  const Test({Key? key}) : super(key: key);

  @override
  State<Test> createState() => _TestState();
}

class _TestState extends State<Test> {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        OutlinedButton(
            onPressed: () async {
              final player = AudioPlayer();
              try {
                final audioSource = LockCachingAudioSource(
                    Uri.parse("https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3"));
                await audioSource.clearCache();
                await player.setAudioSource(audioSource);
                await player.dispose();
                print('successfully loaded');
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

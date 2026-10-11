import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/video_plan.dart';

/// A video ready to upload as its target.
class PreparedVideo {
  const PreparedVideo({
    required this.path,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.bytes,
    required this.converted,
  });

  /// When [converted], a new cache file the caller deletes when done with it; else the input.
  final String path;

  /// Zero when there is no native side to measure the clip (tests).
  final int width;
  final int height;
  final int durationMs;
  final int bytes;
  final bool converted;
}

class VideoPrepException implements Exception {
  const VideoPrepException(this.failure, [this.detail]);

  final VideoPrepFailure failure;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'VideoPrepException(${failure.name})'
      : 'VideoPrepException(${failure.name}): $detail';
}

/// Converts a picked video on the phone until it passes the server's byte QC for its target.
class VideoPrepService {
  VideoPrepService({
    MethodChannel? channel,
    EventChannel? progressChannel,
    Future<Directory> Function()? cacheDirectory,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _progressChannel =
           progressChannel ?? const EventChannel(progressChannelName),
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  static const channelName = 'com.hsrutility.arul/video_prep';
  static const progressChannelName = 'com.hsrutility.arul/video_prep/progress';

  // VideoPrepChannel refuses an output anywhere else: that folder is what it sweeps at engine start.
  static const _preparedDir = 'upload_prepared';

  /// The share of the cap a shrunk retry aims for: margin for content busier than the first cut.
  static const _retryFill = 0.85;

  final MethodChannel _channel;
  final EventChannel _progressChannel;
  final Future<Directory> Function() _cacheDirectory;

  _Run? _run;

  /// Probes [path], then passes it through or converts it; [onProgress] runs 0..1 per export.
  Future<PreparedVideo> prepare(
    String path,
    VideoTarget target, {
    void Function(double progress)? onProgress,
  }) async {
    final run = _run = _Run();
    try {
      final VideoProbe probe;
      try {
        probe = await _probe(path);
      } on MissingPluginException {
        // No native side (widget tests, a future platform) -> the clip goes up as picked.
        return PreparedVideo(
          path: path,
          width: 0,
          height: 0,
          durationMs: 0,
          bytes: await _lengthOf(path),
          converted: false,
        );
      }
      run.throwIfCancelled();
      return switch (planVideo(probe, target)) {
        PassThroughPlan() => PreparedVideo(
          path: path,
          width: probe.width,
          height: probe.height,
          durationMs: probe.durationMs,
          bytes: probe.bytes,
          converted: false,
        ),
        RejectPlan(:final failure) => throw VideoPrepException(failure),
        final ExportPlan plan => await _convert(
          path,
          plan,
          target,
          run,
          onProgress,
        ),
      };
    } finally {
      if (identical(_run, run)) _run = null;
    }
  }

  /// Stops the [prepare] in flight, which then throws [VideoPrepFailure.cancelled].
  Future<void> cancel() async {
    final run = _run;
    if (run == null) return;
    run.cancelled = true;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // No native side -> nothing to stop.
    } on PlatformException {
      // The export already ended; prepare() sees the flag at its next step.
    }
  }

  Future<PreparedVideo> _convert(
    String input,
    ExportPlan plan,
    VideoTarget target,
    _Run run,
    void Function(double progress)? onProgress,
  ) async {
    final progress = onProgress == null
        ? null
        : _progressChannel.receiveBroadcastStream().listen((event) {
            if (event is num) onProgress((event / 100).clamp(0, 1).toDouble());
          }, onError: (Object _) {});
    try {
      var attempt = plan;
      var retried = false;
      while (true) {
        final output = await _export(input, attempt, run);
        final VideoProbe made;
        try {
          made = await _probe(output);
        } on Object {
          await _deleteOutput(output);
          throw const VideoPrepException(
            VideoPrepFailure.exportFailed,
            'the converted file could not be read back',
          );
        }
        if (run.cancelled) {
          await _deleteOutput(output);
          throw const VideoPrepException(VideoPrepFailure.cancelled);
        }
        switch (checkExport(made, attempt, target)) {
          case ExportCheck.ok:
            onProgress?.call(1);
            return PreparedVideo(
              path: output,
              width: made.width,
              height: made.height,
              durationMs: made.durationMs,
              bytes: made.bytes,
              converted: true,
            );
          case ExportCheck.tooLarge when !retried:
            await _deleteOutput(output);
            // An exact-size target (live) can only lower the bitrate; a shape-keeping one (status)
            // also steps down a size, which an encoder that ignores the bitrate still obeys.
            attempt = target.exactWidth == null
                ? attempt.shrunkToward(
                    made.bytes,
                    (target.maxBytes * _retryFill).floor(),
                    videoBitrate: target.retryVideoBitrate,
                  )
                : attempt.withVideoBitrate(target.retryVideoBitrate);
            retried = true;
          case ExportCheck.tooLarge:
            await _deleteOutput(output);
            throw VideoPrepException(
              VideoPrepFailure.tooLarge,
              '${made.bytes} bytes over ${target.maxBytes}',
            );
          case ExportCheck.offPlan:
            await _deleteOutput(output);
            throw VideoPrepException(
              VideoPrepFailure.exportFailed,
              'output ${made.width}x${made.height} ${made.videoMime} '
              'rotation ${made.rotationDegrees} audio ${made.hasAudio} '
              '${made.durationMs} ms, planned $attempt',
            );
        }
      }
    } finally {
      await progress?.cancel();
    }
  }

  Future<String> _export(String input, ExportPlan plan, _Run run) async {
    run.throwIfCancelled();
    final output = await _outputPathFor(input);
    run.throwIfCancelled();
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>('export', {
        'inputPath': input,
        'outputPath': output,
        'width': plan.width,
        'height': plan.height,
        'endMs': plan.endMs,
        'removeAudio': plan.removeAudio,
        'videoBitrate': plan.videoBitrate,
        'audioBitrate': plan.audioBitrate,
      });
      return reply?['path'] as String? ?? output;
    } on PlatformException catch (e) {
      throw VideoPrepException(_failureFor(e.code), e.message);
    } on MissingPluginException {
      throw const VideoPrepException(
        VideoPrepFailure.exportFailed,
        'no native converter',
      );
    }
  }

  /// Throws [MissingPluginException] untouched: [prepare] reads it as "no native side".
  Future<VideoProbe> _probe(String path) async {
    final Map<String, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('probe', {
        'path': path,
      });
    } on PlatformException catch (e) {
      throw VideoPrepException(VideoPrepFailure.unreadable, e.message);
    }
    if (raw == null) {
      throw const VideoPrepException(VideoPrepFailure.unreadable);
    }
    return VideoProbe.fromChannel(raw, path: path);
  }

  static VideoPrepFailure _failureFor(String code) => switch (code) {
    'unsupported_api' => VideoPrepFailure.unsupportedDevice,
    'busy' => VideoPrepFailure.busy,
    'cancelled' => VideoPrepFailure.cancelled,
    'bad_input' => VideoPrepFailure.unreadable,
    _ => VideoPrepFailure.exportFailed,
  };

  // Each export gets its own folder, so a retry never reuses a name the first attempt held.
  Future<String> _outputPathFor(String input) async {
    final cache = await _cacheDirectory();
    final id = DateTime.now().microsecondsSinceEpoch;
    return '${cache.path}/$_preparedDir/$id/${_stemOf(input)}.mp4';
  }

  static String _stemOf(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return stem.isEmpty ? 'video' : stem;
  }

  // Only ever an output of ours: its folder holds nothing else, so it goes too.
  static Future<void> _deleteOutput(String output) async {
    final folder = File(output).parent;
    if (folder.parent.path.split('/').last != _preparedDir) return;
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // Already gone; the engine-start sweep covers anything left.
    }
  }

  static Future<int> _lengthOf(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return 0;
    }
  }
}

class _Run {
  bool cancelled = false;

  void throwIfCancelled() {
    if (cancelled) throw const VideoPrepException(VideoPrepFailure.cancelled);
  }
}

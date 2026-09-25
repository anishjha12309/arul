import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/app_update_policy.dart';

/// The Dart side of android/.../update/AppUpdateChannel.kt.
class AppUpdateClient {
  AppUpdateClient([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(_name) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onInstallState' && call.arguments is String) {
        _installStates.add(call.arguments as String);
      }
    });
  }

  static const _name = 'com.hsrutility.arul/app_update';

  final MethodChannel _channel;
  final _installStates = StreamController<String>.broadcast();

  Stream<String> get installStates => _installStates.stream;

  Future<UpdateInfo> check() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('check');
      return map == null
          ? const UpdateInfo.unavailable('empty')
          : UpdateInfo.fromMap(map);
    } on MissingPluginException {
      return const UpdateInfo.unavailable('no_channel');
    } on PlatformException catch (e) {
      return UpdateInfo.unavailable(e.message ?? e.code);
    }
  }

  /// accepted · cancelled · failed · not_allowed · superseded.
  Future<String> start({required bool immediate}) async {
    try {
      return await _channel.invokeMethod<String>('start', {
            'type': immediate ? 'immediate' : 'flexible',
          }) ??
          'failed';
    } on MissingPluginException {
      return 'failed';
    } on PlatformException {
      return 'failed';
    }
  }

  /// True only on a sideload launched with the fake-update test extra (docs/app-update.md).
  Future<bool> isFake() async {
    try {
      return await _channel.invokeMethod<bool>('isFake') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> completeUpdate() async {
    try {
      return await _channel.invokeMethod<bool>('completeUpdate') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _installStates.close();
  }
}

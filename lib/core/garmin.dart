import 'dart:async';

import 'package:flutter/services.dart';

class GarminBridge {
  GarminBridge._();

  static final GarminBridge instance = GarminBridge._();
  static const MethodChannel _methods = MethodChannel('dsh/garmin');
  static const EventChannel _eventChannel = EventChannel('dsh/garmin_events');

  late final Stream<Map<String, dynamic>> events = _eventChannel
      .receiveBroadcastStream()
      .where((dynamic event) => event is Map)
      .map((dynamic event) => Map<String, dynamic>.from(event as Map));

  Future<void> start() => _methods.invokeMethod<void>('start');
  Future<void> refresh() => _methods.invokeMethod<void>('refresh');
  Future<void> select({required int id, required String name}) => _methods
      .invokeMethod<void>('select', <String, Object>{'id': id, 'name': name});
  Future<bool> push({
    required int deviceId,
    required String deviceName,
    required String text,
  }) async =>
      await _methods.invokeMethod<bool>('reply', <String, Object>{
        'text': text,
        'deviceId': deviceId,
        'deviceName': deviceName,
      }) ??
      false;
  Future<void> stop() => _methods.invokeMethod<void>('stop');
}

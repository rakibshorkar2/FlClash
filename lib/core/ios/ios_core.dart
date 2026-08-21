import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/services.dart';

import '../interface.dart';
import '../method.dart';

/// iOS Core driver.
///
/// The Go core runs inside the Network Extension (PacketTunnel) process. This
/// driver implements the same [CoreHandlerInterface] contract used on Android
/// and desktop, but transports each [CoreMethod] call over a MethodChannel to
/// the Runner app, which forwards it to the extension over its message channel.
///
/// Channel protocol (app <-> native Runner):
///  - app -> native:  'invokeMethod' with a [CoreMethodCall] JSON payload.
///  - native -> app:  a [CoreMethodResponse] JSON payload.
///  - app -> native:  'start' / 'stop' to drive the extension lifecycle.
///  - native -> app:  'event' with a [CoreEvent] JSON payload (async pushes).
class IOSCore extends CoreHandlerInterface {
  static IOSCore? _instance;

  final MethodChannel _channel;
  Completer<void> _connected = Completer<void>();
  bool _closed = false;
  int _lifecycleRevision = 0;
  int _methodCallId = 0;

  IOSCore._internal() : _channel = const MethodChannel('fl_clash/core_ios') {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  factory IOSCore() {
    return _instance ??= IOSCore._internal();
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'event':
        final data = call.arguments;
        for (final event in coreEventsFromData(data)) {
          coreEventManager.sendEvent(event);
        }
        return null;
      default:
        throw MissingPluginException(
          'No implementation for method ${call.method} on iOS core channel',
        );
    }
  }

  @override
  Future<CoreLifecycleResult> start() async {
    if (_closed) {
      throw StateError('Core lifecycle is closed');
    }
    final revision = ++_lifecycleRevision;
    if (_connected.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    final started = await _channel.invokeMethod<bool>('start') ?? false;
    if (!started) {
      throw StateError('iOS Core extension failed to start');
    }
    _connected.complete();
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> restart() async {
    await stop();
    return start();
  }

  @override
  Future<CoreLifecycleResult> stop() async {
    final revision = ++_lifecycleRevision;
    if (!_connected.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    _connected = Completer<void>();
    final stopped = await _channel.invokeMethod<bool>('stop') ?? true;
    if (!stopped) {
      throw StateError('iOS Core extension stop failed');
    }
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> close() {
    _closed = true;
    return stop();
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    try {
      await _connected.future.timeout(const Duration(seconds: 10));
    } catch (error) {
      commonPrint.log(
        'Invoke method ${method.name} before connection timed out: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
    final id = '${++_methodCallId}';
    final payload = CoreMethodCall(
      id: id,
      method: method,
      arguments: arguments,
    ).toJson();
    try {
      final response = await _channel
          .invokeMethod<Map<Object?, Object?>>('invokeMethod', payload)
          .timeout(timeout ?? const Duration(seconds: 30));
      if (response == null) {
        return null;
      }
      return CoreMethodResponse.fromJson(
        Map<String, Object?>.from(response),
      ).unwrap<T>();
    } on TimeoutException {
      return null;
    } on PlatformException catch (error) {
      commonPrint.log(
        'iOS core invoke ${method.name} failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }
}

IOSCore? get iosCore => system.isIOS ? IOSCore() : null;
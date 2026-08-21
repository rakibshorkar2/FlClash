import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestListener with CoreEventListener {
  Log? receivedLog;

  @override
  void onLog(Log log) {
    receivedLog = log;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fl_clash/core_ios');
  final logCalls = <MethodCall>[];

  setUp(() {
    logCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          logCalls.add(call);
          switch (call.method) {
            case 'start':
              return true;
            case 'stop':
              return true;
            case 'invokeMethod':
              final args = call.arguments as Map<Object?, Object?>;
              final id = args['id'] as String;
              return {
                'id': id,
                'result': 'ok',
                'error': null,
              };
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    CoreController.resetInstance();
  });

  group('IOSCore lifecycle', () {
    test('start invokes start method on channel', () async {
      final core = IOSCore();
      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      expect(logCalls.any((call) => call.method == 'start'), isTrue);
    });

    test('coalesces repeated start calls when already connected', () async {
      final core = IOSCore();
      final first = await core.start();
      final second = await core.start();

      expect(first.outcome, CoreLifecycleOutcome.applied);
      expect(second.outcome, CoreLifecycleOutcome.coalesced);
    });

    test('stop invokes stop method on channel', () async {
      final core = IOSCore();
      await core.start();
      final stopResult = await core.stop();

      expect(stopResult.outcome, CoreLifecycleOutcome.applied);
      expect(logCalls.any((call) => call.method == 'stop'), isTrue);
    });

    test('invokeMethod dispatches structured method call and receives response', () async {
      final core = IOSCore();
      await core.start();

      final res = await core.invokeMethod<String>(
        method: CoreMethod.validateConfig,
        arguments: '/path/to/config.yaml',
      );

      expect(res, 'ok');
      expect(logCalls.any((call) => call.method == 'invokeMethod'), isTrue);
    });

    test('event handler receives async push and dispatches to coreEventManager', () async {
      final core = IOSCore();
      await core.start();

      final listener = _TestListener();
      coreEventManager.addListener(listener);

      const codec = StandardMethodCodec();
      final message = codec.encodeMethodCall(
        const MethodCall('event', [
          {
            'type': 'log',
            'data': {'logLevel': 'info', 'payload': 'test log'},
          }
        ]),
      );

      final binaryMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await binaryMessenger.handlePlatformMessage('fl_clash/core_ios', message, (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(listener.receivedLog?.payload, 'test log');
      coreEventManager.removeListener(listener);
    });
  });
}

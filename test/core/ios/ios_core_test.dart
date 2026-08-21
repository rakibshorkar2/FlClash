import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/ios/ios_core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fl_clash/core_ios');
  final log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          log.add(call);
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
      expect(log.any((call) => call.method == 'start'), isTrue);
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
      expect(log.any((call) => call.method == 'stop'), isTrue);
    });

    test('invokeMethod dispatches structured method call and receives response', () async {
      final core = IOSCore();
      await core.start();

      final res = await core.invokeMethod<String>(
        method: CoreMethod.validateConfig,
        arguments: '/path/to/config.yaml',
      );

      expect(res, 'ok');
      expect(log.any((call) => call.method == 'invokeMethod'), isTrue);
    });

    test('event handler receives async push and dispatches to coreEventManager', () async {
      final core = IOSCore();
      await core.start();

      CoreEvent? receivedEvent;
      final listener = coreEventManager.addListener((event) {
        receivedEvent = event;
      });

      final binaryMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codec = const StandardMethodCodec();
      final message = codec.encodeMethodCall(
        const MethodCall('event', [
          {
            'type': 'traffic',
            'data': {'up': 100, 'down': 200},
          }
        ]),
      );

      await binaryMessenger.handlePlatformMessage('fl_clash/core_ios', message, (_) {});

      expect(receivedEvent, isNotNull);
      expect(receivedEvent?.type, 'traffic');
      listener.cancel();
    });
  });
}

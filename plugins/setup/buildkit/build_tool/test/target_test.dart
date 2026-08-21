import 'package:build_tool/src/error.dart';
import 'package:build_tool/src/target.dart';
import 'package:test/test.dart';

void main() {
  group('resolveAndroidTargets', () {
    test('defaults to all Android targets', () {
      final targets = Target.resolveAndroidTargets();

      expect(targets,
          [Target.androidArm, Target.androidArm64, Target.androidAmd64]);
    });

    test('maps a Flutter target platform to the matching Android target', () {
      final targets = Target.resolveAndroidTargets(
        flutterTargetPlatforms: 'android-arm64',
      );

      expect(targets, [Target.androidArm64]);
    });

    test('maps multiple Flutter target platforms in order', () {
      final targets = Target.resolveAndroidTargets(
        flutterTargetPlatforms: 'android-arm64,android-x64',
      );

      expect(targets, [Target.androidArm64, Target.androidAmd64]);
    });

    test('uses explicit arch when provided', () {
      final targets = Target.resolveAndroidTargets(archName: 'arm');

      expect(targets, [Target.androidArm]);
    });

    test('rejects unsupported Flutter target platforms', () {
      expect(
        () => Target.resolveAndroidTargets(
          flutterTargetPlatforms: 'android-riscv64',
        ),
        throwsA(isA<BuildException>()),
      );
    });
  });

  group('ios target', () {
    test('lists iosArm64 for the ios platform', () {
      expect(Target.forPlatform('ios'), [Target.iosArm64]);
    });

    test('is a static library target', () {
      expect(Target.iosArm64.isLib, isTrue);
      expect(Target.iosArm64.dynamicLibExtension, '.a');
      expect(Target.iosArm64.flutterPlatform, 'ios-arm64');
      expect(Target.iosArm64.abi, isNull);
    });
  });
}

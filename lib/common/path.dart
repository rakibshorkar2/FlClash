import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class AppPath {
  static AppPath? _instance;
  Completer<Directory> dataDir = Completer();
  late final Future<Directory?> _downloadDir = getDownloadsDirectory();
  Completer<Directory> tempDir = Completer();
  Completer<Directory> cacheDir = Completer();
  late String appDirPath;

  static const MethodChannel _iosChannel = MethodChannel('fl_clash/core_ios');

  AppPath._internal() {
    appDirPath = join(dirname(Platform.resolvedExecutable));
    if (system.isIOS) {
      _initIOSDirectories();
    } else {
      getApplicationSupportDirectory().then((value) {
        dataDir.complete(value);
      });
      getTemporaryDirectory().then((value) {
        tempDir.complete(value);
      });
      getApplicationCacheDirectory().then((value) {
        cacheDir.complete(value);
      });
    }
  }

  /// On iOS the home directory must live in the app group container so both
  /// the app and the Network Extension can reach it. Falls back to the app's
  /// own support directory when the native side has not been wired up yet
  /// (for example when running on the simulator without the extension).
  Future<void> _initIOSDirectories() async {
    String? groupPath;
    try {
      groupPath = await _iosChannel.invokeMethod<String>(
        'getGroupContainerPath',
      );
    } catch (error) {
      commonPrint.log(
        'Unable to resolve iOS group container, falling back to app container: $error',
        logLevel: LogLevel.warning,
      );
    }
    final support = await getApplicationSupportDirectory();
    final temp = await getTemporaryDirectory();
    final cache = await getApplicationCacheDirectory();
    if (groupPath != null && groupPath.isNotEmpty) {
      final dir = Directory(groupPath);
      dataDir.complete(dir);
      tempDir.complete(Directory(join(groupPath, 'tmp')));
      cacheDir.complete(Directory(join(groupPath, 'Library', 'Caches')));
    } else {
      dataDir.complete(support);
      tempDir.complete(temp);
      cacheDir.complete(cache);
    }
  }

  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  String get executableExtension {
    return system.isWindows ? '.exe' : '';
  }

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get corePath {
    return join(executableDirPath, 'FlClashCore$executableExtension');
  }

  String get helperPath {
    return join(executableDirPath, '$appHelperService$executableExtension');
  }

  Future<String> get downloadDirPath async {
    final directory = await _downloadDir;
    return directory?.path ?? await homeDirPath;
  }

  Future<String> get homeDirPath async {
    final directory = await dataDir.future;
    return directory.path;
  }

  Future<String> get databasePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'database.sqlite');
  }

  Future<String> get backupFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'backup.zip');
  }

  Future<String> get restoreDirPath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'restore');
  }

  Future<String> get tempFilePath async {
    final mTempDir = await tempDir.future;
    return join(mTempDir.path, 'temp${utils.id}');
  }

  Future<String> get lockFilePath async {
    final homeDirPath = await appPath.homeDirPath;
    return join(homeDirPath, 'FlClash.lock');
  }

  Future<String> get configFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'config.yaml');
  }

  Future<String> get sharedFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'shared.json');
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'shared_preferences.json');
  }

  Future<String> get profilesPath async {
    final directory = await dataDir.future;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String fileName) async {
    return join(await profilesPath, '$fileName.yaml');
  }

  Future<String> get scriptsDirPath async {
    final path = await homeDirPath;
    return join(path, 'scripts');
  }

  Future<String> getScriptPath(String fileName) async {
    final path = await scriptsDirPath;
    return join(path, '$fileName.js');
  }

  Future<String> getIconsCacheDir() async {
    final directory = await cacheDir.future;
    return join(directory.path, 'icons');
  }

  Future<String> getProvidersRootPath() async {
    final directory = await profilesPath;
    return join(directory, 'providers');
  }

  Future<String> getProvidersDirPath(String id) async {
    final directory = await profilesPath;
    return join(directory, 'providers', id);
  }

  Future<String> getProvidersFilePath(
    String id,
    String type,
    String url,
  ) async {
    final directory = await profilesPath;
    return join(directory, 'providers', id, type, url.toMd5());
  }

  Future<String> get tempPath async {
    final directory = await tempDir.future;
    return directory.path;
  }
}

final appPath = AppPath();

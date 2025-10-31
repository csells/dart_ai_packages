import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_mcp/api.dart';
import 'package:dart_mcp/client.dart';
import 'package:dtd/dtd.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterAppAutomation E2E via MCP', () {
    late _AutomationE2EHarness harness;

    setUpAll(() async {
      harness = await _AutomationE2EHarness.start();
    });

    tearDownAll(() async {
      await harness.dispose();
    });

    test('drives the counter app, captures screenshots, and hot reloads theme',
        () async {
      await harness.waitForAppReady();

      final initialShot = await harness.screenshot(pixelRatio: 1.0);
      final initialImage = _decodeImage(initialShot);
      expect(initialImage.width, greaterThan(0));
      expect(initialImage.height, greaterThan(0));

      await harness.tap(byKey: 'incrementFab');
      await harness.waitForIdle();

      final postTapShot = await harness.screenshot(pixelRatio: 1.0);
      final postTapImage = _decodeImage(postTapShot);
      expect(_countChangedPixels(initialImage, postTapImage), greaterThan(0));

      final semantics = await harness.semantics();
      expect(
        _semanticsContainsLabel(semantics['semantics'] as Map<String, Object?>?, 'counter:1'),
        isTrue,
        reason: 'Semantics tree should report the incremented counter.',
      );

      await harness.updateThemeSeedColor(const Color(0xFFE65100));
      await harness.hotReload();
      await harness.waitForIdle();

      final reloadedShot = await harness.screenshot(pixelRatio: 1.0);
      final reloadedImage = _decodeImage(reloadedShot);
      final initialAppBarColor = _colorAt(initialImage, 10, 10);
      final reloadedAppBarColor = _colorAt(reloadedImage, 10, 10);
      expect(reloadedAppBarColor, isNot(equals(initialAppBarColor)));
      expect(reloadedAppBarColor.red, greaterThan(initialAppBarColor.red));

      expect(
        harness.automationLogs.where((line) => line.contains('app.screenshot')).length,
        greaterThanOrEqualTo(3),
        reason: 'Expected automation debug logs for screenshot handling.',
      );
      expect(
        harness.automationLogs.any((line) => line.contains('Resolving tap selector')),
        isTrue,
        reason: 'Expected automation logs for tap resolution.',
      );
      expect(harness.serverLogs, isNotEmpty, reason: 'MCP server logs should be captured.');
    });
  });
}

img.Image _decodeImage(Map<String, Object?> payload) {
  final pngBase64 = payload['pngBase64'] as String?;
  expect(pngBase64, isNotNull, reason: 'Expected pngBase64 in screenshot payload');
  final bytes = base64Decode(pngBase64!);
  final decoded = img.decodePng(bytes);
  expect(decoded, isNotNull, reason: 'Expected valid PNG image data');
  return decoded!;
}

String _describeContent(List<Content>? content) {
  if (content == null || content.isEmpty) {
    return '';
  }
  return content.map((entry) => entry.toString()).join('\n');
}

int _countChangedPixels(img.Image a, img.Image b) {
  expect(a.width, equals(b.width));
  expect(a.height, equals(b.height));
  var diff = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      if (a.getPixel(x, y) != b.getPixel(x, y)) {
        diff++;
      }
    }
  }
  return diff;
}

bool _semanticsContainsLabel(Map<String, Object?>? node, String label) {
  if (node == null) {
    return false;
  }
  if (node['label'] == label) {
    return true;
  }
  final children = node['children'];
  if (children is List) {
    for (final child in children.cast<Map<String, Object?>>()) {
      if (_semanticsContainsLabel(child, label)) {
        return true;
      }
    }
  }
  return false;
}

Color _colorAt(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  return Color.fromARGB(
    img.getAlpha(pixel),
    img.getRed(pixel),
    img.getGreen(pixel),
    img.getBlue(pixel),
  );
}

class _AutomationE2EHarness {
  _AutomationE2EHarness._({
    required this.projectDir,
    required this.flutterProcess,
    required this.flutterStdoutQueue,
    required this.flutterStdoutSubscription,
    required this.flutterStderrSubscription,
    required this.dtdProcess,
    required this.dtd,
    required this.dtdSecret,
    required this.serverProcess,
    required this.client,
    required this.connection,
    required this.serverLogSubscription,
    required this.automationLogs,
    required this.serverLogs,
  });

  final Directory projectDir;
  final Process flutterProcess;
  final StreamQueue<String> flutterStdoutQueue;
  final StreamSubscription<String> flutterStdoutSubscription;
  final StreamSubscription<String> flutterStderrSubscription;
  final Process dtdProcess;
  final DartToolingDaemon dtd;
  final String dtdSecret;
  final Process serverProcess;
  final _AutomationTestClient client;
  final ServerConnection connection;
  final StreamSubscription<LoggingMessageNotification> serverLogSubscription;

  final List<String> automationLogs;
  final List<String> serverLogs;

  String? _vmServiceUri;

  static Future<_AutomationE2EHarness> start() async {
    final packageDir = Directory.current.absolute;
    final templateDir = Directory(p.join(
      packageDir.path,
      'test',
      'integration_fixtures',
      'automation_counter_app',
    ));
    final workingDir = await Directory.systemTemp.createTemp('automation_counter_app_');
    await _copyDirectory(templateDir, workingDir);
    await _rewritePubspec(workingDir, packageDir.path);

    await _runFlutterPubGet(workingDir);

    final automationLogs = <String>[];
    final serverLogs = <String>[];

    final dtdProcess = await Process.start('dart', ['tooling-daemon', '--machine']);
    final dtdStdoutStream =
        dtdProcess.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final dtdFirstLine = await dtdStdoutStream.first;
    final dtdInfo = jsonDecode(dtdFirstLine) as Map<String, Object?>;
    final toolingDetails = dtdInfo['tooling_daemon_details'] as Map<String, Object?>;
    final dtdUri = toolingDetails['uri'] as String;
    final dtdSecret = toolingDetails['trusted_client_secret'] as String;

    // Drain any additional output for debugging purposes.
    dtdStdoutStream.listen((_) {});
    dtdProcess.stderr.transform(utf8.decoder).listen((_) {});

    final dtd = await DartToolingDaemon.connect(Uri.parse(dtdUri));

    final serverProcess = await Process.start('dart', ['run', '../dart_mcp_server:main'],
        workingDirectory: packageDir.path);
    serverProcess.stderr.transform(utf8.decoder).listen((line) {
      serverLogs.add('[stderr] $line');
    });

    final client = _AutomationTestClient();
    final connection = client.connectStdioServer(serverProcess.stdin, serverProcess.stdout);
    final initializeResult = await connection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    expect(
      initializeResult.protocolVersion?.isSupported,
      isTrue,
      reason: 'Failed to negotiate MCP protocol version: ${initializeResult.protocolVersion}',
    );
    connection.notifyInitialized(InitializedNotification());

    final serverLogSubscription = connection.onLog.listen((log) {
      serverLogs.add(log.message ?? '');
    });

    final flutterProcess = await Process.start(
      'flutter',
      [
        'run',
        '--no-devtools',
        '-d',
        'flutter-tester',
        'lib/main.dart',
      ],
      workingDirectory: workingDir.path,
      runInShell: true,
    );

    final stdoutStream =
        flutterProcess.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final stdoutSubscription = stdoutStream.listen(automationLogs.add);
    final stderrSubscription =
        flutterProcess.stderr.transform(utf8.decoder).listen((line) {
      automationLogs.add('[stderr] $line');
    });
    final stdoutQueue = StreamQueue(stdoutStream);

    final harness = _AutomationE2EHarness._(
      projectDir: workingDir,
      flutterProcess: flutterProcess,
      flutterStdoutQueue: stdoutQueue,
      flutterStdoutSubscription: stdoutSubscription,
      flutterStderrSubscription: stderrSubscription,
      dtdProcess: dtdProcess,
      dtd: dtd,
      dtdSecret: dtdSecret,
      serverProcess: serverProcess,
      client: client,
      connection: connection,
      serverLogSubscription: serverLogSubscription,
      automationLogs: automationLogs,
      serverLogs: serverLogs,
    );

    await harness._captureVmServiceUri();

    await dtd.registerVmService(
      uri: harness._vmServiceUri!,
      secret: dtdSecret,
      name: 'automation-counter-app',
    );

    final connectResult = await connection.callTool(
      CallToolRequest(
        name: 'connect_dart_tooling_daemon',
        arguments: {ParameterNames.uri: dtdUri},
      ),
    );
    expect(
      connectResult.isError,
      isNot(true),
      reason: _describeContent(connectResult.content),
    );

    return harness;
  }

  Future<void> waitForAppReady() async {
    await _retry(() async {
      await waitForIdle();
    });
  }

  Future<void> waitForIdle() async {
    await callAppControl('waitForIdle');
  }

  Future<Map<String, Object?>> screenshot({double? pixelRatio}) {
    return callAppControl('screenshot', arguments: {
      if (pixelRatio != null) 'pixelRatio': pixelRatio,
    });
  }

  Future<Map<String, Object?>> semantics() {
    return callAppControl('getSemantics');
  }

  Future<void> tap({required String byKey}) async {
    final result = await callAppControl('tap', arguments: {
      'selector': {'byKey': byKey},
    });
    expect(result['performed'], isTrue, reason: 'Tap failed: $result');
  }

  Future<void> updateThemeSeedColor(Color color) async {
    final themeFile = File(p.join(projectDir.path, 'lib', 'theme.dart'));
    final contents = await themeFile.readAsString();
    final newLiteral = 'Color(0x${color.value.toRadixString(16).padLeft(8, '0').toUpperCase()})';
    final updated = contents.replaceFirst(RegExp(r'Color\(0x[0-9A-Fa-f]{8}\)'), newLiteral);
    if (updated == contents) {
      throw StateError('Failed to update theme color literal.');
    }
    await themeFile.writeAsString(updated);
  }

  Future<void> hotReload() async {
    flutterProcess.stdin.writeln('R');
    await flutterProcess.stdin.flush();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      Duration remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        break;
      }
      try {
        final line = await flutterStdoutQueue.next.timeout(remaining);
        if (line.contains('Reloaded') || line.contains('Hot reload')) {
          return;
        }
      } on TimeoutException {
        break;
      }
    }
    throw StateError('Hot reload output not observed.');
  }

  Future<Map<String, Object?>> callAppControl(
    String tool, {
    Map<String, Object?>? arguments,
  }) async {
    CallToolResult? lastResult;
    return _retry<Map<String, Object?>>(() async {
      lastResult = await connection.callTool(
        CallToolRequest(
          name: 'app_control.$tool',
          arguments: arguments,
        ),
      );
      if (lastResult!.isError == true) {
        throw StateError(
          'app_control.$tool returned error: ${_describeContent(lastResult!.content)}',
        );
      }
      final structured = lastResult!.structuredContent;
      if (structured is! Map<String, Object?>) {
        throw StateError('Expected structured response for $tool, got: $structured');
      }
      if (structured['ok'] != true) {
        throw StateError('Extension reported error for $tool: $structured');
      }
      final payload = structured['result'];
      if (payload is Map<String, Object?>) {
        return payload;
      }
      if (payload is Map) {
        return payload.cast<String, Object?>();
      }
      return <String, Object?>{};
    }, onFailure: () {
      if (lastResult != null) {
        automationLogs.add(
          'callAppControl failure: ${_describeContent(lastResult!.content)}',
        );
      }
    });
  }

  Future<void> _captureVmServiceUri() async {
    while (await flutterStdoutQueue.hasNext) {
      final line = await flutterStdoutQueue.next;
      if (line.contains('A Dart VM Service') || line.contains('The Dart VM service')) {
        final startIndex = line.indexOf('http');
        if (startIndex != -1) {
          final uri = line.substring(startIndex).trim();
          _vmServiceUri = uri.replaceFirst('http:', 'ws:');
          break;
        }
      }
    }
    if (_vmServiceUri == null) {
      fail('Failed to locate VM service URI from flutter run output.');
    }
  }

  Future<void> dispose() async {
    await _safe(() => connection.shutdown());
    await _safe(() => serverLogSubscription.cancel());
    await _safe(() => flutterStdoutSubscription.cancel());
    await _safe(() => flutterStdoutQueue.cancel());
    await _safe(() => flutterStderrSubscription.cancel());

    flutterProcess.stdin.writeln('q');
    await flutterProcess.stdin.flush();
    await flutterProcess.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      flutterProcess.kill(ProcessSignal.sigkill);
      return -1;
    });

    await serverProcess.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      serverProcess.kill(ProcessSignal.sigkill);
      return -1;
    });

    dtdProcess.kill(ProcessSignal.sigterm);
    await dtdProcess.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      dtdProcess.kill(ProcessSignal.sigkill);
      return -1;
    });

    await _safe(() => dtd.close());
    if (projectDir.existsSync()) {
      await projectDir.delete(recursive: true);
    }
  }

  static Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relativePath = p.relative(entity.path, from: source.path);
      final targetPath = p.join(destination.path, relativePath);
      if (entity is File) {
        final targetFile = File(targetPath);
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(await entity.readAsBytes());
      } else if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      }
    }
  }

  static Future<void> _rewritePubspec(Directory workingDir, String packagePath) async {
    final pubspecFile = File(p.join(workingDir.path, 'pubspec.yaml'));
    final original = await pubspecFile.readAsString();
    final replacementPath = Platform.isWindows
        ? packagePath.replaceAll('\\', '\\\\')
        : packagePath;
    final updated = original.replaceAll('__FLUTTER_APP_AUTOMATION_PATH__', replacementPath);
    await pubspecFile.writeAsString(updated);
  }

  static Future<void> _runFlutterPubGet(Directory workingDir) async {
    final result = await Process.run(
      'flutter',
      ['pub', 'get'],
      workingDirectory: workingDir.path,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw StateError('flutter pub get failed: ${result.stderr}');
    }
  }

  Future<T> _retry<T>(Future<T> Function() action, {void Function()? onFailure}) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        return await action();
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        onFailure?.call();
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  Future<void> _safe(FutureOr<void> Function() callback) async {
    try {
      await callback();
    } catch (_) {}
  }
}

class _AutomationTestClient extends MCPClient {
  _AutomationTestClient()
      : super(
          Implementation(
            name: 'flutter_app_automation_test_client',
            version: '0.0.1',
          ),
        );
}

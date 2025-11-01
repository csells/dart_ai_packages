library flutter_app_automation;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Provides service extensions that expose Flutter application state and
/// semantics to external tooling during development.
///
/// Call [install] early in `main()` (ideally before [runApp]) and wrap the root
/// widget with [wrapApp] so screenshots can be captured.
class FlutterAppAutomation {
  FlutterAppAutomation._();

  static const _objectGroupName = 'flutter-app-automation';

  static final GlobalKey _rootBoundaryKey =
      GlobalKey(debugLabel: _objectGroupName);

  static bool _installed = false;

  static AutomationConfig _config = const AutomationConfig();

  static void _log(String message, {Object? details}) {
    if (!_config.debugLogging) {
      return;
    }
    final sink = _config.logSink;
    final buffer = StringBuffer('[flutter_app_automation] $message');
    if (details != null) {
      buffer
        ..write(': ')
        ..write(_stringify(details));
    }
    final output = buffer.toString();
    if (sink != null) {
      sink(output);
    } else {
      debugPrint(output);
    }
  }

  static String _stringify(Object? details) {
    if (details == null) {
      return 'null';
    }
    if (details is String) {
      return details;
    }
    try {
      return jsonEncode(details);
    } catch (_) {
      return details.toString();
    }
  }

  /// Wrap the root widget with a [RepaintBoundary] so screenshots can be
  /// captured reliably.
  static Widget wrapApp(Widget app) {
    return RepaintBoundary(key: _rootBoundaryKey, child: app);
  }

  /// Installs the automation service extensions.
  ///
  /// Extensions are only enabled when asserts are active or when
  /// [AutomationConfig.enableInProfile] is true. In release builds the method
  /// has no effect.
  static void install({AutomationConfig config = const AutomationConfig()}) {
    if (_installed) {
      return;
    }

    assert(() {
      _installed = true;
      _config = config;
      _registerExtensions();
      return true;
    }());

    if (!_installed && config.enableInProfile && kProfileMode) {
      _installed = true;
      _config = config;
      _registerExtensions();
    }
  }

  static void _registerExtensions() {
    SemanticsBinding.instance.ensureSemantics();

    _register('app.getWidgetTree', _handleGetWidgetTree);
    _register('app.getSemantics', _handleGetSemantics);
    _register('app.tap', _handleTap);
    _register('app.enterText', _handleEnterText);
    _register('app.scroll', _handleScroll);
    _register('app.waitForIdle', _handleWaitForIdle);
    _register('app.screenshot', _handleScreenshot);
  }

  static void _register(
    String name,
    Future<Map<String, Object?>> Function(Map<String, Object?> payload) handler,
  ) {
    _log('Registering service extension', details: 'ext.app.$name');
    developer.registerExtension(
      'ext.app.$name',
      (method, parameters) async {
        try {
          final payload = _decodePayload(parameters);
          _log('Handling $name request', details: payload);
          final result = await handler(payload);
          _log('Completed $name request', details: result);
          final response = {'ok': true, 'result': result};
          return developer.ServiceExtensionResponse.result(
            jsonEncode(response),
          );
        } catch (error, stackTrace) {
          _log('Error handling $name request', details: '$error');
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'flutter_app_automation',
              informationCollector: () sync* {
                yield DiagnosticsProperty<String>('serviceExtension', name);
              },
            ),
          );
          final response = {'ok': false, 'error': '$error'};
          return developer.ServiceExtensionResponse.result(
            jsonEncode(response),
          );
        }
      },
    );
  }

  static Map<String, Object?> _decodePayload(Map<String, String> parameters) {
    if (parameters.isEmpty) {
      return const {};
    }
    final payload = parameters['payload'];
    if (payload == null) {
      return parameters;
    }
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    return const {};
  }

  static Future<Map<String, Object?>> _handleGetSemantics(
    Map<String, Object?> payload,
  ) async {
    final int? nodeId;
    if (payload['nodeId'] is int) {
      nodeId = payload['nodeId'] as int;
    } else if (payload['nodeId'] is num) {
      nodeId = (payload['nodeId'] as num).toInt();
    } else {
      nodeId = null;
    }

    final owner = RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    final root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      _log('Semantics not enabled when handling getSemantics');
      return {'semantics': null, 'reason': 'Semantics not enabled'};
    }

    final SemanticsNode target;
    if (nodeId != null) {
      final found = _findSemanticsNodeById(root, nodeId);
      if (found == null) {
        _log('Semantics node not found for getSemantics', details: nodeId);
        return {'semantics': null, 'reason': 'Node $nodeId not found'};
      }
      target = found;
    } else {
      target = root;
    }

    final serialized = _serializeSemantics(target, includeChildren: true);
    return {'semantics': serialized};
  }

  static SemanticsNode? _findSemanticsNodeById(SemanticsNode node, int id) {
    if (node.id == id) {
      return node;
    }
    SemanticsNode? match;
    node.visitChildren((child) {
      match ??= _findSemanticsNodeById(child, id);
      return match == null;
    });
    return match;
  }

  static Map<String, Object?> _serializeSemantics(
    SemanticsNode node, {
    required bool includeChildren,
  }) {
    final data = node.getSemanticsData();
    final element = _elementForSemanticsNode(node);
    final rect = node.rect;
    final transform = node.transform;
    return {
      'id': node.id,
      'label': data.label,
      'value': data.value,
      'hint': data.hint,
      'flags': data.flagsCollection.toStrings().toList(),
      'actions': [
        for (final action in SemanticsAction.values)
          if (data.hasAction(action)) action.name,
      ],
      'rect': _rectToMap(rect),
      'globalRect': _rectToMap(_semanticsGlobalRect(node)),
      if (transform != null) 'transform': transform.storage.toList(),
      'widgetType': element?.widget.runtimeType.toString(),
      'widgetKey': element?.widget.key?.toString(),
      if (element?.widget is Text) 'text': (element!.widget as Text).data,
      if (includeChildren) 'children': _collectChildren(node),
    };
  }

  static Future<Map<String, Object?>> _handleTap(
    Map<String, Object?> payload,
  ) async {
    final selector = AutomationSelector.fromJson(payload['selector']);
    if (selector == null) {
      throw ArgumentError('Missing selector');
    }

    _log('Resolving tap selector', details: selector.toJson());
    final target = _resolveTarget(selector);
    if (target == null) {
      _log('Tap selector resolved to no node', details: selector.toJson());
      return {'performed': false, 'reason': 'No node matched selector'};
    }

    final owner = RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    if (owner == null) {
      _log('Semantics owner missing when attempting tap');
      return {'performed': false, 'reason': 'Semantics not enabled'};
    }

    _log('Performing tap', details: {'nodeId': target.node.id});
    owner.performAction(target.node.id, SemanticsAction.tap);
    await _waitForSettleFrames();
    return {'performed': true, 'nodeId': target.node.id};
  }

  static Future<Map<String, Object?>> _handleEnterText(
    Map<String, Object?> payload,
  ) async {
    final selector = AutomationSelector.fromJson(payload['selector']);
    final text = payload['text'] as String?;
    if (selector == null || text == null) {
      throw ArgumentError('Missing selector or text');
    }

    _log('Resolving enterText selector', details: selector.toJson());
    final target = _resolveTarget(selector);
    if (target == null) {
      _log('Enter text selector resolved to no node',
          details: selector.toJson());
      return {'performed': false, 'reason': 'No node matched selector'};
    }

    final element = target.element;
    if (element != null) {
      final focusNode = Focus.maybeOf(element, scopeOk: true);
      focusNode?.requestFocus();
    }

    final owner = RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    if (owner == null) {
      _log('Semantics owner missing when attempting enterText');
      return {'performed': false, 'reason': 'Semantics not enabled'};
    }

    _log('Setting text via semantics', details: {
      'nodeId': target.node.id,
      'length': text.length,
    });
    owner.performAction(target.node.id, SemanticsAction.setText, text);

    await _waitForSettleFrames();
    return {'performed': true, 'nodeId': target.node.id};
  }

  static Future<Map<String, Object?>> _handleScroll(
    Map<String, Object?> payload,
  ) async {
    final selector = AutomationSelector.fromJson(payload['selector']);
    if (selector == null) {
      throw ArgumentError('Missing selector');
    }

    _log('Resolving scroll selector', details: selector.toJson());
    final target = _resolveTarget(selector);
    if (target == null) {
      _log('Scroll selector resolved to no node', details: selector.toJson());
      return {'performed': false, 'reason': 'No node matched selector'};
    }

    final element = target.element;
    if (element == null) {
      _log('Unable to resolve widget element for scroll selector',
          details: selector.toJson());
      return {'performed': false, 'reason': 'Unable to resolve widget context'};
    }

    final scrollable = _findScrollable(element);
    if (scrollable == null) {
      _log('No Scrollable found for selector', details: selector.toJson());
      return {'performed': false, 'reason': 'No Scrollable found for selector'};
    }

    final position = scrollable.position;
    const curve = Curves.easeInOut;
    final duration = _config.scrollAnimationDuration;

    final toOffset = payload['toOffset'] as Map<String, Object?>?;
    if (toOffset != null) {
      final double? x = _asDouble(toOffset['x']);
      final double? y = _asDouble(toOffset['y']);
      if (position.axis == Axis.horizontal && x != null) {
        final targetPixels =
            x.clamp(position.minScrollExtent, position.maxScrollExtent);
        await position.animateTo(targetPixels,
            duration: duration, curve: curve);
      } else if (position.axis == Axis.vertical && y != null) {
        final targetPixels =
            y.clamp(position.minScrollExtent, position.maxScrollExtent);
        await position.animateTo(targetPixels,
            duration: duration, curve: curve);
      } else {
        return {'performed': false, 'reason': 'Missing axis offset for scroll'};
      }
    } else {
      final dx = _asDouble(payload['dx']) ?? 0;
      final dy = _asDouble(payload['dy']) ?? 0;
      final delta = position.axis == Axis.horizontal ? dx : dy;
      final targetPixels = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      await position.animateTo(targetPixels, duration: duration, curve: curve);
    }

    await _waitForSettleFrames();
    return {
      'performed': true,
      'nodeId': target.node.id,
      'pixels': position.pixels
    };
  }

  static Future<Map<String, Object?>> _handleWaitForIdle(
    Map<String, Object?> payload,
  ) async {
    final timeoutMs = (payload['timeoutMs'] is num)
        ? (payload['timeoutMs'] as num).toInt()
        : _config.defaultTimeout.inMilliseconds;
    final settleFrames = (payload['settleFrames'] is num)
        ? (payload['settleFrames'] as num).toInt()
        : _config.settleFrames;

    _log('Waiting for idle', details: {
      'timeoutMs': timeoutMs,
      'settleFrames': settleFrames,
    });
    final stopwatch = Stopwatch()..start();
    var stableFrames = 0;
    while (stopwatch.elapsedMilliseconds < timeoutMs) {
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(Duration.zero);
      if (_isUiIdle) {
        stableFrames++;
        if (stableFrames >= settleFrames) {
          _log('UI settled', details: {
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'frames': stableFrames,
          });
          return {
            'settled': true,
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'frames': stableFrames,
          };
        }
      } else {
        stableFrames = 0;
      }
    }

    _log('Idle wait timed out', details: {
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'frames': stableFrames,
    });
    return {
      'settled': false,
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'frames': stableFrames,
      'reason': 'Timeout waiting for idle',
    };
  }

  static Future<Map<String, Object?>> _handleScreenshot(
    Map<String, Object?> payload,
  ) async {
    final pixelRatio = _asDouble(payload['pixelRatio']);
    final highlightSelector = AutomationSelector.fromJson(payload['highlight']);

    final boundaryContext = _rootBoundaryKey.currentContext;
    final renderObject = boundaryContext?.findRenderObject();
    final repaintBoundary =
        renderObject is RenderRepaintBoundary ? renderObject : null;
    if (repaintBoundary == null) {
      _log('Root repaint boundary not found when taking screenshot');
      return {'pngBase64': null, 'reason': 'Root boundary not found'};
    }

    final double ratio = pixelRatio ??
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    _log('Capturing screenshot', details: {
      'pixelRatio': ratio,
      if (highlightSelector != null) 'highlight': highlightSelector.toJson(),
    });
    final ui.Image image = await repaintBoundary.toImage(pixelRatio: ratio);
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      _log('Unable to encode screenshot image bytes');
      return {'pngBase64': null, 'reason': 'Unable to encode screenshot'};
    }

    Uint8List pngBytes = bytes.buffer.asUint8List();
    if (highlightSelector != null) {
      final target = _resolveTarget(highlightSelector);
      if (target != null) {
        _log('Applying highlight overlay', details: {
          'nodeId': target.node.id,
          'selector': highlightSelector.toJson(),
        });
        pngBytes = await _drawHighlight(pngBytes, target.node, ratio);
      }
    }

    return {'pngBase64': base64Encode(pngBytes)};
  }

  static Future<void> _waitForSettleFrames() async {
    await _handleWaitForIdle({
      'timeoutMs': _config.defaultTimeout.inMilliseconds,
      'settleFrames': _config.settleFrames,
    });
  }

  static bool get _isUiIdle {
    final scheduler = SchedulerBinding.instance;
    return !scheduler.hasScheduledFrame &&
        scheduler.transientCallbackCount == 0;
  }

  static AutomationTarget? _resolveTarget(AutomationSelector selector) {
    final owner = RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    final root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return null;
    }

    AutomationTarget? found;
    void visit(SemanticsNode node) {
      if (found != null) {
        return;
      }
      final element = _elementForSemanticsNode(node);
      if (element != null && _selectorMatches(selector, node, element)) {
        found = AutomationTarget(node, element);
        return;
      }
      node.visitChildren((child) {
        visit(child);
        return found == null;
      });
    }

    visit(root);
    return found;
  }

  static bool _selectorMatches(
    AutomationSelector selector,
    SemanticsNode node,
    Element element,
  ) {
    final data = node.getSemanticsData();
    final widget = element.widget;
    final keyString = widget.key?.toString();
    final typeString = widget.runtimeType.toString();
    final textData = widget is Text ? widget.data : null;

    if (selector.byKey != null) {
      if (keyString == null || !keyString.contains(selector.byKey!)) {
        return false;
      }
    }

    if (selector.bySemanticsLabel != null) {
      if (data.label != selector.bySemanticsLabel) {
        return false;
      }
    }

    if (selector.byType != null) {
      if (typeString != selector.byType) {
        return false;
      }
    }

    if (selector.byText != null) {
      if (textData != selector.byText) {
        return false;
      }
    }

    if (selector.path != null && selector.path!.isNotEmpty) {
      final path = _runtimeTypePath(element);
      if (!_endsWithPath(path, selector.path!)) {
        return false;
      }
    }

    return true;
  }

  static List<String> _runtimeTypePath(Element element) {
    final types = <String>[element.widget.runtimeType.toString()];
    element.visitAncestorElements((ancestor) {
      types.add(ancestor.widget.runtimeType.toString());
      return true;
    });
    return types.reversed.toList(growable: false);
  }

  static bool _endsWithPath(List<String> fullPath, List<String> candidate) {
    if (candidate.length > fullPath.length) {
      return false;
    }
    for (var i = 0; i < candidate.length; i++) {
      if (fullPath[fullPath.length - candidate.length + i] != candidate[i]) {
        return false;
      }
    }
    return true;
  }

  static Element? _elementForSemanticsNode(SemanticsNode node) {
    final owner = RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    if (owner == null) {
      return null;
    }
    SemanticsNode? current = node;
    while (current != null) {
      final nodeId = current.id;
      final renderObjectOwner = RendererBinding.instance.rootPipelineOwner;
      RenderObject? foundRenderObject;
      void visitRenderObject(RenderObject? renderObject) {
        if (renderObject == null || foundRenderObject != null) {
          return;
        }
        if (renderObject is RenderSemanticsGestureHandler ||
            renderObject is RenderSemanticsAnnotations) {
          final semanticsNode = renderObject.debugSemantics;
          if (semanticsNode?.id == nodeId) {
            foundRenderObject = renderObject;
            return;
          }
        }
        renderObject.visitChildren(visitRenderObject);
      }

      visitRenderObject(renderObjectOwner.rootNode);
      final creator = foundRenderObject?.debugCreator;
      if (creator is DebugCreator) {
        return creator.element;
      }
      current = current.parent;
    }
    return null;
  }

  static ScrollableState? _findScrollable(Element element) {
    if (element is StatefulElement && element.state is ScrollableState) {
      return element.state as ScrollableState;
    }
    ScrollableState? scrollable;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
        scrollable = ancestor.state as ScrollableState;
        return false;
      }
      return true;
    });
    return scrollable;
  }

  static Future<Uint8List> _drawHighlight(
    Uint8List pngBytes,
    SemanticsNode node,
    double pixelRatio,
  ) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(
      pictureRecorder,
      Rect.fromLTWH(
          0, 0, frame.image.width.toDouble(), frame.image.height.toDouble()),
    );
    final paint = Paint()
      ..color = const Color(0x66FF5722)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;
    canvas.drawImage(frame.image, Offset.zero, Paint());
    final rect = _semanticsGlobalRect(node);
    final scaledRect = Rect.fromLTWH(
      rect.left * pixelRatio,
      rect.top * pixelRatio,
      rect.width * pixelRatio,
      rect.height * pixelRatio,
    );
    canvas.drawRect(scaledRect, paint);
    final highlighted = await pictureRecorder
        .endRecording()
        .toImage(frame.image.width, frame.image.height);
    final bytes = await highlighted.toByteData(format: ui.ImageByteFormat.png);
    codec.dispose();
    frame.image.dispose();
    return bytes!.buffer.asUint8List();
  }

  static Rect _semanticsGlobalRect(SemanticsNode node) {
    Rect rect = node.rect;
    SemanticsNode? current = node;
    while (current != null) {
      final transform = current.transform;
      if (transform != null) {
        rect = MatrixUtils.transformRect(transform, rect);
      }
      final parent = current.parent;
      if (parent != null) {
        rect = rect.shift(parent.rect.topLeft);
      }
      current = parent;
    }
    return rect;
  }

  static Map<String, Object?> _rectToMap(Rect rect) {
    return <String, Object?>{
      'left': rect.left,
      'top': rect.top,
      'right': rect.right,
      'bottom': rect.bottom,
      'width': rect.width,
      'height': rect.height,
    };
  }

  static double? _asDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static List<Map<String, Object?>> _collectChildren(SemanticsNode node) {
    final children = <SemanticsNode>[];
    node.visitChildren((child) {
      children.add(child);
      return true;
    });
    return [
      for (final child in children)
        _serializeSemantics(child, includeChildren: true),
    ];
  }

  static Future<Map<String, Object?>> _handleGetWidgetTree(
    Map<String, Object?> payload,
  ) async {
    return {
      'error':
          'Widget tree inspection not yet implemented. Use Flutter DevTools '
              'or the VM service inspector extensions directly.',
    };
  }
}

/// Configuration for [FlutterAppAutomation].
@immutable
class AutomationConfig {
  const AutomationConfig({
    this.enableInProfile = false,
    this.defaultTimeout = const Duration(seconds: 10),
    this.settleFrames = 2,
    this.scrollAnimationDuration = const Duration(milliseconds: 200),
    this.debugLogging = false,
    this.logSink,
  });

  final bool enableInProfile;

  final Duration defaultTimeout;

  final int settleFrames;

  final Duration scrollAnimationDuration;

  final bool debugLogging;

  final void Function(String message)? logSink;
}

/// Represents a selector used to find widgets or semantics nodes.
class AutomationSelector {
  AutomationSelector({
    this.byKey,
    this.bySemanticsLabel,
    this.byType,
    this.byText,
    this.path,
  });

  static AutomationSelector? fromJson(Object? json) {
    if (json is Map<String, Object?>) {
      return AutomationSelector(
        byKey: json['byKey'] as String?,
        bySemanticsLabel: json['bySemanticsLabel'] as String?,
        byType: json['byType'] as String?,
        byText: json['byText'] as String?,
        path: (json['path'] as List?)?.cast<String>(),
      );
    }
    return null;
  }

  final String? byKey;
  final String? bySemanticsLabel;
  final String? byType;
  final String? byText;
  final List<String>? path;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (byKey != null) 'byKey': byKey,
      if (bySemanticsLabel != null) 'bySemanticsLabel': bySemanticsLabel,
      if (byType != null) 'byType': byType,
      if (byText != null) 'byText': byText,
      if (path != null) 'path': path,
    };
  }
}

class AutomationTarget {
  AutomationTarget(this.node, this.element);

  final SemanticsNode node;
  final Element? element;
}

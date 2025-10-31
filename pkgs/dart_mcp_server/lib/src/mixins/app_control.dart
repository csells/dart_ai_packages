// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';

import 'dtd.dart';

/// Provides app control tools that proxy automation requests to a running
/// Flutter application via VM service extensions.
base mixin AppControlSupport on DartToolingDaemonSupport {
  static final Schema _selectorSchema = Schema.combined(
    description: 'Selects a widget or semantics node to target.',
    oneOf: [
      Schema.object(
        description: 'Match by ValueKey string representation.',
        properties: {
          'byKey': Schema.string(
            description: 'Sub-string to match against widget ValueKey.toString().',
          ),
        },
        required: const ['byKey'],
      ),
      Schema.object(
        description: 'Match by semantics label.',
        properties: {
          'bySemanticsLabel': Schema.string(description: 'Exact semantics label to match.'),
        },
        required: const ['bySemanticsLabel'],
      ),
      Schema.object(
        description: 'Match by widget runtime type name.',
        properties: {
          'byType': Schema.string(description: 'Widget runtimeType to match.'),
        },
        required: const ['byType'],
      ),
      Schema.object(
        description: 'Match by Text widget contents.',
        properties: {
          'byText': Schema.string(description: 'Exact text content to match.'),
        },
        required: const ['byText'],
      ),
      Schema.object(
        description: 'Match by widget ancestry path.',
        properties: {
          'path': Schema.list(
            description: 'Runtime type breadcrumbs from root to widget.',
            items: Schema.string(),
          ),
        },
        required: const ['path'],
      ),
    ],
  );

  static final ObjectSchema _extensionResponseSchema = ObjectSchema(
    description: 'Pass-through response from automation service extension.',
    additionalProperties: true,
  );

  static final Tool _getWidgetTreeTool = Tool(
    name: 'app_control.getWidgetTree',
    description: 'Returns the widget summary tree from the running Flutter app.',
    inputSchema: Schema.object(
      properties: {
        'withPreviews': Schema.bool(
          description: 'Include preview data where available.',
        ),
        'subtreeId': Schema.string(
          description: 'Optional inspector node id to return a subtree for.',
        ),
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  static final Tool _getSemanticsTool = Tool(
    name: 'app_control.getSemantics',
    description: 'Returns a semantics subtree identified by nodeId.',
    inputSchema: Schema.object(
      properties: {
        'nodeId': Schema.int(description: 'Optional semantics node id to use as the root.'),
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  static final Tool _tapTool = Tool(
    name: 'app_control.tap',
    description: 'Performs a tap gesture on a widget resolved by selector.',
    inputSchema: Schema.object(
      required: const ['selector'],
      properties: {
        'selector': _selectorSchema,
        'timeoutMs': Schema.int(
          description: 'Optional timeout after the tap to wait for app idle.',
          minimum: 0,
        ),
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  static final Tool _enterTextTool = Tool(
    name: 'app_control.enterText',
    description: 'Sets the text for the target widget.',
    inputSchema: Schema.object(
      required: const ['selector', 'text'],
      properties: {
        'selector': _selectorSchema,
        'text': Schema.string(description: 'Text to enter.'),
        'replace': Schema.bool(
          description: 'Replace existing text. Non-replace mode may be limited.',
        ),
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  static final Tool _scrollTool = Tool(
    name: 'app_control.scroll',
    description: 'Scrolls the widget identified by selector.',
    inputSchema: Schema.object(
      required: const ['selector'],
      properties: {
        'selector': _selectorSchema,
        'dx': Schema.num(description: 'Horizontal delta to scroll.'),
        'dy': Schema.num(description: 'Vertical delta to scroll.'),
        'toOffset': Schema.object(
          description: 'Absolute offset to scroll to.',
          properties: {
            'x': Schema.num(description: 'Horizontal offset in logical pixels.'),
            'y': Schema.num(description: 'Vertical offset in logical pixels.'),
          },
        ),
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  static final Tool _screenshotTool = Tool(
    name: 'app_control.screenshot',
    description: 'Captures a screenshot of the Flutter view.',
    inputSchema: Schema.object(
      properties: {
        'pixelRatio': Schema.num(description: 'Optional pixel ratio override.'),
        'highlight': _selectorSchema,
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  static final Tool _waitForIdleTool = Tool(
    name: 'app_control.waitForIdle',
    description: 'Waits for the Flutter app to finish pending frames.',
    inputSchema: Schema.object(
      properties: {
        'timeoutMs': Schema.int(description: 'Timeout in milliseconds.', minimum: 0),
        'settleFrames': Schema.int(description: 'Number of consecutive idle frames to await.'),
      },
    ),
    outputSchema: _extensionResponseSchema,
  );

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) {
    registerTool(_getWidgetTreeTool, _getWidgetTree);
    registerTool(_getSemanticsTool, _getSemantics);
    registerTool(_tapTool, _tap);
    registerTool(_enterTextTool, _enterText);
    registerTool(_scrollTool, _scroll);
    registerTool(_screenshotTool, _screenshot);
    registerTool(_waitForIdleTool, _waitForIdle);
    return super.initialize(request);
  }

  Future<CallToolResult> _getWidgetTree(CallToolRequest request) {
    final payload = <String, Object?>{};
    final withPreviews = request.arguments?['withPreviews'];
    final subtreeId = request.arguments?['subtreeId'];
    if (withPreviews != null) payload['withPreviews'] = withPreviews;
    if (subtreeId != null) payload['subtreeId'] = subtreeId;
    return _callAppExtension('getWidgetTree', payload);
  }

  Future<CallToolResult> _getSemantics(CallToolRequest request) {
    final payload = <String, Object?>{};
    final nodeId = request.arguments?['nodeId'];
    if (nodeId != null) payload['nodeId'] = nodeId;
    return _callAppExtension('getSemantics', payload);
  }

  Future<CallToolResult> _tap(CallToolRequest request) {
    final payload = <String, Object?>{};
    final selector = request.arguments?['selector'];
    if (selector is! Map<String, Object?>) {
      return _invalidSelector();
    }
    payload['selector'] = selector;
    final timeoutMs = request.arguments?['timeoutMs'];
    if (timeoutMs != null) payload['timeoutMs'] = timeoutMs;
    return _callAppExtension('tap', payload);
  }

  Future<CallToolResult> _enterText(CallToolRequest request) {
    final payload = <String, Object?>{};
    final selector = request.arguments?['selector'];
    final text = request.arguments?['text'];
    if (selector is! Map<String, Object?> || text is! String) {
      return _invalidSelector();
    }
    payload['selector'] = selector;
    payload['text'] = text;
    final replace = request.arguments?['replace'];
    if (replace != null) payload['replace'] = replace;
    return _callAppExtension('enterText', payload);
  }

  Future<CallToolResult> _scroll(CallToolRequest request) {
    final payload = <String, Object?>{};
    final selector = request.arguments?['selector'];
    if (selector is! Map<String, Object?>) {
      return _invalidSelector();
    }
    payload['selector'] = selector;
    final dx = request.arguments?['dx'];
    final dy = request.arguments?['dy'];
    final toOffset = request.arguments?['toOffset'];
    if (dx != null) payload['dx'] = dx;
    if (dy != null) payload['dy'] = dy;
    if (toOffset != null) {
      if (toOffset is! Map<String, Object?>) {
        return _invalidSelector(message: 'toOffset must be an object');
      }
      payload['toOffset'] = toOffset;
    }
    return _callAppExtension('scroll', payload);
  }

  Future<CallToolResult> _screenshot(CallToolRequest request) {
    final payload = <String, Object?>{};
    final pixelRatio = request.arguments?['pixelRatio'];
    final highlight = request.arguments?['highlight'];
    if (pixelRatio != null) payload['pixelRatio'] = pixelRatio;
    if (highlight != null) {
      if (highlight is! Map<String, Object?>) {
        return _invalidSelector();
      }
      payload['highlight'] = highlight;
    }
    return _callAppExtension('screenshot', payload);
  }

  Future<CallToolResult> _waitForIdle(CallToolRequest request) {
    final payload = <String, Object?>{};
    final timeoutMs = request.arguments?['timeoutMs'];
    final settleFrames = request.arguments?['settleFrames'];
    if (timeoutMs != null) payload['timeoutMs'] = timeoutMs;
    if (settleFrames != null) payload['settleFrames'] = settleFrames;
    return _callAppExtension('waitForIdle', payload);
  }

  Future<CallToolResult> _callAppExtension(
    String method,
    Map<String, Object?> payload,
  ) async {
    return callWithActiveVmService((VmService vmService) async {
      try {
        final vm = await vmService.getVM();
        final isolate = vm.isolates?.firstWhere(
          (iso) => iso.id != null,
          orElse: () => throw StateError('No active isolate found.'),
        );
        final isolateId = isolate.id;
        if (isolateId == null) {
          return CallToolResult(
            content: [TextContent(text: 'No active isolate id found.')],
            isError: true,
          );
        }
        final args = <String, Object?>{};
        if (payload.isNotEmpty) {
          args['payload'] = jsonEncode(payload);
        }
        final response = await vmService.callServiceExtension(
          'ext.app.$method',
          isolateId: isolateId,
          args: args,
        );
        final jsonResponse =
            Map<String, Object?>.from(response.json ?? const <String, Object?>{});
        final serialized = jsonEncode(jsonResponse);
        return CallToolResult(
          content: [TextContent(text: serialized)],
          structuredContent: jsonResponse,
          isError: jsonResponse['ok'] == false,
        );
      } catch (error) {
        return CallToolResult(
          content: [TextContent(text: '$error')],
          isError: true,
        );
      }
    });
  }

  Future<CallToolResult> _invalidSelector({String message = 'selector must be an object'}) async {
    return CallToolResult(
      content: [TextContent(text: message)],
      isError: true,
    );
  }
}

# flutter_app_automation

`flutter_app_automation` wires a Flutter debug/profile build into a suite of
VM service extensions that make it possible for external tooling to inspect,
act on, and capture visuals from your app while it is running.

The extensions back the `app_control.*` tools in the Dart MCP server and expose
capabilities such as:

* Widget tree summaries and subtree previews.
* Semantics snapshots, including geometry, labels, and available actions.
* Input primitives for tapping, entering text, and scrolling by semantics
  selectors.
* Frame-settled `waitForIdle` coordination for deterministic automation.
* Full-application screenshots (PNG) with optional debug logging to trace every
  request.

## Getting started

1. Add the dependency to your app's `pubspec.yaml`:
   ```yaml
   dependencies:
     flutter_app_automation:
       path: ../pkgs/flutter_app_automation
   ```
2. In `main.dart`, install the extensions and wrap the root widget **before**
   calling `runApp`:
   ```dart
   import 'package:flutter_app_automation/flutter_app_automation.dart';

   void main() {
     FlutterAppAutomation.install(
       config: const AutomationConfig(
         debugLogging: true, // Optional: pipe verbose traces to debugPrint.
       ),
     );

     runApp(FlutterAppAutomation.wrapApp(const MyApp()));
   }
   ```
3. Run the app in debug or profile mode. The extensions are automatically gated
   behind asserts and can optionally be enabled in profile builds by setting
   `AutomationConfig.enableInProfile` to `true`.

## Configuration

`AutomationConfig` lets you tailor how the extensions behave:

* `enableInProfile` &mdash; expose the extensions when running with
  `--profile` (release builds never register hooks).
* `defaultTimeout` &mdash; wait duration used by asynchronous helpers when a
  request does not supply an explicit timeout.
* `settleFrames` &mdash; the number of frames to pump when `waitForIdle` is
  invoked.
* `scrollAnimationDuration` &mdash; duration applied to programmatic scroll
  gestures.
* `debugLogging` / `logSink` &mdash; enable structured logging and optionally
  redirect the output to a custom sink for tests.

## Service extensions

The package registers the following VM service extensions under the
`ext.app.*` namespace:

| Extension            | Description                                                  |
| -------------------- | ------------------------------------------------------------ |
| `app.getWidgetTree`  | Returns widget tree snapshots with optional preview data.    |
| `app.getSemantics`   | Surfaces the current semantics tree or a focused subtree.    |
| `app.tap`            | Performs a semantics-driven tap on the matched selector.     |
| `app.enterText`      | Updates a text field via semantics or by focusing then typing.|
| `app.scroll`         | Scrolls the target semantics node by delta or absolute offset.|
| `app.waitForIdle`    | Pumps frames and microtasks until the app settles.           |
| `app.screenshot`     | Captures a PNG screenshot of the `RepaintBoundary` wrapper.  |

Each handler returns an envelope of the form `{ "ok": true, "result": ... }` or
`{ "ok": false, "error": "message" }`, making it straightforward to diagnose
failures during automation runs.

## Using with the Dart MCP server

When both the automation extensions and the Dart MCP server are running, the
server's `app_control.*` tool group proxies requests directly to the extensions.
Refer to the [`dart_mcp_server` README](../dart_mcp_server/README.md) for setup
instructions and to learn how to invoke the tools from an MCP-compatible client.

## Fixtures and tests

The package contains an augmented counter application fixture and an
end-to-end integration test (`test/flutter_app_automation_flow_test.dart`) that
exercise the entire automation stack via the MCP protocol. These are helpful
references when integrating the package into your own Flutter application or
when authoring additional automation flows.

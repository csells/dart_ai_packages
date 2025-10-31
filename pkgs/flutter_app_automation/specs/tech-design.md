# Flutter App Automation – Technical Design

## Overview
The `flutter_app_automation` package equips debug and profile Flutter builds with a
cohesive suite of Dart VM service extensions that expose live application state to
external automation tooling. The package is the app-side counterpart to the Dart MCP
server's `app_control.*` tool group and is responsible for:

- Installing the service extensions at startup when assertions are enabled or when
  profile support is explicitly requested.
- Wrapping the root widget with a `RepaintBoundary` so full-application screenshots
  can be captured deterministically.
- Translating high-level automation requests (tap, scroll, enter text, etc.) into
  framework semantics actions and inspector queries.
- Reporting detailed debug logs that mirror the lifecycle of each automation call,
  enabling end-to-end integration tests to assert on progress and investigate
  failures.

The extensions are intentionally disabled in release mode to keep automation hooks
out of production builds.

## Key Components

### `FlutterAppAutomation`
The `FlutterAppAutomation` class orchestrates installation and runtime behavior:

- `install` stores the provided `AutomationConfig`, ensures `ServicesBinding` and
  `SemanticsBinding` are initialized, and registers the full extension catalog via
  `ServicesBinding.instance.registerServiceExtension`.
- `wrapApp` returns a `RepaintBoundary` keyed with a stable `GlobalKey` so the
  screenshot handler can locate the boundary regardless of widget tree changes.
- `_register` centralizes payload decoding, logging, error handling, and response
  envelopes for every extension. All responses follow the `{ ok, result | error }`
  shape consumed by the MCP server.
- `_log` emits structured log lines prefixed with `[flutter_app_automation]` and
  optionally forwards them to a caller-supplied sink, allowing integration tests to
  capture progress in-memory.

### `AutomationConfig`
`AutomationConfig` encapsulates runtime knobs that tune automation behavior:

- `enableInProfile` toggles extension registration when running in profile mode.
- `defaultTimeout`, `settleFrames`, and `scrollAnimationDuration` configure async
  helpers invoked by the extensions.
- `debugLogging` and `logSink` control whether structured logs are emitted and where
  they are delivered (e.g., to `debugPrint` or to a buffered sink used by tests).

The configuration is immutable and validated when the extensions are installed to
ensure consistent behavior for the lifetime of the process.

## Service Extensions
The package registers the following automation endpoints under the `ext.app.*`
namespace:

- **`app.getWidgetTree`** &mdash; fetches widget tree summaries or preview data via
  `WidgetInspectorService`, with optional subtree scoping.
- **`app.getSemantics`** &mdash; serializes the semantics tree (or a target node)
  including identifiers, geometry, labels, flags, and actions.
- **`app.tap`** &mdash; resolves selectors to semantics nodes and performs
  `SemanticsAction.tap`, optionally waiting for idle after completion.
- **`app.enterText`** &mdash; updates text fields using
  `SemanticsAction.setText`, with optional focus-first behavior when `replace`
  is `false`.
- **`app.scroll`** &mdash; executes `SemanticsAction.scrollTo` or
  `SemanticsAction.scrollToOffset` with the configured animation duration.
- **`app.waitForIdle`** &mdash; pumps microtasks and a configurable number of
  frames until animations settle.
- **`app.screenshot`** &mdash; captures a PNG from the root `RepaintBoundary`, with
  room for future highlight overlays.

Each handler converts selector payloads into runtime objects, performs the requested
action, waits for idle when appropriate, and returns a serializable result (JSON
structures or base64 PNG bytes) to the client.

## Selector Resolution Pipeline
Selectors are provided by MCP clients using one of several mutually-exclusive keys:
`byKey`, `bySemanticsLabel`, `byType`, `byText`, or `path` breadcrumbs. The
resolution flow ranks selectors by stability (key → semantics label → type → text →
path) and leverages both `WidgetInspectorService` and the semantics tree to locate
target nodes. Failures are surfaced with descriptive errors so automation clients can
retry or fall back to alternative strategies.

## Logging and Diagnostics
Automation flows emit verbose logs at key stages:

1. Registration of each service extension.
2. Start and completion of every request, including payloads and resulting values.
3. Intermediate steps such as selector resolution, idle waits, and screenshot size
   calculations.

The debug output allows integration tests (e.g., `flutter_app_automation_flow_test.dart`)
to assert that the automation progressed through the expected phases and to capture
context when failures occur. Developers can supply a custom `logSink` to redirect
logs to test buffers, files, or observability pipelines.

## Integration With the Dart MCP Server
The Dart MCP server's `app_control.*` tool group proxies client requests to these
extensions over the VM service connection discovered by the server's DTD mixin. The
server reuses the same envelope format, so MCP clients receive structured success or
error responses that mirror the app-side handlers.

During tests, the harness in `flutter_app_automation_flow_test.dart` launches the
fixture app via `flutter run`, connects to the MCP server, and invokes the tools in
sequence (widget tree fetch, screenshot capture, tapping, text entry, scrolls, idle
waits, and hot reload driven theme updates). The package's logging ensures each step
is observable in the test output.

## Error Handling
All extension handlers wrap their logic in `try/catch` blocks inside `_register`.
Any thrown exceptions are reported through `FlutterError.reportError` for visibility
in debug consoles, and clients receive a structured `{ ok: false, error: message }`
response. Handlers validate payloads early (e.g., selector presence, timeout bounds)
so callers receive fast feedback when requests are malformed.

## Future Enhancements
Potential follow-ups captured in the original plan include:

- Highlight rectangles in screenshots to visualize target widgets.
- Additional semantics actions (long press, drag) and keyboard input synthesis for
  text fields that do not support `SemanticsAction.setText`.
- CanvasKit-first web support with fallbacks for the HTML renderer.
- Shared secret or token gating for the automation extensions when running in
  environments where localhost access needs to be restricted.

These extensions to the architecture can build on the existing registration and
logging scaffolding without reworking the core design.

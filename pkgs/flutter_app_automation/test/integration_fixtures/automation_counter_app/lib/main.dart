import 'package:flutter/material.dart';
import 'package:flutter_app_automation/flutter_app_automation.dart';

import 'counter_app.dart';

void main() {
  FlutterAppAutomation.install(
    config: const AutomationConfig(
      debugLogging: true,
      settleFrames: 1,
    ),
  );

  runApp(
    FlutterAppAutomation.wrapApp(
      const AutomationCounterApp(),
    ),
  );
}

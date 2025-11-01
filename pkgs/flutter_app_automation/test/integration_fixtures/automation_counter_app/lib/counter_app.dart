import 'package:flutter/material.dart';

import 'theme.dart';

class AutomationCounterApp extends StatefulWidget {
  const AutomationCounterApp({super.key});

  @override
  State<AutomationCounterApp> createState() => _AutomationCounterAppState();
}

class _AutomationCounterAppState extends State<AutomationCounterApp> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Automation Counter',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: automationSeedColor),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Automation Counter'),
        ),
        body: Center(
          child: Semantics(
            label: 'counter:${_counter.toString()}',
            child: Text(
              '$_counter',
              key: const ValueKey('counterText'),
              style: Theme.of(context).textTheme.displayLarge,
            ),
          ),
        ),
        floatingActionButton: Semantics(
          label: 'automation:increment',
          button: true,
          child: FloatingActionButton(
            key: const ValueKey('incrementFab'),
            onPressed: () {
              setState(() {
                _counter++;
              });
            },
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );
  }
}

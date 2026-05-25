import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Church Cam',
      home: Scaffold(
        appBar: AppBar(title: const Text('Church Cam')),
        body: const Center(
          child: Text('✓ App Working!', style: TextStyle(fontSize: 32)),
        ),
      ),
    );
  }
}

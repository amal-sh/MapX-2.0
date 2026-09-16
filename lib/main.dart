import 'package:flutter/material.dart';
import 'screens/dashboard_screen.dart';

void main() {
  runApp(const MapXApp());
}

class MapXApp extends StatelessWidget {
  const MapXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MapX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

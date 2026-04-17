// lib/main.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'features/home/home_page.dart';
import 'services/offline_queue_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://pjfoomtbjnjrnggxioxc.supabase.co', // replace
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBqZm9vbXRiam5qcm5nZ3hpb3hjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDU2NDMsImV4cCI6MjA4MzUyMTY0M30.Z5rMrKptyFgSxP0iyfsfNgPq3uNhVU5ecEskmqTSz0U',         // replace
  );

  // Try process queue on app start if online
  final conn = await Connectivity().checkConnectivity();
  if (conn != ConnectivityResult.none) {
    await OfflineQueueService.instance.processQueue();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Collage Tools',
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }
}

// lib/main.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'features/home/home_page.dart';
import 'services/offline_queue_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

// berisi file konfigurasi supabase key dan url
import 'core/supabase.client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.anonKey,
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

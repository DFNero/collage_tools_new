// lib/services/offline_queue_service.dart

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OfflineQueueService {
  OfflineQueueService._internal();
  static final OfflineQueueService instance = OfflineQueueService._internal();

  final _client = Supabase.instance.client;
  static const _queueFile = 'offline_queue.json';

  Future<File> _getQueueFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_queueFile');
  }

  /// Tambah file ke queue
  Future<void> addToQueue(File imageFile) async {
    try {
      final file = await _getQueueFile();

      List<Map<String, dynamic>> queue = [];

      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          queue = List<Map<String, dynamic>>.from(jsonDecode(content));
        } catch (e) {
          print('Error reading queue: $e');
          queue = [];
        }
      }

      // Cek duplikat
      final alreadyExists = queue.any((item) => item['path'] == imageFile.path);
      if (alreadyExists) {
        print('File already in queue: ${imageFile.path}');
        return;
      }

      queue.add({
        'path': imageFile.path,
        'created_at': DateTime.now().toIso8601String(),
      });

      await file.writeAsString(jsonEncode(queue));
      print('Added to queue: ${imageFile.path}');
    } catch (e) {
      print('Error addToQueue: $e');
    }
  }

  /// Hapus file dari queue (untuk delete manual)
  Future<void> removeFromQueue(String localPath) async {
    try {
      final file = await _getQueueFile();
      if (!await file.exists()) return;

      final content = await file.readAsString();
      List<Map<String, dynamic>> queue = List<Map<String, dynamic>>.from(jsonDecode(content));

      queue.removeWhere((item) => item['path'] == localPath);

      if (queue.isEmpty) {
        await file.delete();
      } else {
        await file.writeAsString(jsonEncode(queue));
      }

      print('Removed from queue: $localPath');
    } catch (e) {
      print('Error removeFromQueue: $e');
    }
  }

  /// Process queue: upload semua file yang pending
  Future<int> processQueue() async {
    try {
      final file = await _getQueueFile();
      if (!await file.exists()) return 0;

      final content = await file.readAsString();
      final List list = jsonDecode(content);

      int uploaded = 0;
      final remaining = <Map<String, dynamic>>[];

      for (final item in list) {
        final path = item['path'] as String;
        final imageFile = File(path);

        if (!await imageFile.exists()) {
          print('Skipping missing file: $path');
          continue;
        }

        try {
          final fileName = 'collage_${DateTime.now().millisecondsSinceEpoch}.png';

          // Upload ke Supabase
          await _client.storage.from('collages').upload(
                fileName,
                imageFile,
                fileOptions: const FileOptions(upsert: true),
              );

          final publicUrl = _client.storage.from('collages').getPublicUrl(fileName);

          // Insert ke database
          await _client.from('collages').insert({
            'image_url': publicUrl,
            'created_at': item['created_at'],
          });

          print('Uploaded: $fileName');
          uploaded++;
        } catch (e) {
          print('Upload failed for $path: $e');
          // Keep in queue untuk retry nanti
          remaining.add(Map<String, dynamic>.from(item));
        }
      }

      // Update queue file
      if (remaining.isEmpty) {
        await file.delete();
        print('Queue cleared');
      } else {
        await file.writeAsString(jsonEncode(remaining));
        print('${remaining.length} items still in queue');
      }

      return uploaded;
    } catch (e) {
      print('Error processQueue: $e');
      return 0;
    }
  }

  /// Get list of queued items
  Future<List<Map<String, dynamic>>> getQueuedItems() async {
    try {
      final file = await _getQueueFile();
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final List list = jsonDecode(content);

      return List<Map<String, dynamic>>.from(list);
    } catch (e) {
      print('Error getQueuedItems: $e');
      return [];
    }
  }
}
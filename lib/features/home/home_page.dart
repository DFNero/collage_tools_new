// lib/features/home/home_page.dart

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'widgets/collage_card.dart';
import '../editor/editor_page.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../services/offline_queue_service.dart';
import 'dart:async';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  bool loading = true;
  List<Map<String, dynamic>> collages = [];

  StreamSubscription<ConnectivityResult>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _fetchCollages();

    _connectivitySub = Connectivity().onConnectivityChanged.listen((
      status,
    ) async {
      if (status != ConnectivityResult.none) {
        final uploaded = await OfflineQueueService.instance.processQueue();
        if (uploaded > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ $uploaded kolase berhasil diupload')),
          );
          _fetchCollages();
        }
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  // ================= FETCH =================
  Future<void> _fetchCollages() async {
    setState(() => loading = true);
    try {
      // Fetch remote collages
      final res = await supabase
          .from('collages')
          .select('id, image_url, created_at')
          .order('created_at', ascending: false);

      final remote = List<Map<String, dynamic>>.from(res as List);

      // Fetch queued local items
      final queued = await OfflineQueueService.instance.getQueuedItems();

      // Filter: hanya tampilkan file yang masih ada
      final localItems = <Map<String, dynamic>>[];
      for (var q in queued) {
        final file = File(q['path'] as String);
        if (await file.exists()) {
          localItems.add({
            'image_url': q['path'], // local path
            'created_at': q['created_at'],
            'local': true, // FLAG: ini item lokal
          });
        }
      }

      // Merge: lokal di atas, remote di bawah
      collages = [...localItems, ...remote];
    } catch (e) {
      print('Fetch error: $e');
      collages = [];
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Gagal memuat kolase: $e')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ================= CREATE =================
  Future<void> _pickAndCreateCollage() async {
    final picked = await _picker.pickMultiImage();
    if (!mounted || picked.isEmpty) return;

    if (picked.length > 4) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Maksimal 4 gambar')));
      return;
    }

    final files = picked.map((x) => File(x.path)).toList();

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditorPage(images: files)),
    );

    if (result == true && mounted) {
      _fetchCollages();
    }
  }

  // ================= DELETE =================
  Future<void> _confirmDelete(int index) async {
    final item = collages[index];
    final isLocal = item['local'] == true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus kolase?'),
        content: Text(
          isLocal
              ? 'Kolase ini belum terupload. Hapus dari queue?'
              : 'Aksi ini tidak bisa dibatalkan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (ok == true) {
      if (isLocal) {
        await _deleteLocalCollage(item['image_url'], index);
      } else {
        await _deleteRemoteCollage(item['image_url'], index);
      }
    }
  }

  Future<void> _deleteLocalCollage(String localPath, int index) async {
    try {
      // Hapus dari queue
      await OfflineQueueService.instance.removeFromQueue(localPath);

      if (!mounted) return;
      setState(() {
        collages.removeAt(index);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kolase lokal dihapus dari queue')),
      );
    } catch (e) {
      print('Delete local error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gagal hapus: $e')));
    }
  }

  Future<void> _deleteRemoteCollage(String imageUrl, int index) async {
    try {
      final fileName = Uri.parse(imageUrl).pathSegments.last;

      await supabase.storage.from('collages').remove([fileName]);
      await supabase.from('collages').delete().eq('image_url', imageUrl);

      if (!mounted) return;

      setState(() {
        collages.removeAt(index);
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Kolase dihapus')));
    } catch (e) {
      print('Delete remote error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gagal hapus: $e')));
    }
  }

  // ================= EDIT =================
  Future<void> _editCollage(Map<String, dynamic> item) async {
    final imageUrl = item['image_url'] as String;
    final isLocal = item['local'] == true;

    try {
      File file;

      if (isLocal) {
        // File lokal, langsung buka
        file = File(imageUrl);
        if (!await file.exists()) {
          throw Exception('File lokal tidak ditemukan');
        }
      } else {
        // File remote, download dulu
        final uri = Uri.parse(imageUrl);
        final client = HttpClient();
        final req = await client.getUrl(uri);
        final resp = await req.close();

        if (resp.statusCode != 200) {
          throw Exception('HTTP ${resp.statusCode}');
        }

        final bytes = await consolidateHttpClientResponseBytes(resp);
        final dir = await getTemporaryDirectory();
        file = File(
          '${dir.path}/edit_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await file.writeAsBytes(bytes);
      }

      if (!mounted) return;

      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => EditorPage(images: [file])),
      );

      if (result == true && mounted) {
        _fetchCollages();
      }
    } catch (e) {
      print('Edit error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gagal edit kolase: $e')));
    }
  }

  Widget _buildQueueBadge() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: OfflineQueueService.instance.getQueuedItems(),
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        if (count == 0) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.orangeAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$count Pending',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text(
          'My Collages',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            color: Colors.white,
          ),
        ),
        centerTitle: false,
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [_buildQueueBadge()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickAndCreateCollage,
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        elevation: 4,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text(
          'Create New',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.blueAccent),
      );
    }

    if (collages.isEmpty) {
      return _buildEmptyState();
    }

    return RefreshIndicator(
      color: Colors.blueAccent,
      backgroundColor: Colors.grey.shade900,
      onRefresh: _fetchCollages,
      child: _buildGrid(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.collections_outlined,
            size: 80,
            color: Colors.white.withOpacity(0.1),
          ),
          const SizedBox(height: 16),
          const Text(
            'No collages yet',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap "Create New" to start your first collage',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.75,
      ),
      itemCount: collages.length,
      itemBuilder: (context, index) {
        final collage = collages[index];
        final isLocal = collage['local'] == true;

        return Stack(
          children: [
            CollageCard(
              imageUrl: collage['image_url'],
              onEdit: () => _editCollage(collage),
              onDelete: () => _confirmDelete(index),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _PreviewPage(
                      imageUrl: collage['image_url'],
                      isLocal: isLocal,
                    ),
                  ),
                );
              },
            ),
            if (isLocal) _buildPendingBadge(),
          ],
        );
      },
    );
  }

  Widget _buildPendingBadge() {
    return Positioned(
      top: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_upload_outlined, size: 12, color: Colors.white),
            SizedBox(width: 4),
            Text(
              'Pending',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= PREVIEW =================
class _PreviewPage extends StatelessWidget {
  final String imageUrl;
  final bool isLocal;

  const _PreviewPage({required this.imageUrl, this.isLocal = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(isLocal ? 'Preview (Local)' : 'Preview'),
      ),
      body: Center(
        child: InteractiveViewer(
          child: isLocal ? Image.file(File(imageUrl)) : Image.network(imageUrl),
        ),
      ),
    );
  }
}

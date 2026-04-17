// lib/utils/gallery_saver.dart

import 'dart:io';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// Simpan gambar ke galeri DAN return path file lokal
Future<String?> saveImageToGallery(Uint8List bytes) async {
  try {
    // 1. Simpan ke GALERI dulu (penting!)
    final result = await SaverGallery.saveImage(
      bytes,
      quality: 100,
      fileName: "collage_${DateTime.now().millisecondsSinceEpoch}",
      androidRelativePath: "Pictures/CollageTools",
      skipIfExists: false,
    );

    debugPrint('Gallery save result: $result');

    // 2. Simpan juga ke local app directory untuk queue system
    final dir = await getApplicationDocumentsDirectory();
    final localPath =
        '${dir.path}/collage_${DateTime.now().millisecondsSinceEpoch}.png';
    final localFile = File(localPath);
    await localFile.writeAsBytes(bytes);

    debugPrint('Local file saved: $localPath');

    // Return local path untuk queue system
    return localPath;
  } catch (e) {
    debugPrint('Error saveImageToGallery: $e');
    return null;
  }
}

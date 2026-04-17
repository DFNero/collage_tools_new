// lib/features/home/preview_page.dart

import 'package:flutter/material.dart';

class PreviewPage extends StatelessWidget {
  final String imageUrl;
  const PreviewPage({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Preview")),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(imageUrl),
        ),
      ),
    );
  }
}

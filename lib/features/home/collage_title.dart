// lib/features/home/collage_title.dart

import 'package:flutter/material.dart';

class CollageTile extends StatelessWidget {
  final String imageUrl;
  final VoidCallback onDelete;

  const CollageTile({
    super.key,
    required this.imageUrl,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Image.network(
            imageUrl,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: PopupMenuButton(
            onSelected: (_) => onDelete(),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'delete',
                child: Text('Hapus'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

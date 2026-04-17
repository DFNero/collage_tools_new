// lib/features/editor/editable_image.dart

import 'dart:io';
import 'package:flutter/material.dart';

class EditableImage {
  final File? file;
  final String? url;

  // Mutable properties used by editor
  Offset position;
  double scale;
  double rotation;
  double width;
  double height;

  // Mirror/flip properties
  bool flipX; // Horizontal mirror
  bool flipY; // Vertical mirror

  // transient: used while the user performs a scale/rotate gesture
  double gestureStartScale = 1.0;
  double gestureStartRotation = 0.0;
  double gestureStartWidth = 140.0;
  double gestureStartHeight = 140.0;
  Offset gestureStartPosition = Offset.zero;

  EditableImage({
    required this.file,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.width = 140.0,
    this.height = 140.0,
    this.flipX = false,
    this.flipY = false,
  }) : url = null;

  EditableImage.network({
    required this.url,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.width = 140.0,
    this.height = 140.0,
    this.flipX = false,
    this.flipY = false,
  }) : file = null;
}

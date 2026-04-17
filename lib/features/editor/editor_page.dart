// lib/features/editor/editor_page.dart

import '../../utils/gallery_saver.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';

import 'editable_image.dart';
import '../../services/offline_queue_service.dart';

class EditorPage extends StatefulWidget {
  final List<File> images;
  final String? singleImageUrl;

  const EditorPage({super.key, required this.images, this.singleImageUrl});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final GlobalKey _canvasKey = GlobalKey();
  final supabase = Supabase.instance.client;

  late List<EditableImage> _images;
  EditableImage? selected;

  double _exportScale = 2.0;
  final Color _exportBackground = Colors.white;

  static const double canvasSize = 360.0;
  static const double baseImageSize = 140.0;

  double _templateGap = 0.0;
  int? _currentLayoutIndex;

  @override
  void initState() {
    super.initState();

    if (widget.singleImageUrl != null && widget.singleImageUrl!.isNotEmpty) {
      _images = [
        EditableImage.network(
          url: widget.singleImageUrl!,
          position: Offset(
            (canvasSize - baseImageSize) / 2,
            (canvasSize - baseImageSize) / 2,
          ),
        ),
      ];
    } else {
      _images = widget.images
          .map(
            (file) => EditableImage(
              file: file,
              position: Offset(
                (canvasSize - baseImageSize) / 2,
                (canvasSize - baseImageSize) / 2,
              ),
            ),
          )
          .toList();
    }
  }

  Offset _clampPosition(Offset pos, double width, double height, double scale) {
    final scaledW = width * scale;
    final scaledH = height * scale;

    // We allow the image to be moved anywhere as long as some part of it is within the canvas
    // But the user specifically complained about "margin" and not being able to touch the border.
    // Let's ensure clamping allows touching the border (0 to canvasSize - scaled).

    double minX, minY, maxX, maxY;

    if (scaledW <= canvasSize) {
      minX = 0;
      maxX = canvasSize - scaledW;
    } else {
      minX = canvasSize - scaledW;
      maxX = 0;
    }

    if (scaledH <= canvasSize) {
      minY = 0;
      maxY = canvasSize - scaledH;
    } else {
      minY = canvasSize - scaledH;
      maxY = 0;
    }

    return Offset(pos.dx.clamp(minX, maxX), pos.dy.clamp(minY, maxY));
  }

  Future<Uint8List> _exportCanvasBytes() async {
    final boundary =
        _canvasKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: _exportScale);

    if (_exportBackground == Colors.transparent) {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData!.buffer.asUint8List();
    } else {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..color = _exportBackground;
      canvas.drawRect(
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        paint,
      );
      canvas.drawImage(image, Offset.zero, Paint());
      final picture = recorder.endRecording();
      final ui.Image finalImage = await picture.toImage(
        image.width,
        image.height,
      );
      final byteData = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return byteData!.buffer.asUint8List();
    }
  }

  Future<String> _uploadToSupabase(File file) async {
    final fileName = 'collage_${DateTime.now().millisecondsSinceEpoch}.png';
    await supabase.storage
        .from('collages')
        .upload(fileName, file, fileOptions: const FileOptions(upsert: true));

    return supabase.storage.from('collages').getPublicUrl(fileName);
  }

  Future<void> _saveToDatabase(String imageUrl) async {
    await supabase.from('collages').insert({
      'image_url': imageUrl,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  // ================= TEMPLATE LOGIC =================

  void _applyTemplate(int index) {
    if (_images.isEmpty) return;

    setState(() {
      final count = _images.length;
      selected = null; // Deselect to avoid confusion
      _currentLayoutIndex = index;

      final rects = _getTemplateNormalizedRects(count, index);
      if (rects.isEmpty) return;

      // Sort images visually: top to bottom, then left to right
      // Use center points for better accuracy
      _images.sort((a, b) {
        final aCenter = Offset(a.position.dx + a.width / 2, a.position.dy + a.height / 2);
        final bCenter = Offset(b.position.dx + b.width / 2, b.position.dy + b.height / 2);

        if ((aCenter.dy - bCenter.dy).abs() > 40) {
          return aCenter.dy.compareTo(bCenter.dy);
        }
        return aCenter.dx.compareTo(bCenter.dx);
      });

      for (int i = 0; i < rects.length && i < _images.length; i++) {
        final rect = rects[i];
        final gap = _templateGap;

        double left = rect.left * canvasSize + gap;
        double top = rect.top * canvasSize + gap;
        double width = rect.width * canvasSize - (gap * 2);
        double height = rect.height * canvasSize - (gap * 2);

        // Ensure minimum dimensions just in case gap is too big
        if (width < 20) width = 20;
        if (height < 20) height = 20;

        _images[i].position = Offset(left, top);
        _images[i].width = width;
        _images[i].height = height;
        _images[i].scale = 1.0;
        _images[i].rotation = 0.0; // Reset rotation so templates align nicely
      }

      // Ensure everything is clamped after template application
      for (var img in _images) {
        img.position = _clampPosition(
          img.position,
          img.width,
          img.height,
          img.scale,
        );
      }
    });
  }

  void _showTemplatePicker() {
    final count = _images.length;
    if (count < 2 || count > 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Template hanya tersedia untuk 2-4 gambar'),
        ),
      );
      return;
    }

    final totalTemplates = _getTemplateCount(count);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(20),
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.55),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Pilih Template',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Gap Slider
                  Row(
                    children: [
                      const Icon(Icons.space_bar, color: Colors.white54),
                      const SizedBox(width: 8),
                      const Text('Gap', style: TextStyle(color: Colors.white70)),
                      Expanded(
                        child: Slider(
                          value: _templateGap,
                          min: 0,
                          max: 30,
                          activeColor: Colors.blueAccent,
                          inactiveColor: Colors.white10,
                          onChanged: (val) {
                            setModalState(() {
                              _templateGap = val;
                            });
                            setState(() {
                              _templateGap = val;
                            });
                            // Re-apply if a template is active
                            if (_currentLayoutIndex != null && _currentLayoutIndex! < totalTemplates) {
                              _applyTemplate(_currentLayoutIndex!);
                            }
                          },
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text('${_templateGap.toInt()}', style: const TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        childAspectRatio: 0.8,
                      ),
                      itemCount: totalTemplates,
                      itemBuilder: (context, index) {
                        return _buildTemplateOption(index, 'Layout ${index + 1}', setModalState);
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTemplateOption(int index, String label, StateSetter setModalState) {
    final count = _images.length;
    final isSelected = _currentLayoutIndex == index;
    return GestureDetector(
      onTap: () {
        setModalState(() {
          _currentLayoutIndex = index;
        });
        _applyTemplate(index);
      },
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSelected ? Colors.blueAccent.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                color: isSelected ? Colors.blueAccent : Colors.white12,
                width: isSelected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CustomPaint(
                  painter: TemplateIconPainter(
                    imageCount: count,
                    layoutIndex: index,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.blueAccent : Colors.white70,
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// FIXED: Save flow yang benar
  Future<void> _saveAndClose() async {
    try {
      // 0. Deselect any image to remove the blue border in export
      if (selected != null) {
        setState(() {
          selected = null;
        });
        // Give a small frame for the UI to update if needed (optional but safer for RepaintBoundary)
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // 1. Export canvas ke bytes
      final bytes = await _exportCanvasBytes();

      // 2. SIMPAN KE GALERI + dapat local path
      final localPath = await saveImageToGallery(bytes);

      if (localPath == null) {
        throw Exception('Gagal menyimpan ke galeri');
      }

      final localFile = File(localPath);
      print('File saved locally: $localPath');

      // 3. Cek koneksi
      final conn = await Connectivity().checkConnectivity();
      final isOffline = conn == ConnectivityResult.none;

      if (isOffline) {
        // Mode OFFLINE: queue untuk upload nanti
        await OfflineQueueService.instance.addToQueue(localFile);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Disimpan ke galeri. Akan diupload saat online.'),
            duration: Duration(seconds: 3),
          ),
        );
      } else {
        // Mode ONLINE: upload langsung
        try {
          final url = await _uploadToSupabase(localFile);
          await _saveToDatabase(url);

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Kolase disimpan ke galeri & Supabase'),
              duration: Duration(seconds: 2),
            ),
          );
        } catch (uploadError) {
          // Gagal upload tapi file sudah di galeri
          print('Upload error: $uploadError');
          await OfflineQueueService.instance.addToQueue(localFile);

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Disimpan ke galeri. Upload gagal, masuk queue.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }

      // Show "success export and save gallery" toast as requested
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('success export and save gallery'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // Kembali ke homepage dan refresh
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      print('Save error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('❌ Gagal menyimpan: $e')));
    }
  }

  Future<void> _shareLocalFile(File file) async {
    try {
      final xfile = XFile(file.path);
      await Share.shareXFiles([xfile], text: 'My collage from CollageTools');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Gagal share: $e')));
    }
  }

  Future<void> _showExportDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.grey.shade900,
          title: const Text(
            'Export Collage',
            style: TextStyle(color: Colors.white),
          ),
          content: StatefulBuilder(
            builder: (c, setInner) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Resolution',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButton<double>(
                      dropdownColor: Colors.grey.shade900,
                      style: const TextStyle(color: Colors.white),
                      value: _exportScale,
                      underline: const SizedBox(),
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                          value: 1.0,
                          child: Text('Standard (1x)'),
                        ),
                        DropdownMenuItem(value: 2.0, child: Text('High (2x)')),
                        DropdownMenuItem(value: 3.0, child: Text('Ultra (3x)')),
                      ],
                      onChanged: (v) => setInner(() => _exportScale = v ?? 2.0),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Background: White (Default)',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                if (_images.isEmpty) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Canvas kosong')),
                  );
                  return;
                }
                if (!context.mounted) return;
                Navigator.pop(context);

                // Show loading dialog
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) =>
                      const Center(child: CircularProgressIndicator()),
                );

                await _saveAndClose();

                // Dismiss loading dialog
                if (mounted && Navigator.canPop(context)) {
                  Navigator.pop(context);
                }
              },
              child: const Text('Export'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _onWillPop() async {
    if (_images.isEmpty) return true;
    final should = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar editor?'),
        content: const Text('Perubahan belum disimpan. Yakin keluar?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
    return should ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final should = await _onWillPop();
        if (should && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        appBar: AppBar(
          title: const Text(
            'Collage Editor',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: Colors.white,
            ),
          ),
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.black,
          actions: [
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Save / Export',
              onPressed: _showExportDialog,
            ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share current canvas',
              onPressed: () async {
                try {
                  final bytes = await _exportCanvasBytes();
                  final dir = await getTemporaryDirectory();
                  final file = File(
                    '${dir.path}/share_${DateTime.now().millisecondsSinceEpoch}.png',
                  );
                  await file.writeAsBytes(bytes);
                  await _shareLocalFile(file);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Gagal share: $e')));
                }
              },
            ),
          ],
        ),
        body: Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            child: RepaintBoundary(
              key: _canvasKey,
              child: Container(
                width: canvasSize,
                height: canvasSize,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.white12, width: 1),
                  borderRadius: BorderRadius.zero,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      selected = null;
                    });
                  },
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: _images.map(_buildEditableImage).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
        bottomNavigationBar: _buildToolbar(),
      ),
    );
  }

  Widget _buildEditableImage(EditableImage item) {
    final bool isSelected = selected == item;

    return Positioned(
      left: item.position.dx,
      top: item.position.dy,
      child: GestureDetector(
        onTap: () {
          setState(() {
            selected = item;
            _images.remove(item);
            _images.add(item);
          });
        },
        onScaleStart: (details) {
          item.gestureStartScale = item.scale;
          item.gestureStartRotation = item.rotation;
          item.gestureStartWidth = item.width;
          item.gestureStartHeight = item.height;
          item.gestureStartPosition = item.position;
        },
        onScaleUpdate: (details) {
          setState(() {
            final isPinching = (details.scale - 1.0).abs() > 0.01;

            if (isPinching) {
              // Calculate new sizes based on gesture scale factor
              // We maintain the aspect ratio by scaling current width/height
              double newWidth = (item.gestureStartWidth * details.scale).clamp(
                40.0,
                360.0,
              );
              double newHeight = (item.gestureStartHeight * details.scale)
                  .clamp(40.0, 360.0);

              // Calculate the center of the image before scaling
              final oldW = item.width;
              final oldH = item.height;
              final oldCenterX = item.position.dx + oldW / 2;
              final oldCenterY = item.position.dy + oldH / 2;

              // Apply new width and height (and reset scale to 1.0 for consistency with sliders)
              item.width = newWidth;
              item.height = newHeight;
              item.scale = 1.0;

              // Calculate new position to keep the center stable
              final newX = oldCenterX - newWidth / 2;
              final newY = oldCenterY - newHeight / 2;

              // Clamp the new position within canvas bounds
              item.position = _clampPosition(
                Offset(newX, newY),
                newWidth,
                newHeight,
                1.0,
              );
            } else {
              // Pan only - apply delta movement
              final newPos = _clampPosition(
                item.position + details.focalPointDelta,
                item.width,
                item.height,
                item.scale,
              );
              item.position = newPos;
            }

            // Handle rotation gesture
            if (details.rotation.abs() > 0.001) {
              double newRot = item.gestureStartRotation + details.rotation;
              // Normalize angle between -pi and pi
              newRot = newRot % (2 * math.pi);
              if (newRot > math.pi) newRot -= 2 * math.pi;
              if (newRot < -math.pi) newRot += 2 * math.pi;
              
              // Prevent extreme floating point precision issues near the bounds
              if (newRot > math.pi) newRot = math.pi;
              if (newRot < -math.pi) newRot = -math.pi;
              
              item.rotation = newRot;
            }
          });
        },
        onScaleEnd: (details) {},
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..rotateZ(item.rotation)
            ..scale(
              item.scale * (item.flipX ? -1.0 : 1.0),
              item.scale * (item.flipY ? -1.0 : 1.0),
            ),
          child: Container(
            width: item.width,
            height: item.height,
            decoration: isSelected
                ? BoxDecoration(
                    border: Border.all(color: Colors.blueAccent, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blueAccent.withValues(alpha: 0.35),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  )
                : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(isSelected ? 2 : 0),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.file != null)
                    Image.file(item.file!, fit: BoxFit.cover)
                  else if (item.url != null)
                    Image.network(
                      item.url!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image),
                    )
                  else
                    Container(color: Colors.grey.shade300),
                  if (isSelected)
                    Positioned.fill(
                      child: Container(
                        color: Colors.blueAccent.withValues(alpha: 0.1),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            offset: const Offset(0, -4),
            blurRadius: 10,
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected != null) _buildSelectedTools(),
              _buildMainControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedTools() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.symmetric(
          horizontal: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: Column(
        children: [
          _buildSizeSlider('W', selected!.width, (v) {
            setState(() {
              selected!.width = v;
              _autoClamp(selected!);
            });
          }),
          const SizedBox(height: 8),
          _buildSizeSlider('H', selected!.height, (v) {
            setState(() {
              selected!.height = v;
              _autoClamp(selected!);
            });
          }),
        ],
      ),
    );
  }

  void _autoClamp(EditableImage img) {
    img.position = _clampPosition(
      img.position,
      img.width,
      img.height,
      img.scale,
    );
  }

  Widget _buildSizeSlider(
    String label,
    double value,
    Function(double) onChanged,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded( 
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white10,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value,
              min: 40,
              max: 360,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            value.toInt().toString(),
            textAlign: TextAlign.end,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ),
      ],
    );
  }

  Widget _buildMainControls() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildToolButton(
            icon: Icons.add_photo_alternate_outlined,
            color: Colors.orangeAccent,
            label: 'Add',
            onTap: _pickImage,
          ),
          _buildToolButton(
            icon: Icons.grid_view_rounded,
            color: Colors.purpleAccent,
            label: 'Template',
            onTap: _showTemplatePicker,
          ),
          _buildToolButton(
            icon: Icons.rotate_right_rounded,
            color: Colors.cyanAccent,
            label: 'Rotate',
            onTap: selected != null ? _showRotatePanel : null,
          ),
          _buildToolButton(
            icon: Icons.flip_rounded,
            color: Colors.indigoAccent,
            label: 'Mirror',
            onTap: selected != null ? _showMirrorPanel : null,
          ),
          _buildToolButton(
            icon: Icons.delete_outline_rounded,
            color: Colors.redAccent,
            label: 'Delete',
            onTap: selected != null ? _deleteSelected : null,
          ),
          _buildToolButton(
            icon: Icons.layers_clear_outlined,
            color: Colors.white70,
            label: 'Deselect',
            onTap: selected != null
                ? () => setState(() => selected = null)
                : null,
          ),
          _buildToolButton(
            icon: Icons.refresh_rounded,
            color: Colors.white54,
            label: 'Reset',
            onTap: _confirmReset,
          ),
        ],
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback? onTap,
  }) {
    final bool isDisabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDisabled
                    ? Colors.white.withValues(alpha: 0.05)
                    : color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDisabled
                      ? Colors.white.withValues(alpha: 0.05)
                      : color.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Icon(
                icon,
                color: isDisabled ? Colors.white24 : color,
                size: 26,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: isDisabled ? Colors.white24 : Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteSelected() {
    if (selected == null) return;
    setState(() {
      _images.remove(selected);
      selected = null;
    });
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final List<XFile> picked = await picker.pickMultiImage();
    if (picked.isEmpty) return;

    if (_images.length + picked.length > 4) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Maksimal 4 gambar')));
      return;
    }

    setState(() {
      for (var xf in picked) {
        _images.add(
          EditableImage(
            file: File(xf.path),
            position: Offset(
              (canvasSize - baseImageSize) / 2,
              (canvasSize - baseImageSize) / 2,
            ),
          ),
        );
      }
    });
  }

  void _confirmReset() {
    if (_images.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text(
          'Reset Canvas',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Hapus semua gambar?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _images.clear();
                selected = null;
              });
            },
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
  }

  // ================= ROTATE PANEL =================

  void _showRotatePanel() {
    if (selected == null) return;
    
    // Safety normalization before showing slider to avoid bounds exception / safety nya rotasi biar gk aneh
    double safeRot = selected!.rotation % (2 * math.pi);
    if (safeRot > math.pi) safeRot -= 2 * math.pi;
    if (safeRot < -math.pi) safeRot += 2 * math.pi;
    // clamp it directly if floating bounds get weird / clamp nya rotasi biar gk aneh
    if (safeRot > math.pi) safeRot = math.pi;
    if (safeRot < -math.pi) safeRot = -math.pi;
    selected!.rotation = safeRot;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Rotate Image',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ini 4 tombol preset rotate
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildRotatePresetButton('0°', 0, setModalState),
                      _buildRotatePresetButton('90°', math.pi / 2, setModalState),
                      _buildRotatePresetButton('180°', math.pi, setModalState),
                      _buildRotatePresetButton('-90°', -math.pi / 2, setModalState),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ini slider dan manggil slider di line 
                  Row(
                    children: [
                      const Icon(Icons.rotate_left, color: Colors.white54), 
                      Expanded(
                        child: Slider(
                          value: selected!.rotation,
                          min: -math.pi,
                          max: math.pi,
                          onChanged: (v) {
                            setState(() {
                              selected!.rotation = v;
                            });
                            setModalState(() {});
                          },
                        ),
                      ),
                      const Icon(Icons.rotate_right, color: Colors.white54),
                    ],
                  ),
                  Text(
                    '${(selected!.rotation * 180 / math.pi).toInt()}°', // ini text yang angka slider
                    style: const TextStyle(color: Colors.blueAccent),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRotatePresetButton( // 4 TOMBOL PRESET ROTATE
    String label,
    double degrees,
    StateSetter setModalState,
  ) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () {
        setState(() {
          selected!.rotation = degrees; // nyambung kode line 1141
        });
        setModalState(() {});
      },
      child: Text(label, style: const TextStyle(color: Colors.white)), 
    );
  }

  // ================= MIRROR PANEL =================

  void _showMirrorPanel() {
    if (selected == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mirror Image',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Flip your image horizontally or vertically',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildMirrorOption( // HORIZONTAL MIRROR
                  icon: Icons.flip_rounded,
                  label: 'Horizontal',
                  isActive: selected!.flipX,
                  onTap: () {
                    setState(() {
                      selected!.flipX = !selected!.flipX;
                    });
                    Navigator.pop(context);
                  },
                ),
                const SizedBox(width: 24),
                _buildMirrorOption( // VERTICAL MIRROR
                  icon: Icons.flip_rounded,
                  label: 'Vertical',
                  isActive: selected!.flipY,
                  rotateIcon: true,
                  onTap: () {
                    setState(() {
                      selected!.flipY = !selected!.flipY;
                    });
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // MIRROR OPTION
  Widget _buildMirrorOption({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
    bool rotateIcon = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          // background nya icon mirror
          color: isActive
              ? Colors.blueAccent.withValues(alpha: 0.05) 
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          // border nya icon mirror
          // awal nya gelap dulu, if click true = biru di opsi mirror | def active=blueAccent, def NonActive=white24
          // yang '2' itu warna aktif, '1' yang false(abu)
          border: Border.all(
            color: isActive ? Colors.blueAccent : Colors.white24,
            width: isActive ? 2 : 1, 
          ),
        ),
        child: Column(
          children: [
            Transform.rotate(
              angle: rotateIcon ? 1.5708 : 0, // 90 degrees for vertical
              child: Icon(
                icon,
                color: isActive ? Colors.blueAccent : Colors.white70, // warna icon mirror
                size: 36,
              ),
            ),
            const SizedBox(height: 8),

            // text nya icon mirror
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.blueAccent : Colors.white70,
                fontSize: 14,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isActive ? 'ON' : 'OFF',
              style: TextStyle(
                color: isActive ? Colors.blueAccent : Colors.white38,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// WARNA ICON TEMPLATE
class TemplateIconPainter extends CustomPainter {
  final int imageCount;
  final int layoutIndex;

  TemplateIconPainter({required this.imageCount, required this.layoutIndex});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const ui.Color.fromARGB(255, 255, 255, 255) // bisa di ganti dan check di template, def = white
      ..style = PaintingStyle.fill;

    final rects = _getTemplateNormalizedRects(imageCount, layoutIndex);
    const double gap = 1.5; 

    for (var nRect in rects) {
      double left = nRect.left * size.width + gap;
      double top = nRect.top * size.height + gap;
      double right = nRect.right * size.width - gap;
      double bottom = nRect.bottom * size.height - gap;
      
      if (right > left && bottom > top) {
        // slightly rounded corners for tiny layout preview
        canvas.drawRRect(
          RRect.fromLTRBR(left, top, right, bottom, const Radius.circular(2)), 
          paint
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

List<Rect> _getTemplateNormalizedRects(int imageCount, int layoutIndex) {
  // jika gambar nya terdeteksi 2, masuk == 2
  if (imageCount == 2) {
    if (layoutIndex == 0) {
      // Kiri Kanan
      return [const Rect.fromLTRB(0, 0, 0.5, 1), const Rect.fromLTRB(0.5, 0, 1, 1)];
    } else {
      // Atas Bawah
      return [const Rect.fromLTRB(0, 0, 1, 0.5), const Rect.fromLTRB(0, 0.5, 1, 1)];
    }
    // jika gambar nya terdeteksi 3, masuk == 3
  } else if (imageCount == 3) {
    switch (layoutIndex) {
      case 0: //  1 besar kiri, 2 kecil kanan
        return [
          const Rect.fromLTRB(0, 0, 0.5, 1), // kiri besar
          const Rect.fromLTRB(0.5, 0, 1, 0.5), // kanan atas
          const Rect.fromLTRB(0.5, 0.5, 1, 1), // kanan bawah
        ];
      case 1: // 2 kiri kecil, 1 kanan besar
        return [
          const Rect.fromLTRB(0, 0, 0.5, 0.5), // kiri atas
          const Rect.fromLTRB(0, 0.5, 0.5, 1), // kiri bawah
          const Rect.fromLTRB(0.5, 0, 1, 1), // kanan besar
        ];
      case 2: // 1 atas besar, 2 bawah kecil
        return [
          const Rect.fromLTRB(0, 0, 1, 0.5), // atas besar
          const Rect.fromLTRB(0, 0.5, 0.5, 1), // bawah kiri
          const Rect.fromLTRB(0.5, 0.5, 1, 1), // bawah kanan
        ];
      case 3: // 2 atas kecil, 1 bawah besar
        return [
          const Rect.fromLTRB(0, 0, 0.5, 0.5), // atas kiri
          const Rect.fromLTRB(0.5, 0, 1, 0.5), // atas kanan
          const Rect.fromLTRB(0, 0.5, 1, 1), // bawah besar
        ];
      case 4: // Vertical Stack 
        return [
          const Rect.fromLTRB(0, 0, 1, 1 / 3), // atas
          const Rect.fromLTRB(0, 1 / 3, 1, 2 / 3), // tengah
          const Rect.fromLTRB(0, 2 / 3, 1, 1), // bawah
        ];
      case 5: // Horizontal Stack
        return [
          const Rect.fromLTRB(0, 0, 1 / 3, 1), // kiri
          const Rect.fromLTRB(1 / 3, 0, 2 / 3, 1), // tengah
          const Rect.fromLTRB(2 / 3, 0, 1, 1), // kanan
        ];
      default:
        return [];
    }
  } else if (imageCount == 4) {
    switch (layoutIndex) {
      case 0: // 2x2 Grid
        return [
          const Rect.fromLTRB(0, 0, 0.5, 0.5), // kiri atas
          const Rect.fromLTRB(0.5, 0, 1, 0.5), // kanan atas
          const Rect.fromLTRB(0, 0.5, 0.5, 1), // kiri bawah
          const Rect.fromLTRB(0.5, 0.5, 1, 1), // kanan bawah
        ];
      case 1: // 1 kiri besar, 3 kanan kecil
        return [
          const Rect.fromLTRB(0, 0, 0.6, 1), // kiri besar
          const Rect.fromLTRB(0.6, 0, 1, 1 / 3), // kanan atas
          const Rect.fromLTRB(0.6, 1 / 3, 1, 2 / 3), // kanan tengah
          const Rect.fromLTRB(0.6, 2 / 3, 1, 1), // kanan bawah
        ];
      case 2: // 3 kiri kecil, 1 kanan besar
        return [
          const Rect.fromLTRB(0, 0, 0.4, 1 / 3), // kiri atas
          const Rect.fromLTRB(0, 1 / 3, 0.4, 2 / 3), // kiri tengah
          const Rect.fromLTRB(0, 2 / 3, 0.4, 1), // kiri bawah
          const Rect.fromLTRB(0.4, 0, 1, 1), // kanan besar
        ];
      case 3: // 1 atas besar, 3 bawah kecil
        return [
          const Rect.fromLTRB(0, 0, 1, 0.6), // atas besar
          const Rect.fromLTRB(0, 0.6, 1 / 3, 1), // bawah kiri
          const Rect.fromLTRB(1 / 3, 0.6, 2 / 3, 1), // bawah tengah
          const Rect.fromLTRB(2 / 3, 0.6, 1, 1), // bawah kanan
        ];
      case 4: // 3 atas kecil, 1 bawah besar
        return [
          const Rect.fromLTRB(0, 0, 1 / 3, 0.4), // atas kiri
          const Rect.fromLTRB(1 / 3, 0, 2 / 3, 0.4), // atas tengah
          const Rect.fromLTRB(2 / 3, 0, 1, 0.4), // atas kanan
          const Rect.fromLTRB(0, 0.4, 1, 1), // bawah besar
        ];
      case 5: // Vertical Stack
        return [
          const Rect.fromLTRB(0, 0, 1, 0.25), // atas
          const Rect.fromLTRB(0, 0.25, 1, 0.5), // tengah atas
          const Rect.fromLTRB(0, 0.5, 1, 0.75), // tengah bawah
          const Rect.fromLTRB(0, 0.75, 1, 1), // bawah
        ];
      case 6: // Horizontal Stack
        return [
          const Rect.fromLTRB(0, 0, 0.25, 1), // kiri
          const Rect.fromLTRB(0.25, 0, 0.5, 1), // tengah kiril
          const Rect.fromLTRB(0.5, 0, 0.75, 1), // tengah kanan
          const Rect.fromLTRB(0.75, 0, 1, 1), // kanan
        ];
      default:
        return [];
    }
  }
  return [];
}

// bagian mendeteksi jumlah gambar lalu jadi kasih template
int _getTemplateCount(int imageCount) {
  if (imageCount == 2) return 2;
  if (imageCount == 3) return 6;
  if (imageCount == 4) return 7;
  return 0;
}

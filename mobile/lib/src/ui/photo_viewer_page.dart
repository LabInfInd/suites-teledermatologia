import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Anteprima a schermo intero con zoom, per controllare messa a fuoco e
/// inquadratura prima dell'invio.
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  // Limite di decodifica: sufficiente per valutare la nitidezza senza
  // occupare troppa memoria con sensori ad alta risoluzione.
  static const _maxDecodedSide = 4096;

  late final ImageProvider _image = ResizeImage(
    MemoryImage(widget.bytes),
    width: _maxDecodedSide,
    height: _maxDecodedSide,
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );

  @override
  void dispose() {
    _image.evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Controllo della foto'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: InteractiveViewer(
          maxScale: 10,
          child: Center(
            child: Image(
              image: _image,
              fit: BoxFit.contain,
              semanticLabel: 'Foto acquisita, ingrandibile',
              errorBuilder: (context, error, stackTrace) => const Text(
                'Anteprima non disponibile per questo formato su questo dispositivo.',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

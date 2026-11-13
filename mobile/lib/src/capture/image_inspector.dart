import 'dart:typed_data';
import 'dart:ui' as ui;

import '../domain/captured_photo.dart';

abstract interface class ImageInspector {
  /// Dimensioni in pixel, oppure `null` se il formato non è decodificabile
  /// su questo dispositivo.
  Future<ImageDimensions?> dimensions(Uint8List bytes);
}

/// Legge le dimensioni con i decoder del motore Flutter, senza decodificare
/// l'intera immagine.
class EngineImageInspector implements ImageInspector {
  const EngineImageInspector();

  @override
  Future<ImageDimensions?> dimensions(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return ImageDimensions(descriptor.width, descriptor.height);
    } on Exception {
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

import '../domain/captured_photo.dart';
import 'image_inspector.dart';
import 'location_metadata.dart';
import 'photo_picker.dart';

enum PhotoRejection { unsupportedFormat, tooLarge }

class PhotoRejectedException implements Exception {
  const PhotoRejectedException(this.reason);

  final PhotoRejection reason;
}

/// Controlla formato e dimensione della foto acquisita, rimuove la posizione
/// GPS e ne legge le dimensioni. Usata sia dall'analisi rapida del medico sia
/// dai casi del paziente.
Future<CapturedPhoto> preparePhoto(
  PickedPhoto picked,
  ImageInspector inspector, {
  required int maxBytes,
}) async {
  final format = ImageFormat.detect(picked.bytes);
  if (format == null) {
    throw const PhotoRejectedException(PhotoRejection.unsupportedFormat);
  }
  if (picked.bytes.length > maxBytes) {
    throw const PhotoRejectedException(PhotoRejection.tooLarge);
  }
  final sanitized = removeLocationMetadata(picked.bytes, format);
  return CapturedPhoto(
    bytes: sanitized.bytes,
    format: format,
    source: picked.source,
    dimensions: await inspector.dimensions(sanitized.bytes),
    locationMetadataRemoved: sanitized.locationRemoved,
  );
}

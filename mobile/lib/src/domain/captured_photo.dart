import 'dart:typed_data';

/// Provenienza della foto, inviata al server nel campo `source`.
enum PhotoSource {
  camera,
  gallery,

  /// Foto recuperata dopo che Android ha chiuso l'app durante lo scatto:
  /// il sistema non indica se proveniva dalla fotocamera o dalla galleria.
  unknown;

  String get apiValue => name;
}

/// Formati accettati, riconosciuti dal contenuto e non dall'estensione.
enum ImageFormat {
  jpeg('image/jpeg', 'jpg', 'JPEG'),
  png('image/png', 'png', 'PNG'),
  heic('image/heic', 'heic', 'HEIC'),
  heif('image/heif', 'heif', 'HEIF'),
  webp('image/webp', 'webp', 'WebP');

  const ImageFormat(this.mediaType, this.extension, this.label);

  final String mediaType;
  final String extension;
  final String label;

  static const _heicBrands = {'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx'};
  static const _heifBrands = {'mif1', 'msf1'};

  /// Riconosce il formato dalla firma iniziale del file; `null` se non è
  /// tra quelli accettati.
  static ImageFormat? detect(Uint8List bytes) {
    if (_startsWith(bytes, 0, const [0xFF, 0xD8, 0xFF])) return jpeg;
    if (_startsWith(bytes, 0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return png;
    }
    if (_ascii(bytes, 0, 4) == 'RIFF' && _ascii(bytes, 8, 4) == 'WEBP') return webp;
    if (_ascii(bytes, 4, 4) == 'ftyp') {
      final brand = _ascii(bytes, 8, 4);
      if (_heicBrands.contains(brand)) return heic;
      if (_heifBrands.contains(brand)) return heif;
    }
    return null;
  }

  static bool _startsWith(Uint8List bytes, int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  static String? _ascii(Uint8List bytes, int offset, int length) {
    if (bytes.length < offset + length) return null;
    return String.fromCharCodes(bytes, offset, offset + length);
  }
}

class ImageDimensions {
  const ImageDimensions(this.width, this.height);

  final int width;
  final int height;

  int get shortSide => width < height ? width : height;
  double get megapixels => width * height / 1e6;
}

/// Foto pronta per l'anteprima e l'invio, conservata solo in memoria.
class CapturedPhoto {
  const CapturedPhoto({
    required this.bytes,
    required this.format,
    required this.source,
    this.dimensions,
    this.locationMetadataRemoved = false,
  });

  /// Lato corto sotto il quale l'anteprima segnala una risoluzione bassa.
  /// È un avviso per l'operatore, non un requisito dei modelli.
  static const recommendedMinShortSide = 1000;

  final Uint8List bytes;
  final ImageFormat format;
  final PhotoSource source;

  /// `null` se il formato non è decodificabile su questo dispositivo.
  final ImageDimensions? dimensions;

  /// Vero se dalla foto sono stati rimossi metadati di posizione (GPS).
  final bool locationMetadataRemoved;

  int get sizeInBytes => bytes.length;

  bool get hasLowResolution {
    final dimensions = this.dimensions;
    return dimensions != null && dimensions.shortSide < recommendedMinShortSide;
  }
}

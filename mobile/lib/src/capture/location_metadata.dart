import 'dart:convert';
import 'dart:typed_data';

import '../domain/captured_photo.dart';

class SanitizedImage {
  const SanitizedImage(this.bytes, {required this.locationRemoved});

  final Uint8List bytes;
  final bool locationRemoved;
}

/// Rimuove i metadati di posizione (GPS) dai file JPEG senza ricomprimere
/// l'immagine: i dati dei pixel e gli altri metadati, compreso
/// l'orientamento EXIF, restano invariati.
///
/// Gli altri formati vengono restituiti invariati; per questi la rimozione
/// dei metadati spetta al server (vedi `docs/api-contratto-proposta.md`).
/// Anche un JPEG non interpretabile viene restituito invariato.
SanitizedImage removeLocationMetadata(Uint8List bytes, ImageFormat format) {
  if (format != ImageFormat.jpeg) {
    return SanitizedImage(bytes, locationRemoved: false);
  }
  try {
    return _sanitizeJpeg(bytes);
  } on RangeError {
    return SanitizedImage(bytes, locationRemoved: false);
  }
}

const _exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
final _xmpHeaders = [
  ascii.encode('http://ns.adobe.com/xap/1.0/\x00'),
  ascii.encode('http://ns.adobe.com/xmp/extension/\x00'),
];
final _gpsMarker = ascii.encode('GPS');

const _gpsInfoTag = 0x8825;
const _gpsVersionTag = 0x0000;

SanitizedImage _sanitizeJpeg(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return SanitizedImage(bytes, locationRemoved: false);
  }

  Uint8List? patched;
  final dropped = <(int, int)>[];
  var offset = 2;

  // I metadati precedono l'inizio della scansione (SOS): oltre non si legge.
  while (offset + 4 <= bytes.length && bytes[offset] == 0xFF) {
    final marker = bytes[offset + 1];
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) break;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    final dataStart = offset + 4;
    final segmentEnd = offset + 2 + length;
    if (length < 2 || segmentEnd > bytes.length) break;

    if (marker == 0xE1) {
      if (_matches(bytes, dataStart, _exifHeader)) {
        final target = patched ?? Uint8List.fromList(bytes);
        if (_neutralizeGps(target, dataStart + _exifHeader.length, segmentEnd)) {
          patched = target;
        }
      } else if (_xmpHeaders.any((h) => _matches(bytes, dataStart, h)) &&
          _contains(bytes, dataStart, segmentEnd, _gpsMarker)) {
        // Un pacchetto XMP con coordinate viene eliminato per intero.
        dropped.add((offset, segmentEnd));
      }
    }
    offset = segmentEnd;
  }

  final source = patched ?? bytes;
  final removed = patched != null || dropped.isNotEmpty;
  if (dropped.isEmpty) return SanitizedImage(source, locationRemoved: removed);

  final builder = BytesBuilder(copy: false);
  var cursor = 0;
  for (final (start, end) in dropped) {
    builder.add(Uint8List.sublistView(source, cursor, start));
    cursor = end;
  }
  builder.add(Uint8List.sublistView(source, cursor));
  return SanitizedImage(builder.takeBytes(), locationRemoved: true);
}

/// Sostituisce il contenuto della sottodirectory GPS del blocco EXIF con la
/// sola voce GPSVersionID, azzerando coordinate, altitudine, orario e
/// direzione. Restituisce `true` se c'erano dati da rimuovere.
bool _neutralizeGps(Uint8List out, int tiffStart, int segmentEnd) {
  if (tiffStart + 8 > segmentEnd) return false;
  final Endian endian;
  if (out[tiffStart] == 0x49 && out[tiffStart + 1] == 0x49) {
    endian = Endian.little;
  } else if (out[tiffStart] == 0x4D && out[tiffStart + 1] == 0x4D) {
    endian = Endian.big;
  } else {
    return false;
  }
  // Gli offset TIFF sono relativi all'inizio dell'intestazione TIFF.
  final tiff = ByteData.sublistView(out, tiffStart, segmentEnd);
  if (tiff.getUint16(2, endian) != 42) return false;

  final gps = _findIfdPointer(tiff, tiff.getUint32(4, endian), _gpsInfoTag, endian);
  if (gps == null || gps + 2 > tiff.lengthInBytes) return false;

  final count = tiff.getUint16(gps, endian);
  final entriesEnd = gps + 2 + count * 12;
  if (count == 0 || entriesEnd + 4 > tiff.lengthInBytes) return false;
  if (count == 1 && tiff.getUint16(gps + 2, endian) == _gpsVersionTag) return false;

  for (var i = 0; i < count; i++) {
    final entry = gps + 2 + i * 12;
    final size = _typeSize(tiff.getUint16(entry + 2, endian)) * tiff.getUint32(entry + 4, endian);
    if (size > 4) {
      final valueOffset = tiff.getUint32(entry + 8, endian);
      if (valueOffset + size <= tiff.lengthInBytes) {
        _zero(tiff, valueOffset, valueOffset + size);
      }
    }
  }
  _zero(tiff, gps, entriesEnd + 4);

  // Una directory TIFF deve contenere almeno una voce: resta GPSVersionID 2.3.0.0.
  tiff
    ..setUint16(gps, 1, endian)
    ..setUint16(gps + 2, _gpsVersionTag, endian)
    ..setUint16(gps + 4, 1, endian) // BYTE
    ..setUint32(gps + 6, 4, endian)
    ..setUint8(gps + 10, 2)
    ..setUint8(gps + 11, 3)
    ..setUint32(gps + 14, 0, endian);
  return true;
}

int? _findIfdPointer(ByteData tiff, int ifd, int tag, Endian endian) {
  if (ifd + 2 > tiff.lengthInBytes) return null;
  final count = tiff.getUint16(ifd, endian);
  for (var i = 0; i < count; i++) {
    final entry = ifd + 2 + i * 12;
    if (entry + 12 > tiff.lengthInBytes) return null;
    if (tiff.getUint16(entry, endian) == tag) return tiff.getUint32(entry + 8, endian);
  }
  return null;
}

int _typeSize(int type) => switch (type) {
  1 || 2 || 6 || 7 => 1,
  3 || 8 => 2,
  4 || 9 || 11 || 13 => 4,
  5 || 10 || 12 => 8,
  _ => 0,
};

void _zero(ByteData data, int start, int end) {
  for (var i = start; i < end; i++) {
    data.setUint8(i, 0);
  }
}

bool _matches(Uint8List bytes, int offset, List<int> pattern) {
  if (offset + pattern.length > bytes.length) return false;
  for (var i = 0; i < pattern.length; i++) {
    if (bytes[offset + i] != pattern[i]) return false;
  }
  return true;
}

bool _contains(Uint8List bytes, int start, int end, List<int> pattern) {
  for (var i = start; i + pattern.length <= end; i++) {
    if (_matches(bytes, i, pattern)) return true;
  }
  return false;
}

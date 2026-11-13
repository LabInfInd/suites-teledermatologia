import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/capture/location_metadata.dart';
import 'package:teledermatologia/src/domain/captured_photo.dart';

import '../support/fakes.dart';

void main() {
  for (final endian in [Endian.little, Endian.big]) {
    final order = endian == Endian.little ? 'little endian' : 'big endian';

    test('rimuove le coordinate GPS da un JPEG ($order) senza toccare il resto', () {
      final jpeg = TestJpeg(endian: endian);
      final input = jpeg.build();
      final original = Uint8List.fromList(input);

      final result = removeLocationMetadata(input, ImageFormat.jpeg);

      expect(result.locationRemoved, isTrue);
      expect(input, original, reason: 'l’originale non deve essere modificato');
      expect(result.bytes, hasLength(input.length));

      final tiff = ByteData.sublistView(result.bytes, TestJpeg.tiffStart, jpeg.exifSegmentEnd);
      // Orientamento invariato.
      expect(tiff.getUint16(TestJpeg.ifd0 + 2, endian), 0x0112);
      expect(tiff.getUint16(TestJpeg.ifd0 + 10, endian), 6);
      // Resta solo GPSVersionID 2.3.0.0.
      const gps = TestJpeg.gpsIfd;
      expect(tiff.getUint16(gps, endian), 1);
      expect(tiff.getUint16(gps + 2, endian), 0x0000);
      expect(tiff.getUint16(gps + 4, endian), 1);
      expect(tiff.getUint32(gps + 6, endian), 4);
      expect([tiff.getUint8(gps + 10), tiff.getUint8(gps + 11)], [2, 3]);
      expect(tiff.getUint32(gps + 14, endian), 0);
      // Riferimenti, coordinate e valori razionali azzerati.
      final cleared = Uint8List.sublistView(
        result.bytes,
        TestJpeg.tiffStart + gps + 18,
        jpeg.exifSegmentEnd,
      );
      expect(cleared.every((b) => b == 0), isTrue);
      // Tutto ciò che segue il blocco EXIF, scansione compresa, è identico.
      expect(
        result.bytes.sublist(jpeg.exifSegmentEnd),
        original.sublist(jpeg.exifSegmentEnd),
      );
    });
  }

  test('lascia invariato un JPEG senza GPS', () {
    final input = TestJpeg(withGps: false).build();
    final result = removeLocationMetadata(input, ImageFormat.jpeg);
    expect(result.locationRemoved, isFalse);
    expect(result.bytes, input);
  });

  test('lascia invariata una directory GPS senza posizione', () {
    final input = TestJpeg(gpsVersionOnly: true).build();
    final result = removeLocationMetadata(input, ImageFormat.jpeg);
    expect(result.locationRemoved, isFalse);
    expect(result.bytes, input);
  });

  test('elimina i pacchetti XMP con coordinate e conserva gli altri', () {
    final withGps = app1Segment(
      'http://ns.adobe.com/xap/1.0/',
      '<x:xmpmeta><rdf:Description exif:GPSLatitude="41,7.2N"/></x:xmpmeta>',
    );
    final withoutGps = app1Segment(
      'http://ns.adobe.com/xap/1.0/',
      '<x:xmpmeta><rdf:Description tiff:Orientation="6"/></x:xmpmeta>',
    );
    final jpeg = TestJpeg(withGps: false);
    final input = jpeg.build(segmentsAfterExif: [withGps, withoutGps]);

    final result = removeLocationMetadata(input, ImageFormat.jpeg);

    expect(result.locationRemoved, isTrue);
    expect(result.bytes, [
      ...input.sublist(0, jpeg.exifSegmentEnd),
      ...input.sublist(jpeg.exifSegmentEnd + withGps.length),
    ]);
  });

  test('non modifica formati diversi dal JPEG', () {
    final result = removeLocationMetadata(pngBytes, ImageFormat.png);
    expect(result.locationRemoved, isFalse);
    expect(identical(result.bytes, pngBytes), isTrue);
  });

  test('restituisce invariato un JPEG troncato o malformato', () {
    final complete = TestJpeg().build();
    for (final length in [3, 8, 20, 60]) {
      final truncated = Uint8List.sublistView(complete, 0, length);
      final result = removeLocationMetadata(truncated, ImageFormat.jpeg);
      expect(result.bytes, truncated, reason: 'lunghezza $length');
      expect(result.locationRemoved, isFalse);
    }
  });
}

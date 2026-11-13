import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:teledermatologia/src/api/submission_api.dart';
import 'package:teledermatologia/src/capture/image_inspector.dart';
import 'package:teledermatologia/src/capture/photo_picker.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/captured_photo.dart';
import 'package:teledermatologia/src/domain/submission.dart';

/// PNG valido di 1×1 pixel.
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Inizio di un JPEG: basta per il riconoscimento del formato.
final Uint8List jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xD9]);

final Uint8List gifBytes = Uint8List.fromList(ascii.encode('GIF89a......'));

PickedPhoto pickedPng({PhotoSource source = PhotoSource.camera}) =>
    PickedPhoto(bytes: pngBytes, source: source);

CapturedPhoto capturedJpeg({int size = 300 * 1024}) => CapturedPhoto(
  bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(size - 3, 7)]),
  format: ImageFormat.jpeg,
  source: PhotoSource.camera,
);

SubmissionRequest sampleRequest({CapturedPhoto? photo}) => SubmissionRequest(
  submissionId: '0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b',
  caseCode: 'CASO-001',
  mode: AcquisitionMode.dermoscopic,
  photo: photo ?? capturedJpeg(),
);

class FakePhotoPicker implements PhotoPicker {
  final _results = Queue<Object?>();
  final requests = <PhotoSource>[];
  PickedPhoto? lostPhoto;

  /// Accoda un risultato: [PickedPhoto], `null` (annullato), un'eccezione
  /// oppure un `Future` da completare nel test.
  void enqueue(Object? result) => _results.add(result);

  @override
  Future<PickedPhoto?> pick(PhotoSource source) async {
    requests.add(source);
    final result = _results.removeFirst();
    if (result is Exception) throw result;
    if (result is Future<PickedPhoto?>) return result;
    return result as PickedPhoto?;
  }

  @override
  Future<PickedPhoto?> recoverLostPhoto() async => lostPhoto;
}

class FakeImageInspector implements ImageInspector {
  FakeImageInspector([this.result = const ImageDimensions(4032, 3024)]);

  final ImageDimensions? result;

  @override
  Future<ImageDimensions?> dimensions(Uint8List bytes) async => result;
}

typedef FakeSubmitHandler =
    Future<SubmissionReceipt> Function(
      SubmissionRequest request,
      void Function(SubmissionProgress progress)? onProgress,
      Future<void>? cancelSignal,
    );

class FakeSubmissionApi implements SubmissionApi {
  FakeSubmissionApi([FakeSubmitHandler? handler]) : handler = handler ?? receiptFor;

  FakeSubmitHandler handler;
  final requests = <SubmissionRequest>[];

  @override
  bool get isSimulated => false;

  @override
  Future<SubmissionReceipt> submit(
    SubmissionRequest request, {
    void Function(SubmissionProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) {
    requests.add(request);
    return handler(request, onProgress, cancelSignal);
  }

  static Future<SubmissionReceipt> receiptFor(
    SubmissionRequest request,
    void Function(SubmissionProgress progress)? onProgress,
    Future<void>? cancelSignal,
  ) async => SubmissionReceipt(
    submissionId: request.submissionId,
    caseCode: request.caseCode,
    mode: request.mode,
    serverReference: 'SRV-1',
  );
}

/// Costruisce un JPEG sintetico con blocco EXIF (orientamento e GPS), una
/// tabella fittizia e un segmento di scansione.
class TestJpeg {
  TestJpeg({this.endian = Endian.little, this.withGps = true, this.gpsVersionOnly = false});

  final Endian endian;
  final bool withGps;
  final bool gpsVersionOnly;

  // Offset relativi all'inizio dell'intestazione TIFF.
  static const ifd0 = 8;
  static const gpsIfd = 38;
  int get gpsCount => gpsVersionOnly ? 1 : 4;
  int get gpsData => gpsIfd + 2 + gpsCount * 12 + 4;
  int get tiffLength => withGps ? gpsData + (gpsVersionOnly ? 0 : 24) : gpsIfd;

  /// Posizione dell'intestazione TIFF nel file.
  static const tiffStart = 2 + 4 + 6;

  Uint8List buildTiff() {
    final tiff = ByteData(tiffLength);
    tiff
      ..setUint8(0, endian == Endian.little ? 0x49 : 0x4D)
      ..setUint8(1, endian == Endian.little ? 0x49 : 0x4D)
      ..setUint16(2, 42, endian)
      ..setUint32(4, ifd0, endian)
      ..setUint16(ifd0, withGps ? 2 : 1, endian);
    _entry(tiff, ifd0 + 2, tag: 0x0112, type: 3, count: 1, value: 6); // orientamento
    if (withGps) {
      _entry(tiff, ifd0 + 14, tag: 0x8825, type: 4, count: 1, value: gpsIfd);
      tiff.setUint32(ifd0 + 26, 0, endian);
      tiff.setUint16(gpsIfd, gpsCount, endian);
      _entry(tiff, gpsIfd + 2, tag: 0x0000, type: 1, count: 4, value: 0);
      tiff
        ..setUint8(gpsIfd + 10, 2)
        ..setUint8(gpsIfd + 11, 3);
      if (!gpsVersionOnly) {
        _entry(tiff, gpsIfd + 14, tag: 0x0001, type: 2, count: 2, value: 0);
        tiff.setUint8(gpsIfd + 22, 0x4E); // 'N'
        _entry(tiff, gpsIfd + 26, tag: 0x0002, type: 5, count: 3, value: gpsData);
        _entry(tiff, gpsIfd + 38, tag: 0x0003, type: 2, count: 2, value: 0);
        tiff.setUint8(gpsIfd + 46, 0x45); // 'E'
        for (final (i, value) in [41, 1, 7, 1, 1234, 100].indexed) {
          tiff.setUint32(gpsData + i * 4, value, endian);
        }
      }
    } else {
      tiff.setUint32(ifd0 + 14, 0, endian);
    }
    return tiff.buffer.asUint8List();
  }

  void _entry(ByteData tiff, int at, {required int tag, required int type, required int count, required int value}) {
    tiff
      ..setUint16(at, tag, endian)
      ..setUint16(at + 2, type, endian)
      ..setUint32(at + 4, count, endian);
    if (type == 3) {
      tiff.setUint16(at + 8, value, endian);
    } else if (type == 4 || type == 5) {
      tiff.setUint32(at + 8, value, endian);
    }
  }

  static const scan = [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x12, 0x34, 0xFF, 0x00, 0x56];

  Uint8List build({List<List<int>> segmentsAfterExif = const []}) {
    final tiff = buildTiff();
    final exifLength = 2 + 6 + tiff.length;
    return Uint8List.fromList([
      0xFF, 0xD8,
      0xFF, 0xE1, exifLength >> 8, exifLength & 0xFF,
      ...ascii.encode('Exif'), 0, 0,
      ...tiff,
      for (final segment in segmentsAfterExif) ...segment,
      0xFF, 0xDB, 0x00, 0x04, 0x00, 0x00,
      ...scan,
      0xFF, 0xD9,
    ]);
  }

  int get exifSegmentEnd => tiffStart + tiffLength;
}

List<int> app1Segment(String header, String payload) {
  final data = [...ascii.encode(header), 0, ...utf8.encode(payload)];
  final length = data.length + 2;
  return [0xFF, 0xE1, length >> 8, length & 0xFF, ...data];
}

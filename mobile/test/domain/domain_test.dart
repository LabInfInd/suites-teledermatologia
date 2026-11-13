import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/captured_photo.dart';
import 'package:teledermatologia/src/domain/case_code.dart';
import 'package:teledermatologia/src/domain/submission.dart';

import '../support/fakes.dart';

void main() {
  group('AcquisitionMode', () {
    test('usa i valori concordati per il server', () {
      expect(AcquisitionMode.clinical.apiValue, 'clinical');
      expect(AcquisitionMode.dermoscopic.apiValue, 'dermoscopic');
    });
  });

  group('CaseCode', () {
    test('accetta codici pseudonimi', () {
      for (final code in ['CASO-001', 'abc', 'P_12-B', '  BA2026-07  ']) {
        expect(CaseCode.validate(code), isNull, reason: code);
      }
    });

    test('elimina gli spazi esterni', () {
      expect(CaseCode.normalize('  CASO-001 '), 'CASO-001');
    });

    test('segnala codici vuoti, corti o lunghi', () {
      expect(CaseCode.validate('   '), CaseCodeIssue.empty);
      expect(CaseCode.validate('AB'), CaseCodeIssue.tooShort);
      expect(CaseCode.validate('A' * 41), CaseCodeIssue.tooLong);
    });

    test('rifiuta caratteri non ammessi', () {
      for (final code in ['Mario Rossi', '-ABC', 'caso/1', 'càso1', 'a@b.it']) {
        expect(CaseCode.validate(code), CaseCodeIssue.invalidCharacters, reason: code);
      }
    });

    test('rifiuta strutture da codice fiscale, anche con omocodia', () {
      expect(CaseCode.validate('RSSMRA85T10A562S'), CaseCodeIssue.looksLikeTaxCode);
      expect(CaseCode.validate('rssmra85t10a562s'), CaseCodeIssue.looksLikeTaxCode);
      expect(CaseCode.validate('RSSMRAURTMLARSNL'), CaseCodeIssue.looksLikeTaxCode);
    });
  });

  group('ImageFormat.detect', () {
    Uint8List bytes(List<int> prefix) => Uint8List.fromList([...prefix, ...List.filled(16, 0)]);
    Uint8List isoBox(String brand) =>
        bytes([0, 0, 0, 24, ...ascii.encode('ftyp'), ...ascii.encode(brand)]);

    test('riconosce i formati accettati dal contenuto', () {
      expect(ImageFormat.detect(jpegBytes), ImageFormat.jpeg);
      expect(ImageFormat.detect(pngBytes), ImageFormat.png);
      expect(
        ImageFormat.detect(bytes([...ascii.encode('RIFF'), 1, 2, 3, 4, ...ascii.encode('WEBP')])),
        ImageFormat.webp,
      );
      expect(ImageFormat.detect(isoBox('heic')), ImageFormat.heic);
      expect(ImageFormat.detect(isoBox('mif1')), ImageFormat.heif);
    });

    test('rifiuta formati non previsti o file troppo corti', () {
      expect(ImageFormat.detect(gifBytes), isNull);
      expect(ImageFormat.detect(isoBox('avif')), isNull);
      expect(ImageFormat.detect(bytes(ascii.encode('II*\x00'))), isNull); // TIFF/DNG
      expect(ImageFormat.detect(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(ImageFormat.detect(Uint8List(0)), isNull);
    });
  });

  group('CapturedPhoto', () {
    test('segnala la risoluzione bassa sul lato corto', () {
      CapturedPhoto photo(ImageDimensions? d) => CapturedPhoto(
        bytes: pngBytes,
        format: ImageFormat.png,
        source: PhotoSource.gallery,
        dimensions: d,
      );
      expect(photo(const ImageDimensions(4032, 3024)).hasLowResolution, isFalse);
      expect(photo(const ImageDimensions(1600, 900)).hasLowResolution, isTrue);
      expect(photo(null).hasLowResolution, isFalse);
    });
  });

  group('generateSubmissionId', () {
    test('produce UUID v4 distinti', () {
      final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      final ids = List.generate(200, (_) => generateSubmissionId());
      expect(ids.every(uuid.hasMatch), isTrue);
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('SubmissionFailure', () {
    test('ritenta da solo soltanto gli errori transitori', () {
      const transient = {
        SubmissionFailureKind.network,
        SubmissionFailureKind.timeout,
        SubmissionFailureKind.rateLimited,
        SubmissionFailureKind.serverUnavailable,
      };
      for (final kind in SubmissionFailureKind.values) {
        final failure = SubmissionFailure(kind);
        expect(failure.isTransient, transient.contains(kind), reason: kind.name);
        if (failure.isTransient) expect(failure.canRetry, isTrue, reason: kind.name);
      }
    });

    test('non propone di ritentare errori che richiedono modifiche', () {
      for (final kind in [
        SubmissionFailureKind.rejected,
        SubmissionFailureKind.unauthorized,
        SubmissionFailureKind.payloadTooLarge,
        SubmissionFailureKind.notConfigured,
      ]) {
        expect(SubmissionFailure(kind).canRetry, isFalse, reason: kind.name);
      }
    });
  });
}

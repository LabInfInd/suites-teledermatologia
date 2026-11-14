import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/capture/photo_picker.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/captured_photo.dart';
import 'package:teledermatologia/src/domain/submission.dart';
import 'package:teledermatologia/src/ui/acquisition_controller.dart';

import '../support/fakes.dart';

void main() {
  late FakePhotoPicker picker;
  late FakeSubmissionApi api;
  late AcquisitionController controller;
  var idCounter = 0;

  AcquisitionController create({
    bool withServer = true,
    int maxUploadBytes = 1 << 20,
  }) => AcquisitionController(
    picker: picker,
    inspector: FakeImageInspector(),
    api: withServer ? api : null,
    maxUploadBytes: maxUploadBytes,
    newSubmissionId: () => 'id-${++idCounter}',
  );

  Future<void> readyToSubmit() async {
    controller.selectMode(AcquisitionMode.clinical);
    picker.enqueue(pickedPng());
    await controller.acquire(PhotoSource.camera);
    controller.updateCaseCode('  CASO-001 ');
  }

  setUp(() {
    idCounter = 0;
    picker = FakePhotoPicker();
    api = FakeSubmissionApi();
    controller = create();
  });

  tearDown(() => controller.dispose());

  test('cambiare modello genera un nuovo invio e cambiare modalita azzera il modello', () async {
    await readyToSubmit();
    api.handler = (_, _, _) async =>
        throw const SubmissionFailure(SubmissionFailureKind.network);
    controller.selectModel('clinical-convnextv2-tiny');
    await controller.submit();
    controller.selectModel('clinical-dinov2-base');
    await controller.submit();
    expect(api.requests.map((r) => r.submissionId), ['id-1', 'id-2']);
    expect(api.requests.map((r) => r.modelId), [
      'clinical-convnextv2-tiny',
      'clinical-dinov2-base',
    ]);
    controller.selectMode(AcquisitionMode.dermoscopic);
    expect(controller.modelId, isNull);
  });

  group('acquisizione', () {
    test('richiede prima la scelta del tipo di acquisizione', () async {
      expect(controller.canAcquire, isFalse);
      await controller.acquire(PhotoSource.camera);
      expect(picker.requests, isEmpty);

      controller.selectMode(AcquisitionMode.dermoscopic);
      expect(controller.canAcquire, isTrue);
    });

    test(
      'conserva la foto scattata con formato, origine e dimensioni',
      () async {
        controller.selectMode(AcquisitionMode.clinical);
        picker.enqueue(pickedPng());

        await controller.acquire(PhotoSource.camera);

        final photo = controller.photo!;
        expect(picker.requests, [PhotoSource.camera]);
        expect(photo.format, ImageFormat.png);
        expect(photo.source, PhotoSource.camera);
        expect(photo.dimensions?.width, 4032);
        expect(controller.photoNotice, isNull);
      },
    );

    test('segnala l’acquisizione in corso', () async {
      controller.selectMode(AcquisitionMode.clinical);
      final pending = Completer<PickedPhoto?>();
      picker.enqueue(pending.future);

      final done = controller.acquire(PhotoSource.gallery);
      expect(controller.isPicking, isTrue);
      expect(controller.canAcquire, isFalse);
      pending.complete(pickedPng(source: PhotoSource.gallery));
      await done;

      expect(controller.isPicking, isFalse);
      expect(controller.photo?.source, PhotoSource.gallery);
    });

    test('l’annullamento mantiene la foto precedente', () async {
      controller.selectMode(AcquisitionMode.clinical);
      picker.enqueue(null);
      await controller.acquire(PhotoSource.camera);
      expect(controller.photo, isNull);
      expect(controller.photoNotice, PhotoNotice.cancelled);

      picker
        ..enqueue(pickedPng())
        ..enqueue(null);
      await controller.acquire(PhotoSource.camera);
      final previous = controller.photo;
      await controller.acquire(PhotoSource.camera);

      expect(controller.photo, same(previous));
      expect(controller.photoNotice, PhotoNotice.cancelledKeptPrevious);
    });

    test('segnala i permessi negati senza perdere la foto', () async {
      controller.selectMode(AcquisitionMode.clinical);
      picker
        ..enqueue(pickedPng())
        ..enqueue(
          const PhotoPickException(PhotoPickFailureKind.cameraPermissionDenied),
        )
        ..enqueue(
          const PhotoPickException(PhotoPickFailureKind.photoPermissionDenied),
        );
      await controller.acquire(PhotoSource.camera);
      final previous = controller.photo;

      await controller.acquire(PhotoSource.camera);
      expect(controller.photoNotice, PhotoNotice.cameraPermissionDenied);
      await controller.acquire(PhotoSource.gallery);
      expect(controller.photoNotice, PhotoNotice.photoPermissionDenied);
      expect(controller.photo, same(previous));
      expect(controller.isPicking, isFalse);
    });

    test('rifiuta formati non supportati e file oltre il limite', () async {
      controller.dispose();
      controller = create(maxUploadBytes: 50);
      controller.selectMode(AcquisitionMode.clinical);
      picker
        ..enqueue(PickedPhoto(bytes: gifBytes, source: PhotoSource.gallery))
        ..enqueue(
          PickedPhoto(bytes: TestJpeg().build(), source: PhotoSource.gallery),
        );

      await controller.acquire(PhotoSource.gallery);
      expect(controller.photoNotice, PhotoNotice.unsupportedFormat);
      await controller.acquire(PhotoSource.gallery);
      expect(controller.photoNotice, PhotoNotice.tooLarge);
      expect(controller.photo, isNull);
    });

    test('rimuove la posizione GPS dalle foto JPEG', () async {
      controller.selectMode(AcquisitionMode.clinical);
      final jpeg = TestJpeg().build();
      picker.enqueue(PickedPhoto(bytes: jpeg, source: PhotoSource.gallery));

      await controller.acquire(PhotoSource.gallery);

      expect(controller.photo!.locationMetadataRemoved, isTrue);
      expect(controller.photo!.bytes, isNot(jpeg));
    });

    test(
      'recupera la foto persa da Android senza scegliere la modalità',
      () async {
        picker.lostPhoto = PickedPhoto(
          bytes: pngBytes,
          source: PhotoSource.unknown,
        );
        await controller.recoverLostPhoto();
        expect(controller.photo?.source, PhotoSource.unknown);
        expect(controller.photoNotice, PhotoNotice.recovered);
        expect(controller.mode, isNull);
        expect(controller.canSubmit, isFalse);
      },
    );
  });

  group('invio', () {
    test('richiede modalità, foto, codice caso valido e server', () async {
      expect(controller.canSubmit, isFalse);
      await readyToSubmit();
      expect(controller.canSubmit, isTrue);

      controller.updateCaseCode('RSSMRA85T10A562S');
      expect(controller.canSubmit, isFalse);

      final noServer = create(withServer: false);
      addTearDown(noServer.dispose);
      noServer.selectMode(AcquisitionMode.clinical);
      picker.enqueue(pickedPng());
      await noServer.acquire(PhotoSource.camera);
      noServer.updateCaseCode('CASO-001');
      expect(noServer.hasServer, isFalse);
      expect(noServer.canSubmit, isFalse);
    });

    test(
      'invia i dati dichiarati e blocca le modifiche dopo la conferma',
      () async {
        await readyToSubmit();
        await controller.submit();

        final sent = api.requests.single;
        expect(sent.mode, AcquisitionMode.clinical);
        expect(sent.caseCode, 'CASO-001');
        expect(sent.submissionId, 'id-1');
        expect(sent.photo, same(controller.photo));
        expect(controller.upload, isA<UploadSucceeded>());
        expect(controller.isLocked, isTrue);

        controller.selectMode(AcquisitionMode.dermoscopic);
        controller.updateCaseCode('ALTRO');
        expect(controller.mode, AcquisitionMode.clinical);
        expect(controller.caseCode, '  CASO-001 ');
      },
    );

    test('mostra l’avanzamento durante l’invio', () async {
      await readyToSubmit();
      final response = Completer<SubmissionReceipt>();
      api.handler = (request, onProgress, _) {
        onProgress?.call(
          const SubmissionProgress(
            phase: SubmissionPhase.uploading,
            attempt: 1,
            maxAttempts: 3,
            bytesSent: 50,
            totalBytes: 100,
          ),
        );
        return response.future;
      };

      final done = controller.submit();
      final state = controller.upload as UploadInProgress;
      expect(state.progress?.fraction, 0.5);
      expect(controller.isLocked, isTrue);
      expect(controller.canAcquire, isFalse);

      response.complete(
        await FakeSubmissionApi.receiptFor(api.requests.single, null, null),
      );
      await done;
      expect(controller.upload, isA<UploadSucceeded>());
    });

    test(
      'il nuovo tentativo riusa l’identificativo finché i dati non cambiano',
      () async {
        await readyToSubmit();
        api.handler = (_, _, _) async =>
            throw const SubmissionFailure(SubmissionFailureKind.network);

        await controller.submit();
        expect(
          (controller.upload as UploadFailed).failure.kind,
          SubmissionFailureKind.network,
        );
        expect(controller.isLocked, isFalse);
        await controller.submit();

        controller.updateCaseCode('CASO-002');
        expect(controller.upload, isA<UploadIdle>());
        api.handler = FakeSubmissionApi.receiptFor;
        await controller.submit();

        expect(api.requests.map((r) => r.submissionId), [
          'id-1',
          'id-1',
          'id-2',
        ]);
      },
    );

    test(
      'dopo un conflitto il nuovo tentativo usa un altro identificativo',
      () async {
        await readyToSubmit();
        api.handler = (_, _, _) async =>
            throw const SubmissionFailure(SubmissionFailureKind.conflict);
        await controller.submit();
        await controller.submit();
        expect(api.requests.map((r) => r.submissionId), ['id-1', 'id-2']);
      },
    );

    test('l’operatore può annullare l’invio', () async {
      await readyToSubmit();
      api.handler = (_, _, cancelSignal) async {
        await cancelSignal;
        throw const SubmissionFailure(SubmissionFailureKind.cancelled);
      };

      final done = controller.submit();
      controller.cancelUpload();
      await done;

      final failure = (controller.upload as UploadFailed).failure;
      expect(failure.kind, SubmissionFailureKind.cancelled);
      expect(failure.canRetry, isTrue);
    });

    test(
      'nuova foto per lo stesso caso o nuovo caso dopo la conferma',
      () async {
        await readyToSubmit();
        await controller.submit();

        controller.startNewPhotoForSameCase();
        expect(controller.photo, isNull);
        expect(controller.mode, AcquisitionMode.clinical);
        expect(controller.caseCode, '  CASO-001 ');
        expect(controller.upload, isA<UploadIdle>());
        expect(controller.submissionId, isNull);

        controller.startNewCase();
        expect(controller.mode, isNull);
        expect(controller.caseCode, isEmpty);
      },
    );
  });
}

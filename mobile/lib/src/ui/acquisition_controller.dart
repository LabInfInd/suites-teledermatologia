import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/submission_api.dart';
import '../capture/image_inspector.dart';
import '../capture/location_metadata.dart';
import '../capture/photo_picker.dart';
import '../config/app_config.dart';
import '../domain/acquisition_mode.dart';
import '../domain/captured_photo.dart';
import '../domain/case_code.dart';
import '../domain/submission.dart';

sealed class UploadState {
  const UploadState();
}

final class UploadIdle extends UploadState {
  const UploadIdle();
}

final class UploadInProgress extends UploadState {
  const UploadInProgress([this.progress]);

  final SubmissionProgress? progress;
}

final class UploadSucceeded extends UploadState {
  const UploadSucceeded(this.receipt);

  final SubmissionReceipt receipt;
}

final class UploadFailed extends UploadState {
  const UploadFailed(this.failure);

  final SubmissionFailure failure;
}

/// Esito dell'ultima acquisizione da mostrare all'operatore.
enum PhotoNotice {
  cancelled,
  cancelledKeptPrevious,
  recovered,
  cameraPermissionDenied,
  photoPermissionDenied,
  cameraUnavailable,
  alreadyActive,
  unreadable,
  unsupportedFormat,
  tooLarge,
  failed,
}

/// Stato del flusso: tipo di acquisizione, foto, codice caso e invio.
class AcquisitionController extends ChangeNotifier {
  AcquisitionController({
    required this._picker,
    required this._inspector,
    required this._api,
    this.maxUploadBytes = AppConfig.defaultMaxUploadBytes,
    String Function()? newSubmissionId,
  }) : _newSubmissionId = newSubmissionId ?? generateSubmissionId;

  final PhotoPicker _picker;
  final ImageInspector _inspector;
  final SubmissionApi? _api;
  final String Function() _newSubmissionId;
  final int maxUploadBytes;

  AcquisitionMode? _mode;
  CapturedPhoto? _photo;
  String _caseCode = '';
  bool _isPicking = false;
  PhotoNotice? _photoNotice;
  UploadState _upload = const UploadIdle();
  String? _submissionId;
  Completer<void>? _cancelUpload;
  bool _disposed = false;

  AcquisitionMode? get mode => _mode;
  CapturedPhoto? get photo => _photo;
  String get caseCode => _caseCode;
  bool get isPicking => _isPicking;
  PhotoNotice? get photoNotice => _photoNotice;
  UploadState get upload => _upload;
  bool get hasServer => _api != null;
  bool get isSimulated => _api?.isSimulated ?? false;

  /// Identificativo dell'invio corrente, riusato nei ritentativi.
  String? get submissionId => _submissionId;

  bool get isUploading => _upload is UploadInProgress;

  /// Durante l'invio e dopo la conferma i dati non sono modificabili.
  bool get isLocked => isUploading || _upload is UploadSucceeded;

  CaseCodeIssue? get caseCodeIssue => CaseCode.validate(_caseCode);

  bool get canAcquire => !isLocked && !_isPicking && _mode != null;

  bool get canSubmit =>
      _api != null &&
      !isLocked &&
      !_isPicking &&
      _mode != null &&
      _photo != null &&
      caseCodeIssue == null;

  void selectMode(AcquisitionMode mode) {
    if (isLocked || mode == _mode) return;
    _mode = mode;
    _startNewSubmission();
    _notify();
  }

  void updateCaseCode(String value) {
    if (isLocked || value == _caseCode) return;
    _caseCode = value;
    _startNewSubmission();
    _notify();
  }

  /// Scatta una foto o la sceglie dalla galleria. Se l'operatore annulla,
  /// l'eventuale foto precedente resta invariata.
  Future<void> acquire(PhotoSource source) async {
    if (!canAcquire) return;
    _isPicking = true;
    _photoNotice = null;
    _notify();
    try {
      final picked = await _picker.pick(source);
      if (picked == null) {
        _photoNotice = _photo == null ? PhotoNotice.cancelled : PhotoNotice.cancelledKeptPrevious;
      } else {
        await _accept(picked);
      }
    } on PhotoPickException catch (e) {
      _photoNotice = switch (e.kind) {
        PhotoPickFailureKind.cameraPermissionDenied => PhotoNotice.cameraPermissionDenied,
        PhotoPickFailureKind.photoPermissionDenied => PhotoNotice.photoPermissionDenied,
        PhotoPickFailureKind.cameraUnavailable => PhotoNotice.cameraUnavailable,
        PhotoPickFailureKind.alreadyActive => PhotoNotice.alreadyActive,
        PhotoPickFailureKind.unreadable => PhotoNotice.unreadable,
        PhotoPickFailureKind.unknown => PhotoNotice.failed,
      };
    } finally {
      _isPicking = false;
      _notify();
    }
  }

  /// Su Android recupera la foto scattata se il sistema ha chiuso l'app
  /// mentre la fotocamera era aperta. Il tipo di acquisizione va comunque
  /// selezionato di nuovo.
  Future<void> recoverLostPhoto() async {
    final PickedPhoto? picked;
    try {
      picked = await _picker.recoverLostPhoto();
    } on PhotoPickException {
      return;
    }
    if (picked == null || isLocked || _photo != null) return;
    await _accept(picked);
    if (_photo != null) _photoNotice = PhotoNotice.recovered;
    _notify();
  }

  Future<void> _accept(PickedPhoto picked) async {
    final format = ImageFormat.detect(picked.bytes);
    if (format == null) {
      _photoNotice = PhotoNotice.unsupportedFormat;
      return;
    }
    if (picked.bytes.length > maxUploadBytes) {
      _photoNotice = PhotoNotice.tooLarge;
      return;
    }
    final sanitized = removeLocationMetadata(picked.bytes, format);
    final dimensions = await _inspector.dimensions(sanitized.bytes);
    _photo = CapturedPhoto(
      bytes: sanitized.bytes,
      format: format,
      source: picked.source,
      dimensions: dimensions,
      locationMetadataRemoved: sanitized.locationRemoved,
    );
    _startNewSubmission();
  }

  void removePhoto() {
    if (isLocked || _photo == null) return;
    _photo = null;
    _photoNotice = null;
    _startNewSubmission();
    _notify();
  }

  /// Invia la foto. Dopo un errore, una nuova chiamata senza modifiche ai
  /// dati riusa lo stesso identificativo e quindi non crea duplicati.
  Future<void> submit() async {
    final api = _api;
    final mode = _mode;
    final photo = _photo;
    if (!canSubmit || api == null || mode == null || photo == null) return;

    final request = SubmissionRequest(
      submissionId: _submissionId ??= _newSubmissionId(),
      caseCode: CaseCode.normalize(_caseCode),
      mode: mode,
      photo: photo,
    );
    final cancel = _cancelUpload = Completer<void>();
    _upload = const UploadInProgress();
    _notify();

    UploadState result;
    try {
      final receipt = await api.submit(
        request,
        cancelSignal: cancel.future,
        onProgress: (progress) {
          if (!identical(_cancelUpload, cancel)) return;
          _upload = UploadInProgress(progress);
          _notify();
        },
      );
      result = UploadSucceeded(receipt);
    } on SubmissionFailure catch (failure) {
      // Il server ha già un invio diverso con questo identificativo.
      if (failure.kind == SubmissionFailureKind.conflict) _submissionId = null;
      result = UploadFailed(failure);
    } on Exception {
      result = const UploadFailed(SubmissionFailure(SubmissionFailureKind.unknown));
    }
    if (identical(_cancelUpload, cancel)) _cancelUpload = null;
    _upload = result;
    _notify();
  }

  void cancelUpload() {
    final cancel = _cancelUpload;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Dopo una conferma: nuova foto per lo stesso caso e tipo di acquisizione.
  void startNewPhotoForSameCase() {
    if (isUploading) return;
    _photo = null;
    _photoNotice = null;
    _upload = const UploadIdle();
    _submissionId = null;
    _notify();
  }

  /// Dopo una conferma: azzera tutto, compreso il tipo di acquisizione.
  void startNewCase() {
    if (isUploading) return;
    _mode = null;
    _caseCode = '';
    startNewPhotoForSameCase();
  }

  void _startNewSubmission() {
    _submissionId = null;
    if (_upload is UploadFailed) _upload = const UploadIdle();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancelUpload();
    super.dispose();
  }
}

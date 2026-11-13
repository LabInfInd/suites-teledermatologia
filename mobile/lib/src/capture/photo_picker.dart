import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/captured_photo.dart';

class PickedPhoto {
  const PickedPhoto({required this.bytes, required this.source});

  final Uint8List bytes;
  final PhotoSource source;
}

enum PhotoPickFailureKind {
  cameraPermissionDenied,
  photoPermissionDenied,
  cameraUnavailable,
  alreadyActive,
  unreadable,
  unknown,
}

class PhotoPickException implements Exception {
  const PhotoPickException(this.kind, {this.platformCode});

  final PhotoPickFailureKind kind;
  final String? platformCode;

  @override
  String toString() => 'PhotoPickException(${kind.name}, code: $platformCode)';
}

/// Acquisizione delle foto, separata dall'interfaccia per poterla simulare
/// nei test.
abstract interface class PhotoPicker {
  /// Restituisce `null` se l'operatore annulla lo scatto o la selezione.
  ///
  /// [source] deve essere [PhotoSource.camera] o [PhotoSource.gallery].
  Future<PickedPhoto?> pick(PhotoSource source);

  /// Recupera una foto scattata mentre Android chiudeva l'app per liberare
  /// memoria. Su iOS restituisce sempre `null`.
  Future<PickedPhoto?> recoverLostPhoto();
}

/// Implementazione basata su `image_picker`.
///
/// Apre la fotocamera o la galleria di sistema: l'app non controlla
/// obiettivo, messa a fuoco, macro o flash, che restano gestiti dall'app
/// fotocamera del telefono.
class ImagePickerPhotoPicker implements PhotoPicker {
  ImagePickerPhotoPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedPhoto?> pick(PhotoSource source) async {
    assert(source != PhotoSource.unknown);
    final XFile? file;
    try {
      // Nessun maxWidth, maxHeight o imageQuality: la foto non viene
      // ridimensionata né ricompressa dall'app.
      file = await _picker.pickImage(
        source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.rear,
        // Evita la richiesta del permesso per l'intera libreria foto su iOS.
        requestFullMetadata: false,
      );
    } on PlatformException catch (e) {
      throw PhotoPickException(_kindFor(e.code), platformCode: e.code);
    }
    if (file == null) return null;
    return PickedPhoto(bytes: await _readAndDiscard(file), source: source);
  }

  @override
  Future<PickedPhoto?> recoverLostPhoto() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    final LostDataResponse response;
    try {
      response = await _picker.retrieveLostData();
    } on PlatformException {
      return null;
    }
    final file = response.file;
    if (response.isEmpty || file == null || response.type != RetrieveType.image) {
      return null;
    }
    return PickedPhoto(bytes: await _readAndDiscard(file), source: PhotoSource.unknown);
  }

  /// Legge la foto in memoria ed elimina la copia temporanea creata dal
  /// plugin, così l'immagine non resta nella cache dell'app.
  Future<Uint8List> _readAndDiscard(XFile file) async {
    try {
      return await file.readAsBytes();
    } on Exception {
      throw const PhotoPickException(PhotoPickFailureKind.unreadable);
    } finally {
      unawaited(_deleteQuietly(file.path));
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // La copia è nella cache temporanea: il sistema la eliminerà comunque.
    }
  }

  static PhotoPickFailureKind _kindFor(String code) => switch (code) {
    'camera_access_denied' || 'camera_access_restricted' =>
      PhotoPickFailureKind.cameraPermissionDenied,
    'photo_access_denied' || 'photo_access_restricted' =>
      PhotoPickFailureKind.photoPermissionDenied,
    'no_available_camera' => PhotoPickFailureKind.cameraUnavailable,
    'already_active' || 'multiple_request' => PhotoPickFailureKind.alreadyActive,
    'invalid_image' => PhotoPickFailureKind.unreadable,
    _ => PhotoPickFailureKind.unknown,
  };
}

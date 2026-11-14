import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Consegna una PNG già scaricata con il token al foglio di condivisione di
/// sistema, da cui si può salvare in Foto o in File.
typedef ImageSharer = Future<void> Function(Uint8List bytes, String fileName);

Future<void> shareImageWithSystem(Uint8List bytes, String fileName) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'image/png', name: fileName)],
      fileNameOverrides: [fileName],
    ),
  );
}

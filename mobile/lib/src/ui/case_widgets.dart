import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../domain/acquisition_mode.dart';
import '../domain/patient_case.dart';
import 'photo_viewer_page.dart';

String caseModeLabel(AcquisitionMode? mode) => switch (mode) {
  AcquisitionMode.clinical => 'Foto clinica',
  AcquisitionMode.dermoscopic => 'Dermatoscopica',
  null => 'Modalità non indicata',
};

/// Come scegliere la modalità: dipende dallo strumento, non dalla foto.
String caseModeDescription(AcquisitionMode mode) => switch (mode) {
  AcquisitionMode.clinical =>
    'Smartphone normale, anche con foto ravvicinate o in modalità macro.',
  AcquisitionMode.dermoscopic =>
    'Dermatoscopio, oppure smartphone con adattatore dermatoscopico.',
};

String formatShortDate(DateTime? value) {
  if (value == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)}/${value.year} ${two(value.hour)}:${two(value.minute)}';
}

class CaseStateChip extends StatelessWidget {
  const CaseStateChip(this.state, {super.key});

  final CaseState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (state) {
      CaseState.released => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      CaseState.needsImages || CaseState.analysisFailed => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      CaseState.awaitingReview => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        state.label,
        style: TextStyle(color: foreground, fontSize: 12),
      ),
    );
  }
}

class CaseListTile extends StatelessWidget {
  const CaseListTile({super.key, required this.item, required this.onTap});

  final CaseSummary item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (item.patientCode != null) 'Paziente ${item.patientCode}',
      caseModeLabel(item.mode),
      if (item.bodySite.isNotEmpty) item.bodySite,
      '${item.imageCount} ${item.imageCount == 1 ? 'foto' : 'foto'}',
      if (item.updatedAt != null)
        'aggiornato ${formatShortDate(item.updatedAt)}',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(item.code),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CaseStateChip(item.state),
              const SizedBox(height: 4),
              Text(details.join(' · ')),
            ],
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Immagine del server scaricata con il token della sessione, con al più
/// una sovrapposizione trasparente (segmentazione o overlay Grad-CAM).
/// Le foto già composte (`heatmap_composite`) si passano senza overlay.
/// Toccandola si apre a schermo intero.
class CaseImageView extends StatefulWidget {
  const CaseImageView({
    super.key,
    required this.api,
    required this.path,
    this.overlayPath,
    this.aspectRatio = 1,
    this.fit = BoxFit.cover,
    this.unavailableText = 'Immagine non più disponibile.',
  });

  final CasesApi api;
  final String path;
  final String? overlayPath;
  final double aspectRatio;
  final BoxFit fit;

  /// Mostrato se il server risponde 404, per esempio una mappa revocata.
  final String unavailableText;

  @override
  State<CaseImageView> createState() => _CaseImageViewState();
}

class _CaseImageViewState extends State<CaseImageView> {
  late Future<(Uint8List, Uint8List?)> _bytes = _load();

  @override
  void didUpdateWidget(CaseImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.overlayPath != widget.overlayPath) {
      _bytes = _load();
    }
  }

  Future<(Uint8List, Uint8List?)> _load() async {
    final overlay = widget.overlayPath;
    return (
      await widget.api.image(widget.path),
      overlay == null ? null : await widget.api.image(overlay),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder(
          future: _bytes,
          builder: (context, snapshot) {
            final scheme = Theme.of(context).colorScheme;
            final error = snapshot.error;
            if (error is CasesFailure && error.statusCode == 404) {
              // Revocata o non più presente: non si riprova con lo stesso URL.
              return ColoredBox(
                key: const ValueKey('case-image-unavailable'),
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      widget.unavailableText,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              );
            }
            if (snapshot.hasError) {
              return ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: IconButton(
                    tooltip: 'Immagine non disponibile: riprova',
                    icon: const Icon(Icons.broken_image_outlined),
                    onPressed: () => setState(() => _bytes = _load()),
                  ),
                ),
              );
            }
            final data = snapshot.data;
            if (data == null) {
              return ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Center(child: CircularProgressIndicator()),
              );
            }
            final (image, overlay) = data;
            return InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PhotoViewerPage(bytes: image),
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(image, fit: widget.fit, cacheWidth: 1024),
                  if (overlay != null)
                    Image.memory(overlay, fit: widget.fit, cacheWidth: 1024),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

void showCasesError(BuildContext context, Object error) {
  final message = error is CasesFailure
      ? error.message
      : 'Operazione non riuscita. Riprova.';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

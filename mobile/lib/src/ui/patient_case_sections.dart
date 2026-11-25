import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../domain/acquisition_mode.dart';
import '../domain/analysis_task.dart';
import '../domain/patient_case.dart';
import 'case_widgets.dart';
import 'new_case_page.dart';
import 'widgets.dart';

/// Percorso del caso dal lato paziente (modalità e, sui server che lo
/// supportano, tipo di analisi): modificabile in bozza; con nuove foto
/// richieste si può solo confermare una modalità storica mancante.
class PatientModeSection extends StatefulWidget {
  const PatientModeSection({
    super.key,
    required this.data,
    required this.busy,
    required this.tasksFor,
    required this.onSelect,
  });

  final CaseDetails data;
  final bool busy;

  /// Tipi di analisi offerti dal server per una modalità; vuoto sui server
  /// precedenti.
  final List<AnalysisTask> Function(AcquisitionMode mode) tasksFor;
  final void Function(AcquisitionMode mode, AnalysisTask? task) onSelect;

  @override
  State<PatientModeSection> createState() => _PatientModeSectionState();
}

class _PatientModeSectionState extends State<PatientModeSection> {
  /// Modalità scelta ma non ancora salvata, in attesa del tipo di analisi.
  AcquisitionMode? _pending;

  @override
  void didUpdateWidget(PatientModeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.version != widget.data.version) _pending = null;
  }

  void _selectMode(AcquisitionMode mode) {
    final data = widget.data;
    if (mode == data.mode) {
      setState(() => _pending = null);
      return;
    }
    final tasks = widget.tasksFor(mode);
    if (tasks.length > 1) {
      // Il tipo di analisi va scelto esplicitamente prima di salvare.
      setState(() => _pending = mode);
      return;
    }
    widget.onSelect(mode, tasks.length == 1 ? tasks.single : null);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final editable =
        data.state == CaseState.draft ||
        (data.state == CaseState.needsImages && data.mode == null);
    if (!editable) return const SizedBox.shrink();
    final mode = _pending ?? data.mode;
    final tasks = mode == null ? const <AnalysisTask>[] : widget.tasksFor(mode);
    final task = _pending == null ? data.analysisTask : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Modalità di acquisizione'),
        if (data.mode == null)
          NoticeCard(
            icon: Icons.help_outline,
            title: 'Modalità da confermare',
            message: data.state == CaseState.needsImages
                ? 'Indica con quale strumento hai acquisito le foto di questo caso, poi aggiungi quelle richieste.'
                : 'Indica con quale strumento acquisirai le foto prima di inviare il caso.',
          )
        else
          const Text(
            'Vale per tutte le foto del caso. Per foto acquisite in modo diverso apri un altro caso.',
          ),
        const SizedBox(height: 4),
        ModeSelector(
          value: mode,
          enabled: !widget.busy,
          onChanged: _selectMode,
        ),
        if (mode != null && tasks.isNotEmpty) ...[
          const SectionTitle('Tipo di analisi'),
          if (tasks.length > 1 && !tasks.contains(task))
            const Text(
              'Scegli cosa vuoi far valutare per salvare il percorso.',
            ),
          TaskSelector(
            tasks: tasks,
            value: task,
            enabled: !widget.busy,
            onChanged: (value) {
              if (value != task) widget.onSelect(mode, value);
            },
          ),
        ],
      ],
    );
  }
}

/// Risposta del medico al paziente: valutazione e sole mappe pubblicate.
/// Nessun punteggio del modello.
class PatientResponse extends StatelessWidget {
  const PatientResponse({
    super.key,
    required this.api,
    required this.data,
    required this.onDownload,
  });

  final CasesApi api;
  final CaseDetails data;
  final ValueChanged<PublishedExplanation> onDownload;

  @override
  Widget build(BuildContext context) {
    final review = data.latestReview;
    if (review == null || review.decision == ReviewDecision.needsImages) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    // Le mappe valgono solo per la valutazione con cui sono state pubblicate.
    final explanations = data.publishedExplanations
        .where((e) => review.id == null || e.reviewId == review.id)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: const EdgeInsets.only(top: 16),
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.verified_user_outlined),
                    SizedBox(width: 8),
                    Text('Validato dal medico'),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Classificazione comunicata',
                  style: theme.textTheme.labelMedium,
                ),
                Text(
                  review.finalLabel == null
                      ? ''
                      : classDisplayName(review.finalLabel!),
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(review.patientMessage),
              ],
            ),
          ),
        ),
        if (explanations.isNotEmpty) ...[
          const SectionTitle('Mappa Grad-CAM condivisa dal medico'),
          for (final explanation in explanations)
            if (data.imageById(explanation.imageId) case final image?)
              _PublishedExplanationCard(
                key: ValueKey(explanation.compositeUrl),
                api: api,
                image: image,
                explanation: explanation,
                onDownload: () => onDownload(explanation),
              ),
        ],
        if (data.publishedSegmentations.isNotEmpty) ...[
          const SectionTitle('Segmentazione condivisa dal medico'),
          const Text(
            'L’area verde è la segmentazione del modello: è diversa dalla mappa Grad-CAM.',
          ),
          const SizedBox(height: 8),
          for (final segment in data.publishedSegmentations)
            if (data.imageById(segment.imageId) case final image?)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: CaseImageView(
                  key: ValueKey(segment.overlayUrl),
                  api: api,
                  path: image.url,
                  overlayPath: segment.overlayUrl,
                  aspectRatio: image.aspectRatio,
                  fit: BoxFit.fill,
                  unavailableText: 'La segmentazione non è più disponibile.',
                ),
              ),
        ],
      ],
    );
  }
}

class _PublishedExplanationCard extends StatelessWidget {
  const _PublishedExplanationCard({
    super.key,
    required this.api,
    required this.image,
    required this.explanation,
    required this.onDownload,
  });

  final CasesApi api;
  final CaseImage image;
  final PublishedExplanation explanation;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Classe spiegata: ${classDisplayName(explanation.targetClass)}',
            ),
            const SizedBox(height: 8),
            // La foto composta contiene già la mappa: nessun overlay aggiuntivo.
            CaseImageView(
              api: api,
              path: explanation.compositeUrl,
              aspectRatio: image.aspectRatio,
              fit: BoxFit.fill,
              unavailableText: 'La mappa non è più disponibile.',
            ),
            if (explanation.status == 'no_positive_signal')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Nessun contributo positivo visualizzabile per questa classe: '
                  'non significa che la lesione sia assente.',
                ),
              ),
            if (explanation.warning.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(explanation.warning),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download),
              label: const Text('Scarica la foto con la mappa'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../domain/acquisition_mode.dart';
import '../domain/analysis_task.dart';
import '../domain/model_catalog.dart';
import '../domain/patient_case.dart';
import 'case_widgets.dart';
import 'messages.dart';
import 'new_case_page.dart';
import 'widgets.dart';

/// Bozza della valutazione, tenuta dalla pagina così sopravvive agli
/// aggiornamenti automatici durante il ricalcolo delle mappe.
class ReviewDraft {
  ReviewDecision? decision;
  final label = TextEditingController();
  final message = TextEditingController();
  bool shareSegmentation = false;
  bool shareExplanation = false;
  bool labelInitialized = false;

  void reset() {
    decision = null;
    label.clear();
    message.clear();
    shareSegmentation = false;
    shareExplanation = false;
    labelInitialized = false;
  }

  void dispose() {
    label.dispose();
    message.dispose();
  }
}

CatalogModel? _model(List<CatalogModel>? catalog, String? id) =>
    catalog?.where((m) => m.id == id).firstOrNull;

String _modelName(List<CatalogModel>? catalog, String? id) =>
    _model(catalog, id)?.name ?? id ?? 'non indicato';

/// Risultato del modello: solo per il medico (il server non lo invia al
/// paziente).
class AnalysisSection extends StatelessWidget {
  const AnalysisSection({
    super.key,
    required this.api,
    required this.data,
    required this.catalog,
  });

  final CasesApi api;
  final CaseDetails data;
  final List<CatalogModel>? catalog;

  @override
  Widget build(BuildContext context) {
    final analysis = data.latestAnalysis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Analisi del modello'),
        const Text(
          'Risultato sperimentale riservato al medico: non è una diagnosi clinica validata.',
        ),
        const SizedBox(height: 8),
        if (analysis == null)
          const Text('Nessuna analisi disponibile.')
        else ...[
          Text(
            'Modalità: ${caseModeLabel(analysis.mode)} · '
            '${analysis.analysisTask == null ? '' : 'Tipo di analisi: ${analysis.analysisTask!.label} · '}'
            'Modello: ${_modelName(catalog, analysis.modelId)} · '
            'Grad-CAM per: ${analysis.explanationTarget == null ? 'classe predetta di ogni foto' : classDisplayName(analysis.explanationTarget!, _model(catalog, analysis.modelId)?.classNamesIt)}',
          ),
          const SizedBox(height: 8),
          if (!analysis.completed)
            Text(switch (analysis.state) {
              'queued' ||
              'running' => 'Analisi in corso: la pagina si aggiorna da sola.',
              'waiting_model' =>
                analysis.failureCode == 'acquisition_mode_required'
                    ? 'In attesa: conferma la modalità di acquisizione e avvia una nuova analisi.'
                    : 'In attesa del modello.',
              'failed' =>
                'Analisi non riuscita${analysis.failureCode == null ? '' : ' (${analysis.failureCode})'}.',
              _ => 'Stato dell’analisi: ${analysis.state}.',
            })
          else
            for (final result in analysis.images)
              if (data.imageById(result.imageId) case final image?)
                AnalysisImageCard(
                  key: ValueKey('${analysis.id}-${result.imageId}'),
                  api: api,
                  image: image,
                  result: result,
                  catalogNames:
                      _model(catalog, analysis.modelId)?.classNamesIt ??
                      const {},
                  wound: analysis.analysisTask == AnalysisTask.woundType,
                ),
        ],
      ],
    );
  }
}

enum _MapView { photo, gradcam, segmentation }

/// Una foto analizzata con le sue viste separate: foto, Grad-CAM e, solo se
/// il modello la produce, segmentazione.
class AnalysisImageCard extends StatefulWidget {
  const AnalysisImageCard({
    super.key,
    required this.api,
    required this.image,
    required this.result,
    this.catalogNames = const {},
    this.wound = false,
  });

  final CasesApi api;
  final CaseImage image;
  final AnalysisImage result;

  /// `class_names_it` del modello nel catalogo, se il risultato non li ha.
  final Map<String, String> catalogNames;

  /// Analisi del percorso ferite secondo il caso.
  final bool wound;

  @override
  State<AnalysisImageCard> createState() => _AnalysisImageCardState();
}

class _AnalysisImageCardState extends State<AnalysisImageCard> {
  late _MapView _view = widget.result.heatmapCompositeUrl != null
      ? _MapView.gradcam
      : _MapView.photo;

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final image = widget.image;
    final explanation = result.explanation;
    final names = {
      ...widget.catalogNames,
      ...result.classification.classNamesIt,
    };
    final wound = widget.wound || result.classification.isWound;
    final view = switch (_view) {
      _MapView.gradcam when result.heatmapCompositeUrl == null =>
        _MapView.photo,
      _MapView.segmentation when !result.hasSegmentation => _MapView.photo,
      final v => v,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_MapView>(
              segments: [
                const ButtonSegment(value: _MapView.photo, label: Text('Foto')),
                ButtonSegment(
                  value: _MapView.gradcam,
                  label: const Text('Grad-CAM'),
                  enabled: result.heatmapCompositeUrl != null,
                ),
                if (result.hasSegmentation)
                  const ButtonSegment(
                    value: _MapView.segmentation,
                    label: Text('Segmentazione'),
                  ),
              ],
              selected: {view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
            const SizedBox(height: 8),
            switch (view) {
              // La foto composta contiene già la mappa: nessun overlay aggiuntivo.
              _MapView.gradcam => CaseImageView(
                key: ValueKey(result.heatmapCompositeUrl),
                api: widget.api,
                path: result.heatmapCompositeUrl!,
                aspectRatio: image.aspectRatio,
                fit: BoxFit.fill,
                unavailableText: 'Mappa Grad-CAM non disponibile.',
              ),
              _MapView.segmentation => CaseImageView(
                key: ValueKey(result.overlayUrl),
                api: widget.api,
                path: image.url,
                overlayPath: result.overlayUrl,
                aspectRatio: image.aspectRatio,
                fit: BoxFit.fill,
                unavailableText: 'Segmentazione non disponibile.',
              ),
              _MapView.photo => CaseImageView(
                key: ValueKey(image.url),
                api: widget.api,
                path: image.url,
                aspectRatio: image.aspectRatio,
                fit: BoxFit.fill,
              ),
            },
            const SizedBox(height: 8),
            if (wound)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(woundResearchNotice),
              ),
            if (result.modelName.isNotEmpty)
              Text(
                'Modello: ${result.modelName}'
                '${result.modelVersion.isEmpty ? '' : ' (versione ${result.modelVersion})'}',
              ),
            // Punteggi associati per etichetta, dal più alto.
            for (final row in result.labels.take(4))
              Text(
                '${classDisplayName(row.label, names)}: ${(row.score * 100).toStringAsFixed(1)}%',
              ),
            const SizedBox(height: 4),
            Text(
              explanation.targetClass == null
                  ? 'Grad-CAM non disponibile (${explanation.status}).'
                  : 'Grad-CAM per la classe «${classDisplayName(explanation.targetClass!, names)}» · ${explanation.status}',
            ),
            if (explanation.status == 'no_positive_signal')
              Text(
                wound
                    ? 'Nessun contributo positivo per la classe spiegata: non significa assenza di ferita.'
                    : 'Nessun contributo positivo per la classe spiegata: non significa assenza di lesione.',
              ),
            Text(
              view == _MapView.segmentation
                  ? 'La segmentazione FTN è separata da Grad-CAM.'
                  : 'Grad-CAM evidenzia le aree che influenzano la classificazione: non è il contorno della lesione né una probabilità per pixel.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

typedef ReanalyzeRequest = Future<void> Function(
  AcquisitionMode? mode,
  AnalysisTask? task,
  String? modelId,
  String? explanationTarget,
);

/// Nuova analisi: modalità (obbligatoria per i casi storici), tipo di
/// analisi, modello del catalogo e classe da spiegare con Grad-CAM. I target
/// vengono dalle classi del modello scelto e si azzerano cambiando modello.
class ReanalyzePanel extends StatefulWidget {
  const ReanalyzePanel({
    super.key,
    required this.data,
    required this.catalogFor,
    required this.onNeedCatalog,
    required this.busy,
    required this.onSubmit,
  });

  final CaseDetails data;
  final List<CatalogModel>? Function(AcquisitionMode mode) catalogFor;
  final ValueChanged<AcquisitionMode> onNeedCatalog;
  final bool busy;
  final ReanalyzeRequest onSubmit;

  @override
  State<ReanalyzePanel> createState() => _ReanalyzePanelState();
}

class _ReanalyzePanelState extends State<ReanalyzePanel> {
  late AcquisitionMode? _mode = widget.data.mode;
  late AnalysisTask? _task =
      widget.data.latestAnalysis?.analysisTask ?? widget.data.analysisTask;
  String? _modelId;
  String? _target;

  /// Modello precedente se compatibile con modalità e task; per le ferite il
  /// modello ferite; altrimenti il predefinito del percorso. Mai un modello
  /// di un altro tipo di analisi.
  String? _defaultModel(
    List<CatalogModel> catalog,
    List<CatalogModel> available,
    AnalysisTask task,
  ) {
    final previous = widget.data.latestAnalysis;
    if (previous != null &&
        previous.mode == _mode &&
        available.any((m) => m.id == previous.modelId)) {
      return previous.modelId;
    }
    if (task == AnalysisTask.woundType) return woundModel(catalog)?.id;
    return (available.where((m) => m.isDefault).firstOrNull ??
            available.firstOrNull)
        ?.id;
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode;
    final catalog = mode == null ? null : widget.catalogFor(mode);
    final tasks = mode == null || catalog == null
        ? const <AnalysisTask>[]
        : catalogTasks(catalog, mode);
    final task = tasks.contains(_task)
        ? _task
        : tasks.length == 1
        ? tasks.single
        : null;
    final available = mode == null || catalog == null || task == null
        ? const <CatalogModel>[]
        : catalogModelsFor(catalog, mode, task);
    final modelId = available.any((m) => m.id == _modelId)
        ? _modelId
        : catalog == null || task == null
        ? null
        : _defaultModel(catalog, available, task);
    final model = available.where((m) => m.id == modelId).firstOrNull;
    final classes = model?.classes ?? const <String>[];
    final historical = widget.data.mode == null;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        key: const ValueKey('reanalyze-panel'),
        initiallyExpanded: historical,
        title: const Text('Nuova analisi'),
        subtitle: Text(
          historical
              ? 'Caso storico: conferma la modalità prima di analizzare.'
              : 'Modello e classe da spiegare con Grad-CAM.',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ModeSelector(
            value: mode,
            enabled: !widget.busy,
            onChanged: (value) {
              setState(
                () => (
                  _mode = value,
                  _task = null,
                  _modelId = null,
                  _target = null,
                ),
              );
              widget.onNeedCatalog(value);
            },
          ),
          if (mode != null && catalog == null) const LinearProgressIndicator(),
          if (tasks.length > 1) ...[
            const SizedBox(height: 8),
            Text(
              'Tipo di analisi',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            TaskSelector(
              tasks: tasks,
              value: task,
              enabled: !widget.busy,
              onChanged: (value) => setState(
                () => (_task = value, _modelId = null, _target = null),
              ),
            ),
          ],
          if (mode != null &&
              catalog != null &&
              task != null &&
              available.isEmpty)
            Text(
              task == AnalysisTask.woundType
                  ? 'Modello per ferite e ulcere non disponibile: la nuova analisi non viene avviata con un altro modello.'
                  : 'Nessun modello disponibile per questa modalità.',
              key: const ValueKey('reanalyze-no-model'),
            ),
          if (available.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('reanalyze-model-${mode?.apiValue}-${task?.name}'),
              initialValue: modelId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Modello',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final model in available)
                  DropdownMenuItem(
                    value: model.id,
                    child: Text(model.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: widget.busy
                  ? null
                  : (value) =>
                        setState(() => (_modelId = value, _target = null)),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              key: ValueKey('reanalyze-target-$modelId'),
              initialValue: classes.contains(_target) ? _target : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Classe da spiegare con Grad-CAM',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Classe predetta di ogni foto'),
                ),
                for (final label in classes)
                  DropdownMenuItem<String?>(
                    value: label,
                    child: Text(model!.nameOf(label)),
                  ),
              ],
              onChanged: widget.busy
                  ? null
                  : (value) => setState(() => _target = value),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('reanalyze-submit'),
            onPressed: mode != null && modelId != null && !widget.busy
                ? () => widget.onSubmit(
                    mode == widget.data.mode ? null : mode,
                    // Solo i server che dichiarano il task lo ricevono.
                    model?.declaresTask == true ? task : null,
                    modelId,
                    classes.contains(_target) ? _target : null,
                  )
                : null,
            icon: const Icon(Icons.replay),
            label: const Text('Avvia nuova analisi'),
          ),
        ],
      ),
    );
  }
}

typedef ReviewSubmit = Future<bool> Function(
  ReviewDecision decision,
  String? finalLabel,
  String message,
  bool shareSegmentation,
  bool shareExplanation,
);

/// Valutazione del medico, con le stesse regole del server: Grad-CAM si
/// condivide solo con consenso esplicito e mappe per la classe finale.
class ReviewSection extends StatefulWidget {
  const ReviewSection({
    super.key,
    required this.data,
    required this.draft,
    required this.busy,
    required this.catalog,
    required this.onRecompute,
    required this.onSubmit,
  });

  final CaseDetails data;
  final ReviewDraft draft;
  final bool busy;

  /// Catalogo della modalità dell'ultima analisi, per sapere se la classe
  /// finale ha una mappa calcolabile.
  final List<CatalogModel>? catalog;
  final ValueChanged<String> onRecompute;
  final ReviewSubmit onSubmit;

  static bool canValidate(CaseDetails data) {
    final analysis = data.latestAnalysis;
    return data.state == CaseState.awaitingReview &&
        analysis != null &&
        analysis.completed &&
        data.mode != null &&
        analysis.mode == data.mode &&
        analysis.modelId != null;
  }

  static bool canRequestImages(CaseDetails data) =>
      data.images.length < maxCaseImages &&
      {
        CaseState.awaitingReview,
        CaseState.waitingModel,
        CaseState.analysisFailed,
      }.contains(data.state);

  @override
  State<ReviewSection> createState() => _ReviewSectionState();
}

class _ReviewSectionState extends State<ReviewSection> {
  static const _minMessage = 10;

  ReviewDraft get _draft => widget.draft;
  CaseAnalysis? get _analysis => widget.data.latestAnalysis;

  List<String> get _suggested => {
    for (final image in _analysis?.images ?? const <AnalysisImage>[])
      ?image.topLabel,
  }.toList();

  bool get _requestsImages => _draft.decision == ReviewDecision.needsImages;
  String get _label => _draft.label.text.trim();

  CatalogModel? get _analysisModel =>
      _model(widget.catalog, _analysis?.modelId);

  List<String>? get _modelClasses => _analysisModel?.classes;

  String _nameOf(String label) =>
      classDisplayName(label, _analysisModel?.classNamesIt);

  void _onLabelChanged(String value) {
    // Come sul web: un'etichetta diversa dalla predizione è una correzione.
    setState(() {
      if (_draft.decision == ReviewDecision.approved &&
          !_suggested.contains(value.trim())) {
        _draft.decision = ReviewDecision.corrected;
      }
    });
  }

  Future<void> _confirm(bool shareSegmentation, bool shareExplanation) async {
    final label = _requestsImages ? null : _label;
    final message = _draft.message.text.trim();
    final decision = _draft.decision!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _requestsImages
              ? 'Invia la richiesta di nuove foto'
              : 'Pubblica la valutazione',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Controlla il contenuto che sarà comunicato al paziente.',
              ),
              if (label != null) ...[
                const SizedBox(height: 12),
                Text(label, style: Theme.of(context).textTheme.titleLarge),
              ],
              const SizedBox(height: 12),
              Text(message),
              if (!_requestsImages) ...[
                const SizedBox(height: 12),
                Text(
                  shareExplanation
                      ? 'Sarà condivisa la mappa Grad-CAM per «$label».'
                      : 'Nessuna mappa Grad-CAM sarà condivisa.',
                ),
                if (shareSegmentation)
                  const Text('Sarà condivisa anche la segmentazione.'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Torna alla modifica'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _requestsImages ? 'Invia richiesta' : 'Pubblica per il paziente',
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onSubmit(
        decision,
        label,
        message,
        shareSegmentation,
        shareExplanation,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final canValidate = ReviewSection.canValidate(data);
    final canRequest = ReviewSection.canRequestImages(data);
    if (!canValidate && !canRequest) {
      if (data.state == CaseState.awaitingReview) {
        return const NoticeCard(
          icon: Icons.warning_amber_outlined,
          title: 'Pubblicazione non ancora possibile',
          message: 'Conferma la modalità di acquisizione e ripeti l’analisi prima di pubblicare una valutazione.',
        );
      }
      return const SizedBox.shrink();
    }
    final decisions = [
      if (canValidate) ...[
        (ReviewDecision.approved, 'Conferma classificazione'),
        (ReviewDecision.corrected, 'Correggi classificazione'),
      ],
      if (canRequest) (ReviewDecision.needsImages, 'Richiedi nuove foto'),
    ];
    if (!decisions.any((d) => d.$1 == _draft.decision)) {
      _draft.decision = decisions.first.$1;
    }
    if (!_draft.labelInitialized && _suggested.isNotEmpty) {
      _draft.label.text = _suggested.first;
      _draft.labelInitialized = true;
    }
    final analysis = _analysis;
    final label = _label;
    final explanationReady =
        canValidate && (analysis?.explanationReadyFor(label) ?? false);
    final segmentationReady =
        canValidate && (analysis?.hasSegmentation ?? false);
    final shareExplanation =
        !_requestsImages && _draft.shareExplanation && explanationReady;
    final shareSegmentation =
        !_requestsImages && _draft.shareSegmentation && segmentationReady;
    final valid =
        _draft.message.text.trim().length >= _minMessage &&
        (_requestsImages || label.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('La tua valutazione'),
        RadioGroup<ReviewDecision>(
          groupValue: _draft.decision,
          onChanged: (value) {
            if (value != null && !widget.busy) {
              setState(() => _draft.decision = value);
            }
          },
          child: Column(
            children: [
              for (final (value, text) in decisions)
                RadioListTile<ReviewDecision>(
                  contentPadding: EdgeInsets.zero,
                  value: value,
                  title: Text(text),
                ),
            ],
          ),
        ),
        if (!_requestsImages) ...[
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('final-label'),
            controller: _draft.label,
            enabled: !widget.busy,
            maxLength: 160,
            onChanged: _onLabelChanged,
            decoration: InputDecoration(
              labelText: 'Classificazione da comunicare',
              // Si pubblica l'etichetta API; il nome italiano aiuta la verifica.
              helperText: label.isNotEmpty && _nameOf(label) != label
                  ? 'Il paziente leggerà: ${_nameOf(label)}'
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_suggested.length > 1)
            Wrap(
              spacing: 8,
              children: [
                for (final suggestion in _suggested)
                  ActionChip(
                    label: Text(_nameOf(suggestion)),
                    onPressed: () {
                      _draft.label.text = suggestion;
                      _onLabelChanged(suggestion);
                    },
                  ),
              ],
            ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('patient-message'),
          controller: _draft.message,
          enabled: !widget.busy,
          minLines: 3,
          maxLines: 8,
          maxLength: 5000,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: _requestsImages
                ? 'Quali foto servono e perché'
                : 'Messaggio per il paziente',
            helperText:
                'Almeno $_minMessage caratteri. Sarà letto dal paziente.',
            border: const OutlineInputBorder(),
          ),
        ),
        if (!_requestsImages) ...[
          CheckboxListTile(
            key: const ValueKey('share-explanation'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: shareExplanation,
            onChanged: explanationReady && !widget.busy
                ? (value) =>
                      setState(() => _draft.shareExplanation = value ?? false)
                : null,
            title: const Text('Condividi la mappa Grad-CAM con il paziente'),
            subtitle: Text(
              explanationReady
                  ? 'Mappe per «$label» su tutte le foto: esaminale prima di pubblicare.'
                  : _explanationBlocker(label),
            ),
          ),
          if (!explanationReady &&
              label.isNotEmpty &&
              (_modelClasses?.contains(label) ?? false))
            OutlinedButton.icon(
              key: const ValueKey('recompute-gradcam'),
              onPressed: widget.busy ? null : () => widget.onRecompute(label),
              icon: const Icon(Icons.autorenew),
              label: Text('Ricalcola Grad-CAM per «$label»'),
            ),
          if (segmentationReady)
            CheckboxListTile(
              key: const ValueKey('share-segmentation'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: shareSegmentation,
              onChanged: widget.busy
                  ? null
                  : (value) => setState(
                      () => _draft.shareSegmentation = value ?? false,
                    ),
              title: const Text('Condividi la segmentazione con il paziente'),
              subtitle: const Text('Separata dalla mappa Grad-CAM.'),
            ),
        ],
        const SizedBox(height: 8),
        FilledButton(
          onPressed: valid && !widget.busy
              ? () => _confirm(shareSegmentation, shareExplanation)
              : null,
          child: Text(
            _requestsImages
                ? 'Invia la richiesta al paziente'
                : 'Pubblica la valutazione',
          ),
        ),
      ],
    );
  }

  String _explanationBlocker(String label) {
    if (label.isEmpty) return 'Inserisci la classificazione da comunicare.';
    final classes = _modelClasses;
    if (classes == null) return 'Catalogo dei modelli non disponibile.';
    if (!classes.contains(label)) {
      return '«$label» non è una classe del modello: la valutazione sarà pubblicata solo come testo, senza Grad-CAM.';
    }
    final targets = {
      for (final image in _analysis?.images ?? const <AnalysisImage>[])
        ?image.explanation.targetClass,
    };
    return 'Le mappe attuali spiegano ${targets.isEmpty ? 'un’altra classe' : targets.map((t) => '«$t»').join(', ')}: '
        'ricalcola Grad-CAM per «$label» ed esamina le nuove mappe prima di condividerle.';
  }
}

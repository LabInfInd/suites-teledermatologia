import 'dart:async';

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../api/user_session.dart';
import '../capture/image_inspector.dart';
import '../capture/photo_picker.dart';
import '../capture/photo_preparation.dart';
import '../domain/captured_photo.dart';
import '../domain/patient_case.dart';
import 'acquisition_controller.dart';
import 'case_widgets.dart';
import 'messages.dart';
import 'widgets.dart';

/// Servizi usati dalle schermate dei casi.
class CaseServices {
  const CaseServices({
    required this.session,
    required this.api,
    required this.picker,
    required this.inspector,
    required this.maxUploadBytes,
  });

  final UserSession session;
  final CasesApi api;
  final PhotoPicker picker;
  final ImageInspector inspector;
  final int maxUploadBytes;

  bool get isDoctor => session.role == UserRole.doctor;
}

class CaseDetailPage extends StatefulWidget {
  const CaseDetailPage({
    super.key,
    required this.services,
    required this.caseId,
    this.initial,
  });

  final CaseServices services;
  final String caseId;

  /// Dettagli già disponibili, per esempio subito dopo la creazione.
  final CaseDetails? initial;

  @override
  State<CaseDetailPage> createState() => _CaseDetailPageState();
}

class _CaseDetailPageState extends State<CaseDetailPage> {
  late CaseDetails? _case = widget.initial;
  bool _busy = false;
  String? _loadError;
  PhotoNotice? _photoNotice;

  CaseServices get _services => widget.services;
  CasesApi get _api => _services.api;
  bool get _doctor => _services.isDoctor;

  @override
  void initState() {
    super.initState();
    if (_case == null) unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final data = await _api.details(widget.caseId);
      if (mounted) setState(() => (_case = data, _loadError = null));
    } on CasesFailure catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  /// Esegue un'operazione che restituisce il caso aggiornato. Se il caso è
  /// cambiato nel frattempo, lo ricarica e mostra il messaggio del server.
  Future<bool> _run(
    Future<CaseDetails> Function() action, {
    String? done,
  }) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final data = await action();
      if (!mounted) return true;
      setState(() => _case = data);
      if (done != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      showCasesError(context, e);
      if (e is CasesFailure && e.isConflict) await _reload();
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPhoto(PhotoSource source) async {
    final current = _case;
    if (current == null || _busy) return;
    setState(() => _photoNotice = null);
    final CapturedPhoto photo;
    try {
      final picked = await _services.picker.pick(source);
      if (picked == null) return;
      photo = await preparePhoto(
        picked,
        _services.inspector,
        maxBytes: _services.maxUploadBytes,
      );
    } on PhotoPickException catch (e) {
      if (mounted) {
        setState(() => _photoNotice = photoNoticeForPickFailure(e.kind));
      }
      return;
    } on PhotoRejectedException catch (e) {
      if (mounted) {
        setState(() => _photoNotice = photoNoticeForRejection(e.reason));
      }
      return;
    }
    await _run(
      () => _api.uploadImage(current, photo),
      done: 'Foto aggiunta al caso.',
    );
  }

  Future<void> _removePhoto(CaseImage image) async {
    final current = _case;
    if (current == null) return;
    await _run(
      () => _api.removeImage(current, image.id),
      done: 'Foto rimossa.',
    );
  }

  Future<void> _submit() async {
    final current = _case;
    if (current == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Inviare il caso?'),
        content: const Text(
          'Dopo l’invio le foto vengono analizzate e valutate dal medico, e non si possono più modificare.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Invia'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => _api.submit(current), done: 'Caso inviato al medico.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _case;
    return Scaffold(
      appBar: AppBar(
        title: Text(data?.code ?? 'Caso'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: SafeArea(
        child: data == null
            ? Center(
                child: _loadError == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_loadError!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: _reload,
                              child: const Text('Riprova'),
                            ),
                          ],
                        ),
                      ),
              )
            : RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    _Header(data: data),
                    ..._stateNotice(data),
                    SectionTitle(
                      'Foto (${data.images.length} di $maxCaseImages)',
                    ),
                    _Photos(
                      api: _api,
                      data: data,
                      canRemove:
                          !_doctor && data.state == CaseState.draft && !_busy,
                      onRemove: _removePhoto,
                    ),
                    if (!_doctor && data.state.acceptsPatientPhotos)
                      ..._patientActions(data),
                    if (!_doctor && data.state == CaseState.released)
                      _PatientReport(api: _api, data: data),
                    if (_doctor) ...[
                      _AnalysisSection(api: _api, data: data),
                      if (data.state.canReanalyze)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => _api.reanalyze(data),
                                    done: 'Nuova analisi richiesta.',
                                  ),
                            icon: const Icon(Icons.replay),
                            label: const Text('Ripeti l’analisi'),
                          ),
                        ),
                      if (_ReviewForm.applies(data))
                        _ReviewForm(
                          key: ValueKey('review-${data.version}'),
                          data: data,
                          busy: _busy,
                          onSubmit: (decision, label, message, share) => _run(
                            () => _api.review(
                              data,
                              decision: decision,
                              finalLabel: label,
                              patientMessage: message,
                              shareSegmentation: share,
                            ),
                            done: decision == ReviewDecision.needsImages
                                ? 'Richiesta inviata al paziente.'
                                : 'Valutazione pubblicata.',
                          ),
                        ),
                    ],
                    if (data.reviews.isNotEmpty) ...[
                      const SectionTitle('Comunicazioni del medico'),
                      for (final review in data.reviews.reversed)
                        _ReviewCard(review),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  List<Widget> _patientActions(CaseDetails data) {
    final full = data.images.length >= maxCaseImages;
    final notice = _photoNotice;
    return [
      if (notice != null)
        NoticeCard(
          icon: isErrorNotice(notice)
              ? Icons.error_outline
              : Icons.info_outline,
          title: isErrorNotice(notice) ? 'Foto non aggiunta' : 'Acquisizione',
          message: photoNoticeText(
            notice,
            maxUploadBytes: _services.maxUploadBytes,
          ),
          isError: isErrorNotice(notice),
        ),
      if (full)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Hai raggiunto il massimo di quattro foto per caso.'),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: full || _busy
                  ? null
                  : () => _addPhoto(PhotoSource.camera),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Fotocamera'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: full || _busy
                  ? null
                  : () => _addPhoto(PhotoSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Galleria'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: data.images.isEmpty || _busy ? null : _submit,
        icon: const Icon(Icons.send),
        label: Text(
          data.state == CaseState.needsImages
              ? 'Invia di nuovo il caso'
              : 'Invia il caso al medico',
        ),
      ),
    ];
  }

  List<Widget> _stateNotice(CaseDetails data) {
    final (String, String)? text = switch (data.state) {
      CaseState.draft when !_doctor => (
        'Il caso è in preparazione.',
        'Aggiungi da una a quattro foto della stessa lesione, poi invia il caso al medico.',
      ),
      CaseState.queued =>
        _doctor
            ? ('Analisi in coda.', 'Il modello elaborerà le foto a breve.')
            : (
                'Caso inviato.',
                'L’analisi è in coda: lo stato si aggiornerà qui.',
              ),
      CaseState.waitingModel =>
        _doctor
            ? (
                'Il modello è in preparazione.',
                'Le foto sono disponibili: l’analisi partirà quando il modello sarà installato.',
              )
            : (
                'Il caso è salvato.',
                'Il modello è in preparazione: il medico riceverà le foto appena possibile.',
              ),
      CaseState.analysisFailed =>
        _doctor
            ? (
                'L’analisi non è stata completata.',
                'Verifica la disponibilità del modello e ripeti l’analisi. Nessun risultato è stato pubblicato.',
              )
            : (
                'L’analisi non è stata completata.',
                'Le foto sono salvate: l’analisi verrà ripetuta.',
              ),
      CaseState.awaitingReview =>
        _doctor
            ? (
                'Da validare.',
                'Controlla l’analisi e pubblica la valutazione per il paziente.',
              )
            : (
                'Il tuo caso è in valutazione.',
                'Il medico sta verificando i risultati: la risposta comparirà qui dopo la validazione.',
              ),
      CaseState.needsImages => (
        'Il medico ha richiesto altre immagini.',
        _doctor
            ? 'In attesa delle nuove foto del paziente.'
            : '${data.latestReview?.patientMessage ?? ''}\n\nAggiungi almeno una nuova foto e invia di nuovo il caso.'
                  .trim(),
      ),
      CaseState.released when _doctor => (
        'Valutazione pubblicata.',
        'Il paziente può leggere la risposta.',
      ),
      _ => null,
    };
    if (text == null) return const [];
    return [
      NoticeCard(
        icon: data.state == CaseState.analysisFailed
            ? Icons.error_outline
            : Icons.info_outline,
        title: text.$1,
        message: text.$2,
        isError: data.state == CaseState.analysisFailed,
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.data});

  final CaseDetails data;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CaseStateChip(data.state),
          const SizedBox(height: 8),
          if (data.patientCode != null) Text('Paziente: ${data.patientCode}'),
          if (data.bodySite.isNotEmpty) Text('Sede: ${data.bodySite}'),
          if (data.createdAt != null)
            Text('Creato il ${formatShortDate(data.createdAt)}', style: muted),
          if (data.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Note: ${data.notes}'),
          ],
        ],
      ),
    );
  }
}

class _Photos extends StatelessWidget {
  const _Photos({
    required this.api,
    required this.data,
    required this.canRemove,
    required this.onRemove,
  });

  final CasesApi api;
  final CaseDetails data;
  final bool canRemove;
  final ValueChanged<CaseImage> onRemove;

  @override
  Widget build(BuildContext context) {
    if (data.images.isEmpty) return const Text('Nessuna foto nel caso.');
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final image in data.images)
          Stack(
            children: [
              CaseImageView(key: ValueKey(image.id), api: api, path: image.url),
              if (canRemove)
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton.filledTonal(
                    tooltip: 'Rimuovi foto',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onRemove(image),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _PatientReport extends StatelessWidget {
  const _PatientReport({required this.api, required this.data});

  final CasesApi api;
  final CaseDetails data;

  @override
  Widget build(BuildContext context) {
    final review = data.reviews.lastWhere(
      (r) => r.decision != ReviewDecision.needsImages,
      orElse: () => data.latestReview!,
    );
    final theme = Theme.of(context);
    return Card(
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
            Text(review.finalLabel ?? '', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(review.patientMessage),
            for (final segment in data.publishedSegmentations)
              if (data.images.where((i) => i.id == segment.imageId).firstOrNull
                  case final image?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: CaseImageView(
                    api: api,
                    path: image.url,
                    overlayPath: segment.overlayUrl,
                    aspectRatio: image.height == 0
                        ? 1
                        : image.width / image.height,
                    fit: BoxFit.fill,
                  ),
                ),
            if (data.publishedSegmentations.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'L’area evidenziata è la segmentazione condivisa dal medico.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Risultato del modello: solo per il medico (il server non lo invia al
/// paziente).
class _AnalysisSection extends StatefulWidget {
  const _AnalysisSection({required this.api, required this.data});

  final CasesApi api;
  final CaseDetails data;

  @override
  State<_AnalysisSection> createState() => _AnalysisSectionState();
}

class _AnalysisSectionState extends State<_AnalysisSection> {
  bool _showSegmentation = true;

  @override
  Widget build(BuildContext context) {
    final analysis = widget.data.latestAnalysis;
    final children = <Widget>[
      const SectionTitle('Analisi del modello'),
      const Text(
        'Risultato sperimentale riservato al medico: non è una diagnosi clinica validata.',
      ),
      const SizedBox(height: 8),
    ];
    if (analysis == null) {
      children.add(const Text('Nessuna analisi disponibile.'));
    } else if (!analysis.completed) {
      children.add(
        Text(switch (analysis.state) {
          'queued' => 'Analisi in coda.',
          'running' => 'Analisi in corso.',
          'waiting_model' => 'In attesa del modello.',
          'failed' =>
            'Analisi non riuscita${analysis.failureCode == null ? '' : ' (${analysis.failureCode})'}.',
          _ => 'Stato dell’analisi: ${analysis.state}.',
        }),
      );
    } else {
      final hasMasks = analysis.images.any((i) => i.overlayUrl != null);
      if (hasMasks) {
        children.add(
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mostra la segmentazione'),
            value: _showSegmentation,
            onChanged: (value) => setState(() => _showSegmentation = value),
          ),
        );
      }
      for (final result in analysis.images) {
        final image = widget.data.images
            .where((i) => i.id == result.imageId)
            .firstOrNull;
        children.add(
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (image != null)
                    CaseImageView(
                      key: ValueKey('${image.id}-$_showSegmentation'),
                      api: widget.api,
                      path: image.url,
                      overlayPath: _showSegmentation ? result.overlayUrl : null,
                      aspectRatio: image.height == 0
                          ? 1
                          : image.width / image.height,
                      fit: BoxFit.fill,
                    ),
                  const SizedBox(height: 8),
                  if (result.modelName.isNotEmpty)
                    Text('Modello: ${result.modelName}'),
                  for (final row in result.labels.take(3))
                    Text(
                      '${row.label}: ${(row.score * 100).toStringAsFixed(1)}%',
                    ),
                ],
              ),
            ),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

typedef ReviewSubmit = Future<bool> Function(
  ReviewDecision decision,
  String? finalLabel,
  String message,
  bool shareSegmentation,
);

/// Valutazione del medico, con le stesse regole del web.
class _ReviewForm extends StatefulWidget {
  const _ReviewForm({
    super.key,
    required this.data,
    required this.busy,
    required this.onSubmit,
  });

  final CaseDetails data;
  final bool busy;
  final ReviewSubmit onSubmit;

  static bool canValidate(CaseDetails data) =>
      data.state == CaseState.awaitingReview &&
      (data.latestAnalysis?.completed ?? false);

  static bool canRequestImages(CaseDetails data) =>
      data.images.length < maxCaseImages && data.state.canReanalyze;

  static bool applies(CaseDetails data) =>
      canValidate(data) || canRequestImages(data);

  @override
  State<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<_ReviewForm> {
  static const _minMessage = 10;

  late final bool _canValidate = _ReviewForm.canValidate(widget.data);
  late final List<String> _suggested = {
    for (final image
        in widget.data.latestAnalysis?.images ?? const <AnalysisImage>[])
      ?image.topLabel,
  }.toList();
  late ReviewDecision _decision = _canValidate
      ? ReviewDecision.approved
      : ReviewDecision.needsImages;
  late final _label = TextEditingController(text: _suggested.firstOrNull ?? '');
  final _message = TextEditingController();
  bool _share = false;

  bool get _requestsImages => _decision == ReviewDecision.needsImages;
  bool get _hasMasks =>
      widget.data.latestAnalysis?.images.any((i) => i.overlayUrl != null) ??
      false;

  @override
  void dispose() {
    _label.dispose();
    _message.dispose();
    super.dispose();
  }

  void _onLabelChanged(String value) {
    // Come sul web: un'etichetta diversa dalla predizione è una correzione.
    if (_decision == ReviewDecision.approved &&
        !_suggested.contains(value.trim())) {
      setState(() => _decision = ReviewDecision.corrected);
    } else {
      setState(() {});
    }
  }

  bool get _valid =>
      _message.text.trim().length >= _minMessage &&
      (_requestsImages || _label.text.trim().isNotEmpty);

  Future<void> _confirm() async {
    final label = _requestsImages ? null : _label.text.trim();
    final message = _message.text.trim();
    final share = !_requestsImages && _share;
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
              if (share)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Sarà condivisa anche la segmentazione.'),
                ),
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
      await widget.onSubmit(_decision, label, message, share);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decisions = [
      if (_canValidate) ...[
        (ReviewDecision.approved, 'Conferma classificazione'),
        (ReviewDecision.corrected, 'Correggi classificazione'),
      ],
      if (_ReviewForm.canRequestImages(widget.data))
        (ReviewDecision.needsImages, 'Richiedi nuove foto'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('La tua valutazione'),
        RadioGroup<ReviewDecision>(
          groupValue: _decision,
          onChanged: (value) {
            if (value != null && !widget.busy) {
              setState(() => _decision = value);
            }
          },
          child: Column(
            children: [
              for (final (value, label) in decisions)
                RadioListTile<ReviewDecision>(
                  contentPadding: EdgeInsets.zero,
                  value: value,
                  title: Text(label),
                ),
            ],
          ),
        ),
        if (!_requestsImages) ...[
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('final-label'),
            controller: _label,
            enabled: !widget.busy,
            maxLength: 160,
            onChanged: _onLabelChanged,
            decoration: const InputDecoration(
              labelText: 'Classificazione da comunicare',
              border: OutlineInputBorder(),
            ),
          ),
          if (_suggested.length > 1)
            Wrap(
              spacing: 8,
              children: [
                for (final label in _suggested)
                  ActionChip(
                    label: Text(label),
                    onPressed: () {
                      _label.text = label;
                      _onLabelChanged(label);
                    },
                  ),
              ],
            ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('patient-message'),
          controller: _message,
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
        if (!_requestsImages && _hasMasks)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Condividi la segmentazione con il paziente'),
            value: _share,
            onChanged: widget.busy
                ? null
                : (value) => setState(() => _share = value),
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _valid && !widget.busy ? _confirm : null,
          child: Text(
            _requestsImages
                ? 'Invia la richiesta al paziente'
                : 'Pubblica la valutazione',
          ),
        ),
      ],
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard(this.review);

  final CaseReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              review.decision?.label ?? 'Comunicazione',
              style: theme.textTheme.titleSmall,
            ),
            if (review.finalLabel case final label? when label.isNotEmpty)
              Text('Classificazione: $label'),
            const SizedBox(height: 4),
            Text(review.patientMessage),
            const SizedBox(height: 4),
            Text(
              [
                review.doctor,
                formatShortDate(review.createdAt),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

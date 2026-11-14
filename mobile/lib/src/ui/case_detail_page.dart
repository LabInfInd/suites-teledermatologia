import 'dart:async';

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../api/user_session.dart';
import '../capture/image_inspector.dart';
import '../capture/photo_picker.dart';
import '../capture/photo_preparation.dart';
import '../domain/acquisition_mode.dart';
import '../domain/captured_photo.dart';
import '../domain/patient_case.dart';
import 'acquisition_controller.dart';
import 'case_widgets.dart';
import 'doctor_case_sections.dart';
import 'image_export.dart';
import 'messages.dart';
import 'patient_case_sections.dart';
import 'widgets.dart';

/// Servizi usati dalle schermate dei casi.
class CaseServices {
  const CaseServices({
    required this.session,
    required this.api,
    required this.picker,
    required this.inspector,
    required this.maxUploadBytes,
    this.shareImage = shareImageWithSystem,
  });

  final UserSession session;
  final CasesApi api;
  final PhotoPicker picker;
  final ImageInspector inspector;
  final int maxUploadBytes;

  /// Consegna al sistema la foto composta scaricata con il token.
  final ImageSharer shareImage;

  bool get isDoctor => session.role == UserRole.doctor;
}

class CaseDetailPage extends StatefulWidget {
  const CaseDetailPage({
    super.key,
    required this.services,
    required this.caseId,
    this.initial,
    this.pollInterval = const Duration(seconds: 3),
  });

  final CaseServices services;
  final String caseId;

  /// Dettagli già disponibili, per esempio subito dopo la creazione.
  final CaseDetails? initial;

  /// Intervallo di aggiornamento mentre un'analisi è in corso.
  final Duration pollInterval;

  @override
  State<CaseDetailPage> createState() => _CaseDetailPageState();
}

class _CaseDetailPageState extends State<CaseDetailPage> {
  static const _maxPolls = 100;

  late CaseDetails? _case = widget.initial;
  bool _busy = false;
  String? _loadError;
  PhotoNotice? _photoNotice;
  Timer? _poll;
  int _polls = 0;

  /// Solo medico: bozza della valutazione e cataloghi per modalità.
  final _draft = ReviewDraft();
  final _catalogs = <AcquisitionMode, List<CatalogModel>>{};

  CaseServices get _services => widget.services;
  CasesApi get _api => _services.api;
  bool get _doctor => _services.isDoctor;

  @override
  void initState() {
    super.initState();
    final initial = _case;
    if (initial == null) {
      unawaited(_reload());
    } else {
      _afterLoad(initial);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _draft.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      _apply(await _api.details(widget.caseId));
    } on CasesFailure catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  void _apply(CaseDetails data) {
    if (!mounted) return;
    setState(() => (_case = data, _loadError = null));
    _afterLoad(data);
  }

  void _afterLoad(CaseDetails data) {
    _schedulePoll(data);
    if (_doctor) {
      final mode = data.latestAnalysis?.mode ?? data.mode;
      if (mode != null) unawaited(_loadCatalog(mode));
    }
  }

  /// Mentre l'analisi è in corso il dettaglio si ricarica da solo; la bozza
  /// della valutazione resta nei campi.
  void _schedulePoll(CaseDetails data) {
    _poll?.cancel();
    final running =
        data.state.isAnalyzing || (data.latestAnalysis?.isRunning ?? false);
    if (!running) {
      _polls = 0;
      return;
    }
    if (_polls++ >= _maxPolls) return;
    _poll = Timer(widget.pollInterval, () {
      if (mounted) unawaited(_reload());
    });
  }

  /// Il catalogo serve solo al medico: il paziente non chiama mai
  /// `/api/models`.
  Future<void> _loadCatalog(AcquisitionMode mode) async {
    if (!_doctor || _catalogs.containsKey(mode)) return;
    try {
      final models = await _api.models(mode);
      if (mounted) setState(() => _catalogs[mode] = models);
    } on CasesFailure catch (e) {
      if (mounted) showCasesError(context, e);
    }
  }

  /// Esegue un'operazione che restituisce il caso aggiornato. Se il caso è
  /// cambiato nel frattempo (409), lo ricarica e mostra il messaggio del
  /// server senza ritentare.
  Future<bool> _run(
    Future<CaseDetails> Function() action, {
    String? done,
  }) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final data = await action();
      if (!mounted) return true;
      _apply(data);
      if (done != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      showCasesError(context, e);
      if (e is CasesFailure && (e.isConflict || e.statusCode == 404)) {
        await _reload();
      }
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

  Future<void> _setMode(AcquisitionMode mode) async {
    final current = _case;
    if (current == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Modalità: ${caseModeLabel(mode)}'),
        content: Text(
          '${caseModeDescription(mode)}\n\n'
          'Confermi che tutte le foto di questo caso sono acquisite così?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Conferma'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(
        () => _api.setAcquisition(current, mode),
        done: 'Modalità di acquisizione salvata.',
      );
    }
  }

  Future<void> _reanalyze(
    AcquisitionMode? mode,
    String? modelId,
    String? explanationTarget,
  ) async {
    final current = _case;
    if (current == null) return;
    await _run(
      () => _api.reanalyze(
        current,
        mode: mode,
        modelId: modelId,
        explanationTarget: explanationTarget,
      ),
      done: 'Nuova analisi richiesta: la pagina si aggiorna da sola.',
    );
  }

  /// Ricalcolo delle mappe per la classe corretta: stesso modello e stessa
  /// modalità, la classificazione non cambia.
  Future<void> _recompute(String label) async {
    final analysis = _case?.latestAnalysis;
    await _reanalyze(null, analysis?.modelId, label);
  }

  Future<void> _download(PublishedExplanation explanation) async {
    final data = _case;
    if (data == null) return;
    try {
      final bytes = await _api.image(explanation.compositeUrl);
      final index = data.images.indexWhere((i) => i.id == explanation.imageId);
      await _services.shareImage(
        bytes,
        'gradcam-${data.code}-foto-${index + 1}.png',
      );
    } catch (e) {
      if (!mounted) return;
      showCasesError(context, e);
      // Mappa revocata: si ricarica il caso, senza riusare l'URL.
      if (e is CasesFailure && e.statusCode == 404) await _reload();
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
                    if (_doctor && data.mode == null)
                      const NoticeCard(
                        icon: Icons.history,
                        title: 'Caso senza modalità di acquisizione',
                        message:
                            'Caso storico: conferma clinical o dermoscopic in «Nuova analisi» '
                            'e attendi il risultato prima di pubblicare una valutazione.',
                      ),
                    if (!_doctor)
                      PatientModeSection(
                        data: data,
                        busy: _busy,
                        onSelect: _setMode,
                      ),
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
                      PatientResponse(
                        api: _api,
                        data: data,
                        onDownload: _download,
                      ),
                    if (_doctor) ...[
                      AnalysisSection(
                        api: _api,
                        data: data,
                        catalog: _catalogFor(data.latestAnalysis?.mode),
                      ),
                      if (data.state.canReanalyze)
                        ReanalyzePanel(
                          key: ValueKey('reanalyze-${data.version}'),
                          data: data,
                          catalogFor: (mode) => _catalogs[mode],
                          onNeedCatalog: (mode) =>
                              unawaited(_loadCatalog(mode)),
                          busy: _busy,
                          onSubmit: _reanalyze,
                        ),
                      ReviewSection(
                        data: data,
                        draft: _draft,
                        busy: _busy,
                        catalog: _catalogFor(data.latestAnalysis?.mode),
                        onRecompute: _recompute,
                        onSubmit:
                            (
                              decision,
                              label,
                              message,
                              segmentation,
                              explanation,
                            ) async {
                              final done = await _run(
                                () => _api.review(
                                  data,
                                  decision: decision,
                                  finalLabel: label,
                                  patientMessage: message,
                                  shareSegmentation: segmentation,
                                  shareExplanation: explanation,
                                ),
                                done: decision == ReviewDecision.needsImages
                                    ? 'Richiesta inviata al paziente.'
                                    : 'Valutazione pubblicata.',
                              );
                              if (done) _draft.reset();
                              return done;
                            },
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

  List<CatalogModel>? _catalogFor(AcquisitionMode? mode) =>
      mode == null ? null : _catalogs[mode];

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
        // Senza modalità il server non può scegliere il percorso di analisi.
        onPressed: data.images.isEmpty || data.mode == null || _busy
            ? null
            : _submit,
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
          Text('Modalità: ${caseModeLabel(data.mode)}'),
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
            if (review.shareExplanation || review.shareSegmentation)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    if (review.shareExplanation) 'Grad-CAM condivisa',
                    if (review.shareSegmentation) 'segmentazione condivisa',
                  ].join(' · '),
                ),
              ),
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

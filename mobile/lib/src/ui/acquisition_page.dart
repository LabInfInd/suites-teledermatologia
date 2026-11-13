import 'package:flutter/material.dart';

import '../api/simulated_server.dart';
import '../config/app_config.dart';
import '../domain/acquisition_mode.dart';
import '../domain/captured_photo.dart';
import '../domain/case_code.dart';
import '../domain/submission.dart';
import 'acquisition_controller.dart';
import 'brand.dart';
import 'messages.dart';
import 'photo_viewer_page.dart';

/// Schermata unica del flusso: tipo di acquisizione, foto, codice caso, invio.
class AcquisitionPage extends StatefulWidget {
  const AcquisitionPage({super.key, required this.controller, required this.connection});

  final AcquisitionController controller;
  final ServerConnection connection;

  @override
  State<AcquisitionPage> createState() => _AcquisitionPageState();
}

class _AcquisitionPageState extends State<AcquisitionPage> {
  late final _caseCode = TextEditingController(text: widget.controller.caseCode);

  AcquisitionController get _controller => widget.controller;

  @override
  void dispose() {
    _caseCode.dispose();
    super.dispose();
  }

  void _startNewCase() {
    _controller.startNewCase();
    _caseCode.clear();
  }

  void _openViewer(CapturedPhoto photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PhotoViewerPage(bytes: photo.bytes)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final caseCodeIssue = c.caseCodeIssue;
        return PopScope(
          canPop: !c.isUploading,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Invio in corso: annullalo prima di uscire.')),
            );
          },
          child: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  const BrandSymbol(size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(Brand.name, overflow: TextOverflow.ellipsis),
                        Text(
                          Brand.caseStudy,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Informazioni',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => showBrandAboutDialog(context),
                ),
              ],
            ),
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  ..._connectionNotice(),
                  const _SectionTitle('1. Tipo di acquisizione'),
                  for (final mode in AcquisitionMode.values)
                    _ModeOption(
                      mode: mode,
                      selected: c.mode == mode,
                      enabled: !c.isLocked,
                      onSelected: () => c.selectMode(mode),
                    ),
                  if (c.mode case final mode?) _Guidance(mode.guidance),
                  const _SectionTitle('2. Foto'),
                  _PhotoSection(controller: c, onOpenViewer: _openViewer),
                  const _SectionTitle('3. Codice caso'),
                  TextField(
                    key: const ValueKey('case-code'),
                    controller: _caseCode,
                    enabled: !c.isLocked,
                    onChanged: c.updateCaseCode,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    maxLength: CaseCode.maxLength,
                    decoration: InputDecoration(
                      labelText: 'Codice caso',
                      helperText:
                          'Codice pseudonimo del caso: non inserire nome, cognome o codice fiscale.',
                      helperMaxLines: 2,
                      errorMaxLines: 3,
                      errorText: c.caseCode.trim().isNotEmpty && caseCodeIssue != null
                          ? caseCodeIssueText(caseCodeIssue)
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const _SectionTitle('4. Invio'),
                  _SubmitSection(
                    controller: c,
                    onNewPhoto: c.startNewPhotoForSameCase,
                    onNewCase: _startNewCase,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _connectionNotice() => switch (widget.connection) {
    SimulatedServer(:final scenario) => [_SimulatedServerBanner(scenario)],
    ServerNotConfigured(:final issue) => [
      _NoticeCard(
        icon: Icons.cloud_off_outlined,
        title: 'Server non configurato',
        message: '${configurationIssueText(issue)} Puoi acquisire le foto, ma non inviarle.',
        isError: true,
      ),
    ],
    RemoteServer() => const [],
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary),
        ),
      ),
    );
  }
}

class _SimulatedServerBanner extends StatelessWidget {
  const _SimulatedServerBanner(this.scenario);

  final SimulatedScenario scenario;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('simulated-banner'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade200,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.shade800, width: 2),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.black87),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.science_outlined, color: Colors.black87),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SERVER SIMULATO', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text(
                    'Solo per sviluppo: le foto non lasciano il telefono e le conferme sono fittizie.',
                  ),
                  if (scenario != SimulatedScenario.success)
                    Text('Scenario di prova: ${scenario.configValue}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = isError ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: isError ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: foreground, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(message, style: TextStyle(color: foreground)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final AcquisitionMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        child: Material(
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('mode-${mode.apiValue}'),
            onTap: enabled ? onSelected : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: enabled ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(mode.label, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(mode.description, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Guidance extends StatelessWidget {
  const _Guidance(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _PhotoSection extends StatelessWidget {
  const _PhotoSection({required this.controller, required this.onOpenViewer});

  final AcquisitionController controller;
  final void Function(CapturedPhoto photo) onOpenViewer;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final photo = c.photo;
    final notice = c.photoNotice;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (photo == null)
          _EmptyPreview(picking: c.isPicking)
        else ...[
          _PhotoPreview(photo: photo, onTap: () => onOpenViewer(photo)),
          const SizedBox(height: 8),
          _PhotoDetails(photo),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('acquire-camera'),
              onPressed: c.canAcquire ? () => c.acquire(PhotoSource.camera) : null,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(photo == null ? 'Scatta foto' : 'Scatta di nuovo'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('acquire-gallery'),
              onPressed: c.canAcquire ? () => c.acquire(PhotoSource.gallery) : null,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(photo == null ? 'Scegli dalla galleria' : 'Sostituisci dalla galleria'),
            ),
            if (photo != null)
              TextButton.icon(
                key: const ValueKey('remove-photo'),
                onPressed: c.isLocked || c.isPicking ? null : c.removePhoto,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Rimuovi'),
              ),
          ],
        ),
        if (c.mode == null && !c.isLocked)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Seleziona prima il tipo di acquisizione.', style: textTheme.bodySmall),
          ),
        if (notice != null)
          _InlineNotice(
            photoNoticeText(notice, maxUploadBytes: c.maxUploadBytes),
            isError: isErrorNotice(notice),
          ),
      ],
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({required this.picking});

  final bool picking;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      alignment: Alignment.center,
      child: picking
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Acquisizione in corso…'),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 40, color: scheme.outline),
                const SizedBox(height: 8),
                const Text('Nessuna foto'),
              ],
            ),
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  const _PhotoPreview({required this.photo, required this.onTap});

  static const _height = 280.0;

  final CapturedPhoto photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        button: true,
        label: 'Anteprima della foto. Tocca per ingrandire.',
        child: GestureDetector(
          key: const ValueKey('photo-preview'),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: Colors.black,
              child: SizedBox(
                height: _height,
                width: double.infinity,
                // Decodifica alla risoluzione dello schermo: la foto inviata
                // resta quella originale.
                child: Image(
                  image: ResizeImage(
                    MemoryImage(photo.bytes),
                    width: (constraints.maxWidth * pixelRatio).round(),
                    height: (_height * pixelRatio).round(),
                    policy: ResizeImagePolicy.fit,
                    allowUpscaling: false,
                  ),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Anteprima non disponibile per questo formato su questo dispositivo.',
                        style: TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoDetails extends StatelessWidget {
  const _PhotoDetails(this.photo);

  final CapturedPhoto photo;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dimensions = photo.dimensions;
    final summary = [
      dimensions == null ? 'Dimensioni non disponibili' : formatDimensions(dimensions),
      formatBytes(photo.sizeInBytes),
      photo.format.label,
      photo.source.label,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(summary, style: textTheme.bodyMedium),
        Text(
          'Tocca l’anteprima per ingrandirla e controllare la nitidezza.',
          style: textTheme.bodySmall,
        ),
        if (photo.hasLowResolution)
          const _InlineNotice(
            'Risoluzione bassa: verifica che la lesione sia nitida e ben inquadrata.',
            isError: true,
          ),
        if (photo.locationMetadataRemoved)
          const _InlineNotice('Rimossi dalla foto i dati di posizione (GPS).', isError: false),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice(this.text, {required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isError ? Icons.warning_amber_rounded : Icons.info_outline, size: 18, color: color),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color))),
          ],
        ),
      ),
    );
  }
}

class _SubmitSection extends StatelessWidget {
  const _SubmitSection({
    required this.controller,
    required this.onNewPhoto,
    required this.onNewCase,
  });

  final AcquisitionController controller;
  final VoidCallback onNewPhoto;
  final VoidCallback onNewCase;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return switch (c.upload) {
      UploadSucceeded(:final receipt) => _ReceiptCard(
        receipt: receipt,
        onNewPhoto: onNewPhoto,
        onNewCase: onNewCase,
      ),
      UploadInProgress(:final progress) => _ProgressCard(progress, onCancel: c.cancelUpload),
      UploadFailed(:final failure) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FailureCard(failure),
          const SizedBox(height: 12),
          ..._requirements(context),
          _submitButton(failure.canRetry ? 'Riprova invio' : null),
        ],
      ),
      UploadIdle() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [..._requirements(context), _submitButton(null)],
      ),
    };
  }

  Widget _submitButton(String? label) => FilledButton.icon(
    key: const ValueKey('submit'),
    onPressed: controller.canSubmit ? controller.submit : null,
    icon: const Icon(Icons.cloud_upload_outlined),
    label: Text(label ?? controller.mode?.submitLabel ?? 'Invia'),
  );

  List<Widget> _requirements(BuildContext context) {
    final c = controller;
    final missing = [
      if (!c.hasServer) 'Configura il collegamento al server',
      if (c.mode == null) 'Seleziona il tipo di acquisizione',
      if (c.photo == null) 'Scatta o scegli una foto',
      if (c.caseCodeIssue != null) 'Inserisci un codice caso valido',
    ];
    if (missing.isEmpty) return const [];
    final style = Theme.of(context).textTheme.bodySmall;
    return [
      for (final item in missing) Text('• $item', style: style),
      const SizedBox(height: 12),
    ];
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard(this.progress, {required this.onCancel});

  final SubmissionProgress? progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = progress;
    final (title, value) = switch (p?.phase) {
      null => ('Preparazione dell’invio…', null),
      SubmissionPhase.uploading => ('Invio della foto…', p!.fraction),
      SubmissionPhase.awaitingResponse => ('In attesa della conferma del server…', null),
      SubmissionPhase.waitingToRetry => (
        'Invio non riuscito: nuovo tentativo tra ${p!.retryIn?.inSeconds ?? 0} s…',
        null,
      ),
    };
    return Card(
      key: const ValueKey('upload-progress'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(liveRegion: true, child: Text(title, style: theme.textTheme.titleSmall)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value, semanticsLabel: 'Avanzamento dell’invio'),
            if (p != null && p.phase == SubmissionPhase.uploading && p.totalBytes > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${(p.fraction! * 100).floor()}% · '
                '${formatBytes(p.bytesSent)} di ${formatBytes(p.totalBytes)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (p != null && p.attempt > 1) ...[
              const SizedBox(height: 4),
              Text('Tentativo ${p.attempt} di ${p.maxAttempts}', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('cancel-upload'),
              onPressed: onCancel,
              icon: const Icon(Icons.close),
              label: const Text('Annulla invio'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.receipt, required this.onNewPhoto, required this.onNewCase});

  final SubmissionReceipt receipt;
  final VoidCallback onNewPhoto;
  final VoidCallback onNewCase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receivedAt = receipt.receivedAt;
    final foreground = receipt.simulated
        ? Colors.black87
        : theme.colorScheme.onSecondaryContainer;
    return Card(
      key: const ValueKey('receipt'),
      color: receipt.simulated ? Colors.amber.shade100 : theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: foreground),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: foreground),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        receipt.simulated
                            ? 'Ricezione confermata (SIMULATA)'
                            : 'Ricezione confermata dal server',
                        style: theme.textTheme.titleMedium?.copyWith(color: foreground),
                      ),
                    ),
                  ],
                ),
              ),
              if (receipt.simulated) ...[
                const SizedBox(height: 4),
                const Text('Conferma fittizia del server simulato: nessuna foto è stata inviata.'),
              ],
              const SizedBox(height: 12),
              _Field('Riferimento', receipt.serverReference ?? '—'),
              if (receivedAt != null) _Field('Ricevuta il', formatDateTime(receivedAt)),
              _Field('Tipo di acquisizione', receipt.mode.label),
              _Field('Codice caso', receipt.caseCode),
              _Field('Identificativo invio', receipt.submissionId),
              const SizedBox(height: 12),
              const Text(
                'Questa conferma attesta solo che il server ha ricevuto la foto. '
                'Non è un risultato diagnostico.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('new-photo'),
                    onPressed: onNewPhoto,
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: const Text('Nuova foto, stesso caso'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('new-case'),
                    onPressed: onNewCase,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Nuovo caso'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard(this.failure);

  final SubmissionFailure failure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = failureText(failure);
    final detail = failureDetail(failure);
    final serverMessage = failure.serverMessage;
    final style = TextStyle(color: scheme.onErrorContainer);
    return Card(
      key: const ValueKey('upload-failure'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(text.title, style: style.copyWith(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(text.message, style: style),
              if (serverMessage != null) ...[
                const SizedBox(height: 8),
                Text('Messaggio del server: $serverMessage', style: style),
              ],
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(detail, style: style.copyWith(fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

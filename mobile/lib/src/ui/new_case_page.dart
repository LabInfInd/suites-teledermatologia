import 'dart:async';

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../domain/acquisition_mode.dart';
import '../domain/patient_case.dart';
import 'case_widgets.dart';
import 'widgets.dart';

/// Crea un caso del paziente. La modalità di acquisizione è obbligatoria e
/// vale per tutte le foto del caso; le foto si aggiungono subito dopo.
class NewCasePage extends StatefulWidget {
  const NewCasePage({super.key, required this.api});

  final CasesApi api;

  @override
  State<NewCasePage> createState() => _NewCasePageState();
}

class _NewCasePageState extends State<NewCasePage> {
  final _bodySite = TextEditingController();
  final _notes = TextEditingController();
  AcquisitionMode? _mode;
  bool _confirmed = false;
  bool _busy = false;

  /// `null` finché non si sa se il server supporta il contratto 2.
  bool? _supported;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    unawaited(_checkServer());
  }

  @override
  void dispose() {
    _bodySite.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Un server senza modalità di acquisizione assegnerebbe un percorso
  /// sbagliato: in quel caso la creazione resta bloccata.
  Future<void> _checkServer() async {
    setState(() => (_supported = null, _statusError = null));
    try {
      final status = await widget.api.status();
      if (mounted) setState(() => _supported = status.supportsAcquisitionModes);
    } on CasesFailure catch (e) {
      if (mounted) setState(() => _statusError = e.message);
    }
  }

  Future<void> _create() async {
    final mode = _mode;
    if (mode == null) return;
    setState(() => _busy = true);
    try {
      final CaseDetails created = await widget.api.create(
        mode: mode,
        bodySite: _bodySite.text.trim(),
        notes: _notes.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) showCasesError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _supported == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Nuovo caso')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_supported == null && _statusError == null)
              const LinearProgressIndicator(),
            if (_statusError != null)
              NoticeCard(
                icon: Icons.cloud_off_outlined,
                title: 'Server non raggiungibile',
                message: _statusError!,
                isError: true,
              ),
            if (_supported == false)
              const NoticeCard(
                icon: Icons.update_disabled,
                title: 'Server non aggiornato',
                message:
                    'Il server non supporta ancora la scelta della modalità di acquisizione: '
                    'non è possibile creare casi finché non viene aggiornato.',
                isError: true,
              ),
            const Text(
              'Dedica un caso a una sola lesione. Dopo averlo creato potrai aggiungere fino a quattro foto della stessa sede.',
            ),
            const SectionTitle('Con cosa acquisirai le foto?'),
            const Text(
              'Tutte le foto del caso devono essere acquisite allo stesso modo. '
              'Per foto acquisite in modo diverso apri un altro caso.',
            ),
            const SizedBox(height: 8),
            ModeSelector(
              value: _mode,
              enabled: ready && !_busy,
              onChanged: (mode) => setState(() => _mode = mode),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('body-site'),
              controller: _bodySite,
              enabled: !_busy,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Dove si trova la lesione? (facoltativo)',
                hintText: 'Es. avambraccio sinistro',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('notes'),
              controller: _notes,
              enabled: !_busy,
              minLines: 3,
              maxLines: 8,
              maxLength: 4000,
              decoration: const InputDecoration(
                labelText: 'Vuoi aggiungere una nota? (facoltativo)',
                helperText: 'Nelle prove evita nomi, date di nascita e altri dati personali.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('demo-confirmed'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmed,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _confirmed = value ?? false),
              title: const Text(
                'Confermo che questo invio contiene soltanto immagini sintetiche e dati di prova.',
              ),
            ),
            const SizedBox(height: 16),
            if (ready && _mode == null)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Scegli la modalità di acquisizione per continuare.',
                ),
              ),
            FilledButton(
              onPressed: ready && _mode != null && _confirmed && !_busy
                  ? _create
                  : null,
              child: Text(
                _busy
                    ? 'Creazione in corso…'
                    : 'Crea il caso e aggiungi le foto',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scelta esplicita della modalità di acquisizione, senza valore predefinito.
class ModeSelector extends StatelessWidget {
  const ModeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final AcquisitionMode? value;
  final ValueChanged<AcquisitionMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<AcquisitionMode>(
      groupValue: value,
      onChanged: (mode) {
        if (mode != null && enabled) onChanged(mode);
      },
      child: Column(
        children: [
          for (final mode in AcquisitionMode.values)
            RadioListTile<AcquisitionMode>(
              key: ValueKey('mode-${mode.apiValue}'),
              contentPadding: EdgeInsets.zero,
              value: mode,
              enabled: enabled,
              title: Text(caseModeLabel(mode)),
              subtitle: Text(caseModeDescription(mode)),
            ),
        ],
      ),
    );
  }
}

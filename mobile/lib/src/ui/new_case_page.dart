import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../domain/patient_case.dart';
import 'case_widgets.dart';

/// Crea un caso del paziente. Le foto si aggiungono subito dopo, nel
/// dettaglio del caso.
class NewCasePage extends StatefulWidget {
  const NewCasePage({super.key, required this.api});

  final CasesApi api;

  @override
  State<NewCasePage> createState() => _NewCasePageState();
}

class _NewCasePageState extends State<NewCasePage> {
  final _bodySite = TextEditingController();
  final _notes = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;

  @override
  void dispose() {
    _bodySite.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final CaseDetails created = await widget.api.create(
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
    return Scaffold(
      appBar: AppBar(title: const Text('Nuovo caso')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Dedica un caso a una sola lesione. Dopo averlo creato potrai aggiungere fino a quattro foto della stessa sede.',
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
            FilledButton(
              onPressed: _confirmed && !_busy ? _create : null,
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

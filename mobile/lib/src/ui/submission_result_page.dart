import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/operator_session.dart';

class SubmissionResultPage extends StatefulWidget {
  const SubmissionResultPage({
    super.key,
    required this.session,
    required this.submissionId,
  });
  final OperatorSession session;
  final String submissionId;
  @override
  State<SubmissionResultPage> createState() => _SubmissionResultPageState();
}

class _SubmissionResultPageState extends State<SubmissionResultPage> {
  Map<String, dynamic>? _status;
  Uint8List? _image, _heat, _seg;
  bool _busy = false, _showHeat = true;
  String? _error;
  Timer? _timer;
  int _polls = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _timer?.cancel();
    setState(() => _busy = true);
    try {
      final status = await widget.session.status(widget.submissionId);
      if (status['state'] == 'completed') {
        final artifacts =
            (status['result'] as Map<String, dynamic>)['artifacts']
                as Map<String, dynamic>;
        _image = await widget.session.artifact(
          artifacts['normalized_image'] as String,
        );
        if (artifacts['heatmap_overlay'] case final String path) {
          _heat = await widget.session.artifact(path);
        }
        if (artifacts['segmentation_overlay'] case final String path) {
          _seg = await widget.session.artifact(path);
        }
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
      if (['queued', 'running'].contains(status['state']) && ++_polls < 30) {
        _timer = Timer(const Duration(seconds: 2), () => unawaited(_refresh()));
      }
    } on OperatorFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Impossibile recuperare l’analisi. Riprova.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _status?['result'] as Map<String, dynamic>?;
    final classification = result?['classification'] as Map<String, dynamic>?;
    final labels = classification?['labels'] as List<dynamic>? ?? [];
    final imageInfo = result?['image'] as Map<String, dynamic>?;
    final overlay = _showHeat ? _heat : _seg;
    return Scaffold(
      appBar: AppBar(title: const Text('Analisi sperimentale')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Risultato di ricerca riservato all’operatore medico. Non sostituisce la valutazione clinica.',
          ),
          const SizedBox(height: 12),
          Text(switch (_status?['state']) {
            'completed' => 'Analisi completata',
            'failed' => 'Analisi non riuscita',
            'running' => 'Analisi in corso',
            _ => 'In attesa di analisi',
          }),
          if (_error != null) Text(_error!),
          if (_busy) const LinearProgressIndicator(),
          if (classification != null) ...[
            const SizedBox(height: 12),
            Text('Modello: ${classification['model_name']}'),
            for (final row in labels)
              Text(
                '${row['label']}: ${((row['score'] as num) * 100).toStringAsFixed(1)}%',
              ),
            const SizedBox(height: 12),
            const Text(
              'Grad-CAM evidenzia aree che influenzano la classificazione; non è una maschera della lesione né una probabilità per pixel.',
            ),
            if ((result?['explanation'] as Map<String, dynamic>?)?['status'] ==
                'no_positive_signal')
              const Text(
                'Nessun contributo positivo visualizzabile per la classe spiegata.',
              ),
            if (_seg != null)
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Grad-CAM'),
                    selected: _showHeat,
                    onSelected: (_) => setState(() => _showHeat = true),
                  ),
                  ChoiceChip(
                    label: const Text('Segmentazione separata'),
                    selected: !_showHeat,
                    onSelected: (_) => setState(() => _showHeat = false),
                  ),
                ],
              ),
            if (_seg == null)
              const Text('Questo modello non produce una segmentazione.'),
            if (_image != null && imageInfo != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: AspectRatio(
                  aspectRatio:
                      (imageInfo['width'] as num) /
                      (imageInfo['height'] as num),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(_image!, fit: BoxFit.fill, cacheWidth: 1024),
                      if (overlay != null)
                        Image.memory(
                          overlay,
                          fit: BoxFit.fill,
                          cacheWidth: 1024,
                        ),
                    ],
                  ),
                ),
              ),
          ],
          OutlinedButton(
            onPressed: _busy ? null : _refresh,
            child: const Text('Aggiorna analisi'),
          ),
        ],
      ),
    );
  }
}

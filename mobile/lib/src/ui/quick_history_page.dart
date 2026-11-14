import 'dart:async';

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../api/user_session.dart';
import 'case_widgets.dart';
import 'submission_result_page.dart';

/// Storico delle analisi rapide inviate dal medico, visibile anche sul web.
class QuickHistoryPage extends StatefulWidget {
  const QuickHistoryPage({super.key, required this.session, required this.api});

  final UserSession session;
  final CasesApi api;

  @override
  State<QuickHistoryPage> createState() => _QuickHistoryPageState();
}

class _QuickHistoryPageState extends State<QuickHistoryPage> {
  List<QuickSubmissionSummary>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final items = await widget.api.quickSubmissions();
      if (mounted) setState(() => (_items = items, _error = null));
    } on CasesFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Analisi rapide inviate')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (items == null && _error == null)
              const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            if (items != null && items.isEmpty)
              const Text('Non hai ancora inviato analisi rapide.'),
            for (final item in items ?? const <QuickSubmissionSummary>[])
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(item.caseCode),
                  subtitle: Text(
                    [
                      item.mode == 'dermoscopic'
                          ? 'Dermatoscopica'
                          : 'Foto clinica',
                      switch (item.state) {
                        'completed' =>
                          item.topLabel == null
                              ? 'Completata'
                              : '${item.topLabel}${item.topScore == null ? '' : ' ${(item.topScore! * 100).toStringAsFixed(1)}%'}',
                        'failed' => 'Non riuscita',
                        'running' => 'In corso',
                        _ => 'In coda',
                      },
                      if (item.receivedAt != null)
                        formatShortDate(item.receivedAt),
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SubmissionResultPage(
                        session: widget.session,
                        submissionId: item.id,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

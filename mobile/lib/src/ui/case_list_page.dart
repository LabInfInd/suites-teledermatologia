import 'dart:async';

import 'package:flutter/material.dart';

import '../api/cases_api.dart';
import '../domain/patient_case.dart';
import 'brand.dart';
import 'case_detail_page.dart';
import 'case_widgets.dart';
import 'new_case_page.dart';

enum _DoctorFilter {
  review('Da validare'),
  waiting('In attesa'),
  released('Pubblicati'),
  all('Tutti');

  const _DoctorFilter(this.label);
  final String label;

  bool includes(CaseState state) => switch (this) {
    review => state == CaseState.awaitingReview,
    waiting => state != CaseState.awaitingReview && state != CaseState.released,
    released => state == CaseState.released,
    all => true,
  };
}

/// "I miei casi" per il paziente, "Casi ricevuti" per il medico.
class CaseListPage extends StatefulWidget {
  const CaseListPage({super.key, required this.services});

  final CaseServices services;

  @override
  State<CaseListPage> createState() => _CaseListPageState();
}

class _CaseListPageState extends State<CaseListPage> {
  CaseList? _cases;
  String? _error;
  bool _loading = false;
  _DoctorFilter _filter = _DoctorFilter.review;

  bool get _doctor => widget.services.isDoctor;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final data = await widget.services.api.list();
      if (mounted) setState(() => (_cases = data, _error = null));
    } on CasesFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String id, {CaseDetails? initial}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CaseDetailPage(
          services: widget.services,
          caseId: id,
          initial: initial,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _newCase() async {
    final created = await Navigator.of(context).push<CaseDetails>(
      MaterialPageRoute(builder: (_) => NewCasePage(api: widget.services.api)),
    );
    if (created != null && mounted) await _open(created.id, initial: created);
  }

  @override
  Widget build(BuildContext context) {
    final items = (_cases?.items ?? const <CaseSummary>[])
        .where((c) => !_doctor || _filter.includes(c.state))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: BrandAppBarTitle(
          subtitle: _doctor
              ? 'Area medico · Casi ricevuti'
              : 'Area paziente · I miei casi',
        ),
        actions: [
          IconButton(
            tooltip: 'Esci',
            icon: const Icon(Icons.logout),
            onPressed: () => widget.services.session.logout(),
          ),
          IconButton(
            tooltip: 'Informazioni',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showBrandAboutDialog(context),
          ),
        ],
      ),
      floatingActionButton: _doctor
          ? null
          : FloatingActionButton.extended(
              onPressed: _newCase,
              icon: const Icon(Icons.add),
              label: const Text('Nuovo caso'),
            ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (_loading) const LinearProgressIndicator(),
              if (_doctor)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final filter in _DoctorFilter.values)
                      ChoiceChip(
                        label: Text(filter.label),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                  ],
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: _reload,
                        child: const Text('Riprova'),
                      ),
                    ],
                  ),
                ),
              if (_cases != null && items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    _doctor
                        ? (_cases!.items.isEmpty
                              ? 'I nuovi casi inviati dai pazienti compariranno qui.'
                              : 'Nessun caso in questa vista.')
                        : 'Non hai ancora casi. Tocca «Nuovo caso» per inviare le foto di una lesione al medico.',
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 8),
              for (final item in items)
                CaseListTile(item: item, onTap: () => _open(item.id)),
            ],
          ),
        ),
      ),
    );
  }
}

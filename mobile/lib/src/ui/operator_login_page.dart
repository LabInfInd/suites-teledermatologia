import 'package:flutter/material.dart';

import '../api/operator_session.dart';
import 'brand.dart';

class OperatorLoginPage extends StatefulWidget {
  const OperatorLoginPage({super.key, required this.session});
  final OperatorSession session;
  @override
  State<OperatorLoginPage> createState() => _OperatorLoginPageState();
}

class _OperatorLoginPageState extends State<OperatorLoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.login(_username.text.trim(), _password.text);
    } on OperatorFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Collegamento al server non riuscito.');
      }
    } finally {
      _password.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(Brand.name)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Accesso operatore medico',
              style: TextStyle(fontSize: 24),
            ),
            const SizedBox(height: 12),
            const Text(
              'Prototipo di ricerca. I risultati non costituiscono una diagnosi clinica validata.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _username,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Nome utente',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) {
                if (!_busy) _login();
              },
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _login,
              child: Text(_busy ? 'Accesso in corso…' : 'Accedi'),
            ),
          ],
        ),
      ),
    ),
  );
}

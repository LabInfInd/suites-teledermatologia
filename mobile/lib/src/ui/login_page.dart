import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/user_session.dart';
import 'brand.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});
  final UserSession session;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  /// Incolla dagli appunti, senza spazi o a capo copiati per errore ai lati.
  Future<void> _paste(TextEditingController controller) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text == null || text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gli appunti non contengono testo.')),
        );
      }
      return;
    }
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Widget _pasteButton(TextEditingController controller, String what) =>
      IconButton(
        tooltip: 'Incolla $what',
        icon: const Icon(Icons.content_paste),
        onPressed: _busy ? null : () => _paste(controller),
      );

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
    } on SessionFailure catch (e) {
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
    appBar: AppBar(title: const BrandAppBarTitle()),
    // Il gruppo permette a iOS e Android di proporre e salvare le credenziali.
    body: AutofillGroup(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Text('Accedi', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 12),
              const Text(
                'Pazienti e medici del progetto: usa le credenziali ricevute dal referente.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Prototipo di ricerca. I risultati non costituiscono una diagnosi clinica validata.',
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                // Incolla dal menu contestuale e compilazione automatica di iOS e Android.
                enableInteractiveSelection: true,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Nome utente',
                  border: const OutlineInputBorder(),
                  suffixIcon: _pasteButton(_username, 'nome utente'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                enableInteractiveSelection: true,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) {
                  if (!_busy) _login();
                },
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: _showPassword
                            ? 'Nascondi password'
                            : 'Mostra password',
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                      ),
                      _pasteButton(_password, 'password'),
                    ],
                  ),
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
    ),
  );
}

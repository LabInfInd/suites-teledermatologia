import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;

import 'api/http_submission_api.dart';
import 'api/simulated_server.dart';
import 'api/submission_api.dart';
import 'capture/image_inspector.dart';
import 'capture/photo_picker.dart';
import 'config/app_config.dart';
import 'ui/acquisition_controller.dart';
import 'ui/acquisition_page.dart';
import 'ui/brand.dart';

/// Servizi usati dall'interfaccia, sostituibili nei test.
class AppDependencies {
  const AppDependencies({
    required this.config,
    required this.picker,
    required this.inspector,
    required this.api,
  });

  factory AppDependencies.production(AppConfig config) {
    // Autenticazione ancora da definire: quando sarà concordata, il token
    // andrà passato con `accessToken` (vedi docs/api-contratto-proposta.md).
    final api = switch (config.connection) {
      RemoteServer(:final baseUrl) => HttpSubmissionApi(
        client: http.Client(),
        baseUrl: baseUrl,
        maxAttempts: config.maxAttempts,
        inactivityTimeout: config.inactivityTimeout,
      ),
      SimulatedServer(:final scenario) => HttpSubmissionApi(
        client: SimulatedServerClient(scenario: scenario),
        // Dominio riservato: non può risolversi verso un server reale.
        baseUrl: Uri.parse('https://server-simulato.invalid'),
        maxAttempts: config.maxAttempts,
        inactivityTimeout: config.inactivityTimeout,
        isSimulated: true,
      ),
      ServerNotConfigured() => null,
    };
    return AppDependencies(
      config: config,
      picker: ImagePickerPhotoPicker(),
      inspector: const EngineImageInspector(),
      api: api,
    );
  }

  final AppConfig config;
  final PhotoPicker picker;
  final ImageInspector inspector;
  final SubmissionApi? api;
}

class SuitesApp extends StatefulWidget {
  const SuitesApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<SuitesApp> createState() => _SuitesAppState();
}

class _SuitesAppState extends State<SuitesApp> {
  late final AcquisitionController _controller = AcquisitionController(
    picker: widget.dependencies.picker,
    inspector: widget.dependencies.inspector,
    api: widget.dependencies.api,
    maxUploadBytes: widget.dependencies.config.maxUploadBytes,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_controller.recoverLostPhoto());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // La variante "fidelity" mantiene il colore primario vicino al blu del logo.
    ColorScheme scheme(Brightness brightness) => ColorScheme.fromSeed(
      seedColor: Brand.blue,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return MaterialApp(
      title: Brand.name,
      debugShowCheckedModeBanner: false,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(colorScheme: scheme(Brightness.light)),
      darkTheme: ThemeData(colorScheme: scheme(Brightness.dark)),
      home: AcquisitionPage(
        controller: _controller,
        connection: widget.dependencies.config.connection,
      ),
    );
  }
}

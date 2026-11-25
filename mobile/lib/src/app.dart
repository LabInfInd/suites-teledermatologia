import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;

import 'api/http_submission_api.dart';
import 'api/cases_api.dart';
import 'api/user_session.dart';
import 'ui/login_page.dart';
import 'api/simulated_server.dart';
import 'api/submission_api.dart';
import 'capture/image_inspector.dart';
import 'capture/photo_picker.dart';
import 'config/app_config.dart';
import 'ui/acquisition_controller.dart';
import 'ui/acquisition_page.dart';
import 'ui/case_detail_page.dart';
import 'ui/case_list_page.dart';
import 'ui/doctor_home_page.dart';
import 'ui/image_export.dart';
import 'ui/brand.dart';

/// Servizi usati dall'interfaccia, sostituibili nei test.
class AppDependencies {
  const AppDependencies({
    required this.config,
    required this.picker,
    required this.inspector,
    required this.api,
    this.session,
    this.cases,
    this.shareImage = shareImageWithSystem,
  });

  factory AppDependencies.production(AppConfig config) {
    final connection = config.connection;
    final session = connection is RemoteServer
        ? UserSession(baseUrl: connection.baseUrl, client: http.Client())
        : null;
    final api = switch (config.connection) {
      RemoteServer(:final baseUrl) => HttpSubmissionApi(
        client: http.Client(),
        baseUrl: baseUrl,
        accessToken: () async => session?.token,
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
      session: session,
      cases: session == null ? null : CasesApi(session),
    );
  }

  final AppConfig config;
  final PhotoPicker picker;
  final ImageInspector inspector;
  final SubmissionApi? api;
  final UserSession? session;

  /// Casi del paziente e revisione del medico; presente con un server reale.
  final CasesApi? cases;

  /// Salvataggio delle mappe pubblicate, sostituibile nei test.
  final ImageSharer shareImage;
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
    catalog: () => widget.dependencies.session?.catalog ?? const [],
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
      home: _home(),
    );
  }

  Widget _home() {
    final dependencies = widget.dependencies;
    final session = dependencies.session;
    if (session == null) {
      return AcquisitionPage(
        controller: _controller,
        connection: dependencies.config.connection,
      );
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.authenticated) return LoginPage(session: session);
        final services = CaseServices(
          session: session,
          api: dependencies.cases ?? CasesApi(session),
          picker: dependencies.picker,
          inspector: dependencies.inspector,
          maxUploadBytes: dependencies.config.maxUploadBytes,
          shareImage: dependencies.shareImage,
        );
        return switch (session.role) {
          UserRole.doctor => DoctorHomePage(
            services: services,
            controller: _controller,
            connection: dependencies.config.connection,
          ),
          _ => CaseListPage(services: services),
        };
      },
    );
  }
}

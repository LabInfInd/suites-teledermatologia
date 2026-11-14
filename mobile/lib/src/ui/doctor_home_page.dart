import 'package:flutter/material.dart';

import '../config/app_config.dart';
import 'acquisition_controller.dart';
import 'acquisition_page.dart';
import 'case_detail_page.dart';
import 'case_list_page.dart';

/// Area del medico: casi ricevuti dai pazienti e analisi rapida.
class DoctorHomePage extends StatefulWidget {
  const DoctorHomePage({
    super.key,
    required this.services,
    required this.controller,
    required this.connection,
  });

  final CaseServices services;
  final AcquisitionController controller;
  final ServerConnection connection;

  @override
  State<DoctorHomePage> createState() => _DoctorHomePageState();
}

class _DoctorHomePageState extends State<DoctorHomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          CaseListPage(services: widget.services),
          AcquisitionPage(
            controller: widget.controller,
            connection: widget.connection,
            session: widget.services.session,
            cases: widget.services.api,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) {
          // Durante un invio rapido si resta sulla schermata di acquisizione.
          if (!widget.controller.isUploading) setState(() => _index = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Casi ricevuti',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_camera_outlined),
            selectedIcon: Icon(Icons.photo_camera),
            label: 'Analisi rapida',
          ),
        ],
      ),
    );
  }
}

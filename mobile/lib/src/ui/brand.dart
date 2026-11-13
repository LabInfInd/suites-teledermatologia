import 'package:flutter/material.dart';

/// Identità della piattaforma SUI.T.E.S., di cui la teledermatologia è un
/// caso studio.
abstract final class Brand {
  static const name = 'SUI.T.E.S.';
  static const fullName = 'Sustainable and Smart Medical Shelter';
  static const caseStudy = 'Teledermatologia · caso studio';

  /// Blu del logo, usato come colore di base del tema.
  static const blue = Color(0xFF126393);

  static const symbolAsset = 'assets/images/suites_symbol.png';
}

/// Simbolo del logo su un riquadro bianco, così resta leggibile anche con il
/// tema scuro. È decorativo: il nome della piattaforma compare sempre accanto.
class BrandSymbol extends StatelessWidget {
  const BrandSymbol({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: Image.asset(Brand.symbolAsset, fit: BoxFit.contain, excludeFromSemantics: true),
    );
  }
}

void showBrandAboutDialog(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: Brand.name,
    applicationIcon: const BrandSymbol(size: 56),
    children: const [
      Text(Brand.fullName, style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 12),
      Text(
        'App per il caso studio di teledermatologia: acquisisce foto cliniche e '
        'dermatoscopiche e le invia al server della piattaforma.',
      ),
      SizedBox(height: 8),
      Text('L’app non esegue modelli e non fornisce risultati diagnostici.'),
    ],
  );
}

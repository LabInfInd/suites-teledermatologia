/// Tipo di acquisizione dichiarato dall'operatore prima dell'invio.
///
/// Il server lo usa per scegliere il modello: le foto cliniche (anche macro)
/// e le immagini dermatoscopiche seguono percorsi distinti e non sono
/// intercambiabili. Una foto macro senza dermatoscopio resta [clinical].
enum AcquisitionMode {
  /// Fotografia clinica con la fotocamera dello smartphone, anche macro.
  clinical('clinical'),

  /// Immagine acquisita attraverso un dermatoscopio collegato al telefono.
  dermoscopic('dermoscopic');

  const AcquisitionMode(this.apiValue);

  /// Valore inviato al server nel campo `mode`.
  final String apiValue;
}

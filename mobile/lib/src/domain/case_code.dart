/// Problemi di validazione del codice caso.
enum CaseCodeIssue { empty, tooShort, tooLong, invalidCharacters, looksLikeTaxCode }

/// Regole del codice caso.
///
/// Il codice caso è un identificativo pseudonimo concordato con il centro:
/// non deve contenere nome, cognome o codice fiscale del paziente.
abstract final class CaseCode {
  static const minLength = 3;
  static const maxLength = 40;

  static final _allowed = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

  // Struttura del codice fiscale, comprese le varianti per omocodia.
  static final _taxCode = RegExp(
    r'^[A-Z]{6}[0-9LMNPQRSTUV]{2}[ABCDEHLMPRST][0-9LMNPQRSTUV]{2}'
    r'[A-Z][0-9LMNPQRSTUV]{3}[A-Z]$',
    caseSensitive: false,
  );

  /// Forma inviata al server.
  static String normalize(String input) => input.trim();

  /// Restituisce il primo problema trovato, oppure `null` se il codice è valido.
  static CaseCodeIssue? validate(String input) {
    final value = normalize(input);
    if (value.isEmpty) return CaseCodeIssue.empty;
    if (value.length < minLength) return CaseCodeIssue.tooShort;
    if (value.length > maxLength) return CaseCodeIssue.tooLong;
    if (!_allowed.hasMatch(value)) return CaseCodeIssue.invalidCharacters;
    if (_taxCode.hasMatch(value)) return CaseCodeIssue.looksLikeTaxCode;
    return null;
  }
}

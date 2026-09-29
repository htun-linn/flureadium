import '../shared/publication/locator.dart';

/// Optional selection API implemented by reader widgets that can expose an
/// EPUB text selection without changing the base reader widget contract.
abstract interface class ReadiumReaderSelectionInterface {
  Future<Locator?> getCurrentSelection();

  /// Selects the full passage described by [locator] in the active EPUB.
  Future<void> selectLocator(Locator locator);

  /// Clears the current EPUB text selection.
  Future<void> clearSelection();
}

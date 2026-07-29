import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';

/// Curated online samples used by the preferences demo.
class _DemoSample {
  const _DemoSample({
    required this.label,
    required this.url,
    required this.blurb,
    required this.icon,
  });

  final String label;
  final String url;
  final String blurb;
  final IconData icon;
}

/// Reflowable samples that respond to lineHeight / publisherStyles.
const _kDemoSamples = [
  _DemoSample(
    label: 'Accessible EPUB 3',
    url:
        'https://github.com/IDPF/epub3-samples/releases/download/20230704/'
        'accessible_epub_3.epub',
    blurb: 'IDPF sample with publisher CSS (direct .epub download)',
    icon: Icons.accessibility_new_outlined,
  ),
  _DemoSample(
    label: 'Moby Dick',
    url: 'https://readium.org/webpub-manifest/examples/MobyDick/manifest.json',
    blurb: 'Readium WebPub manifest sample',
    icon: Icons.menu_book_outlined,
  ),
  _DemoSample(
    label: 'Les Diaboliques',
    url:
        'https://publication-server.readium.org/webpub/'
        'Z3M6Ly9yZWFkaXVtLXBsYXlncm91bmQtZmlsZXMvZGVtby9sZXNfZGlhYm9saXF1ZXMuZXB1Yg/'
        'manifest.json',
    blurb: 'Readium playground reflowable EPUB',
    icon: Icons.auto_stories_outlined,
  ),
];

/// Default sample URL (Accessible EPUB 3).
const kPreferencesDemoEpubUrl =
    'https://github.com/IDPF/epub3-samples/releases/download/20230704/'
    'accessible_epub_3.epub';

const _kFontChoices = ['Georgia', 'Helvetica', 'Times New Roman', 'Courier'];

/// Dedicated screen that demos EPUB preference features from 0.15.0:
/// [EPUBPreferences.lineHeight], [EPUBPreferences.publisherStyles], and
/// optional [EPUBPreferences.fontFamily] (null keeps publisher fonts).
class EpubPreferencesDemoPage extends StatefulWidget {
  const EpubPreferencesDemoPage({
    this.epubUrl = kPreferencesDemoEpubUrl,
    super.key,
  });

  final String epubUrl;

  @override
  State<EpubPreferencesDemoPage> createState() =>
      _EpubPreferencesDemoPageState();
}

class _EpubPreferencesDemoPageState extends State<EpubPreferencesDemoPage> {
  final _flureadium = Flureadium();
  final _sheetController = DraggableScrollableController();

  Publication? _publication;
  String? _error;
  bool _loading = true;
  late String _selectedUrl;

  double _lineHeight = 1.5;
  bool _publisherStyles = false;
  bool _usePublisherFonts = true;
  String _customFontFamily = 'Georgia';
  int _fontSize = 100;

  static const _sheetSizes = [0.12, 0.42, 0.88];

  @override
  void initState() {
    super.initState();
    _selectedUrl = widget.epubUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSample());
  }

  @override
  void dispose() {
    _sheetController.dispose();
    // Flureadium is a singleton shared with ReaderPage — release on exit.
    _flureadium.closePublication();
    super.dispose();
  }

  _DemoSample get _selectedSample => _kDemoSamples.firstWhere(
        (s) => s.url == _selectedUrl,
        orElse: () => _DemoSample(
          label: 'Custom',
          url: _selectedUrl,
          blurb: _selectedUrl,
          icon: Icons.link,
        ),
      );

  Future<void> _openSample() async {
    setState(() {
      _loading = true;
      _error = null;
      _publication = null;
    });
    try {
      final pub = await _flureadium.openPublication(_selectedUrl);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _loading = false;
      });
      await _applyPreferences();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _applyPreferences() async {
    if (_publication == null) return;
    await _flureadium.setEPUBPreferences(
      EPUBPreferences(
        fontFamily: _usePublisherFonts ? null : _customFontFamily,
        fontSize: _fontSize,
        fontWeight: null,
        verticalScroll: false,
        backgroundColor: const Color(0xFFFFFFF8),
        textColor: const Color(0xFF1A1A1A),
        lineHeight: _lineHeight,
        publisherStyles: _publisherStyles,
      ),
    );
  }

  Future<void> _setLineHeightPreset(double value) async {
    setState(() {
      _lineHeight = value;
      _publisherStyles = false;
    });
    await _applyPreferences();
  }

  void _expandSheet() {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(
      _sheetSizes[1],
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('Reading preferences'),
        actions: [
          IconButton(
            tooltip: 'Reload sample',
            onPressed: _loading ? null : _openSample,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Adjust reading',
            onPressed: _expandSheet,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildReader(colorScheme, textTheme)),
          _buildSettingsSheet(colorScheme, textTheme),
        ],
      ),
    );
  }

  Widget _buildReader(ColorScheme colorScheme, TextTheme textTheme) {
    if (_loading) {
      return _EmptyState(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text('Loading sample', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                _selectedSample.blurb,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return _EmptyState(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text('Couldn’t load the sample', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSample,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    final pub = _publication;
    if (pub == null) {
      return _EmptyState(
        child: Text('No publication loaded', style: textTheme.titleMedium),
      );
    }

    return Stack(
      children: [
        // Leave room for the collapsed sheet peek.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: 56,
          child: ReadiumReaderWidget(publication: pub),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 72,
          child: _ReaderChrome(
            onPrevious: () => _flureadium.goLeft(),
            onNext: () => _flureadium.goRight(),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsSheet(ColorScheme colorScheme, TextTheme textTheme) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: _sheetSizes[0],
      minChildSize: _sheetSizes[0],
      maxChildSize: _sheetSizes[2],
      snap: true,
      snapSizes: _sheetSizes,
      builder: (context, scrollController) {
        return Material(
          elevation: 3,
          shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
          color: colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: ListTile(
                  leading: Icon(
                    Icons.tune,
                    color: colorScheme.primary,
                  ),
                  title: Text(
                    'Reading settings',
                    style: textTheme.titleMedium,
                  ),
                  subtitle: Text(
                    _statusLine,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: IconButton.filledTonal(
                    tooltip: 'Expand settings',
                    onPressed: _expandSheet,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                ),
              ),
              const Divider(height: 1),
              _SectionHeader(
                icon: Icons.collections_bookmark_outlined,
                title: 'Sample book',
                subtitle: 'Online reflowable EPUB used for this demo',
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownMenu<String>(
                  initialSelection: _selectedUrl,
                  expandedInsets: EdgeInsets.zero,
                  label: const Text('Publication'),
                  leadingIcon: Icon(_selectedSample.icon),
                  enabled: !_loading,
                  dropdownMenuEntries: [
                    for (final sample in _kDemoSamples)
                      DropdownMenuEntry(
                        value: sample.url,
                        label: sample.label,
                        leadingIcon: Icon(sample.icon),
                      ),
                  ],
                  onSelected: (url) async {
                    if (url == null || url == _selectedUrl) return;
                    setState(() => _selectedUrl = url);
                    await _openSample();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  _selectedSample.blurb,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _SectionHeader(
                icon: Icons.format_line_spacing,
                title: 'Line height',
                subtitle: _publisherStyles
                    ? 'Turn off publisher styles below to apply this'
                    : 'Leading multiplier for reflowable text',
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 1.0, label: Text('Tight')),
                    ButtonSegment(value: 1.5, label: Text('Normal')),
                    ButtonSegment(value: 2.0, label: Text('Loose')),
                  ],
                  emptySelectionAllowed: true,
                  selected: {
                    if (_lineHeight == 1.0 ||
                        _lineHeight == 1.5 ||
                        _lineHeight == 2.0)
                      _lineHeight,
                  },
                  onSelectionChanged: (selection) async {
                    if (selection.isEmpty) return;
                    await _setLineHeightPreset(selection.first);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: ListTile(
                  title: Text(
                    'Custom · ${_lineHeight.toStringAsFixed(1)}',
                    style: textTheme.bodyLarge,
                  ),
                  subtitle: Slider(
                    min: 1.0,
                    max: 2.5,
                    divisions: 15,
                    label: _lineHeight.toStringAsFixed(1),
                    value: _lineHeight,
                    onChanged: (v) => setState(() => _lineHeight = v),
                    onChangeEnd: (_) => _applyPreferences(),
                  ),
                ),
              ),
              _SectionHeader(
                icon: Icons.text_fields,
                title: 'Typeface & size',
                subtitle: 'Font override is independent of publisherStyles',
              ),
              SwitchListTile(
                secondary: Icon(
                  _usePublisherFonts
                      ? Icons.font_download_outlined
                      : Icons.font_download,
                ),
                title: const Text('Use publisher fonts'),
                subtitle: Text(
                  _usePublisherFonts
                      ? 'fontFamily omitted — keep the EPUB typeface'
                      : 'Override with $_customFontFamily',
                ),
                value: _usePublisherFonts,
                onChanged: (v) async {
                  setState(() => _usePublisherFonts = v);
                  await _applyPreferences();
                },
              ),
              if (!_usePublisherFonts)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final font in _kFontChoices)
                        ChoiceChip(
                          label: Text(
                            font,
                            style: TextStyle(fontFamily: font),
                          ),
                          selected: _customFontFamily == font,
                          onSelected: (_) async {
                            setState(() => _customFontFamily = font);
                            await _applyPreferences();
                          },
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
                child: ListTile(
                  title: Text('Font size · $_fontSize%', style: textTheme.bodyLarge),
                  subtitle: Slider(
                    min: 80,
                    max: 160,
                    divisions: 8,
                    label: '$_fontSize%',
                    value: _fontSize.toDouble(),
                    onChanged: (v) => setState(() => _fontSize = v.round()),
                    onChangeEnd: (_) => _applyPreferences(),
                  ),
                ),
              ),
              _SectionHeader(
                icon: Icons.css_outlined,
                title: 'Publisher styles',
                subtitle:
                    'Advanced typography (including line height) requires this off',
              ),
              if (_publisherStyles && _lineHeight != 1.5)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Card(
                    elevation: 0,
                    color: colorScheme.tertiaryContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.info_outline,
                        color: colorScheme.onTertiaryContainer,
                      ),
                      title: Text(
                        'Line height is inactive',
                        style: textTheme.titleSmall?.copyWith(
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                      subtitle: Text(
                        'Publisher CSS is winning. Turn this switch off to see '
                        'your line-height setting.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              SwitchListTile(
                secondary: const Icon(Icons.style_outlined),
                title: const Text('Observe publisher styles'),
                subtitle: Text(
                  _publisherStyles
                      ? 'On — book CSS takes precedence'
                      : 'Off — required for line height to apply',
                ),
                value: _publisherStyles,
                onChanged: (v) async {
                  setState(() => _publisherStyles = v);
                  await _applyPreferences();
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  String get _statusLine {
    final font =
        _usePublisherFonts ? 'Publisher fonts' : _customFontFamily;
    return 'LH ${_lineHeight.toStringAsFixed(1)} · '
        '${_publisherStyles ? 'Styles on' : 'Styles off'} · '
        '$font · $_fontSize%';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: child,
        ),
      ),
    );
  }
}

/// Floating previous / next controls over the reader.
class _ReaderChrome extends StatelessWidget {
  const _ReaderChrome({
    required this.onPrevious,
    required this.onNext,
  });

  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'Previous page',
          onPressed: onPrevious,
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.92),
          ),
          icon: const Icon(Icons.chevron_left),
        ),
        const Spacer(),
        IconButton.filledTonal(
          tooltip: 'Next page',
          onPressed: onNext,
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.92),
          ),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

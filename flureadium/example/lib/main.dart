import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flureadium/flureadium.dart';
import 'audio_stream_fixtures.dart';
import 'epub_preferences_demo.dart';

const _defaultInitialAsset = String.fromEnvironment(
  'FLUREADIUM_INITIAL_ASSET',
  defaultValue: 'assets/pubs/moby_dick.epub',
);

void main({String initialAsset = _defaultInitialAsset}) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ExampleApp(initialAsset: initialAsset));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({this.initialAsset = _defaultInitialAsset, super.key});

  final String initialAsset;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3D5A80), brightness: Brightness.light);
    return MaterialApp(
      title: 'Flureadium Example',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        appBarTheme: AppBarTheme(
          centerTitle: false,
          backgroundColor: colorScheme.surface,
          foregroundColor: colorScheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(48, 48))),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      home: ReaderPage(initialAsset: initialAsset),
    );
  }
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({this.initialAsset = _defaultInitialAsset, super.key});

  final String initialAsset;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _flureadium = Flureadium();
  Publication? _publication;
  Locator? _locator;
  Locator? _savedLocator;
  ReadiumTimebasedState? _timebasedState;
  // Bumped each time a publication finishes opening (after openPublication
  // returns). Integration tests read this before tapping an "Open ..." button
  // and poll until it increments, so they wait exactly until the new
  // publication is loaded instead of a fixed duration.
  int _openGeneration = 0;
  bool _endedSeen = false;
  bool _controlsVisible = true;
  bool _ttsEnabled = false;
  Locator? _lastTtsLocator;
  Locator? _readerLocatorAtTtsDisable;
  bool _audioEnabled = false;
  bool _audioPaused = false;
  List<ReaderTTSVoice> _voices = [];
  int _voiceIndex = 0;
  TimebasedState? _ttsPlaybackState;
  TtsErrorType? _ttsErrorType;
  double _ttsSpeed = 1.0;
  // Latches the last error delivered on onErrorEvent so integration tests can
  // assert that a failed audio resource load surfaces instead of stalling.
  String _lastAudioError = '';
  // Local server backing the 'Open AudioBook BadStream' action: serves a WAV
  // whose Content-Length promises the full clip but drops the socket after a
  // partial body, producing a mid-stream failure both audio engines observe.
  HttpServer? _badStreamServer;
  StreamedAudioServer? _streamedServer;
  // Latched by the streamed-audio fixture when AVFoundation cancels an
  // in-flight range request (client disconnect mid-response); lets the
  // integration test confirm the benign-cancellation path actually ran.
  bool _cancelledStreamDisconnectSeen = false;

  StreamSubscription<ReadiumReaderStatus>? _statusSub;
  StreamSubscription<Locator>? _locatorSub;
  StreamSubscription<ReadiumError>? _errorSub;
  StreamSubscription<ReadiumTimebasedState>? _timebasedSub;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Cycled by the "Line Height" button to manually verify lineHeight support
  // on both platforms. publisherStyles must be false for lineHeight to apply.
  static const _lineHeightPresets = [1.0, 1.5, 2.0];
  int _lineHeightIndex = 0;

  @override
  void initState() {
    super.initState();
    // timebased-state is registered eagerly by the plugin; subscribe here.
    // reader-status, text-locator and error are registered lazily on iOS
    // (inside ReadiumReaderView.init(), which fires from _onPlatformViewCreated).
    // Those channels are subscribed via ReadiumReaderWidget.onReady, which is
    // called from _onPlatformViewCreated after all native handlers are set up.
    _timebasedSub = _flureadium.onTimebasedPlayerStateChanged.listen(
      (s) => setState(() {
        _timebasedState = s;
        // Latch end-of-book: the player can settle to `paused` immediately
        // after emitting `ended`, so the resting state is not reliable. Record
        // that `ended` was ever delivered for end-of-book assertions.
        if (s.state == TimebasedState.ended) _endedSeen = true;
        _ttsPlaybackState = _ttsEnabled ? s.state : null;
        _ttsErrorType = _ttsEnabled ? s.ttsErrorType : null;
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPublicationAsset(widget.initialAsset);
    });
  }

  // Called by ReadiumReaderWidget.onReady, which fires from _onPlatformViewCreated
  // after the native platform view (and all EventChannel handlers) are ready.
  // Safe to call on all platforms: Android registers channels eagerly; iOS
  // registers them lazily in ReadiumReaderView.init() which runs just before
  // onReady fires. No polling, no timers — pumpAndSettle works correctly.
  void _subscribeToChannels() {
    _statusSub?.cancel();
    _locatorSub?.cancel();
    _errorSub?.cancel();
    _statusSub = _flureadium.onReaderStatusChanged.listen((s) => debugPrint('ReaderStatus: $s'));
    _locatorSub = _flureadium.onTextLocatorChanged.listen(
      (l) => setState(() {
        _locator = l;
        _savedLocator = l;
      }),
    );
    _errorSub = _flureadium.onErrorEvent.listen((e) {
      debugPrint('FlureadiumError: $e');
      if (!mounted) return;
      setState(() => _lastAudioError = e.message);
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _locatorSub?.cancel();
    _errorSub?.cancel();
    _timebasedSub?.cancel();
    _badStreamServer?.close(force: true);
    _streamedServer?.close();
    super.dispose();
  }

  Future<void> _openEpub() async {
    try {
      await _openPublicationAsset('assets/pubs/moby_dick.epub');
    } catch (e) {
      debugPrint('openEpub error: $e');
    }
  }

  Future<void> _openCbz() async {
    try {
      await _openPublicationAsset('assets/pubs/sample_comic.cbz');
    } catch (e) {
      debugPrint('openCbz error: $e');
    }
  }

  Future<void> _openDivina() async {
    try {
      await _openPublicationAsset('assets/pubs/sample_visual.divina');
    } catch (e) {
      debugPrint('openDivina error: $e');
    }
  }

  Future<void> _openAudiobook() async {
    try {
      final path = await _extractAsset('assets/pubs/38533.audiobook');
      final pub = await _flureadium.openPublication(path);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _openGeneration++;
        _endedSeen = false;
        _ttsEnabled = false;
        _lastTtsLocator = null;
        _readerLocatorAtTtsDisable = null;
        _audioEnabled = false;
        _audioPaused = false;
        _voices = [];
        _voiceIndex = 0;
      });
    } catch (e) {
      debugPrint('openAudiobook error: $e');
    }
  }

  Future<void> _openAudiobookUntitledChapter() async {
    try {
      final path = await _extractAsset('assets/pubs/untitled_chapter.audiobook');
      final pub = await _flureadium.openPublication(path);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _openGeneration++;
        _ttsEnabled = false;
        _lastTtsLocator = null;
        _readerLocatorAtTtsDisable = null;
        _audioEnabled = false;
        _audioPaused = false;
        _voices = [];
        _voiceIndex = 0;
      });
    } catch (e) {
      debugPrint('openAudiobookUntitledChapter error: $e');
    }
  }

  Future<void> _openUnreachableAudiobook() async {
    // A well-formed audiobook manifest whose only track points at an
    // unreachable host. The manifest parses, but the first audio resource load
    // fails inside AVFoundation — the streaming path Phase 2 forwards to
    // onErrorEvent instead of stalling silently at 0:00.
    const manifest = '''
{
  "@context": "https://readium.org/webpub-manifest/context.jsonld",
  "metadata": {
    "@type": "http://schema.org/Audiobook",
    "conformsTo": "https://readium.org/webpub-manifest/profiles/audiobook",
    "title": "Unreachable Audio",
    "duration": 120
  },
  "links": [
    { "rel": "self", "href": "http://127.0.0.1:9/manifest.json", "type": "application/audiobook+json" }
  ],
  "readingOrder": [
    { "href": "http://127.0.0.1:9/unreachable.mp3", "type": "audio/mpeg", "duration": 120 }
  ]
}
''';
    try {
      final tmp = File(
        '${Directory.systemTemp.path}/'
        '${DateTime.now().millisecondsSinceEpoch}_unreachable.json',
      );
      await tmp.writeAsString(manifest);
      final pub = await _flureadium.openPublication(tmp.path);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _openGeneration++;
        _lastAudioError = '';
        _endedSeen = false;
        _ttsEnabled = false;
        _lastTtsLocator = null;
        _readerLocatorAtTtsDisable = null;
        _audioEnabled = false;
        _audioPaused = false;
        _voices = [];
        _voiceIndex = 0;
      });
    } catch (e) {
      debugPrint('openUnreachableAudiobook error: $e');
    }
  }

  // Opens an audiobook whose single track streams from a local server that
  // sends a valid WAV header plus a short PCM prefix, then drops the socket
  // before satisfying the advertised Content-Length. Playback starts and then
  // fails mid-stream — the observable failure path (unlike a dead host, which
  // fails at load time before iOS can surface it).
  Future<void> _openMidStreamFailAudiobook() async {
    const sampleRate = 8000;
    const bytesPerSample = 2; // 16-bit mono
    const fullDataSize = sampleRate * bytesPerSample * 30; // 30s promised
    const prefixSize = sampleRate * bytesPerSample; // 1s actually sent
    final header = wavHeader(dataSize: fullDataSize, sampleRate: sampleRate);
    final contentLength = header.length + fullDataSize;

    await _badStreamServer?.close(force: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _badStreamServer = server;
    server.listen((request) async {
      // Bypass HttpResponse's length bookkeeping: write a raw response whose
      // Content-Length exceeds what we send, then close early.
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.add(
        utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: audio/wav\r\n'
          'Content-Length: $contentLength\r\n'
          'Accept-Ranges: none\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      socket.add(header);
      socket.add(Uint8List(prefixSize)); // 1s of silence, then nothing
      await socket.flush();
      await socket.close();
      socket.destroy();
    });

    final audioUrl = 'http://127.0.0.1:${server.port}/audio.wav';
    final manifest =
        '''
{
  "@context": "https://readium.org/webpub-manifest/context.jsonld",
  "metadata": {
    "@type": "http://schema.org/Audiobook",
    "conformsTo": "https://readium.org/webpub-manifest/profiles/audiobook",
    "title": "Truncated Stream Audio",
    "duration": 30
  },
  "links": [
    { "rel": "self", "href": "$audioUrl", "type": "application/audiobook+json" }
  ],
  "readingOrder": [
    { "href": "$audioUrl", "type": "audio/wav", "duration": 30 }
  ]
}
''';
    try {
      final tmp = File(
        '${Directory.systemTemp.path}/'
        '${DateTime.now().millisecondsSinceEpoch}_truncated.json',
      );
      await tmp.writeAsString(manifest);
      final pub = await _flureadium.openPublication(tmp.path);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _openGeneration++;
        _lastAudioError = '';
        _endedSeen = false;
        _ttsEnabled = false;
        _lastTtsLocator = null;
        _readerLocatorAtTtsDisable = null;
        _audioEnabled = false;
        _audioPaused = false;
        _voices = [];
        _voiceIndex = 0;
      });
    } catch (e) {
      debugPrint('openMidStreamFailAudiobook error: $e');
    }
  }

  Future<void> _openStreamedAudiobook() async {
    // A complete, valid, range-seekable WAV served by a local server that
    // trickles the tail of each range so a read-ahead request is in flight
    // during playback. Seeking supersedes it, producing the benign
    // HTTPError.cancelled the iOS reporter must swallow (see the
    // 'seeking a streamed audiobook does not surface a spurious cancelled
    // error' integration test).
    await _streamedServer?.close();
    // 10 minutes, so the test's repeated +30s seeks stay well inside the track
    // (each seek supersedes the in-flight read-ahead request without ending it).
    final server = await StreamedAudioServer.startSilentWav(seconds: 600);
    server.onClientCancel = () {
      if (mounted) setState(() => _cancelledStreamDisconnectSeen = true);
    };
    _streamedServer = server;

    final manifest =
        '''
{
  "@context": "https://readium.org/webpub-manifest/context.jsonld",
  "metadata": {
    "@type": "http://schema.org/Audiobook",
    "conformsTo": "https://readium.org/webpub-manifest/profiles/audiobook",
    "title": "Streamed Audio",
    "duration": 600
  },
  "links": [
    { "rel": "self", "href": "${server.url}", "type": "application/audiobook+json" }
  ],
  "readingOrder": [
    { "href": "${server.url}", "type": "audio/wav", "duration": 600 }
  ]
}
''';
    try {
      final tmp = File(
        '${Directory.systemTemp.path}/'
        '${DateTime.now().millisecondsSinceEpoch}_streamed.json',
      );
      await tmp.writeAsString(manifest);
      final pub = await _flureadium.openPublication(tmp.path);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _openGeneration++;
        _lastAudioError = '';
        _cancelledStreamDisconnectSeen = false;
        _endedSeen = false;
        _ttsEnabled = false;
        _lastTtsLocator = null;
        _readerLocatorAtTtsDisable = null;
        _audioEnabled = false;
        _audioPaused = false;
        _voices = [];
        _voiceIndex = 0;
      });
    } catch (e) {
      debugPrint('openStreamedAudiobook error: $e');
    }
  }

  Future<void> _openPublicationAsset(String assetPath) async {
    final path = await _extractAsset(assetPath);
    final pub = await _flureadium.openPublication(path);
    if (!mounted) return;
    setState(() {
      _publication = pub;
      _openGeneration++;
      _endedSeen = false;
      _ttsEnabled = false;
      _lastTtsLocator = null;
      _readerLocatorAtTtsDisable = null;
      _audioEnabled = false;
      _audioPaused = false;
      _voices = [];
      _voiceIndex = 0;
    });
  }

  Future<void> _openWebPub() async {
    try {
      await _flureadium.setCustomHeaders({'X-Example': 'flureadium-demo'});
      const url = 'https://readium.org/webpub-manifest/examples/MobyDick/manifest.json';
      final pub = await _flureadium.openPublication(url);
      if (!mounted) return;
      setState(() {
        _publication = pub;
        _openGeneration++;
        _ttsEnabled = false;
        _lastTtsLocator = null;
        _readerLocatorAtTtsDisable = null;
        _audioEnabled = false;
        _audioPaused = false;
        _voices = [];
        _voiceIndex = 0;
      });
    } catch (e) {
      debugPrint('openWebPub error: $e');
    }
  }

  Future<String> _extractAsset(String assetPath) async {
    if (kIsWeb) {
      return Uri.base.resolve(assetPath).toString();
    }
    final bytes = await rootBundle.load(assetPath);
    final filename = assetPath.split('/').last;
    final tmp = File('${Directory.systemTemp.path}/${DateTime.now().millisecondsSinceEpoch}_$filename');
    await tmp.writeAsBytes(bytes.buffer.asUint8List());
    return tmp.path;
  }

  Future<void> _close() async {
    await _flureadium.closePublication();
    if (!mounted) return;
    setState(() {
      _publication = null;
      _ttsEnabled = false;
      _lastTtsLocator = null;
      _readerLocatorAtTtsDisable = null;
      _audioEnabled = false;
      _audioPaused = false;
      _voices = [];
      _voiceIndex = 0;
    });
  }

  Future<void> _setNightPreferences() async {
    await _flureadium.setEPUBPreferences(
      EPUBPreferences(
        fontFamily: 'Georgia',
        fontSize: 100,
        fontWeight: null,
        verticalScroll: false,
        backgroundColor: const Color(0xFF1A1A1A),
        textColor: const Color(0xFFE0E0E0),
      ),
    );
  }

  /// Cycles through [_lineHeightPresets] to manually verify that lineHeight
  /// (gated behind publisherStyles: false) renders on both platforms while
  /// keeping the EPUB's own / publisher fonts (fontFamily omitted).
  Future<void> _cycleLineHeight() async {
    setState(() {
      _lineHeightIndex = (_lineHeightIndex + 1) % _lineHeightPresets.length;
    });
    final lineHeight = _lineHeightPresets[_lineHeightIndex];

    await _flureadium.setEPUBPreferences(
      EPUBPreferences(
        fontSize: 100,
        fontWeight: null,
        verticalScroll: false,
        backgroundColor: const Color(0xFFFFFFFF),
        textColor: const Color(0xFF000000),
        lineHeight: lineHeight,
        publisherStyles: false,
      ),
    );
  }

  /// Opens the dedicated preferences demo (online sample EPUB). Closes the
  /// current publication first because [Flureadium] is a singleton.
  Future<void> _openPreferencesDemo() async {
    await _flureadium.closePublication();
    if (!mounted) return;
    setState(() {
      _publication = null;
      _ttsEnabled = false;
      _audioEnabled = false;
    });
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EpubPreferencesDemoPage()));
  }

  Future<void> _toggleTts() async {
    if (_ttsEnabled) {
      _lastTtsLocator = _timebasedState?.currentLocator;
      _readerLocatorAtTtsDisable = _locator;
      await _flureadium.stop();
      if (!mounted) return;
      setState(() {
        _ttsEnabled = false;
        _ttsPlaybackState = null;
        _ttsErrorType = null;
        _voices = [];
        _voiceIndex = 0;
      });
      return;
    }
    final canSpeak = await _flureadium.ttsCanSpeak();
    if (!canSpeak) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('TTS is not supported for this publication')));
      }
      return;
    }
    // Detect whether the reader position changed since TTS was disabled.
    // If the user navigated to a different page, start TTS from the current
    // reader position (fromLocator: null) instead of resuming from the saved
    // TTS locator — this prevents backward scrolling to the previous page.
    final navigated = _readerLocatorAtTtsDisable != null && _locator != null && _readerLocatorAtTtsDisable != _locator;
    final resumeLocator = navigated ? null : _lastTtsLocator;
    await _flureadium.ttsEnable(TTSPreferences(speed: _ttsSpeed), fromLocator: resumeLocator);
    if (!mounted) return;
    // Set _ttsEnabled before play() so that the onTimebasedPlayerStateChanged
    // callback (which guards on _ttsEnabled) correctly captures the 'playing'
    // state when the native engine reports it.
    setState(() {
      _ttsEnabled = true;
    });
    await _flureadium.play(null);
    final voices = await _flureadium.ttsGetAvailableVoices();
    if (!mounted) return;
    setState(() {
      _voices = voices;
      _voiceIndex = 0;
    });
  }

  Future<void> _ttsPause() async => _flureadium.pause();

  Future<void> _ttsResume() async => _flureadium.resume();

  Future<void> _installVoice() async => _flureadium.ttsRequestInstallVoice();

  Future<void> _showSystemVoices() async {
    final voices = await _flureadium.ttsGetSystemVoices();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('System voices: ${voices.length}')));
  }

  Future<void> _nextVoice() async {
    if (_voices.isEmpty) return;
    final next = (_voiceIndex + 1) % _voices.length;
    final voice = _voices[next];
    await _flureadium.ttsSetVoice(voice.identifier, voice.language);
    if (!mounted) return;
    setState(() => _voiceIndex = next);
  }

  Future<void> _toggleAudio() async {
    if (_audioEnabled && !_audioPaused) {
      await _flureadium.pause();
      if (!mounted) return;
      setState(() => _audioPaused = true);
    } else if (_audioEnabled && _audioPaused) {
      await _flureadium.resume();
      if (!mounted) return;
      setState(() => _audioPaused = false);
    } else {
      try {
        await _flureadium.audioEnable();
        await _flureadium.play(null);
        if (!mounted) return;
        setState(() {
          _audioEnabled = true;
          _audioPaused = false;
        });
      } catch (e) {
        debugPrint('audioEnable error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Audio playback unavailable: $e')));
        }
      }
    }
  }

  Future<void> _addHighlight() async {
    final loc = _locator;
    if (loc == null) return;
    await _flureadium.applyDecorations('highlights', [
      ReaderDecoration(
        id: 'h_${DateTime.now().millisecondsSinceEpoch}',
        locator: loc,
        style: ReaderDecorationStyle(style: DecorationStyle.highlight, tint: const Color(0xFFFFFF00)),
      ),
    ]);
  }

  Future<void> _goToSaved() async {
    final loc = _savedLocator;
    if (loc == null) return;
    await _flureadium.goToLocator(loc);
  }

  Future<void> _seekForward() => _flureadium.audioSeekBy(const Duration(seconds: 30));

  Future<void> _nextChapter() => _flureadium.next();

  Future<void> _previousChapter() => _flureadium.previous();

  Future<void> _goToFirstChapter() async {
    final pub = _publication;
    if (pub == null) return;
    final link = pub.tableOfContents.firstOrNull ?? pub.readingOrder.firstOrNull;
    if (link == null) return;
    await _flureadium.goByLink(link, pub);
  }

  Future<void> _openHierarchical() async {
    try {
      await _openPublicationAsset('assets/pubs/hierarchical_toc.epub');
    } catch (e) {
      debugPrint('openHierarchical error: $e');
    }
  }

  Future<void> _dartSkipToNext() async => FlureadiumPlatform.instance.currentReaderWidget?.skipToNext();

  Future<void> _dartSkipToPrevious() async => FlureadiumPlatform.instance.currentReaderWidget?.skipToPrevious();

  Future<void> _loadOnly() async {
    try {
      final path = await _extractAsset('assets/pubs/moby_dick.epub');
      final pub = await _flureadium.loadPublication(path);
      debugPrint('Loaded: ${pub.metadata.title} (${pub.tableOfContents.length} chapters)');
    } catch (e) {
      debugPrint('loadOnly error: $e');
    }
  }

  String _fmtDuration(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _closeDrawer() {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _runDrawerAction(FutureOr<void> Function() action) async {
    _closeDrawer();
    await action();
  }

  /// Debug lines shown in the drawer. When [keyed] is true, attach the Keys
  /// integration tests read — those copies live in an always-mounted Offstage
  /// because Scaffold builds [drawer] lazily on first open.
  List<Widget> _debugStatusLines({TextStyle? style, bool keyed = false}) {
    return [
      if (_timebasedState case final s?)
        Text(
          '${_fmtDuration(s.currentOffset)} / ${_fmtDuration(s.currentDuration)}',
          style: style,
        ),
      Text(
        key: keyed ? const Key('open-generation') : null,
        'open-generation: $_openGeneration',
        style: style,
      ),
      Text(
        key: keyed ? const Key('current-track') : null,
        'track: ${_timebasedState?.currentLocator?.locations?.position ?? '-'} '
        '${_timebasedState?.currentLocator?.href ?? ''}',
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Text(
        key: keyed ? const Key('timebased-state') : null,
        'state: ${_timebasedState?.state.name ?? '-'}',
        style: style,
      ),
      Text(
        key: keyed ? const Key('timebased-position') : null,
        'pos: ${_timebasedState?.currentOffset?.inMilliseconds ?? -1} '
        'dur: ${_timebasedState?.currentDuration?.inMilliseconds ?? -1}',
        style: style,
      ),
      Text(
        key: keyed ? const Key('ended-seen') : null,
        'ended-seen: $_endedSeen',
        style: style,
      ),
      Text(
        key: keyed ? const Key('audio-error') : null,
        'audio-error: $_lastAudioError',
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Text(
        key: keyed ? const Key('cancelled-stream-disconnect-seen') : null,
        'cancelled-stream-disconnect-seen: $_cancelledStreamDisconnectSeen',
        style: style,
      ),
      Text(
        key: keyed ? const Key('locator_href') : null,
        _locator?.href ?? '',
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pub = _publication;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final debugStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontFamily: 'monospace',
      fontSize: 11,
    );

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(title: const Text('Flureadium Example')),
      drawer: Drawer(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              Material(
                color: colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Controls', style: textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        'Open the menu to run example actions',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Debug status',
                      style: textTheme.titleSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._debugStatusLines(style: debugStyle),
                  ],
                ),
              ),
              const Divider(height: 1),
              const _DrawerSectionLabel('Publications'),
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('Open EPUB'),
                onTap: () => _runDrawerAction(_openEpub),
              ),
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('Open Hierarchical'),
                onTap: () => _runDrawerAction(_openHierarchical),
              ),
              ListTile(
                leading: const Icon(Icons.headphones_outlined),
                title: const Text('Open AudioBook'),
                onTap: () => _runDrawerAction(_openAudiobook),
              ),
              ListTile(
                leading: const Icon(Icons.title_outlined),
                title: const Text('Open AudioBook NoTitle'),
                onTap: () => _runDrawerAction(_openAudiobookUntitledChapter),
              ),
              ListTile(
                leading: const Icon(Icons.link_off_outlined),
                title: const Text('Open AudioBook BadUrl'),
                onTap: () => _runDrawerAction(_openUnreachableAudiobook),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_off_outlined),
                title: const Text('Open AudioBook BadStream'),
                onTap: () => _runDrawerAction(_openMidStreamFailAudiobook),
              ),
              ListTile(
                leading: const Icon(Icons.stream_outlined),
                title: const Text('Open AudioBook Streamed'),
                onTap: () => _runDrawerAction(_openStreamedAudiobook),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Open CBZ'),
                onTap: () => _runDrawerAction(_openCbz),
              ),
              ListTile(
                leading: const Icon(Icons.auto_stories_outlined),
                title: const Text('Open DIVINA'),
                onTap: () => _runDrawerAction(_openDivina),
              ),
              ListTile(
                leading: const Icon(Icons.language_outlined),
                title: const Text('Open WebPub'),
                onTap: () => _runDrawerAction(_openWebPub),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Load Only'),
                onTap: () => _runDrawerAction(_loadOnly),
              ),
              ListTile(
                leading: const Icon(Icons.close_outlined),
                title: const Text('Close'),
                onTap: () => _runDrawerAction(_close),
              ),
              const Divider(height: 1),
              const _DrawerSectionLabel('Navigation'),
              ListTile(
                leading: const Icon(Icons.chevron_left),
                title: const Text('←'),
                onTap: () => _runDrawerAction(_flureadium.goLeft),
              ),
              ListTile(
                leading: const Icon(Icons.chevron_right),
                title: const Text('→'),
                onTap: () => _runDrawerAction(_flureadium.goRight),
              ),
              ListTile(
                leading: const Icon(Icons.skip_previous_outlined),
                title: const Text('Skip Prev'),
                onTap: () => _runDrawerAction(_flureadium.skipToPrevious),
              ),
              ListTile(
                leading: const Icon(Icons.skip_next_outlined),
                title: const Text('Skip Next'),
                onTap: () => _runDrawerAction(_flureadium.skipToNext),
              ),
              ListTile(
                leading: const Icon(Icons.keyboard_double_arrow_left),
                title: const Text('DartSkip-'),
                onTap: () => _runDrawerAction(_dartSkipToPrevious),
              ),
              ListTile(
                leading: const Icon(Icons.keyboard_double_arrow_right),
                title: const Text('DartSkip+'),
                onTap: () => _runDrawerAction(_dartSkipToNext),
              ),
              if (pub != null)
                ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: const Text('Go To Saved'),
                  onTap: () => _runDrawerAction(_goToSaved),
                ),
              if (pub != null)
                ListTile(
                  leading: const Icon(Icons.looks_one_outlined),
                  title: const Text('Ch.1'),
                  onTap: () => _runDrawerAction(_goToFirstChapter),
                ),
              const Divider(height: 1),
              const _DrawerSectionLabel('EPUB Preferences'),
              ListTile(
                leading: const Icon(Icons.dark_mode_outlined),
                title: const Text('Night'),
                subtitle: const Text('Apply dark theme preferences'),
                onTap: () => _runDrawerAction(_setNightPreferences),
              ),
              ListTile(
                leading: const Icon(Icons.format_line_spacing_outlined),
                title: Text(
                  'Line Height '
                  '${_lineHeightPresets[_lineHeightIndex]}',
                ),
                subtitle: const Text('Cycle 1.0 → 1.5 → 2.0 on current book'),
                onTap: () => _runDrawerAction(_cycleLineHeight),
              ),
              ListTile(
                leading: const Icon(Icons.tune_outlined),
                title: const Text('Prefs Demo'),
                subtitle: const Text(
                  'lineHeight, columns, publisherStyles, fonts',
                ),
                onTap: () => _runDrawerAction(_openPreferencesDemo),
              ),
              const Divider(height: 1),
              const _DrawerSectionLabel('Annotations'),
              ListTile(
                leading: const Icon(Icons.highlight_outlined),
                title: const Text('Highlight'),
                onTap: () => _runDrawerAction(_addHighlight),
              ),
              const Divider(height: 1),
              const _DrawerSectionLabel('Text-to-speech'),
              ListTile(
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('OS TTS'),
                onTap: () => _runDrawerAction(_showSystemVoices),
              ),
              ListTile(
                leading: Icon(_ttsEnabled ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                title: Text(_ttsEnabled ? 'TTS Off' : 'TTS On'),
                onTap: () => _runDrawerAction(_toggleTts),
              ),
              if (_ttsEnabled && _ttsPlaybackState != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'TTS: ${_ttsPlaybackState!.name}',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_ttsEnabled && _ttsPlaybackState == TimebasedState.playing)
                ListTile(
                  leading: const Icon(Icons.pause_outlined),
                  title: const Text('Pause TTS'),
                  onTap: () => _runDrawerAction(_ttsPause),
                ),
              if (_ttsEnabled && _ttsPlaybackState == TimebasedState.paused)
                ListTile(
                  leading: const Icon(Icons.play_arrow_outlined),
                  title: const Text('Resume TTS'),
                  onTap: () => _runDrawerAction(_ttsResume),
                ),
              if (_ttsErrorType == TtsErrorType.languageMissingData)
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Install Voice'),
                  onTap: () => _runDrawerAction(_installVoice),
                ),
              if (_ttsEnabled && _voices.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.voice_chat_outlined),
                  title: Text('Voice ${_voiceIndex + 1}/${_voices.length}'),
                  onTap: () => _runDrawerAction(_nextVoice),
                ),
              if (_ttsEnabled) ...[
                ListTile(
                  leading: const Icon(Icons.keyboard_arrow_up),
                  title: const Text('Prev Sentence'),
                  onTap: () => _runDrawerAction(_flureadium.previous),
                ),
                ListTile(
                  leading: const Icon(Icons.keyboard_arrow_down),
                  title: const Text('Next Sentence'),
                  onTap: () => _runDrawerAction(_flureadium.next),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Speed ${_ttsSpeed.toStringAsFixed(1)}x', style: textTheme.labelLarge),
                      Slider(
                        value: _ttsSpeed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 6,
                        label: '${_ttsSpeed}x',
                        onChanged: (value) async {
                          setState(() => _ttsSpeed = value);
                          if (_ttsEnabled) {
                            await _flureadium.ttsSetPreferences(TTSPreferences(speed: value));
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
              const Divider(height: 1),
              const _DrawerSectionLabel('Audio'),
              ListTile(
                leading: Icon(
                  !_audioEnabled
                      ? Icons.play_arrow_outlined
                      : _audioPaused
                      ? Icons.play_arrow_outlined
                      : Icons.pause_outlined,
                ),
                title: Text(
                  !_audioEnabled
                      ? 'Audio Play'
                      : _audioPaused
                      ? 'Audio Resume'
                      : 'Audio Pause',
                ),
                onTap: () => _runDrawerAction(_toggleAudio),
              ),
              if (_audioEnabled)
                ListTile(
                  leading: const Icon(Icons.forward_30_outlined),
                  title: const Text('+30s'),
                  onTap: () => _runDrawerAction(_seekForward),
                ),
              if (_audioEnabled)
                ListTile(
                  leading: const Icon(Icons.skip_previous_outlined),
                  title: const Text('Audio Prev Chapter'),
                  onTap: () => _runDrawerAction(_previousChapter),
                ),
              if (_audioEnabled)
                ListTile(
                  leading: const Icon(Icons.skip_next_outlined),
                  title: const Text('Audio Next Chapter'),
                  onTap: () => _runDrawerAction(_nextChapter),
                ),
              const SizedBox(height: 24),
            ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Always mounted so integration/widget tests can read status Keys
          // before the drawer has been opened (Scaffold builds it lazily).
          // Avoid Offstage: find.byKey skips offstage widgets by default.
          Opacity(
            opacity: 0,
            child: IgnorePointer(
              child: Column(children: _debugStatusLines(keyed: true)),
            ),
          ),
          if (pub != null)
            ReadiumReaderWidget(
              publication: pub,
              onTap: () {
                final scaffold = _scaffoldKey.currentState;
                if (scaffold?.isDrawerOpen ?? false) {
                  scaffold?.closeDrawer();
                  setState(() => _controlsVisible = false);
                } else {
                  setState(() => _controlsVisible = !_controlsVisible);
                  if (_controlsVisible) {
                    scaffold?.openDrawer();
                  }
                }
              },
              onReady: _subscribeToChannels,
            )
          else
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

/// Section header used inside the example [Drawer].
class _DrawerSectionLabel extends StatelessWidget {
  const _DrawerSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

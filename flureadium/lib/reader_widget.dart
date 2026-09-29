import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flureadium_platform_interface/flureadium_platform_interface.dart';
import 'package:rxdart/rxdart.dart';

import 'reader_channel.dart';
import 'src/reader/orientation_handler_mixin.dart';
import 'src/reader/reader_lifecycle_mixin.dart';
import 'src/reader/wakelock_manager_mixin.dart';
import 'src/utils/navigation_helper.dart';
import 'src/utils/toc_matcher.dart';

const _viewType = 'dev.mulev.flureadium/ReadiumReaderWidget';

@visibleForTesting
ReadiumReaderChannel createReadiumReaderChannel(
  int id, {
  required ValueChanged<Locator> onPageChanged,
  ValueChanged<String>? onExternalLinkActivated,
  void Function(String, Locator)? onSelectionAction,
  void Function(String, Locator)? onDecorationTapped,
}) {
  return ReadiumReaderChannel(
    '$_viewType:$id',
    onPageChanged: onPageChanged,
    onExternalLinkActivated: onExternalLinkActivated,
    onSelectionAction: onSelectionAction,
    onDecorationTapped: onDecorationTapped,
  );
}

/// A ReadiumReaderWidget wraps a native Kotlin/Swift Readium navigator widget.
class ReadiumReaderWidget extends StatefulWidget {
  const ReadiumReaderWidget({
    required this.publication,
    this.loadingWidget = const Center(child: CircularProgressIndicator()),
    this.initialLocator,
    this.onTap,
    this.onGoLeft,
    this.onGoRight,
    this.onSwipe,
    this.onExternalLinkActivated,
    this.onSelectionAction,
    this.onDecorationTapped,
    this.onLocatorChanged,
    this.onReady,
    super.key,
  });

  final Publication publication;
  final Widget loadingWidget;
  final Locator? initialLocator;
  final VoidCallback? onTap;
  final VoidCallback? onGoLeft;
  final VoidCallback? onGoRight;
  final VoidCallback? onSwipe;
  final Function(String)? onExternalLinkActivated;
  final void Function(String, Locator)? onSelectionAction;
  final void Function(String, Locator)? onDecorationTapped;
  final void Function(Locator)? onLocatorChanged;

  /// Called once when the native platform view has been created and all
  /// EventChannel handlers are registered. Safe to subscribe to
  /// [Flureadium.onReaderStatusChanged], [Flureadium.onTextLocatorChanged],
  /// and [Flureadium.onErrorEvent] from within this callback on all platforms.
  final VoidCallback? onReady;

  @override
  State<StatefulWidget> createState() => _ReadiumReaderWidgetState();
}

class _ReadiumReaderWidgetState extends State<ReadiumReaderWidget>
    with WakelockManagerMixin, ReaderLifecycleMixin, OrientationHandlerMixin
    implements ReadiumReaderWidgetInterface, ReadiumReaderSelectionInterface {
  ReadiumReaderChannel? _channel;
  StreamSubscription<Locator>? _locatorDebugSub;
  bool wasDestroyed = false;
  bool isReady = false;

  final _isReadyCompleter = Completer<Locator>();

  late Widget _readerWidget;

  EPUBPreferences? get _defaultPreferences {
    return readium.defaultPreferences;
  }

  PDFPreferences? get _defaultPdfPreferences {
    return readium.defaultPdfPreferences;
  }

  @override
  void initState() {
    super.initState();
    R2Log.d('ReadiumReaderWidget initiated');

    _readerWidget = _buildNativeReader();
    enableWakelock();
    // setCurrentWidgetInterface is called in _onPlatformViewCreated after
    // _channel is assigned, so that callers receive a widget whose channel
    // is ready to send method calls.
  }

  @override
  void dispose() {
    R2Log.d('ReadiumReaderWidget disposed');
    _locatorDebugSub?.cancel();
    _locatorDebugSub = null;
    cleanupWidgetInterface(_channel?.name);
    _channel?.dispose();
    _channel = null;
    lastOrientation = null;

    disableWakelock();
    wasDestroyed = true;

    super.dispose();
  }

  @override
  Widget build(final BuildContext context) {
    handleOrientationChange(
      currentOrientation: MediaQuery.orientationOf(context),
      isReady: isReady,
      currentLocator: _currentLocator,
      channel: _channel,
    );

    return Listener(
      onPointerDown: (final event) {
        R2Log.d('[TAP-DEBUG] Listener onPointerDown at ${event.position}');
        enableWakelock();
      },
      onPointerUp: (final event) {
        R2Log.d('[TAP-DEBUG] Listener onPointerUp at ${event.position}');
      },
      child: _readerWidget,
    );
  }

  @override
  Future<void> go(
    final Locator locator, {
    required final bool isAudioBookWithText,
    final bool animated = false,
  }) async {
    R2Log.d(() => 'Go to $locator');

    await _channel?.go(
      locator,
      animated: animated,
      isAudioBookWithText: isAudioBookWithText,
    );

    R2Log.d('Done');
  }

  @override
  Future<void> goLeft({final bool animated = true}) async =>
      _channel?.goLeft(animated: animated);

  @override
  Future<void> goRight({final bool animated = true}) async =>
      _channel?.goRight(animated: animated);

  @override
  Future<void> skipToNext({final bool animated = true}) async {
    final toc = flattenToc(widget.publication.toc);
    if (toc.isEmpty || _currentLocator == null) {
      R2Log.d('skipToNext: no TOC or no current locator');
      return;
    }

    int curIndex = -1;

    // Priority 1: stored index from last chapter navigation
    if (_lastNavigatedTocIndex != null &&
        _lastNavigatedTocIndex! < toc.length) {
      final expectedPath = normalizePath(toc[_lastNavigatedTocIndex!].hrefPart);
      final currentPath = normalizePath(_currentLocator!.hrefPath);
      if (currentPath == expectedPath) {
        curIndex = _lastNavigatedTocIndex!;
        R2Log.d('skipToNext: using stored index $curIndex');
      } else {
        R2Log.d('skipToNext: stored index invalid (file changed)');
        _lastNavigatedTocIndex = null;
      }
    }

    // Priority 2: toc= fragment matching (sub-chapter granularity)
    if (curIndex == -1) {
      final currentHref = getTextLocatorHrefWithTocFragment(_currentLocator);
      if (currentHref != null) {
        curIndex = toc.indexWhere((l) => l.href == currentHref);
      }
    }

    // Priority 3: path-based fallback (file-level granularity)
    if (curIndex == -1) {
      R2Log.d('skipToNext: toc= fragment matching failed, using fallback');
      // Check if this is a PDF (page-based matching)
      if (isPdfToc(toc)) {
        curIndex = findTocIndexByPage(_currentLocator!, toc);
        R2Log.d('skipToNext: PDF page matching returned index $curIndex');
      } else {
        curIndex = findTocIndexByPath(_currentLocator!, toc, lastMatch: true);
      }
    }

    R2Log.d('skipToNext: curIndex=$curIndex, tocLength=${toc.length}');

    // Use navigation helper to decide where to navigate
    final decision = decideSkipToNext(
      currentLocator: _currentLocator!,
      toc: toc,
      readingOrder: widget.publication.readingOrder,
      currentTocIndex: curIndex,
      publication: widget.publication,
    );

    if (!decision.canNavigate) {
      R2Log.d('skipToNext: ${decision.reason}');
      return;
    }

    // Navigate to the target
    final targetLocator = widget.publication.locatorFromLink(
      decision.targetLink!,
    );
    if (targetLocator != null) {
      R2Log.d('skipToNext: navigating to ${decision.targetLink!.href}');
      await _channel?.go(
        targetLocator,
        isAudioBookWithText: false,
        animated: true,
      );
      _lastNavigatedTocIndex = decision.targetTocIndex;
    }
  }

  @override
  Future<void> skipToPrevious({final bool animated = true}) async {
    final toc = flattenToc(widget.publication.toc);
    if (toc.isEmpty || _currentLocator == null) {
      R2Log.d('skipToPrevious: no TOC or no current locator');
      return;
    }

    int curIndex = -1;

    // Priority 1: stored index from last chapter navigation
    if (_lastNavigatedTocIndex != null &&
        _lastNavigatedTocIndex! < toc.length) {
      final expectedPath = normalizePath(toc[_lastNavigatedTocIndex!].hrefPart);
      final currentPath = normalizePath(_currentLocator!.hrefPath);
      if (currentPath == expectedPath) {
        curIndex = _lastNavigatedTocIndex!;
        R2Log.d('skipToPrevious: using stored index $curIndex');
      } else {
        R2Log.d('skipToPrevious: stored index invalid (file changed)');
        _lastNavigatedTocIndex = null;
      }
    }

    // Priority 2: toc= fragment matching (sub-chapter granularity)
    if (curIndex == -1) {
      final currentHref = getTextLocatorHrefWithTocFragment(_currentLocator);
      if (currentHref != null) {
        curIndex = toc.indexWhere((l) => l.href == currentHref);
      }
    }

    // Priority 3: path-based fallback (file-level granularity)
    if (curIndex == -1) {
      R2Log.d('skipToPrevious: toc= fragment matching failed, using fallback');
      // Check if this is a PDF (page-based matching)
      if (isPdfToc(toc)) {
        curIndex = findTocIndexByPage(_currentLocator!, toc);
        R2Log.d('skipToPrevious: PDF page matching returned index $curIndex');
      } else {
        curIndex = findTocIndexByPath(_currentLocator!, toc, lastMatch: false);
      }
    }

    R2Log.d('skipToPrevious: curIndex=$curIndex, tocLength=${toc.length}');

    // Use navigation helper to decide where to navigate
    final decision = decideSkipToPrevious(
      currentLocator: _currentLocator!,
      toc: toc,
      readingOrder: widget.publication.readingOrder,
      currentTocIndex: curIndex,
      publication: widget.publication,
    );

    if (!decision.canNavigate) {
      R2Log.d('skipToPrevious: ${decision.reason}');
      return;
    }

    // Navigate to the target
    final targetLocator = widget.publication.locatorFromLink(
      decision.targetLink!,
    );
    if (targetLocator != null) {
      R2Log.d('skipToPrevious: navigating to ${decision.targetLink!.href}');
      await _channel?.go(
        targetLocator,
        isAudioBookWithText: false,
        animated: true,
      );
      _lastNavigatedTocIndex = decision.targetTocIndex;
    }
  }

  @override
  Future<Locator?> getLocatorFragments(final Locator locator) async {
    R2Log.d('getLocatorFragments: $locator');

    await _awaitNativeViewReady();

    return await _channel?.getLocatorFragments(locator);
  }

  @override
  Future<Locator?> getCurrentLocator() async {
    R2Log.d('GetCurrentLocator()');
    return _channel?.getCurrentLocator();
  }

  @override
  Future<Locator?> getCurrentSelection() async {
    await _awaitNativeViewReady();
    return _channel?.getCurrentSelection();
  }

  @override
  Future<void> setEPUBPreferences(EPUBPreferences preferences) async {
    _channel?.setEPUBPreferences(preferences);
  }

  @override
  Future<void> setPDFPreferences(PDFPreferences preferences) async {
    _channel?.setPDFPreferences(preferences);
  }

  @override
  Future<void> setNavigationConfig(ReaderNavigationConfig config) async {
    _channel?.setNavigationConfig(config);
  }

  @override
  Future<void> applyDecorations(
    String id,
    List<ReaderDecoration> decorations,
  ) async {
    await _channel?.applyDecorations(id, decorations);
  }

  @override
  Future<void> selectLocator(Locator locator) async {
    await _channel?.selectLocator(locator);
  }

  @override
  Future<void> clearSelection() async {
    await _channel?.clearSelection();
  }

  Widget _buildNativeReader() {
    final publication = widget.publication;

    R2Log.d(publication.identifier);

    // Check if this is a PDF publication by looking at reading order media types
    final isPdf = publication.readingOrder.any(
      (link) => link.type?.contains('pdf') ?? false,
    );

    // Use PDF preferences for PDF publications, EPUB preferences for others
    final defaultPreferences = isPdf
        ? _defaultPdfPreferences?.toJson()
        : _defaultPreferences?.toJson();

    final creationParams = <String, dynamic>{
      'pubIdentifier': publication.identifier,
      'preferences': defaultPreferences,
      'initialLocator': widget.initialLocator == null
          ? null
          : json.encode(widget.initialLocator),
    };

    R2Log.d('creationParams=$creationParams');

    if (Platform.isAndroid) {
      return PlatformViewLink(
        viewType: _viewType,
        surfaceFactory: (final context, final controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const {},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
        onCreatePlatformView: (final params) =>
            PlatformViewsService.initSurfaceAndroidView(
                id: params.id,
                viewType: _viewType,
                layoutDirection: TextDirection.ltr,
                creationParams: creationParams,
                creationParamsCodec: const StandardMessageCodec(),
              )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
              ..create(),
      );
    } else if (Platform.isIOS) {
      return UiKitView(
        viewType: _viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    return ColoredBox(
      color: const Color(0xffff00ff),
      child: Center(
        child: Text(
          'TODO — Implement ReadiumReaderWidget on ${Platform.operatingSystem}.',
        ),
      ),
    );
  }

  Locator? _currentLocator;

  /// Tracks the last TOC index navigated to via skipToNext/skipToPrevious.
  /// Used as highest-priority source for determining current position,
  /// since the JS-reported toc= heading may differ from the navigation target.
  int? _lastNavigatedTocIndex;

  void _onPlatformViewCreated(final int id) {
    _channel = createReadiumReaderChannel(
      id,
      onPageChanged: (final locator) {
        debugPrint('onPageChanged: ${locator.toJson()}');
        _currentLocator = locator;
        widget.onLocatorChanged?.call(locator);

        if (isReady == false) {
          if (mounted) {
            setState(() {
              isReady = true;
            });
          }
          if (!_isReadyCompleter.isCompleted) {
            _isReadyCompleter.complete(locator);
          }
        }
      },
      onExternalLinkActivated: widget.onExternalLinkActivated,
      onSelectionAction: widget.onSelectionAction,
      onDecorationTapped: widget.onDecorationTapped,
    );

    // Register as current widget only after _channel is assigned.
    // This ensures waitForCurrentReaderWidget() callers receive a widget
    // whose channel is ready, so method calls aren't silently dropped.
    setCurrentWidgetInterface(this);

    // Notify the host widget that the platform view (and all native
    // EventChannel handlers) are ready. Safe to call listen() on
    // onReaderStatusChanged / onTextLocatorChanged / onErrorEvent from here.
    widget.onReady?.call();

    R2Log.d('New widget is: ${_channel?.name}');

    // TODO: This is just to demo how to use and debounce the Stream, remove when appropriate.
    final nativeLocatorStream = readium.onTextLocatorChanged
        .debounceTime(const Duration(milliseconds: 50))
        .asBroadcastStream()
        .distinct();

    _locatorDebugSub?.cancel();
    _locatorDebugSub = nativeLocatorStream.listen((locator) {
      R2Log.d('ReaderWidget.LocatorChanged - $locator');
    });
  }

  Future _awaitNativeViewReady() {
    return _isReadyCompleter.future;
  }

  /// Gets a Locator's href with toc fragment appended as identifier
  String? getTextLocatorHrefWithTocFragment(Locator? locator) {
    if (locator == null) {
      return null;
    }

    final txtLoc = locator.toTextLocator();
    final tocFragment = locator.locations?.fragments.firstWhereOrNull(
      (f) => f.startsWith("toc="),
    );
    if (tocFragment == null) {
      return null;
    }
    return '${txtLoc.toTextLocator().hrefPath}#${tocFragment.substring(4)}';
  }
}

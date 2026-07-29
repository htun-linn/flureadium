# Flureadium Example

A minimal single-screen Flutter app that exercises all flureadium plugin capabilities. Suitable for build verification and integration tests on Android, iOS, and Web.

## Structure

```
lib/
├── main.dart                  # ExampleApp + ReaderPage (integration-test host)
├── epub_preferences_demo.dart # Dedicated screen for lineHeight / publisherStyles / optional fontFamily
└── audio_stream_fixtures.dart # Local HTTP fixtures for audiobook stream tests
integration_test/
├── launch_test.dart        # App launches without crash
├── epub_test.dart          # Open EPUB, navigate, preferences, highlight, close
├── epub_tts_test.dart      # TTS enable/disable, voice cycling, position restore
├── epub_tts_web_test.dart  # Web Speech API TTS tests
├── audiobook_test.dart     # Open audiobook, play/pause (native only)
├── cbz_test.dart           # Open CBZ, navigate, goToLocator, extract thumbnails
├── divina_test.dart        # Open DIVINA and navigate image-based pages
└── webpub_test.dart        # Open remote WebPub manifest
test/
└── widget_test.dart    # Widget smoke test
```

The app auto-opens `moby_dick.epub` on launch. A control panel at the bottom lets you switch publication types, navigate, adjust preferences, control TTS and audio, and add highlights. Tap the reader to toggle the panel.

Example actions live in the navigation drawer, grouped as **Publications**, **Navigation**, **EPUB Preferences**, **Annotations**, **Text-to-speech**, and **Audio**.

Tap **Prefs Demo** (drawer → **EPUB Preferences**) for a Material 3 reader with a draggable settings sheet. It loads an online sample EPUB (default: IDPF [Accessible EPUB 3](https://github.com/IDPF/epub3-samples); also Moby Dick WebPub and Les Diaboliques) and lets you live-tune `lineHeight`, `publisherStyles`, and optional `fontFamily` (publisher fonts vs custom override).

## Running the Example

```bash
cd flureadium/example
flutter run
```

## Running Integration Tests

```bash
# Android
flutter test integration_test/ -d <android_device_id>

# iOS
flutter test integration_test/ -d <ios_device_id>
```

> **Note:** `audiobook_test.dart` is tagged `native` and should be skipped on Web.

## Features Demonstrated

### Opening Publications

```dart
// From local file
final pub = await flureadium.openPublication('file:///path/to/book.epub');

// From URL with authentication
await flureadium.setCustomHeaders({'Authorization': 'Bearer token'});
final pub = await flureadium.openPublication('https://example.com/book.epub');
```

### Visual Reading

```dart
// Customize appearance — keep publisher fonts, adjust line height
await flureadium.setEPUBPreferences(EPUBPreferences(
  // fontFamily omitted → keep the EPUB's own fonts
  fontSize: 120,  // 1.2em
  fontWeight: null,
  verticalScroll: false,
  backgroundColor: Color(0xFFF5E6D3),  // Sepia
  textColor: Color(0xFF5C4033),
  pageMargins: 0.1,  // 10% margins
  lineHeight: 1.5,
  publisherStyles: false,  // required for lineHeight to take effect
));

// Or open the in-app Preferences Demo screen (online sample EPUB):
// tap "Prefs Demo" in the control panel.
```

```dart
// Navigate
await flureadium.goLeft();
await flureadium.goRight();
await flureadium.goToLocator(savedLocator);

// Jump to TOC entry
await flureadium.goByLink(tocLink, publication);
```

### Image-Based Publications

```dart
// Open a bundled CBZ or DIVINA file
final comic = await flureadium.openPublication('file:///path/to/comic.cbz');

// Same widget and navigation API as EPUB/PDF
ReadiumReaderWidget(publication: comic);
await flureadium.goRight();
await flureadium.goToLocator(
  const Locator(href: '003.jpg', type: 'image/jpeg'),
);

// Build page preview UI from an image resource in the open publication
final thumbnail = await flureadium.extractPageThumbnail('001.jpg', 80, 70);
```

### Text-to-Speech

```dart
// Check TTS availability before enabling
final canSpeak = await flureadium.ttsCanSpeak();
if (!canSpeak) {
  // TTS engine cannot speak the publication's language
  return;
}

// Get available voices (filtered to publication language)
final voices = await flureadium.ttsGetAvailableVoices();

// Get all system voices (all languages)
final systemVoices = await flureadium.ttsGetSystemVoices();

// Enable TTS with preferences
await flureadium.ttsEnable(TTSPreferences(
  rate: 1.2,   // 20% faster
  pitch: 1.0,  // Normal pitch
));

// Select voice
await flureadium.ttsSetVoice(voices.first.id, 'en-US');

// Control playback
await flureadium.play(null);
await flureadium.pause();
await flureadium.next();  // Skip to next sentence

// Resume from a saved position after disabling/re-enabling TTS
await flureadium.ttsEnable(
  TTSPreferences(rate: 1.2),
  fromLocator: savedLocator,
);

// Open platform voice installer when language data is missing
await flureadium.ttsRequestInstallVoice();
```

### Audiobook Playback

```dart
// Enable audio navigator
await flureadium.audioEnable(
  prefs: AudioPreferences(playbackRate: 1.0),
  fromLocator: savedPosition,
);

// Control playback
await flureadium.play(null);
await flureadium.audioSeekBy(Duration(seconds: 30));  // Skip forward

// Listen for position updates
flureadium.onTimebasedPlayerStateChanged.listen((state) {
  print('Position: ${state.currentOffset}');
  print('Duration: ${state.currentDuration}');
});
```

### Highlighting

```dart
// Add a highlight
await flureadium.applyDecorations('highlights', [
  ReaderDecoration(
    id: 'highlight-1',
    locator: selectedLocator,
    style: DecorationStyle.highlight,
  ),
]);

// Add a bookmark
await flureadium.applyDecorations('bookmarks', [
  ReaderDecoration(
    id: 'bookmark-1',
    locator: currentLocator,
    style: DecorationStyle.underline,
  ),
]);
```

### Saving Reading Position

```dart
// Listen for position changes
flureadium.onTextLocatorChanged.listen((locator) {
  // Save to persistent storage
  prefs.setString('lastPosition', jsonEncode(locator.toJson()));
});

// Restore position on next launch
final savedJson = prefs.getString('lastPosition');
if (savedJson != null) {
  final locator = Locator.fromJson(jsonDecode(savedJson));
  await flureadium.goToLocator(locator);
}
```

## Button-to-API Reference

| Button | API method | Notes |
|---|---|---|
| Open EPUB | `openPublication` | Extracts bundled asset to temp; auto-opens on launch |
| Open CBZ | `openPublication` | Bundled `.cbz` image-based comic |
| Open DIVINA | `openPublication` | Bundled `.divina` visual narrative |
| Open AudioBook | `openPublication` | Bundled `.audiobook` file |
| Open WebPub | `openPublication` + `setCustomHeaders` | Remote manifest; sets `X-Example` header first |
| Load Only | `loadPublication` | Loads metadata without showing in reader; prints title to debug |
| Close | `closePublication` | |
| ← / → | `goLeft` / `goRight` | Page navigation |
| Skip Prev / Skip Next | `skipToPrevious` / `skipToNext` | Chapter skip |
| Go To Saved | `goToLocator` | Navigates to last auto-saved locator |
| Ch.1 | `goByLink` | First TOC entry or first readingOrder link |
| Night | `setEPUBPreferences` | Dark background, light text, Georgia font |
| Highlight | `applyDecorations` | Yellow highlight at current locator |
| TTS On / TTS Off | `ttsCanSpeak` + `ttsEnable` + `play` / `stop` + `ttsGetAvailableVoices` | Checks availability, fetches voices on enable |
| Voice N/Total | `ttsSetVoice` | Cycles available voices (visible when TTS active and voices available) |
| OS TTS | `ttsGetSystemVoices` | Shows all system voices in a dialog (visible when TTS active) |
| Install Voice | `ttsRequestInstallVoice` | Opens platform voice installer (visible on `languageMissingData` error) |
| Prev Sentence / Next Sentence | `previous` / `next` | Sentence-level TTS navigation (visible when TTS active) |
| Audio Play / Audio Pause / Audio Resume | `audioEnable` + `play` / `pause` / `resume` | Three-state toggle |
| +30s | `audioSeekBy` | Seek forward 30 s (visible when audio active) |
| Position display | `onTimebasedPlayerStateChanged` | MM:SS / MM:SS shown during audio or TTS |

### Intentionally Omitted Methods

The following public API methods are not given dedicated buttons because they are configuration variants, PDF-specific, or would clutter the minimal UI without teaching anything new:

| Method | Reason omitted |
|---|---|
| `setNavigationConfig` | Configuration variant; no behavioral difference visible in tests |
| `ttsSetPreferences` | Configuration variant of `ttsEnable` |
| `setDecorationStyle` | TTS highlight style config; covered conceptually by `applyDecorations` |
| `audioSetPreferences` | Configuration variant of `audioEnable` |
| `toPhysicalPageIndex` | Convenience wrapper around `goByLink`; same code path |
| `setDefaultPreferences` | App-level config set before opening; not interactive |
| `setDefaultPdfPreferences` | PDF-specific; no PDF asset bundled |
| `renderFirstPage` | PDF-specific; no PDF asset bundled |
| `extractPageThumbnail` | Covered by CBZ integration tests; no dedicated UI control |

## Platform-Specific Setup

See the main [README](../README.md) for platform setup instructions.

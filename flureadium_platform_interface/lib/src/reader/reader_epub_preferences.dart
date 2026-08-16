// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:ui' show Color;

import '../index.dart';

/// Number of text columns for **reflowable** EPUB pagination.
///
/// Only applies when [EPUBPreferences.verticalScroll] is `false`. Ignored for
/// fixed-layout publications (use [EPUBSpread] for those).
enum EPUBColumnCount {
  /// Let Readium choose based on viewport width (often two columns on tablets).
  auto,

  /// Force a single column.
  one,

  /// Force two columns.
  two;

  /// Wire value sent to native Readium (`"auto"` / `"1"` / `"2"`).
  String get wireValue => switch (this) {
        EPUBColumnCount.auto => 'auto',
        EPUBColumnCount.one => '1',
        EPUBColumnCount.two => '2',
      };

  static EPUBColumnCount? fromWireValue(String value) => switch (value) {
        'auto' => EPUBColumnCount.auto,
        '1' => EPUBColumnCount.one,
        '2' => EPUBColumnCount.two,
        _ => null,
      };
}

/// Synthetic dual-page spreads for **fixed-layout** EPUB pagination.
///
/// For reflowable EPUBs, prefer [EPUBColumnCount].
enum EPUBSpread {
  /// Spread when the viewport is wide enough.
  auto,

  /// Never show two pages side-by-side.
  never,

  /// Always show two pages side-by-side.
  always;

  /// Wire value sent to native Readium (`"auto"` / `"never"` / `"always"`).
  String get wireValue => name;

  static EPUBSpread? fromWireValue(String value) => switch (value) {
        'auto' => EPUBSpread.auto,
        'never' => EPUBSpread.never,
        'always' => EPUBSpread.always,
        _ => null,
      };
}

/// Body text alignment for **reflowable** EPUBs.
///
/// Only takes effect when [EPUBPreferences.publisherStyles] is `false`.
/// Headings that the publication centers usually stay centered; this mainly
/// drives paragraph / list alignment (justify vs left).
enum EPUBTextAlign {
  start,
  left,
  right,
  justify,
  center,
  end;

  /// Wire value sent to native Readium (`"left"` / `"justify"` / …).
  String get wireValue => name;

  static EPUBTextAlign? fromWireValue(String value) => switch (value) {
        'start' => EPUBTextAlign.start,
        'left' => EPUBTextAlign.left,
        'right' => EPUBTextAlign.right,
        'justify' => EPUBTextAlign.justify,
        'center' => EPUBTextAlign.center,
        'end' => EPUBTextAlign.end,
        _ => null,
      };
}

class EPUBPreferences {
  EPUBPreferences({
    this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.verticalScroll,
    required this.backgroundColor,
    required this.textColor,
    this.pageMargins,
    this.lineHeight,
    this.publisherStyles,
    this.columnCount,
    this.spread,
    this.textAlign,
  });

  factory EPUBPreferences.fromJsonMap(final Map<String, dynamic> map) =>
      EPUBPreferences(
        fontFamily: map['fontFamily'] as String?,
        fontSize: map['fontSize'] as int,
        fontWeight: map['fontWeight'] as double,
        verticalScroll: map['verticalScroll'] as bool,
        backgroundColor: map['tint'] is int ? Color(map['tint'] as int) : null,
        textColor: map['tint'] is int ? Color(map['tint'] as int) : null,
        columnCount: map['columnCount'] is String
            ? EPUBColumnCount.fromWireValue(map['columnCount'] as String)
            : null,
        spread: map['spread'] is String
            ? EPUBSpread.fromWireValue(map['spread'] as String)
            : null,
        textAlign: map['textAlign'] is String
            ? EPUBTextAlign.fromWireValue(map['textAlign'] as String)
            : null,
      );

  /// Typeface override. When `null` (or omitted from [toJson]), Readium keeps
  /// the publication's own / publisher fonts. Independent of [publisherStyles].
  String? fontFamily;
  int fontSize;
  double? fontWeight;
  bool? verticalScroll;
  Color? backgroundColor;
  Color? textColor;
  double? pageMargins;

  /// Leading line height, e.g. `1.5`. Only effective for reflowable
  /// publications, and only when [publisherStyles] is set to `false`.
  double? lineHeight;

  /// Whether the original publisher styles should be observed. Several
  /// advanced typography preferences — including [lineHeight] — require
  /// this to be explicitly set to `false` to take effect.
  ///
  /// This does **not** force a custom typeface: omit [fontFamily] (leave it
  /// `null`) to keep the EPUB's default fonts while still adjusting
  /// [lineHeight].
  bool? publisherStyles;

  /// Column layout for reflowable paginated EPUBs.
  ///
  /// When `null`, [toJson] emits [EPUBColumnCount.one] so tablets do not
  /// automatically switch to two columns. Set [EPUBColumnCount.auto] to restore
  /// Readium's viewport-based behaviour, or [EPUBColumnCount.two] for dual
  /// columns.
  EPUBColumnCount? columnCount;

  /// Dual-page spreads for fixed-layout paginated EPUBs.
  ///
  /// When `null`, [toJson] emits [EPUBSpread.never] so wide screens stay on a
  /// single page. Set [EPUBSpread.auto] or [EPUBSpread.always] for dual-page.
  EPUBSpread? spread;

  /// Paragraph alignment for reflowable EPUBs (`left`, `justify`, …).
  ///
  /// When `null`, [toJson] omits the key and Readium keeps its default
  /// (often justify). Requires [publisherStyles] `false` to apply.
  EPUBTextAlign? textAlign;

  // TODO: Add more preferences,
  //see https://github.com/readium/swift-toolkit/blob/develop/Sources/Navigator/EPUB/Preferences/EPUBPreferences.swift

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'fontSize': '${fontSize / 100}',
      'fontWeight': fontWeight.toString(),
      'verticalScroll': verticalScroll.toString(),
      'backgroundColor': backgroundColor.toCSS(),
      'textColor': textColor.toCSS(),
      // Default to single-column / no-spread so tablets do not auto-dual.
      'columnCount': (columnCount ?? EPUBColumnCount.one).wireValue,
      'spread': (spread ?? EPUBSpread.never).wireValue,
    };
    if (fontFamily != null) {
      map['fontFamily'] = fontFamily;
    }
    if (pageMargins != null) {
      map['pageMargins'] = pageMargins.toString();
    }
    if (lineHeight != null) {
      map['lineHeight'] = lineHeight.toString();
    }
    if (publisherStyles != null) {
      map['publisherStyles'] = publisherStyles.toString();
    }
    if (textAlign != null) {
      map['textAlign'] = textAlign!.wireValue;
    }
    return map;
  }
}

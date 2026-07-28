// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:ui' show Color;

import '../index.dart';

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
  });

  factory EPUBPreferences.fromJsonMap(final Map<String, dynamic> map) =>
      EPUBPreferences(
        fontFamily: map['fontFamily'] as String?,
        fontSize: map['fontSize'] as int,
        fontWeight: map['fontWeight'] as double,
        verticalScroll: map['verticalScroll'] as bool,
        backgroundColor: map['tint'] is int ? Color(map['tint'] as int) : null,
        textColor: map['tint'] is int ? Color(map['tint'] as int) : null,
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

  // TODO: Add more preferences,
  //see https://github.com/readium/swift-toolkit/blob/develop/Sources/Navigator/EPUB/Preferences/EPUBPreferences.swift

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'fontSize': '${fontSize / 100}',
      'fontWeight': fontWeight.toString(),
      'verticalScroll': verticalScroll.toString(),
      'backgroundColor': backgroundColor.toCSS(),
      'textColor': textColor.toCSS(),
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
    return map;
  }
}

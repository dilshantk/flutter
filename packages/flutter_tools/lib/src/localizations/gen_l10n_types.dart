// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:intl/locale.dart';

import '../base/file_system.dart';
import '../convert.dart';
import 'localizations_utils.dart';
import 'message_parser.dart';

// The set of date formats that can be automatically localized.
//
// The localizations generation tool makes use of the intl library's
// DateFormat class to properly format dates based on the locale, the
// desired format, as well as the passed in [DateTime]. For example, using
// DateFormat.yMMMMd("en_US").format(DateTime.utc(1996, 7, 10)) results
// in the string "July 10, 1996".
//
// Since the tool generates code that uses DateFormat's constructor, it is
// necessary to verify that the constructor exists, or the
// tool will generate code that may cause a compile-time error.
//
// See also:
//
// * <https://pub.dev/packages/intl>
// * <https://pub.dev/documentation/intl/latest/intl/DateFormat-class.html>
// * <https://api.dartlang.org/stable/2.7.0/dart-core/DateTime-class.html>
const Set<String> _validDateFormats = <String>{
  'd',
  'E',
  'EEEE',
  'LLL',
  'LLLL',
  'M',
  'Md',
  'MEd',
  'MMM',
  'MMMd',
  'MMMEd',
  'MMMM',
  'MMMMd',
  'MMMMEEEEd',
  'QQQ',
  'QQQQ',
  'y',
  'yM',
  'yMd',
  'yMEd',
  'yMMM',
  'yMMMd',
  'yMMMEd',
  'yMMMM',
  'yMMMMd',
  'yMMMMEEEEd',
  'yQQQ',
  'yQQQQ',
  'H',
  'Hm',
  'Hms',
  'j',
  'jm',
  'jms',
  'jmv',
  'jmz',
  'jv',
  'jz',
  'm',
  'ms',
  's',
};

// The set of number formats that can be automatically localized.
//
// The localizations generation tool makes use of the intl library's
// NumberFormat class to properly format numbers based on the locale and
// the desired format. For example, using
// NumberFormat.compactLong("en_US").format(1200000) results
// in the string "1.2 million".
//
// Since the tool generates code that uses NumberFormat's constructor, it is
// necessary to verify that the constructor exists, or the
// tool will generate code that may cause a compile-time error.
//
// See also:
//
// * <https://pub.dev/packages/intl>
// * <https://pub.dev/documentation/intl/latest/intl/NumberFormat-class.html>
const Set<String> _validNumberFormats = <String>{
  'compact',
  'compactCurrency',
  'compactSimpleCurrency',
  'compactLong',
  'currency',
  'decimalPattern',
  'decimalPercentPattern',
  'percentPattern',
  'scientificPattern',
  'simpleCurrency',
};

// The names of the NumberFormat factory constructors which have named
// parameters rather than positional parameters.
//
// This helps the tool correctly generate number formatting code correctly.
//
// Example of code that uses named parameters:
// final NumberFormat format = NumberFormat.compact(
//   locale: localeName,
// );
//
// Example of code that uses positional parameters:
// final NumberFormat format = NumberFormat.scientificPattern(localeName);
const Set<String> _numberFormatsWithNamedParameters = <String>{
  'compact',
  'compactCurrency',
  'compactSimpleCurrency',
  'compactLong',
  'currency',
  'decimalPercentPattern',
  'simpleCurrency',
};

class L10nException implements Exception {
  L10nException(this.message);

  final String message;

  @override
  String toString() => message;
}

class L10nParserException extends L10nException {
  L10nParserException(
    this.error,
    this.fileName,
    this.messageId,
    this.messageString,
    this.charNumber
  ): super('''
$error
[$fileName:$messageId] $messageString
${List<String>.filled(4 + fileName.length + messageId.length + charNumber, ' ').join()}^''');

  final String error;
  final String fileName;
  final String messageId;
  final String messageString;
  final int charNumber;
}

// One optional named parameter to be used by a NumberFormat.
//
// Some of the NumberFormat factory constructors have optional named parameters.
// For example NumberFormat.compactCurrency has a decimalDigits parameter that
// specifies the number of decimal places to use when formatting.
//
// Optional parameters for NumberFormat placeholders are specified as a
// JSON map value for optionalParameters in a resource's "@" ARB file entry:
//
// "@myResourceId": {
//   "placeholders": {
//     "myNumberPlaceholder": {
//       "type": "double",
//       "format": "compactCurrency",
//       "optionalParameters": {
//         "decimalDigits": 2
//       }
//     }
//   }
// }
class OptionalParameter {
  const OptionalParameter(this.name, this.value) : assert(name != null), assert(value != null);

  final String name;
  final Object value;
}

// One message parameter: one placeholder from an @foo entry in the template ARB file.
//
// Placeholders are specified as a JSON map with one entry for each placeholder.
// One placeholder must be specified for each message "{parameter}".
// Each placeholder entry is also a JSON map. If the map is empty, the placeholder
// is assumed to be an Object value whose toString() value will be displayed.
// For example:
//
// "greeting": "{hello} {world}",
// "@greeting": {
//   "description": "A message with a two parameters",
//   "placeholders": {
//     "hello": {},
//     "world": {}
//   }
// }
//
// Each placeholder can optionally specify a valid Dart type. If the type
// is NumberFormat or DateFormat then a format which matches one of the
// type's factory constructors can also be specified. In this example the
// date placeholder is to be formatted with DateFormat.yMMMMd:
//
// "helloWorldOn": "Hello World on {date}",
// "@helloWorldOn": {
//   "description": "A message with a date parameter",
//   "placeholders": {
//     "date": {
//       "type": "DateTime",
//       "format": "yMMMMd"
//     }
//   }
// }
//
class Placeholder {
  Placeholder(this.resourceId, this.name, Map<String, Object?> attributes)
    : assert(resourceId != null),
      assert(name != null),
      example = _stringAttribute(resourceId, name, attributes, 'example'),
      type = _stringAttribute(resourceId, name, attributes, 'type'),
      format = _stringAttribute(resourceId, name, attributes, 'format'),
      optionalParameters = _optionalParameters(resourceId, name, attributes),
      isCustomDateFormat = _boolAttribute(resourceId, name, attributes, 'isCustomDateFormat');

  final String resourceId;
  final String name;
  final String? example;
  final String? format;
  final List<OptionalParameter> optionalParameters;
  final bool? isCustomDateFormat;
  // The following will be initialized after all messages are parsed in the Message constructor.
  String? type;
  bool isPlural = false;
  bool isSelect = false;

  bool get requiresFormatting => requiresDateFormatting || requiresNumFormatting;
  bool get requiresDateFormatting => type == 'DateTime';
  bool get requiresNumFormatting => <String>['int', 'num', 'double'].contains(type) && format != null;
  bool get hasValidNumberFormat => _validNumberFormats.contains(format);
  bool get hasNumberFormatWithParameters => _numberFormatsWithNamedParameters.contains(format);
  bool get hasValidDateFormat => _validDateFormats.contains(format);

  static String? _stringAttribute(
    String resourceId,
    String name,
    Map<String, Object?> attributes,
    String attributeName,
  ) {
    final Object? value = attributes[attributeName];
    if (value == null) {
      return null;
    }
    if (value is! String || value.isEmpty) {
      throw L10nException(
        'The "$attributeName" value of the "$name" placeholder in message $resourceId '
        'must be a non-empty string.',
      );
    }
    return value;
  }

  static bool? _boolAttribute(
      String resourceId,
      String name,
      Map<String, Object?> attributes,
      String attributeName,
      ) {
    final Object? value = attributes[attributeName];
    if (value == null) {
      return null;
    }
    if (value != 'true' && value != 'false') {
      throw L10nException(
        'The "$attributeName" value of the "$name" placeholder in message $resourceId '
            'must be a boolean value.',
      );
    }
    return value == 'true';
  }

  static List<OptionalParameter> _optionalParameters(
    String resourceId,
    String name,
    Map<String, Object?> attributes
  ) {
    final Object? value = attributes['optionalParameters'];
    if (value == null) {
      return <OptionalParameter>[];
    }
    if (value is! Map<String, Object?>) {
      throw L10nException(
        'The "optionalParameters" value of the "$name" placeholder in message '
        '$resourceId is not a properly formatted Map. Ensure that it is a map '
        'with keys that are strings.'
      );
    }
    final Map<String, Object?> optionalParameterMap = value;
    return optionalParameterMap.keys.map<OptionalParameter>((String parameterName) {
      return OptionalParameter(parameterName, optionalParameterMap[parameterName]!);
    }).toList();
  }
}

// All translations for a given message specified by a resource id.
//
// The template ARB file must contain an entry called @myResourceId for each
// message named myResourceId. The @ entry describes message parameters
// called "placeholders" and can include an optional description.
// Here's a simple example message with no parameters:
//
// "helloWorld": "Hello World",
// "@helloWorld": {
//   "description": "The conventional newborn programmer greeting"
// }
//
// The value of this Message is "Hello World". The Message's value is the
// localized string to be shown for the template ARB file's locale.
// The docs for the Placeholder explain how placeholder entries are defined.
class Message {
  Message(
    AppResourceBundle templateBundle,
    AppResourceBundleCollection allBundles,
    this.resourceId,
    bool isResourceAttributeRequired,
    { this.useEscaping = false }
  ) : assert(templateBundle != null),
      assert(allBundles != null),
      assert(resourceId != null && resourceId.isNotEmpty),
      value = _value(templateBundle.resources, resourceId),
      description = _description(templateBundle.resources, resourceId, isResourceAttributeRequired),
      placeholders = _placeholders(templateBundle.resources, resourceId, isResourceAttributeRequired),
      messages = <LocaleInfo, String?>{},
      parsedMessages = <LocaleInfo, Node?>{} {
    // Filenames for error handling.
    final Map<LocaleInfo, String> filenames = <LocaleInfo, String>{};
    // Collect all translations from allBundles and parse them.
    for (final AppResourceBundle bundle in allBundles.bundles) {
      filenames[bundle.locale] = bundle.file.basename;
      final String? translation = bundle.translationFor(resourceId);
      messages[bundle.locale] = translation;
      parsedMessages[bundle.locale] = translation == null ? null : Parser(resourceId, bundle.file.basename, translation, useEscaping: useEscaping).parse();
    }
    // Using parsed translations, attempt to infer types of placeholders used by plurals and selects.
    for (final LocaleInfo locale in parsedMessages.keys) {
      if (parsedMessages[locale] == null) {
        continue;
      }
      final List<Node> traversalStack = <Node>[parsedMessages[locale]!];
      while (traversalStack.isNotEmpty) {
        final Node node = traversalStack.removeLast();
        if (node.type == ST.pluralExpr) {
          final Placeholder? placeholder = placeholders[node.children[1].value!];
          if (placeholder == null) {
            throw L10nParserException(
              'Make sure that the specified plural placeholder is defined in your arb file.',
              filenames[locale]!,
              resourceId,
              messages[locale]!,
              node.children[1].positionInMessage
            );
          }
          placeholders[node.children[1].value!]!.isPlural = true;
        }
        if (node.type == ST.selectExpr) {
          final Placeholder? placeholder = placeholders[node.children[1].value!];
          if (placeholder == null) {
            throw L10nParserException(
              'Make sure that the specified select placeholder is defined in your arb file.',
              filenames[locale]!,
              resourceId,
              messages[locale]!,
              node.children[1].positionInMessage
            );
          }
          placeholders[node.children[1].value!]!.isSelect = true;
        }
        traversalStack.addAll(node.children);
      }
    }
    for (final Placeholder placeholder in placeholders.values) {
      if (placeholder.isPlural && placeholder.isSelect) {
        throw L10nException('Placeholder is used as both a plural and select in certain languages.');
      } else if (placeholder.isPlural) {
        if (placeholder.type == null) {
          placeholder.type = 'num';
        }
        else if (!<String>['num', 'int'].contains(placeholder.type)) {
          throw L10nException("Placeholders used in plurals must be of type 'num' or 'int'");
        }
      } else if (placeholder.isSelect) {
        if (placeholder.type == null) {
          placeholder.type = 'String';
        } else if (placeholder.type != 'String') {
          throw L10nException("Placeholders used in selects must be of type 'String'");
        }
      }
      placeholder.type ??= 'Object';
    }
  }

  final String resourceId;
  final String value;
  final String? description;
  late final Map<LocaleInfo, String?> messages;
  final Map<LocaleInfo, Node?> parsedMessages;
  final Map<String, Placeholder> placeholders;
  final bool useEscaping;

  bool get placeholdersRequireFormatting => placeholders.values.any((Placeholder p) => p.requiresFormatting);

  static String _value(Map<String, Object?> bundle, String resourceId) {
    final Object? value = bundle[resourceId];
    if (value == null) {
      throw L10nException('A value for resource "$resourceId" was not found.');
    }
    if (value is! String) {
      throw L10nException('The value of "$resourceId" is not a string.');
    }
    return value;
  }

  static Map<String, Object?>? _attributes(
    Map<String, Object?> bundle,
    String resourceId,
    bool isResourceAttributeRequired,
  ) {
    final Object? attributes = bundle['@$resourceId'];
    if (isResourceAttributeRequired) {
      if (attributes == null) {
        throw L10nException(
          'Resource attribute "@$resourceId" was not found. Please '
          'ensure that each resource has a corresponding @resource.'
        );
      }
    }

    if (attributes != null && attributes is! Map<String, Object?>) {
      throw L10nException(
        'The resource attribute "@$resourceId" is not a properly formatted Map. '
        'Ensure that it is a map with keys that are strings.'
      );
    }

    return attributes as Map<String, Object?>?;
  }

  static String? _description(
    Map<String, Object?> bundle,
    String resourceId,
    bool isResourceAttributeRequired,
  ) {
    final Map<String, Object?>? resourceAttributes = _attributes(bundle, resourceId, isResourceAttributeRequired);
    if (resourceAttributes == null) {
      return null;
    }

    final Object? value = resourceAttributes['description'];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw L10nException(
        'The description for "@$resourceId" is not a properly formatted String.'
      );
    }
    return value;
  }

  static Map<String, Placeholder> _placeholders(
    Map<String, Object?> bundle,
    String resourceId,
    bool isResourceAttributeRequired,
  ) {
    final Map<String, Object?>? resourceAttributes = _attributes(bundle, resourceId, isResourceAttributeRequired);
    if (resourceAttributes == null) {
      return <String, Placeholder>{};
    }
    final Object? allPlaceholdersMap = resourceAttributes['placeholders'];
    if (allPlaceholdersMap == null) {
      return <String, Placeholder>{};
    }
    if (allPlaceholdersMap is! Map<String, Object?>) {
      throw L10nException(
        'The "placeholders" attribute for message $resourceId, is not '
        'properly formatted. Ensure that it is a map with string valued keys.'
      );
    }
    return Map<String, Placeholder>.fromEntries(
      allPlaceholdersMap.keys.map((String placeholderName) {
        final Object? value = allPlaceholdersMap[placeholderName];
        if (value is! Map<String, Object?>) {
          throw L10nException(
            'The value of the "$placeholderName" placeholder attribute for message '
            '"$resourceId", is not properly formatted. Ensure that it is a map '
            'with string valued keys.'
          );
        }
        return MapEntry<String, Placeholder>(placeholderName, Placeholder(resourceId, placeholderName, value));
      }),
    );
  }
}

// Represents the contents of one ARB file.
class AppResourceBundle {
  factory AppResourceBundle(File file) {
    assert(file != null);
    // Assuming that the caller has verified that the file exists and is readable.
    Map<String, Object?> resources;
    try {
      resources = json.decode(file.readAsStringSync()) as Map<String, Object?>;
    } on FormatException catch (e) {
      throw L10nException(
        'The arb file ${file.path} has the following formatting issue: \n'
        '$e',
      );
    }

    String? localeString = resources['@@locale'] as String?;

    // Look for the first instance of an ISO 639-1 language code, matching exactly.
    final String fileName = file.fileSystem.path.basenameWithoutExtension(file.path);

    for (int index = 0; index < fileName.length; index += 1) {
      // If an underscore was found, check if locale string follows.
      if (fileName[index] == '_' && fileName[index + 1] != null) {
        // If Locale.tryParse fails, it returns null.
        final Locale? parserResult = Locale.tryParse(fileName.substring(index + 1));
        // If the parserResult is not an actual locale identifier, end the loop.
        if (parserResult != null && _iso639Languages.contains(parserResult.languageCode)) {
          // The parsed result uses dashes ('-'), but we want underscores ('_').
          final String parserLocaleString = parserResult.toString().replaceAll('-', '_');


          if (localeString == null) {
            // If @@locale was not defined, use the filename locale suffix.
            localeString = parserLocaleString;
          } else {
            // If the localeString was defined in @@locale and in the filename, verify to
            // see if the parsed locale matches, throw an error if it does not. This
            // prevents developers from confusing issues when both @@locale and
            // "_{locale}" is specified in the filename.
            if (localeString != parserLocaleString) {
              throw L10nException(
                'The locale specified in @@locale and the arb filename do not match. \n'
                'Please make sure that they match, since this prevents any confusion \n'
                'with which locale to use. Otherwise, specify the locale in either the \n'
                'filename of the @@locale key only.\n'
                'Current @@locale value: $localeString\n'
                'Current filename extension: $parserLocaleString'
              );
            }
          }
          break;
        }
      }
    }

    if (localeString == null) {
      throw L10nException(
        "The following .arb file's locale could not be determined: \n"
        '${file.path} \n'
        "Make sure that the locale is specified in the file's '@@locale' "
        'property or as part of the filename (e.g. file_en.arb)'
      );
    }

    final Iterable<String> ids = resources.keys.where((String key) => !key.startsWith('@'));
    return AppResourceBundle._(file, LocaleInfo.fromString(localeString), resources, ids);
  }

  const AppResourceBundle._(this.file, this.locale, this.resources, this.resourceIds);

  final File file;
  final LocaleInfo locale;
  /// JSON representation of the contents of the ARB file.
  final Map<String, Object?> resources;
  final Iterable<String> resourceIds;

  String? translationFor(String resourceId) => resources[resourceId] as String?;

  @override
  String toString() {
    return 'AppResourceBundle($locale, ${file.path})';
  }
}

// Represents all of the ARB files in [directory] as [AppResourceBundle]s.
class AppResourceBundleCollection {
  factory AppResourceBundleCollection(Directory directory) {
    assert(directory != null);
    // Assuming that the caller has verified that the directory is readable.

    final RegExp filenameRE = RegExp(r'(\w+)\.arb$');
    final Map<LocaleInfo, AppResourceBundle> localeToBundle = <LocaleInfo, AppResourceBundle>{};
    final Map<String, List<LocaleInfo>> languageToLocales = <String, List<LocaleInfo>>{};
    final List<File> files = directory.listSync().whereType<File>().toList()..sort(sortFilesByPath);
    for (final File file in files) {
      if (filenameRE.hasMatch(file.path)) {
        final AppResourceBundle bundle = AppResourceBundle(file);
        if (localeToBundle[bundle.locale] != null) {
          throw L10nException(
            "Multiple arb files with the same '${bundle.locale}' locale detected. \n"
            'Ensure that there is exactly one arb file for each locale.'
          );
        }
        localeToBundle[bundle.locale] = bundle;
        languageToLocales[bundle.locale.languageCode] ??= <LocaleInfo>[];
        languageToLocales[bundle.locale.languageCode]!.add(bundle.locale);
      }
    }

    languageToLocales.forEach((String language, List<LocaleInfo> listOfCorrespondingLocales) {
      final List<String> localeStrings = listOfCorrespondingLocales.map((LocaleInfo locale) {
        return locale.toString();
      }).toList();
      if (!localeStrings.contains(language)) {
        throw L10nException(
          'Arb file for a fallback, $language, does not exist, even though \n'
          'the following locale(s) exist: $listOfCorrespondingLocales. \n'
          'When locales specify a script code or country code, a \n'
          'base locale (without the script code or country code) should \n'
          'exist as the fallback. Please create a {fileName}_$language.arb \n'
          'file.'
        );
      }
    });

    return AppResourceBundleCollection._(directory, localeToBundle, languageToLocales);
  }

  const AppResourceBundleCollection._(this._directory, this._localeToBundle, this._languageToLocales);

  final Directory _directory;
  final Map<LocaleInfo, AppResourceBundle> _localeToBundle;
  final Map<String, List<LocaleInfo>> _languageToLocales;

  Iterable<LocaleInfo> get locales => _localeToBundle.keys;
  Iterable<AppResourceBundle> get bundles => _localeToBundle.values;
  AppResourceBundle? bundleFor(LocaleInfo locale) => _localeToBundle[locale];

  Iterable<String> get languages => _languageToLocales.keys;
  Iterable<LocaleInfo> localesForLanguage(String language) => _languageToLocales[language] ?? <LocaleInfo>[];

  @override
  String toString() {
    return 'AppResourceBundleCollection(${_directory.path}, ${locales.length} locales)';
  }
}

// A set containing all the ISO630-1 languages. This list was pulled from https://datahub.io/core/language-codes.
final Set<String> _iso639Languages = <String>{
  'aa',
  'ab',
  'ae',
  'af',
  'ak',
  'am',
  'an',
  'ar',
  'as',
  'av',
  'ay',
  'az',
  'ba',
  'be',
  'bg',
  'bh',
  'bi',
  'bm',
  'bn',
  'bo',
  'br',
  'bs',
  'ca',
  'ce',
  'ch',
  'co',
  'cr',
  'cs',
  'cu',
  'cv',
  'cy',
  'da',
  'de',
  'dv',
  'dz',
  'ee',
  'el',
  'en',
  'eo',
  'es',
  'et',
  'eu',
  'fa',
  'ff',
  'fi',
  'fil',
  'fj',
  'fo',
  'fr',
  'fy',
  'ga',
  'gd',
  'gl',
  'gn',
  'gsw',
  'gu',
  'gv',
  'ha',
  'he',
  'hi',
  'ho',
  'hr',
  'ht',
  'hu',
  'hy',
  'hz',
  'ia',
  'id',
  'ie',
  'ig',
  'ii',
  'ik',
  'io',
  'is',
  'it',
  'iu',
  'ja',
  'jv',
  'ka',
  'kg',
  'ki',
  'kj',
  'kk',
  'kl',
  'km',
  'kn',
  'ko',
  'kr',
  'ks',
  'ku',
  'kv',
  'kw',
  'ky',
  'la',
  'lb',
  'lg',
  'li',
  'ln',
  'lo',
  'lt',
  'lu',
  'lv',
  'mg',
  'mh',
  'mi',
  'mk',
  'ml',
  'mn',
  'mr',
  'ms',
  'mt',
  'my',
  'na',
  'nb',
  'nd',
  'ne',
  'ng',
  'nl',
  'nn',
  'no',
  'nr',
  'nv',
  'ny',
  'oc',
  'oj',
  'om',
  'or',
  'os',
  'pa',
  'pi',
  'pl',
  'ps',
  'pt',
  'qu',
  'rm',
  'rn',
  'ro',
  'ru',
  'rw',
  'sa',
  'sc',
  'sd',
  'se',
  'sg',
  'si',
  'sk',
  'sl',
  'sm',
  'sn',
  'so',
  'sq',
  'sr',
  'ss',
  'st',
  'su',
  'sv',
  'sw',
  'ta',
  'te',
  'tg',
  'th',
  'ti',
  'tk',
  'tl',
  'tn',
  'to',
  'tr',
  'ts',
  'tt',
  'tw',
  'ty',
  'ug',
  'uk',
  'ur',
  'uz',
  've',
  'vi',
  'vo',
  'wa',
  'wo',
  'xh',
  'yi',
  'yo',
  'za',
  'zh',
  'zu',
};

// Used in LocalizationsGenerator._generateMethod.generateHelperMethod.
class HelperMethod {
  HelperMethod(this.dependentPlaceholders, {this.helper, this.placeholder, this.string }):
    assert((() {
      // At least one of helper, placeholder, string must be nonnull.
      final bool a = helper == null;
      final bool b = placeholder == null;
      final bool c = string == null;
      return (!a && b && c) || (a && !b && c) || (a && b && !c);
    })());

  Set<Placeholder> dependentPlaceholders;
  String? helper;
  Placeholder? placeholder;
  String? string;

  String get helperOrPlaceholder {
    if (helper != null) {
      return '$helper($methodArguments)';
    } else if (string != null) {
      return '$string';
    } else {
      if (placeholder!.requiresFormatting) {
        return '${placeholder!.name}String';
      } else {
        return placeholder!.name;
      }
    }
  }

  String get methodParameters {
    assert(helper != null);
    return dependentPlaceholders.map((Placeholder placeholder) =>
      (placeholder.requiresFormatting)
        ? 'String ${placeholder.name}String'
        : '${placeholder.type} ${placeholder.name}').join(', ');
  }

  String get methodArguments {
    assert(helper != null);
    return dependentPlaceholders.map((Placeholder placeholder) =>
      (placeholder.requiresFormatting)
        ? '${placeholder.name}String'
        : placeholder.name).join(', ');
  }
}

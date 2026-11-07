import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What `flutter build` doesn't collect for the license page: Tala's own
/// license, and the libraries inside the prebuilt libwebrtc.so, which isn't a
/// Dart package. `tool/make_webrtc_licenses.py` writes the second file.
void registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Tala'],
      await rootBundle.loadString('LICENSE'),
    );
    final bundled = await rootBundle.loadString(
      'assets/licenses/libwebrtc.txt',
    );
    for (final (name, text) in parseBundledLicenses(bundled)) {
      yield LicenseEntryWithLineBreaks([name], text);
    }
  });
}

/// Splits the generated file into (component name, license text).
List<(String, String)> parseBundledLicenses(String file) {
  const marker = '@@@ ';
  final result = <(String, String)>[];
  String? name;
  final text = StringBuffer();
  void finish() {
    if (name != null) result.add((name, text.toString().trim()));
    text.clear();
  }

  for (final line in file.split('\n')) {
    if (line.startsWith(marker)) {
      finish();
      name = line.substring(marker.length).trim();
    } else {
      text.writeln(line);
    }
  }
  finish();
  return result;
}

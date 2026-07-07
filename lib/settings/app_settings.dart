import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kNamePrefix = 'display_name_prefix';
  static const _kNameSuffix = 'display_name_suffix';
  static const defaultSuffix = '的書坊';

  static Future<String?> getDisplayName() async {
    final sp = await SharedPreferences.getInstance();
    final prefix = (sp.getString(_kNamePrefix) ?? '').trim();
    if (prefix.isEmpty) return null;
    final suffix = (sp.getString(_kNameSuffix) ?? defaultSuffix).trim();
    return '$prefix$suffix';
  }

  static Future<void> setDisplayNameParts({
    required String prefix,
    required String suffix,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kNamePrefix, prefix.trim());
    await sp.setString(_kNameSuffix, suffix.trim());
  }

  static Future<({String? prefix, String suffix})> getDisplayNameParts() async {
    final sp = await SharedPreferences.getInstance();
    final prefix = (sp.getString(_kNamePrefix) ?? '').trim();
    final suffix = (sp.getString(_kNameSuffix) ?? defaultSuffix).trim();
    return (
      prefix: prefix.isEmpty ? null : prefix,
      suffix: suffix.isEmpty ? '' : suffix,
    );
  }
}


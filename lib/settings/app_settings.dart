import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kNamePrefix = 'display_name_prefix';
  static const _kNameSuffix = 'display_name_suffix';
  static const _kFontScale = 'font_scale';
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

  static Future<void> setFontScale(double scale) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kFontScale, scale.clamp(0.8, 1.8));
  }

  static Future<double> getFontScale() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getDouble(_kFontScale) ?? 1.0;
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


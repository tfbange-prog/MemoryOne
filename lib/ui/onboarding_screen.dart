import 'package:flutter/material.dart';

import '../settings/app_settings.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;

  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _prefix = TextEditingController();
  final _suffix = TextEditingController(text: AppSettings.defaultSuffix);
  bool _saving = false;

  @override
  void dispose() {
    _prefix.dispose();
    _suffix.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final prefix = _prefix.text.trim();
    if (prefix.isEmpty) return;
    final suffix = _suffix.text.trim().isEmpty ? '' : _suffix.text.trim();
    setState(() => _saving = true);
    await AppSettings.setDisplayNameParts(prefix: prefix, suffix: suffix);
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('第一次使用')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('請幫你的資料庫取個名字（例如：小明 的書坊）'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _prefix,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '前面（例如：小明）',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _suffix,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '後面（預設：的書坊）',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(_saving ? '儲存中…' : '開始使用'),
            ),
          ],
        ),
      ),
    );
  }
}


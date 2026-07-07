import 'package:flutter/material.dart';

import 'db/app_db.dart';
import 'settings/app_settings.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Friends Vault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const _Bootstrapper(),
    );
  }
}

class _Bootstrapper extends StatefulWidget {
  const _Bootstrapper();

  @override
  State<_Bootstrapper> createState() => _BootstrapperState();
}

class _BootstrapperState extends State<_Bootstrapper> {
  late final AppDb _db;
  String? _displayName;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _db = AppDb();
    _init();
  }

  Future<void> _init() async {
    await _db.bootstrap();
    _displayName = await AppSettings.getDisplayName();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _db.close();
    super.dispose();
  }

  void _refreshName() async {
    _displayName = await AppSettings.getDisplayName();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final name = _displayName;
    if (name == null) {
      return OnboardingScreen(onDone: _refreshName);
    }
    return HomeScreen(db: _db, displayName: name);
  }
}

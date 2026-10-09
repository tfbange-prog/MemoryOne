import 'package:flutter/foundation.dart' show kIsWeb;
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
      title: 'MemoryOne',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F8DE8),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF4F8DE8),
          onPrimary: Colors.white,
          secondary: const Color(0xFF42C2A8),
          primaryContainer: const Color(0xFFE7F2FF),
          secondaryContainer: const Color(0xFFE6F8F2),
          surface: const Color(0xFFFFFEFE),
          surfaceContainerHighest: const Color(0xFFF3F7FB),
        ),
        scaffoldBackgroundColor: const Color(0xFFF6FAFD),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2F80ED),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
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
  double _fontScale = 1.0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _db = AppDb();
    _init();
  }

  Future<void> _init() async {
    if (!kIsWeb) {
      await _db.bootstrap();
    }
    _displayName = await AppSettings.getDisplayName();
    _fontScale = await AppSettings.getFontScale();
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

  void _updateFontScale(double newScale) {
    if (!mounted) return;
    setState(() => _fontScale = newScale);
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
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(_fontScale)),
      child: HomeScreen(db: _db, displayName: name, onFontScaleChanged: _updateFontScale),
    );
  }
}

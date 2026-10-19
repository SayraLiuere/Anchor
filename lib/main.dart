import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/log_entry.dart';
import 'screens/companion_screen.dart';
import 'screens/log_screen.dart';
import 'screens/home_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/memory_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ChangeNotifierProvider(
    create: (_) => AppState()..init(),
    child: const MiraApp(),
  ));
}

class MiraApp extends StatelessWidget {
  const MiraApp({super.key});

  static const seed = Color(0xFF6C63FF);

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      cardTheme: CardTheme(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mira',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: Consumer<AppState>(
        builder: (context, s, _) {
          if (s.loading) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return s.onboarded ? const RootShell() : const OnboardingScreen();
        },
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  static void goTo(BuildContext context, int tab) =>
      context.findAncestorStateOfType<_RootShellState>()?.select(tab);

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;

  void select(int i) => setState(() => _index = i);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Settings (permission granted?) or from another app: refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) context.read<AppState>().refreshDevice();
  }

  /// A tapped notification asks to log an episode or a check-in.
  void _handlePendingAction(AppState s) {
    if (s.pendingAction == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final action = s.takePendingAction();
      if (action == null || !mounted) return;
      select(0);
      openLogSheet(context, action == 'checkin' ? EntryKind.checkIn : EntryKind.episode);
    });
  }

  @override
  Widget build(BuildContext context) {
    _handlePendingAction(context.watch<AppState>());
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomeScreen(),
          CompanionScreen(),
          MemoryScreen(),
          InsightsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: select,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Mira'),
          NavigationDestination(
              icon: Icon(Icons.auto_stories_outlined),
              selectedIcon: Icon(Icons.auto_stories),
              label: 'Memory'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'Insights'),
        ],
      ),
    );
  }
}

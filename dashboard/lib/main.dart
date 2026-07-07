import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore saved hub/token before the first frame so the login screen can
  // prefill them (no retyping on mobile).
  final appState = AppState();
  await appState.restore();
  runApp(PlantMonitoringApp(appState: appState));
}

class PlantMonitoringApp extends StatelessWidget {
  final AppState appState;
  const PlantMonitoringApp({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: appState,
      child: MaterialApp(
        title: 'Crop Health Matrix',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const LoginScreen(),
      ),
    );
  }
}

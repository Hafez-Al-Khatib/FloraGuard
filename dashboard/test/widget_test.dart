import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:plant_monitoring_dashboard/providers/app_state.dart';
import 'package:plant_monitoring_dashboard/screens/login_screen.dart';
import 'package:plant_monitoring_dashboard/theme/app_theme.dart';

void main() {
  testWidgets('Login screen renders the glass console', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(theme: buildAppTheme(), home: const LoginScreen()),
      ),
    );

    expect(find.text('Crop Health Matrix'), findsOneWidget);
    expect(find.text('ESTABLISH LINK'), findsOneWidget);
    // Two inputs: hub endpoint + access token.
    expect(find.byType(TextField), findsNWidgets(2));
  });
}

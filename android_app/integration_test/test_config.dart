import 'package:shared_preferences/shared_preferences.dart';

const testServer = String.fromEnvironment(
  'TEST_SERVER',
  defaultValue: 'http://10.0.2.2:3003',
);
const testEmail = String.fromEnvironment(
  'TEST_EMAIL',
  defaultValue: 'admin@example.test',
);
Uri get testInstaller => Uri.parse(testServer).replace(port: 3005);

Future<void> configureServer(SharedPreferences preferences) async {
  await preferences.setString('server', testServer);
  await preferences.setString('email', testEmail);
}

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Themes {
  static final light = ThemeData(
    brightness: Brightness.light,
    primaryColor: Colors.blue,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(backgroundColor: Colors.blue),
    textTheme: const TextTheme(bodyMedium: TextStyle(color: Colors.black)),
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
    ).copyWith(secondary: Colors.blueAccent),
  );

  static final dark = ThemeData(
    brightness: Brightness.dark,
    primaryColor: Colors.blueGrey,
    scaffoldBackgroundColor: Colors.grey[900],
    appBarTheme: AppBarTheme(backgroundColor: Colors.grey[900]),
    textTheme: const TextTheme(bodyMedium: TextStyle(color: Colors.white)),
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blueGrey,
      brightness: Brightness.dark,
    ),
  );
}

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode; // Make it non-nullable and initialized via constructor

  ThemeProvider(this._themeMode); // Constructor to set initial theme mode

  ThemeMode get themeMode => _themeMode;

  void toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', isDark ? 'dark' : 'light');
  }

  void followSystem() async {
    _themeMode = ThemeMode.system;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', 'system');
  }
}

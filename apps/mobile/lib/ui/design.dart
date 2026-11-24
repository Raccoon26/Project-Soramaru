import 'package:material_ui/material_ui.dart';

abstract final class Palette {
  static const yellow = Color(0xFFFFB400);
  static const gold = Color(0xFFEEB73E);
  static const pink = Color(0xFFFF5A84);
  static const pinkContrast = Color(0xFFBD2E60);
  static const blue = Color(0xFF5A8FDD);
  static const link = Color(0xFF245DA4);
  static const green = Color(0xFF0BAA69);
  static const success = Color(0xFF087045);
  static const ink = Color(0xFF252525);
  static const secondary = Color(0xFF5E5E5E);
  static const divider = Color(0xFFEFEFEF);
  static const background = Color(0xFFFAFAFA);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFF85817A);
  static const error = Color(0xFFAD2439);
  static const errorSurface = Color(0xFFFFEDF0);
  static const warning = Color(0xFF795000);
  static const warm = Color(0xFFFFF5D9);
  static const disabled = Color(0xFFE9E8E5);
  static const focus = link;
  static const night = Color(0xFF24313F);
  static const mutedBlue = Color(0xFFE9F2FB);
}

abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double gap = 12;
  static const double edge = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double section = 32;
  static const double touch = 48;
  static const double header = 52;
  static const double navigation = 62;
  static const double filter = 46;
  static const double radius = 14;
  static const double maxContent = 720;
}

abstract final class TypeStyles {
  static const heading = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );
  static const body = TextStyle(fontSize: 15, height: 1.55);
  static const caption = TextStyle(fontSize: 12, height: 1.4);
  static const tab = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
}

ThemeData soramaruTheme({String? fontFamily}) => ThemeData(
  scaffoldBackgroundColor: Palette.background,
  splashFactory: NoSplash.splashFactory,
  focusColor: Palette.focus.withValues(alpha: 0.15),
  fontFamily: fontFamily,
  dividerColor: Palette.divider,
  dividerTheme: const DividerThemeData(color: Palette.divider),
  colorScheme: const ColorScheme.light(
    primary: Palette.warning,
    onPrimary: Palette.surface,
    primaryContainer: Palette.yellow,
    onPrimaryContainer: Palette.ink,
    secondary: Palette.link,
    surface: Palette.surface,
    onSurface: Palette.ink,
    onSurfaceVariant: Palette.secondary,
    error: Palette.error,
    onError: Palette.surface,
    outline: Palette.border,
  ),
  textTheme:
      const TextTheme(
        titleLarge: TypeStyles.heading,
        bodyMedium: TypeStyles.body,
        bodySmall: TypeStyles.caption,
        labelLarge: TypeStyles.body,
        labelSmall: TypeStyles.tab,
      ).apply(
        fontFamily: fontFamily,
        bodyColor: Palette.ink,
        displayColor: Palette.ink,
      ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Palette.surface,
    contentPadding: const EdgeInsets.all(Space.edge),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Space.radius),
      borderSide: const BorderSide(color: Palette.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Space.radius),
      borderSide: const BorderSide(color: Palette.focus, width: 2),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Space.radius),
    ),
  ),
);

double contrastRatio(Color one, Color two) {
  final a = one.computeLuminance();
  final b = two.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

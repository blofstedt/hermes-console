import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Tono de un aviso efímero. Decide icono, color, duración y háptica.
enum HermesSnackTone {
  /// Información neutra ("cargado", "sin cambios").
  info,

  /// Confirmación de una acción del usuario ("copiado", "aplicado").
  success,

  /// Algo que merece atención pero no ha fallado.
  warning,

  /// Un fallo. Se queda más tiempo y ofrece copiar el texto.
  error,
}

/// Punto único para mostrar avisos efímeros (spec QoL).
///
/// Antes cada pantalla llamaba a `ScaffoldMessenger.of(context).showSnackBar()`
/// a pelo. Como `ScaffoldMessenger` ENCOLA, dos avisos seguidos se convertían en
/// ocho segundos de banner, y una operación que informa por elemento levantaba
/// un muro. Aquí siempre se retira el aviso vigente antes de mostrar el
/// siguiente, así que el último gana y la UI no se queda atascada.
///
/// Además unifica lo que antes cada sitio decidía por su cuenta: duración según
/// gravedad (una confirmación no necesita los 4 s de un error), háptica de
/// confirmación, icono de tono, y — en los errores — una acción «Copiar» para
/// que el texto se pueda pegar en un issue.
class HermesSnack {
  const HermesSnack._();

  /// Ventana anti-rebote: dos avisos idénticos más juntos que esto se
  /// consideran el mismo evento (doble callback, doble toque) y el segundo se
  /// ignora, en vez de reiniciar el banner y hacerlo parpadear.
  static const Duration _dedupeWindow = Duration(milliseconds: 700);

  static String? _lastMessage;
  static DateTime? _lastShownAt;

  /// Solo para tests: olvida el último aviso para que el anti-rebote no filtre
  /// entre casos.
  @visibleForTesting
  static void resetDedupe() {
    _lastMessage = null;
    _lastShownAt = null;
  }

  static Duration _durationFor(HermesSnackTone tone) => switch (tone) {
    // Una confirmación se lee de un vistazo; alargarla solo tapa contenido.
    HermesSnackTone.success => const Duration(milliseconds: 2200),
    HermesSnackTone.info => const Duration(milliseconds: 2800),
    HermesSnackTone.warning => const Duration(milliseconds: 4000),
    // Un error suele traer texto del servidor que hay que leer (y copiar).
    HermesSnackTone.error => const Duration(seconds: 6),
  };

  static IconData _iconFor(HermesSnackTone tone) => switch (tone) {
    HermesSnackTone.success => Icons.check_circle_outline,
    HermesSnackTone.info => Icons.info_outline,
    HermesSnackTone.warning => Icons.warning_amber_rounded,
    HermesSnackTone.error => Icons.error_outline,
  };

  static Color _colorFor(HermesSnackTone tone, HermesThemeColors colors) =>
      switch (tone) {
        HermesSnackTone.success => colors.success,
        HermesSnackTone.info => colors.accent,
        HermesSnackTone.warning => colors.warning,
        HermesSnackTone.error => colors.error,
      };

  static void _hapticFor(HermesSnackTone tone) {
    switch (tone) {
      case HermesSnackTone.success:
      case HermesSnackTone.info:
        HapticFeedback.selectionClick();
      case HermesSnackTone.warning:
        HapticFeedback.lightImpact();
      case HermesSnackTone.error:
        HapticFeedback.mediumImpact();
    }
  }

  /// Muestra [message] retirando antes el aviso vigente.
  ///
  /// [actionLabel]/[onAction] añaden un botón. Si el tono es [
  /// HermesSnackTone.error] y no se pasa acción, se ofrece «Copiar» sobre el
  /// propio mensaje: los errores de gateway y bridge son justo lo que el
  /// usuario necesita pegar en un issue.
  static void show(
    BuildContext context,
    String message, {
    HermesSnackTone tone = HermesSnackTone.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
    bool haptic = true,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _showOnMessenger(
      messenger,
      context,
      message,
      tone: tone,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
      haptic: haptic,
    );
  }

  /// Variante para después de un `await`, cuando el `BuildContext` ya puede
  /// haberse desmontado pero el messenger capturado antes sigue vivo.
  static void showOn(
    ScaffoldMessengerState messenger,
    String message, {
    HermesSnackTone tone = HermesSnackTone.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
    bool haptic = true,
  }) {
    if (!messenger.mounted) return;
    _showOnMessenger(
      messenger,
      messenger.context,
      message,
      tone: tone,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
      haptic: haptic,
    );
  }

  static void _showOnMessenger(
    ScaffoldMessengerState messenger,
    BuildContext context,
    String message, {
    required HermesSnackTone tone,
    required String? actionLabel,
    required VoidCallback? onAction,
    required Duration? duration,
    required bool haptic,
  }) {
    final now = DateTime.now();
    final last = _lastShownAt;
    if (_lastMessage == message &&
        last != null &&
        now.difference(last) < _dedupeWindow) {
      return;
    }
    _lastMessage = message;
    _lastShownAt = now;

    if (haptic) _hapticFor(tone);

    final colors = Theme.of(context).hermes;
    final toneColor = _colorFor(tone, colors);

    String? label = actionLabel;
    VoidCallback? action = onAction;
    if (label == null && action == null && tone == HermesSnackTone.error) {
      label = Strings.of(context).commonCopy;
      action = () => unawaitedCopy(message);
    }

    // El aviso vigente se retira sin animación de salida: encolarlos era el
    // problema original, y un fundido de 200 ms antes del siguiente se percibe
    // como lag cuando el usuario acaba de tocar algo.
    messenger.removeCurrentSnackBar(reason: SnackBarClosedReason.remove);
    messenger.showSnackBar(
      SnackBar(
        duration: duration ?? _durationFor(tone),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              // Alinea el icono con la primera línea cuando el texto envuelve.
              padding: const EdgeInsets.only(top: 1),
              child: Icon(_iconFor(tone), size: 18, color: toneColor),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        action: label == null || action == null
            ? null
            : SnackBarAction(
                label: label,
                textColor: toneColor,
                onPressed: action,
              ),
      ),
    );
  }

  /// Copia [text] y confirma. Sustituye al patrón `Clipboard.setData` +
  /// `if (context.mounted)` + `showSnackBar` repetido por toda la app, que
  /// además solo daba háptica en el chat.
  static Future<void> copied(
    BuildContext context,
    String text, {
    String? message,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmation = message ?? Strings.of(context).commonCopied;
    await Clipboard.setData(ClipboardData(text: text));
    if (messenger == null) return;
    showOn(messenger, confirmation, tone: HermesSnackTone.success);
  }

  /// Copia sin confirmar (la confirmación ya la da el propio aviso de error).
  static void unawaitedCopy(String text) {
    Clipboard.setData(ClipboardData(text: text));
  }
}

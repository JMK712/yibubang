import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/shortcut_config.dart';
import 'app_fullscreen_shortcut.dart';

bool runGlobalShortcut(BuildContext context, ShortcutAction action) {
  if (action == ShortcutAction.toggleFullscreen) {
    return AppFullscreenShortcut.toggleOf(context);
  }
  if (action == ShortcutAction.goBack) {
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return false;
    unawaited(navigator.maybePop());
    return true;
  }
  return false;
}

bool _matches(ShortcutAction action, KeyEvent event) =>
    ShortcutConfig.bindingsFor(
      action,
    ).any((binding) => binding.matches(event.logicalKey));

bool _isTyping() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context?.widget is EditableText ||
      context?.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// 放在 Navigator 外层，让弹窗和页面内部的按键处理优先执行。
class AppBackShortcut extends StatelessWidget {
  const AppBackShortcut({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || !_matches(ShortcutAction.goBack, event)) {
        return KeyEventResult.ignored;
      }
      // 自定义为普通文字键时不抢占输入；Esc 在输入框中仍可返回。
      if (_isTyping() &&
          event.logicalKey.keyLabel.length == 1 &&
          !HardwareKeyboard.instance.isControlPressed &&
          !HardwareKeyboard.instance.isAltPressed &&
          !HardwareKeyboard.instance.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      final navigator = navigatorKey.currentState;
      if (navigator == null || !navigator.canPop()) {
        return KeyEventResult.ignored;
      }
      unawaited(navigator.maybePop());
      return KeyEventResult.handled;
    },
    child: child,
  );
}

class HomeTabShortcuts extends StatelessWidget {
  const HomeTabShortcuts({
    super.key,
    required this.onSelected,
    required this.child,
  });

  final ValueChanged<int> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent ||
          ModalRoute.of(context)?.isCurrent != true ||
          _isTyping()) {
        return KeyEventResult.ignored;
      }
      const actions = [
        ShortcutAction.homeCourses,
        ShortcutAction.homeStatistics,
        ShortcutAction.homeMyPage,
      ];
      for (final action in ShortcutConfig.actionsByPriority) {
        if (!_matches(action, event)) continue;
        final index = actions.indexOf(action);
        if (index >= 0) {
          onSelected(index);
          return KeyEventResult.handled;
        }
        if (runGlobalShortcut(context, action)) return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}

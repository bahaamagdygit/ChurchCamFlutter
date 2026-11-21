import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'tokens.dart';

/// Round icon control that floats over the viewfinder (tool rail, top bar).
/// 48dp touch target; "on" fills with the accent (or [activeColor]) and swaps
/// to the icon's filled variant so state reads at a glance, not by colour alone.
class ToolButton extends StatelessWidget {
  final IconData icon;
  final IconData? activeIcon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;
  final double size;
  final Widget? badge;

  const ToolButton({
    super.key,
    required this.icon,
    required this.label,
    this.activeIcon,
    this.active = false,
    this.activeColor = C.accent,
    this.onTap,
    this.size = S.touch,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled ? C.textFaint : (active ? C.accentInk : C.text);
    return Semantics(
      button: true,
      toggled: active,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          onTap: enabled ? () { HapticFeedback.selectionClick(); onTap!(); } : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: active ? activeColor : C.scrim,
              shape: BoxShape.circle,
              border: Border.all(color: active ? activeColor : C.hairline),
            ),
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              PhosphorIcon(active ? (activeIcon ?? icon) : icon, color: fg, size: size * 0.46),
              if (badge != null) Positioned(right: -2, top: -2, child: badge!),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Small rounded-rect status chip for the top HUD.
class HudChip extends StatelessWidget {
  final Widget child;
  final Color? color;
  final Color? borderColor;
  const HudChip({super.key, required this.child, this.color, this.borderColor});

  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color ?? C.scrim,
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(color: borderColor ?? C.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [child]),
      );
}

/// Selectable chip used for presets, shot sizes, transitions.
class Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color selectedColor;
  const Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.selectedColor = C.accent,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? C.accentInk : C.text;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: () { HapticFeedback.selectionClick(); onTap(); },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? selectedColor : C.surface2,
            borderRadius: BorderRadius.circular(R.pill),
            border: Border.all(color: selected ? selectedColor : C.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[PhosphorIcon(icon!, size: 16, color: fg), const SizedBox(width: 6)],
            Text(label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// Section header inside a panel.
class PanelSection extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;
  const PanelSection({super.key, required this.title, required this.children, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: S.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title.toUpperCase(), style: T.overline)),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: S.md),
          ...children,
        ]),
      );
}

/// A full-width row inside a panel: icon, title, optional subtitle, trailing.
class PanelTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool highlighted;
  final Color highlightColor;
  const PanelTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.highlighted = false,
    this.highlightColor = C.accent,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: S.sm),
        child: Material(
          color: highlighted ? highlightColor.withValues(alpha: 0.16) : C.surface2,
          borderRadius: BorderRadius.circular(R.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(R.md),
            onTap: onTap == null ? null : () { HapticFeedback.selectionClick(); onTap!(); },
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: S.md, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(R.md),
                border: Border.all(color: highlighted ? highlightColor : C.border, width: highlighted ? 1.5 : 1),
              ),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: highlighted ? highlightColor : C.surface3,
                    borderRadius: BorderRadius.circular(R.sm),
                  ),
                  child: PhosphorIcon(icon, size: 19, color: highlighted ? Colors.white : C.text),
                ),
                const SizedBox(width: S.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption),
                    ],
                  ]),
                ),
                if (trailing != null) ...[const SizedBox(width: S.sm), trailing!],
              ]),
            ),
          ),
        ),
      );
}

/// Labelled slider row with a live value readout.
class ValueSlider extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value, min, max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final double? neutral;
  const ValueSlider({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.format,
    this.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final changed = neutral != null && (value - neutral!).abs() > 0.05;
    // Label + value on top, full-width slider below: a narrow side panel
    // otherwise leaves the track too short to set values precisely.
    return Padding(
      padding: const EdgeInsets.only(bottom: S.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          PhosphorIcon(icon, size: 18, color: changed ? C.accent : C.textDim),
          const SizedBox(width: S.sm),
          Expanded(child: Text(label, style: T.label.copyWith(fontSize: 13))),
          // Tap the value to snap back to neutral.
          Semantics(
            button: neutral != null,
            label: neutral != null ? 'Reset $label' : null,
            child: GestureDetector(
              onTap: neutral == null ? null : () => onChanged(neutral!),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: changed ? C.accentSoft : C.surface2, borderRadius: BorderRadius.circular(R.pill)),
                child: Text(format(value), style: T.hud.copyWith(color: changed ? C.accent : C.textDim)),
              ),
            ),
          ),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(overlayShape: const RoundSliderOverlayShape(overlayRadius: 18)),
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
        ),
      ]),
    );
  }
}

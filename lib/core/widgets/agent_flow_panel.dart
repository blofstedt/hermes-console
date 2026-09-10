// Panel colapsable "Agent Flow": timeline horizontal del turno activo con
// símbolos reales de flowchart (terminal/proceso/decisión/subproceso). Vive
// junto a `SubagentActivityCard`/`ThinkingTraceCard` en `chat_screen.dart`
// como resumen visual de alto nivel; esas tarjetas siguen siendo la vista de
// detalle. No dependency package: dibujado a mano con CustomPainter, igual
// que `_DictationBarsPainter` (chat_screen_composer.dart) o
// `jarvis_reactor_core.dart`.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/subagent_activity.dart' show SubagentUsage;
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../utils/agent_flow_builder.dart';
import '../utils/markdown_clipboard.dart';

class AgentFlowPanel extends StatefulWidget {
  final AgentFlowGraph graph;
  final bool turnActive;
  final ValueChanged<AgentFlowNode>? onNodeTap;

  const AgentFlowPanel({
    required this.graph,
    required this.turnActive,
    this.onNodeTap,
    super.key,
  });

  @override
  State<AgentFlowPanel> createState() => _AgentFlowPanelState();
}

class _AgentFlowPanelState extends State<AgentFlowPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _pulse;
  late final Animation<double> _pulseAlpha;
  String? _lastCurrentNodeId;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAlpha = Tween<double>(
      begin: 0.35,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    if (widget.turnActive) _pulse.repeat(reverse: true);
    _lastCurrentNodeId = widget.graph.currentNodeId;
  }

  @override
  void didUpdateWidget(covariant AgentFlowPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.turnActive) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating) {
      _pulse.stop();
    }
    final currentNodeId = widget.graph.currentNodeId;
    if (_expanded && currentNodeId != _lastCurrentNodeId) {
      _lastCurrentNodeId = currentNodeId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    } else {
      _lastCurrentNodeId = currentNodeId;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final id = widget.graph.currentNodeId;
    if (id == null) return;
    final layout = _AgentFlowLayout.compute(widget.graph);
    final rect = layout.rectFor(id);
    if (rect == null) return;
    final position = _scrollController.position;
    final target = (rect.center.dx - position.viewportDimension / 2).clamp(
      0.0,
      position.maxScrollExtent < 0 ? 0.0 : position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: Motion.duration(context, Motion.base),
      curve: Motion.enter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final graph = widget.graph;
    if (graph.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final current = graph.currentNodeId == null
        ? null
        : graph.nodeById(graph.currentNodeId!);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: strings.agentFlowPanelTitle,
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _shapeIcon(current?.shape),
                        size: 14,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          current?.label ?? strings.agentFlowPanelTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: Motion.duration(context, Motion.fast),
                        child: Icon(
                          Icons.expand_more,
                          size: 15,
                          color: colors.textDisabled,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: Motion.duration(context, Motion.base),
            curve: Motion.size,
            child: _expanded
                ? _buildCanvas(context, colors)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(BuildContext context, HermesThemeColors colors) {
    final layout = _AgentFlowLayout.compute(widget.graph);
    final height = layout.height.clamp(96.0, 220.0);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: SizedBox(
        height: height,
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _handleTap(details, layout),
            child: AnimatedBuilder(
              animation: _pulseAlpha,
              builder: (context, _) => CustomPaint(
                size: Size(layout.width, height),
                painter: _AgentFlowPainter(
                  layout: layout,
                  colors: colors,
                  currentNodeId: widget.graph.currentNodeId,
                  pulseAlpha: widget.turnActive ? _pulseAlpha.value : 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleTap(TapUpDetails details, _AgentFlowLayout layout) {
    final onTap = widget.onNodeTap;
    if (onTap == null) return;
    for (final entry in layout.rects) {
      if (entry.rect.contains(details.localPosition)) {
        onTap(entry.node);
        return;
      }
    }
  }

  IconData _shapeIcon(AgentFlowNodeShape? shape) => switch (shape) {
    AgentFlowNodeShape.terminal => Icons.flag_outlined,
    AgentFlowNodeShape.decision => Icons.alt_route,
    AgentFlowNodeShape.subroutine => Icons.account_tree_outlined,
    AgentFlowNodeShape.process || null => Icons.bolt_outlined,
  };
}

/// Muestra el detalle de un nodo tocado (vista previa/razonamiento, duración,
/// uso). Toda la información ya viene resuelta en el nodo — sin fetch nuevo.
Future<void> showAgentFlowNodeDetail(
  BuildContext context,
  AgentFlowNode node,
) {
  final colors = Theme.of(context).hermes;
  final strings = Strings.of(context);
  final isSubagentThinking =
      node.shape == AgentFlowNodeShape.subroutine &&
      node.previewText != null &&
      node.previewText!.isNotEmpty;
  final previewLabel = isSubagentThinking
      ? strings.agentFlowDetailReasoning
      : strings.agentFlowDetailPreview;

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        node.label,
        style: TextStyle(color: colors.textPrimary, fontSize: 15),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (node.previewText != null && node.previewText!.isNotEmpty) ...[
              Text(
                previewLabel,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                markdownToCompactText(node.previewText!),
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (node.detail != null && node.detail!.isNotEmpty) ...[
              Text(
                markdownToCompactText(node.detail!),
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
            ],
            if (node.durationSeconds != null)
              Text(
                '${strings.agentFlowDetailDuration}: '
                '${node.durationSeconds!.toStringAsFixed(1)}s',
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            if (node.usage != null && !node.usage!.isEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _usageSummary(node.usage!, strings),
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(strings.commonClose),
        ),
      ],
    ),
  );
}

String _usageSummary(SubagentUsage usage, Strings strings) {
  final parts = <String>[];
  if (usage.inputTokens != null) {
    parts.add('${strings.agentFlowDetailTokensIn} ${usage.inputTokens}');
  }
  if (usage.outputTokens != null) {
    parts.add('${strings.agentFlowDetailTokensOut} ${usage.outputTokens}');
  }
  if (usage.costUsd != null) {
    parts.add(
      '${strings.agentFlowDetailCost} \$${usage.costUsd!.toStringAsFixed(4)}',
    );
  }
  return parts.join(' · ');
}

class _NodeRect {
  final AgentFlowNode node;
  final Rect rect;

  const _NodeRect(this.node, this.rect);
}

class _AgentFlowLayout {
  static const double nodeWidth = 92;
  static const double spineNodeHeight = 44;
  static const double laneNodeHeight = 38;
  static const double hGap = 30;
  static const double laneGap = 14;
  static const double leftPad = 14;
  static const double topPad = 30;

  final List<_NodeRect> rects;
  final List<AgentFlowEdge> edges;
  final double width;
  final double height;

  const _AgentFlowLayout({
    required this.rects,
    required this.edges,
    required this.width,
    required this.height,
  });

  Rect? rectFor(String id) {
    for (final entry in rects) {
      if (entry.node.id == id) return entry.rect;
    }
    return null;
  }

  factory _AgentFlowLayout.compute(AgentFlowGraph graph) {
    final rects = <_NodeRect>[];
    var spineX = leftPad;
    var lastSpineX = leftPad;
    var maxLane = 0;

    for (final node in graph.nodes) {
      if (node.laneIndex == 0) {
        final rect = Rect.fromLTWH(
          spineX,
          topPad,
          nodeWidth,
          spineNodeHeight,
        );
        rects.add(_NodeRect(node, rect));
        lastSpineX = spineX;
        spineX += nodeWidth + hGap;
      } else {
        if (node.laneIndex > maxLane) maxLane = node.laneIndex;
        final laneY =
            topPad +
            spineNodeHeight +
            laneGap +
            (node.laneIndex - 1) * (laneNodeHeight + laneGap);
        final rect = Rect.fromLTWH(
          lastSpineX,
          laneY,
          nodeWidth,
          laneNodeHeight,
        );
        rects.add(_NodeRect(node, rect));
      }
    }

    final width = rects.isEmpty ? 0.0 : (spineX - hGap + leftPad);
    final height =
        topPad +
        spineNodeHeight +
        laneGap +
        maxLane * (laneNodeHeight + laneGap) +
        leftPad;

    return _AgentFlowLayout(
      rects: rects,
      edges: graph.edges,
      width: width,
      height: height,
    );
  }
}

class _AgentFlowPainter extends CustomPainter {
  final _AgentFlowLayout layout;
  final HermesThemeColors colors;
  final String? currentNodeId;
  final double pulseAlpha;

  _AgentFlowPainter({
    required this.layout,
    required this.colors,
    required this.currentNodeId,
    required this.pulseAlpha,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = colors.divider.withValues(alpha: 0.6)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    for (final edge in layout.edges) {
      final from = layout.rectFor(edge.fromId);
      final to = layout.rectFor(edge.toId);
      if (from == null || to == null) continue;
      _drawEdge(canvas, edgePaint, from, to);
    }

    for (final entry in layout.rects) {
      _drawNode(canvas, entry);
    }
  }

  void _drawEdge(Canvas canvas, Paint paint, Rect from, Rect to) {
    final sameRow = (from.center.dy - to.center.dy).abs() < 0.5;
    final start = sameRow
        ? Offset(from.right, from.center.dy)
        : Offset(from.center.dx, from.bottom);
    final end = sameRow
        ? Offset(to.left, to.center.dy)
        : Offset(to.center.dx, to.top);
    canvas.drawLine(start, end, paint);
    _drawArrowhead(canvas, paint, start, end);
  }

  void _drawArrowhead(Canvas canvas, Paint paint, Offset start, Offset end) {
    if (start == end) return;
    final angle = (end - start).direction;
    const arrowLength = 6.0;
    const arrowAngle = 0.5;
    final p1 = end - Offset.fromDirection(angle - arrowAngle, arrowLength);
    final p2 = end - Offset.fromDirection(angle + arrowAngle, arrowLength);
    final path = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(p1.dx, p1.dy)
      ..moveTo(end.dx, end.dy)
      ..lineTo(p2.dx, p2.dy);
    canvas.drawPath(path, paint);
  }

  void _drawNode(Canvas canvas, _NodeRect entry) {
    final node = entry.node;
    final rect = entry.rect;
    final isCurrent = node.id == currentNodeId;
    final baseColor = _phaseColor(node.phase);
    final alpha = pulseAlpha.clamp(0.35, 1.0);
    final fillPaint = Paint()
      ..color = baseColor.withValues(alpha: isCurrent ? 0.22 * alpha : 0.12)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = baseColor.withValues(alpha: isCurrent ? alpha : 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isCurrent ? 2.2 : 1.4;

    switch (node.shape) {
      case AgentFlowNodeShape.terminal:
        final rrect = RRect.fromRectAndRadius(
          rect,
          Radius.circular(rect.height / 2),
        );
        canvas.drawRRect(rrect, fillPaint);
        canvas.drawRRect(rrect, strokePaint);
      case AgentFlowNodeShape.process:
        final rrect = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(8),
        );
        canvas.drawRRect(rrect, fillPaint);
        canvas.drawRRect(rrect, strokePaint);
      case AgentFlowNodeShape.decision:
        final path = Path()
          ..moveTo(rect.left, rect.center.dy)
          ..lineTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..close();
        canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, strokePaint);
      case AgentFlowNodeShape.subroutine:
        final rrect = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(6),
        );
        canvas.drawRRect(rrect, fillPaint);
        canvas.drawRRect(rrect, strokePaint);
        const inset = 6.0;
        canvas.drawLine(
          Offset(rect.left + inset, rect.top),
          Offset(rect.left + inset, rect.bottom),
          strokePaint,
        );
        canvas.drawLine(
          Offset(rect.right - inset, rect.top),
          Offset(rect.right - inset, rect.bottom),
          strokePaint,
        );
    }

    _drawLabel(canvas, rect, node.label, node.shape == AgentFlowNodeShape.decision);
  }

  Color _phaseColor(AgentFlowNodePhase phase) => switch (phase) {
    AgentFlowNodePhase.pending => colors.textDisabled,
    AgentFlowNodePhase.active => colors.accent,
    AgentFlowNodePhase.done => colors.success,
    AgentFlowNodePhase.error => colors.error,
  };

  void _drawLabel(Canvas canvas, Rect rect, String label, bool isDiamond) {
    final maxWidth = (isDiamond ? rect.width * 0.6 : rect.width - 10).clamp(
      1.0,
      rect.width,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 10,
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
      textAlign: TextAlign.center,
    )..layout(maxWidth: maxWidth);
    final offset = Offset(
      rect.center.dx - painter.width / 2,
      rect.center.dy - painter.height / 2,
    );
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _AgentFlowPainter oldDelegate) {
    return !identical(oldDelegate.layout, layout) ||
        oldDelegate.currentNodeId != currentNodeId ||
        oldDelegate.pulseAlpha != pulseAlpha;
  }
}

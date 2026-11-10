import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass.dart';
import '../../services/backend/backend_service.dart';
import '../assistant/widgets/iris_logo.dart';

const _loading = Center(child: IrisLogo(size: 72, state: IrisState.thinking, glow: true));

Widget _message(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 17, height: 1.4)),
      ),
    );

const _weekdays = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const _months = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre',
    'octubre', 'noviembre', 'diciembre'];

String _dayName(DateTime day) {
  final today = DateTime.now();
  final d = DateTime(day.year, day.month, day.day);
  final diff = DateTime(today.year, today.month, today.day).difference(d).inDays;
  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Ayer';
  return '${_weekdays[d.weekday - 1]} ${d.day} de ${_months[d.month - 1]}';
}

/// Historial: un dia por fila con su diario (o el resumen de hoy); al tocarlo, la conversacion completa.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final Future<List<MemoryDay>> _days = BackendService.instance.memoryDays();

  @override
  Widget build(BuildContext context) {
    return IrisPage(
      title: 'Mi historial',
      child: FutureBuilder<List<MemoryDay>>(
        future: _days,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return _loading;
          final days = snapshot.data ?? const [];
          if (snapshot.hasError) return _message('No se pudo cargar el historial.');
          if (days.isEmpty) return _message('Todavía no hay conversaciones guardadas.');
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: days.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final day = days[i];
              final text = (day.diary ?? day.summary).replaceAll(RegExp(r'[#*]'), '').trim();
              return GlassCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(18, 10, 12, 12),
                  title: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(_dayName(day.day),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppTheme.textOnDark)),
                  ),
                  subtitle: Text(text.isEmpty ? 'Sin resumen todavía' : text,
                      maxLines: 4, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right, color: AppTheme.textFaint),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _DayScreen(day: day))),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _DayScreen extends StatelessWidget {
  const _DayScreen({required this.day});

  final MemoryDay day;

  @override
  Widget build(BuildContext context) {
    return IrisPage(
      title: _dayName(day.day),
      child: FutureBuilder<List<MemoryMessage>>(
        future: BackendService.instance.memoryMessages(day.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return _loading;
          final messages = snapshot.data ?? const [];
          if (messages.isEmpty) {
            // Los mensajes viejos se borran (retencion); queda el diario.
            final diary = (day.diary ?? day.summary).replaceAll(RegExp(r'[#*]'), '').trim();
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: GlassCard(
                child: Text(diary.isEmpty ? 'No quedan mensajes de este día.' : diary,
                    style: const TextStyle(fontSize: 18, height: 1.45, color: AppTheme.textOnDark)),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: messages.length,
            itemBuilder: (context, i) {
              final m = messages[i];
              final time = '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}';
              return Semantics(
                label: '${m.fromUser ? 'Tú' : 'Iris'}, a las $time: ${m.text}',
                excludeSemantics: true,
                child: Align(
                  alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    decoration: BoxDecoration(
                      // Tu: cian; Iris: vidrio.
                      color: m.fromUser ? AppTheme.accentCyan.withValues(alpha: 0.20) : AppTheme.glassFill,
                      border: Border.all(
                        color: m.fromUser ? AppTheme.accentCyan.withValues(alpha: 0.55) : AppTheme.glassBorder,
                      ),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(m.fromUser ? 18 : 4),
                        bottomRight: Radius.circular(m.fromUser ? 4 : 18),
                      ),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.text, style: const TextStyle(fontSize: 17, height: 1.4, color: AppTheme.textOnDark)),
                      const SizedBox(height: 4),
                      Text(time, style: AppTheme.mono.copyWith(fontSize: 11, letterSpacing: 1, color: AppTheme.textFaint)),
                    ]),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

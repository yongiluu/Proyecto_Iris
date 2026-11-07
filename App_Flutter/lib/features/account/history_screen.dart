import 'package:flutter/material.dart';

import '../../services/backend/backend_service.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('Mi historial')),
      body: FutureBuilder<List<MemoryDay>>(
        future: _days,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final days = snapshot.data ?? const [];
          if (snapshot.hasError) return const Center(child: Text('No se pudo cargar el historial.'));
          if (days.isEmpty) return const Center(child: Text('Todavía no hay conversaciones guardadas.'));
          return ListView.separated(
            itemCount: days.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final day = days[i];
              final text = (day.diary ?? day.summary).replaceAll(RegExp(r'[#*]'), '').trim();
              return ListTile(
                title: Text(_dayName(day.day), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                subtitle: Text(text.isEmpty ? 'Sin resumen todavía' : text, maxLines: 4, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => _DayScreen(day: day))),
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
    return Scaffold(
      appBar: AppBar(title: Text(_dayName(day.day))),
      body: FutureBuilder<List<MemoryMessage>>(
        future: BackendService.instance.memoryMessages(day.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final messages = snapshot.data ?? const [];
          if (messages.isEmpty) {
            // Los mensajes viejos se borran (retencion); queda el diario.
            final diary = (day.diary ?? day.summary).replaceAll(RegExp(r'[#*]'), '').trim();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text(diary.isEmpty ? 'No quedan mensajes de este día.' : diary, style: const TextStyle(fontSize: 18)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
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
                      color: m.fromUser ? const Color(0xFFB2EBF2) : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.text, style: const TextStyle(fontSize: 17)),
                      const SizedBox(height: 4),
                      Text(time, style: const TextStyle(fontSize: 12, color: Colors.black54)),
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

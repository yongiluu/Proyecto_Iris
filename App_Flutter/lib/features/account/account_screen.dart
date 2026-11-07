import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../core/theme/app_theme.dart';
import '../../services/backend/backend_service.dart';
import '../data_collection/training_upload_queue.dart';
import 'history_screen.dart';

/// Mi cuenta: memoria, acompañantes y privacidad. Todo con controles grandes y legibles por TalkBack.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _backend = BackendService.instance;
  Map<String, dynamic>? _prefs;
  List<Companion> _companions = const [];
  bool _loading = true;

  static const _retentionOptions = {30: '30 días', 90: '3 meses', 365: '1 año'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await _backend.loadPreferences();
    List<Companion> companions = const [];
    try {
      companions = await _backend.companions();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _companions = companions;
      _loading = false;
    });
  }

  Future<void> _setPref(String key, Object value) async {
    setState(() => _prefs = {...?_prefs, key: value});
    await _backend.savePreferences({key: value});
  }

  void _announce(String message) {
    SemanticsService.sendAnnouncement(View.of(context), message, TextDirection.ltr);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _invite() async {
    try {
      final code = await _backend.createCompanionInvite();
      if (!mounted) return;
      final spaced = code.split('').join(' ');
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Código para tu acompañante'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Semantics(
              label: 'Código: $spaced',
              child: ExcludeSemantics(
                child: Text(code, style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold, letterSpacing: 6)),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Díctale este código. Tu acompañante lo ingresa en su app, en "Soy acompañante". Vale 24 horas.'),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Listo'))],
        ),
      );
    } catch (_) {
      _announce('No se pudo crear el código. Revisa tu conexión.');
    }
  }

  Future<void> _acceptCode() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Soy acompañante'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          style: const TextStyle(fontSize: 28, letterSpacing: 4),
          decoration: const InputDecoration(labelText: 'Código de 6 dígitos'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Vincular')),
        ],
      ),
    );
    if (code == null || code.trim().length != 6) return;
    final error = await _backend.acceptCompanionInvite(code);
    _announce(error ?? 'Listo: quedaste vinculado como acompañante.');
    if (error == null) _load();
  }

  Future<void> _deleteMemory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Borrar toda tu memoria?'),
        content: const Text('Iris olvidará todas tus conversaciones y diarios. No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.dangerRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Borrar todo'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _backend.deleteAllMemory();
      _announce('Memoria borrada.');
    } catch (_) {
      _announce('No se pudo borrar. Revisa tu conexión.');
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Semantics(
          header: true,
          child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs ?? const {};
    final memoryOn = prefs['memory_enabled'] as bool? ?? true;
    final retention = prefs['message_retention_days'] as int? ?? 30;
    final assisting = _companions.where((c) => c.iAmCompanion).toList();
    final myCompanions = _companions.where((c) => !c.iAmCompanion).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Mi cuenta')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.person, size: 32),
                  title: Text(_backend.displayName ?? 'Sin nombre', style: const TextStyle(fontSize: 20)),
                  subtitle: Text(_backend.user?.email ?? ''),
                ),

                _section('Memoria'),
                SwitchListTile(
                  title: const Text('Iris recuerda nuestras conversaciones'),
                  subtitle: const Text('Ejemplo: "¿qué desayuné hoy?" o "¿qué pasó ayer?"'),
                  value: memoryOn,
                  onChanged: (v) => _setPref('memory_enabled', v),
                ),
                ListTile(
                  title: const Text('Guardar las conversaciones por'),
                  trailing: DropdownButton<int>(
                    value: _retentionOptions.containsKey(retention) ? retention : 30,
                    items: [
                      for (final e in _retentionOptions.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => v == null ? null : _setPref('message_retention_days', v),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Ver mi historial'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: AppTheme.dangerRed),
                  title: const Text('Borrar toda mi memoria', style: TextStyle(color: AppTheme.dangerRed)),
                  onTap: _deleteMemory,
                ),

                _section('Acompañantes'),
                for (final c in myCompanions) ...[
                  ListTile(
                    leading: const Icon(Icons.favorite),
                    title: Text(c.name),
                    subtitle: const Text('Te acompaña'),
                    trailing: IconButton(
                      tooltip: 'Quitar a ${c.name}',
                      icon: const Icon(Icons.link_off),
                      onPressed: () async {
                        await _backend.removeCompanion(c.linkId);
                        _load();
                      },
                    ),
                  ),
                  SwitchListTile(
                    title: Text('${c.name} ve mis alertas'),
                    value: c.canSeeAlerts,
                    onChanged: (v) async {
                      await _backend.setCompanionPermissions(c.linkId, alerts: v);
                      _load();
                    },
                  ),
                  SwitchListTile(
                    title: Text('${c.name} ve mi ubicación'),
                    value: c.canSeeLocation,
                    onChanged: (v) async {
                      await _backend.setCompanionPermissions(c.linkId, location: v);
                      _load();
                    },
                  ),
                ],
                for (final c in assisting)
                  ListTile(
                    leading: const Icon(Icons.volunteer_activism),
                    title: Text(c.name),
                    subtitle: const Text('Tú la acompañas'),
                  ),
                ListTile(
                  leading: const Icon(Icons.person_add),
                  title: const Text('Invitar a un acompañante'),
                  subtitle: const Text('Un familiar o profesional que reciba tus alertas'),
                  onTap: _invite,
                ),
                ListTile(
                  leading: const Icon(Icons.pin),
                  title: const Text('Soy acompañante: ingresar código'),
                  onTap: _acceptCode,
                ),

                _section('Privacidad'),
                SwitchListTile(
                  title: const Text('Compartir mi ubicación con mis acompañantes'),
                  subtitle: const Text('Solo con quienes tengan ese permiso activado'),
                  value: prefs['share_location_with_companions'] as bool? ?? false,
                  onChanged: (v) => _setPref('share_location_with_companions', v),
                ),
                SwitchListTile(
                  title: const Text('Donar mis grabaciones para mejorar Iris'),
                  subtitle: const Text('Las misiones de datos se suben para entrenar los modelos de la placa'),
                  value: prefs['training_data_consent'] as bool? ?? false,
                  onChanged: (v) async {
                    await _setPref('training_data_consent', v);
                    await TrainingUploadQueue.instance.consentChanged(v);
                  },
                ),

                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    icon: const Icon(Icons.logout),
                    label: const Text('Cerrar sesión', style: TextStyle(fontSize: 18)),
                    onPressed: () async {
                      await _backend.signOut();
                      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                    },
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

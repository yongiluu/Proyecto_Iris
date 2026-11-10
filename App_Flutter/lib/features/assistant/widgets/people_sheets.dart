import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Pide el nombre de la persona a guardar. Devuelve el nombre o null si se cancela.
/// Guardar la cara de otra persona es sobre un tercero: se recuerda pedirle permiso.
Future<String?> askPersonName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final name = controller.text.trim();
        if (name.isNotEmpty) Navigator.pop(context, name);
      }

      return AlertDialog(
        backgroundColor: AppTheme.inkRaised,
        title: Text('Agregar persona', style: TextStyle(color: AppTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: TextStyle(color: AppTheme.text, fontSize: 18),
              decoration: InputDecoration(
                labelText: 'Nombre',
                hintText: 'Ej. Raul',
                labelStyle: TextStyle(color: AppTheme.textMuted),
                hintStyle: TextStyle(color: AppTheme.textFaint),
              ),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 12),
            Text(
              'Pidele permiso antes de guardar su cara. Se guarda solo en este celular, nada sale de aqui.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 14, height: 1.3),
            ),
            const SizedBox(height: 6),
            Text(
              'Voy a sacar 5 fotos y te ire guiando por voz.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 14, height: 1.3),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar', style: TextStyle(color: AppTheme.accentCyan)),
          ),
          TextButton(
            onPressed: submit,
            child: Text('Empezar', style: TextStyle(color: AppTheme.accentCyan, fontWeight: FontWeight.w700)),
          ),
        ],
      );
    },
  );
}

/// Lista de personas guardadas, con boton para borrar cada una (pide confirmacion).
class PeopleListSheet extends StatefulWidget {
  const PeopleListSheet({
    super.key,
    required this.names,
    required this.samplesOf,
    required this.onForget,
  });

  final List<String> names;
  final int Function(String name) samplesOf;
  final Future<void> Function(String name) onForget;

  @override
  State<PeopleListSheet> createState() => _PeopleListSheetState();
}

class _PeopleListSheetState extends State<PeopleListSheet> {
  late final List<String> _names = [...widget.names];

  Future<void> _confirmForget(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.inkRaised,
        title: Text('¿Olvidar a $name?', style: TextStyle(color: AppTheme.text)),
        content: Text('Se borra su cara de este celular. No se puede deshacer.',
            style: TextStyle(color: AppTheme.textMuted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar', style: TextStyle(color: AppTheme.accentCyan)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Olvidar', style: TextStyle(color: AppTheme.listeningRed, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onForget(name);
    if (mounted) setState(() => _names.remove(name));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text('Personas guardadas',
                  style: TextStyle(color: AppTheme.text, fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 4),
            Text('Solo en este celular. Tambien puedes decir: "Oye Iris, olvida a" y el nombre.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 14)),
            const SizedBox(height: 8),
            if (_names.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text('Todavia no hay nadie. Usa "Agregar persona" o di: "Oye Iris, recuerda a" y el nombre.',
                    style: TextStyle(color: AppTheme.text, fontSize: 16)),
              ),
            for (final name in _names)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: 52,
                leading: Icon(Icons.person, color: AppTheme.accentCyan),
                title: Text(name, style: TextStyle(color: AppTheme.text, fontSize: 18)),
                subtitle: Text('${widget.samplesOf(name)} fotos',
                    style: TextStyle(color: AppTheme.textMuted)),
                trailing: IconButton(
                  tooltip: 'Olvidar a $name',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: Icon(Icons.delete_outline, color: AppTheme.textMuted),
                  onPressed: () => _confirmForget(name),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

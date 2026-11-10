# Capturas de la app

Se generan con los widgets reales y datos fijos (sin servicios ni teléfono):

```bash
flutter test test/capturas_test.dart --dart-define=IRIS_CAPTURAS=true
```

- `*.png`: apariencia oscura. `claro/*.png`: apariencia clara.
- `animaciones/*.gif`: arranque y la secuencia escucha → piensa → responde, en ambas apariencias.

El comando deja los cuadros de las animaciones en `build/capturas_cuadros/<nombre>/`. Para armar
cada GIF (con ffmpeg):

```bash
ffmpeg -y -framerate 20 -i build/capturas_cuadros/estados/%03d.png -vf "fps=14,scale=280:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" docs/capturas/animaciones/estados.gif
```

El "fondo de cámara" de las capturas es un degradado de ejemplo: en el celular real es la cámara
en vivo. Las letras monoespaciadas usan la fuente del computador donde se generan; en Android se
ven con la monoespaciada del sistema.

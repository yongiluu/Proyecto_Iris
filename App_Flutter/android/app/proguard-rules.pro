# ML Kit (lector de texto del celular): el plugin referencia los alfabetos chino, devanagari, japones y
# coreano, pero la app solo incluye el latino. Sin estas reglas R8 falla al compilar la version final.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

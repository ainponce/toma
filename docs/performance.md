# Mediciones de la fase 0

Lo que se mide de la grabación, la recuperación, el export y la vista previa antes de cerrar la fase 0. Las celdas **pendiente** las completa el dueño en su Mac, con los permisos de Grabación de pantalla y Micrófono dados a la Terminal:

```
bash scripts/stress-recovery.sh                         # disco interno
bash scripts/stress-recovery.sh /Volumes/<disco>/toma   # disco USB externo
```

El script compila `recorder-dev` en Release, graba la pantalla principal y el micrófono con contenido en movimiento, mide la memoria (RSS) del grabador a los 5, 15 y 30 min, lo mata con `kill -9` a los 30 min, recupera la toma y la verifica con `--min-duration 1798`. Al final imprime, por pista, la duración, `droppedFrames` y el `endReason` de cada segmento.

**Regla de decisión:** si en el disco externo se pierde más del 0,5 % de los cuadros de la pantalla, los volúmenes no internos graban con `fragmentInterval` de 2 s.

## Resistencia real (`stress-recovery.sh`)

| Medición | Disco interno | Disco USB externo |
|---|---|---|
| Fecha, Mac, macOS | pendiente | pendiente |
| RSS a los 5 min | pendiente | pendiente |
| RSS a los 15 min | pendiente | pendiente |
| RSS a los 30 min | pendiente | pendiente |
| `display-1`: duración recuperada | pendiente | pendiente |
| `display-1`: `droppedFrames` (% de los cuadros) | pendiente | pendiente |
| `mic`: duración recuperada | pendiente | pendiente |
| `mic`: `droppedFrames` | pendiente | pendiente |
| `endReason` de los segmentos | pendiente | pendiente |
| Advertencias (`trackLost`, `samplesDropped`, …) | pendiente | pendiente |
| `verify --min-duration 1798` | pendiente | pendiente |

## Export (Task 11)

| Medición | Valor |
|---|---|
| Velocidad de export a 1080p60 (segundos de video por segundo de reloj) | pendiente |

`stress-recovery.sh` cronometra `recorder-dev export` en cuanto el subcomando existe. Como `export` no tiene opción de rango, mide la toma recuperada entera (30 min), no solo sus primeros 10 min.

## Vista previa (Task 10)

| Medición | Valor |
|---|---|
| fps promedio de la vista previa (registro de Debug cada 5 s) | pendiente |

## Mediciones sintéticas

**No son la captura real.** Usan `recorder-dev synth-record`: ni ScreenCaptureKit ni el micrófono intervienen, y los cuadros sintéticos (un color liso y un cuadrado que se mueve) se comprimen mucho mejor que una pantalla real. Sirven para ver que la recuperación funciona y que la memoria no crece, no para estimar cuadros perdidos ni tamaño en disco.

Apple M5 Pro, macOS 26.6, Swift 6.4.2, disco interno, 13 de noviembre de 2026.

| Prueba | Resultado |
|---|---|
| `make crash-test` (Debug, 640×360 a 30 fps, `kill -9` a los 10 s), 19 corridas | Todas pasan. Pantalla en movimiento: `display-1` 10,00–10,01 s y `mic` 10,07 s recuperados (una vez `mic` 9,05 s: su último fragmento no llegó a escribirse, 0,95 s antes que la pantalla). Pantalla quieta desde los 2 s: `display-1` 9,40 s y `mic` 10,07 s. 0 cuadros perdidos en todas. |
| `synth-record` 640×360 a 30 fps (Debug), RSS | 38 MB a los 5, 10 y 20 s |
| `synth-record` 1920×1080 a 60 fps (Release), `kill -9` a los 91 s | RSS 44,8 MB a los 10 s, 45,2 MB a los 30 s, 45,3 MB a los 60 s y 45,4 MB a los 90 s; CPU ≈ 20 %. Recuperados `display-1` 91,00 s y `mic` 91,05 s, 0 cuadros perdidos; paquete de 42 MB. |
| `verify` de esa toma (Release) | 0,02 s; 0,08 s con `--max-drop-ratio` (cuenta los cuadros de los archivos) |

Lo legible de un segmento abierto, que es lo que la recuperación conserva tras un crash: video y audio grabados en tiempo real se pueden leer hasta su último fragmento de 1 s; en una prueba de audio en tiempo real, lo legible fue 1,02 s a los 1,6 s de audio y después siguió a 1–2 s de lo grabado. Un segmento que lleva menos de eso cuando la app muere queda `empty` o `unreadable` (el archivo se conserva). Escrito sin tiempo real, como en las pruebas, un archivo ALAC no tiene encabezado legible hasta los ~3 s de audio.

## Prueba opcional de reinicio

Comprueba que un corte sin vaciar la caché del sistema de archivos conserva la toma. Va a `docs/release.md` cuando exista (Task 13).

1. `caffeinate -dimsu -t 1000 &` y, en la misma Terminal, `recorder-dev record <carpeta> --duration 900 > out &`; la primera línea de `out` es la ruta del paquete.
2. A los 300 s: `sudo reboot -q -n` (reinicia sin vaciar la caché de disco).
3. Después del arranque: `recorder-dev recover <carpeta>` y `recorder-dev verify <paquete> --min-duration 290`.
4. Anotar aquí la duración recuperada de cada pista y su `endReason`.

| Medición | Valor |
|---|---|
| Fecha, Mac, macOS | pendiente |
| Duración recuperada por pista | pendiente |
| `verify --min-duration 290` | pendiente |

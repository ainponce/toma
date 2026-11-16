# Mediciones de la fase 0

Lo que se mide de la grabación, la recuperación, el export y la vista previa antes de cerrar la fase 0. Las celdas **pendiente** las completa el dueño en su Mac, con los permisos de Grabación de pantalla y Micrófono dados a la Terminal:

```
bash scripts/stress-recovery.sh                         # disco interno
bash scripts/stress-recovery.sh /Volumes/<disco>/toma   # disco USB externo
```

El script compila `recorder-dev` en Release, graba la pantalla principal y el micrófono con contenido en movimiento, mide la memoria (RSS) del grabador a los 5, 15 y 30 min, lo mata con `kill -9` a los 30 min, recupera la toma y la verifica con `--min-duration 1798`. Al final imprime, por pista, la duración, `droppedFrames` y el `endReason` de cada segmento. **Falla** si la memoria crece (RSS a los 30 min > RSS a los 5 min + 50 MB: el objetivo de memoria acotada del spec §9), si una pista se perdió o dejó de grabar (`trackLost`, `trackPaused`, `displayPaused`), si no hay pista de micrófono o si `verify` falla. Mantiene la Mac despierta con `caffeinate -ims`, sin `-d` ni `-u`: es la propia toma la que no deja que la pantalla se apague, y el script lo comprueba así.

Después del `kill -9`, `droppedFrames` sale del último evento `droppedSamples` que el grabador escribió en `events.jsonl` (lo hace cada 2 s, si cambió): pueden faltar los cuadros perdidos en los últimos 2 s antes del corte. `verify` tolera que una pista de una toma recuperada termine hasta 2 s antes que otra (1 s en una toma cerrada por la app), porque cada pista se puede leer hasta su último fragmento completo de 1 s.

**Regla de decisión:** si en el disco externo se pierde más del 0,5 % de los cuadros de la pantalla, los volúmenes no internos graban con `fragmentInterval` de 2 s.

## Resistencia real (`stress-recovery.sh`)

| Medición | Disco interno | Disco USB externo |
|---|---|---|
| Fecha, Mac, macOS | pendiente | pendiente |
| RSS a los 5 min | pendiente | pendiente |
| RSS a los 15 min | pendiente | pendiente |
| RSS a los 30 min | pendiente | pendiente |
| RSS a los 30 min ≤ RSS a los 5 min + 50 MB (el script falla si no) | pendiente | pendiente |
| `display-1`: duración recuperada | pendiente | pendiente |
| `display-1`: `droppedFrames` (% de los cuadros) | pendiente | pendiente |
| `mic`: duración recuperada | pendiente | pendiente |
| `mic`: `droppedFrames` | pendiente | pendiente |
| `endReason` de los segmentos | pendiente | pendiente |
| Advertencias (`trackLost`, `trackPaused`, `displayPaused`, `samplesDropped`, …) | pendiente | pendiente |
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
| Salto en la vista previa del editor (scrub hacia atrás y de 2 s o más hacia adelante): ms del cuadro en el hilo principal | pendiente |

La vista previa decodifica en el hilo principal. El editor carga el proyecto y el primer segmento fuera de él, pero cada salto bloquea el hilo principal mientras decodifica desde el keyframe anterior. El editor registra cada cuadro que tarda más de 17 ms; para verlos, con el editor abierto y arrastrando la barra de tiempo:

```
log stream --level debug --predicate 'subsystem == "dev.toma.Toma" && category == "Preview"'
```

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

## Corrida de 3 h (spec §7.3.9)

El spec pide también una toma de 3 h. Con el mismo script y los tiempos alargados por variables de entorno:

```
DURATION=10800 KILL_AT=10500 MIN_DURATION=10490 RSS_AT="300 5400 10200" bash scripts/stress-recovery.sh
```

El criterio de memoria compara el primer RSS (5 min) con el último (2 h 50 min). Si el dueño decide postergarla, la postergación se escribe acá, con la fecha y el motivo, y la aprueba el dueño.

| Medición | Valor |
|---|---|
| Fecha, Mac, macOS | pendiente |
| RSS a los 5 min y a las 2 h 50 min | pendiente |
| Duración recuperada por pista | pendiente |
| `verify --min-duration 10490` | pendiente |
| Postergación aprobada por el dueño (si no se corre) | — |

## Prueba opcional de reinicio

Pasó a [`docs/release.md`](release.md#prueba-opcional-de-reinicio), con su tabla de resultados.

## Presupuesto del encoder (hito 1a)

`EncoderLoad` (Task 14) estima si el encoder de hardware da abasto con una toma: suma los píxeles por segundo de todas las pistas de video (ancho × alto × fps de cada pantalla, también la pantalla entera de un área, de la ventana y de la cámara) y los compara con `EncoderLoad.defaultBudgetPixelsPerSecond`, 800 000 000 píxeles/s. Desde el 80 % (`warnRatio`) la carga es alta y desde el 100 % pasada; en los dos casos la isla sugiere, en orden, bajar a 30 fps las pantallas que no son la principal, bajar la cámara a 1080p y bajarla a 30 fps. El presupuesto se puede cambiar sin compilar con la clave `encoderBudgetPixelsPerSecond` de los defaults de la app (`defaults write dev.toma.Toma encoderBudgetPixelsPerSecond -int <píxeles/s>`; la toma siguiente ya lo usa) y en el log de la app (subsistema `dev.toma.Toma`, categoría `Recording`) una toma con carga alta dice qué porcentaje del presupuesto usa.

Calibración (dueño, desde Terminal.app con los permisos de Grabación de pantalla, Micrófono y Cámara; los agentes no la corren):

1. `recorder-dev record <carpeta> --duration 300 --display <principal> --display <secundaria> --camera default` (60 fps, el valor por defecto de `--fps`), con las dos pantallas en movimiento (un video o una animación en cada una).
2. `recorder-dev verify <paquete> --max-drop-ratio 0.005`: anotar el porcentaje de cuadros perdidos de cada pista.
3. Anotar en la tabla la carga medida (la suma de ancho × alto × fps de las tres pistas, con el tamaño de cada segmento) y los cuadros perdidos. Si alguna pista supera el 0,5 %, un agente baja `defaultBudgetPixelsPerSecond` hasta la carga medida × 0,8 con lo anotado, y escribe el valor nuevo y por qué.

| Medición | Valor |
|---|---|
| Fecha, Mac, macOS | pendiente |
| Pantallas (píxeles y fps) y cámara (formato grabado) | pendiente |
| Carga medida (píxeles/s) | pendiente |
| Cuadros perdidos por pista (`verify --max-drop-ratio 0.005`) | pendiente |
| Presupuesto resultante | 800 000 000 (sin calibrar) |

## Medidas del agente (M5 Pro)

Esta Mac es el modelo de la del dueño (M5 Pro), así que las metas de esa columna de diseño §7.9 las mide un agente (Tasks 26, 30 y 31); al dueño le queda el piso M1. Puede haber pruebas de otros agentes corriendo en la misma Mac a la vez: cada medida dice la carga de ese momento.

### El zoom con desenfoque de movimiento a 4K (Task 26)

```
TOMA_BENCH=1 swift test --package-path Packages/RecorderKit --filter sixteenSubsamplesAt4KFitTheFrameBudget
```

Apple M5 Pro, macOS 26.6.2, 16 de noviembre de 2026, sobre `a1dbb5d` (el árbol de `hito-1b` en `7723be0`) con los cambios de Task 26 (el commit `feat(render): the zoom camera over the stage, with motion blur of the camera and the cursor`); Debug; carga de 4 a 9, dos corridas con los mismos números (±0,03 ms). Tiempo de GPU de cada cuadro (`gpuEndTime − gpuStartTime` de su command buffer), 120 cuadros seguidos después de 8 para calentar, cada uno esperado antes del siguiente. La escena: 3840 × 2160; la pantalla, una textura de 3840 × 2160 con mipmaps hechos en cada cuadro; el fondo de pantalla `aurora-1` (su malla en una textura del tamaño de la salida, como la da `FrameRenderer` bajo el desenfoque); sombra 0,6; marco de macOS con título; el cursor de Toma suavizado, rápido; los obturadores de la cámara y del cursor de un cuadro entero.

| Caso | Submuestras | p50 | p95 | Máximo | Meta |
|---|---|---|---|---|---|
| La cámara que nunca para: bloques de 0,25 s a profundidad 3 entre dos puntos lejanos | 16 en los 120 cuadros | 4,01 ms | 4,02 ms | 4,06 ms | p95 ≤ 16,7 ms |
| Entrar a un zoom desde el reposo (profundidad 1 → 2): el fondo y la sombra se ven alrededor de la ventana | 16 en los primeros ~50, después la cámara se queda quieta y es 1 | 0,47 ms | 4,06 ms | 7,63 ms | p95 ≤ 16,7 ms |

Cómo se llega:

- **Un solo pase de render** para todas las submuestras (diseño §7.2, revisión del plan I10): la submuestra (`.bgra8Unorm`) y la suma (`rgba16Float`) son adjuntos `memoryless` que viven en la memoria de los tiles; un dibujo de pantalla completa suma cada submuestra × 1/N leyendo `[[color(0)]]` y `[[color(1)]]` (mezcla programable) y otro escribe el promedio al destino. Entre submuestras no va nada a la memoria.
- **Lo que tapa la pantalla no se dibuja:** en cada submuestra, el fondo y la sombra se dibujan solo fuera de lo que la pantalla (con su ventana) cubre opaca, recortados con *scissor rects*: cada píxel dibujado es el mismo que sin recorte y uno opaco no deja ver lo de abajo, así que los bytes no cambian (`whatTheScreenHidesIsNotDrawnAndNothingShows`). Sin esto (medido con carga de 30 a 45), el mismo caso de la cámara que nunca para daba p50 39,4 ms, casi todo del fondo de pantalla calculado 16 veces (ver abajo) y de la sombra, unos 12 ms.
- **La malla del fondo de pantalla, una vez:** bajo el desenfoque, cada submuestra lee la malla de una textura del tamaño de la salida (la que ya se hace para un fondo de pantalla desenfocado) en lugar de calcularla otra vez en cada píxel. Calcularla 16 veces sobre toda la salida a 4K cuesta 22,5 ms de GPU (16 dibujos de `encodeWallpaper` en un command buffer, p50 de 30, carga 3); sin esto, el peor cuadro al entrar a un zoom era de 17,8 ms (con esto, 7,63 ms).
- **Una sola simulación por cuadro** para la cámara y el cursor de las submuestras (`ZoomCameraPath.span`, `CursorPath.span`): evaluar un cuadro desenfocado cuesta 0,027 ms en Release (0,57 ms en Debug), contra 0,365 ms (8,1 ms) simulando desde el punto de control para cada una de las 16 submuestras.

## Medidas del agente (M5 Pro), hito 1c

Las metas de la columna "La Mac del dueño (M5 Pro)" de diseño §15 del hito 1c, que mide un agente en esta Mac (el modelo de la del dueño); al dueño le queda el piso M1. Sección abierta por Task 8 el 16 de noviembre de 2026, Apple M5 Pro, macOS 26.6.2 (`sw_vers -productVersion`), sobre `864b5f7` (el árbol de `hito-1c`) con los cambios de Task 8 (`feat(analysis): the card zoom path inside a split screen`). Cada tarea suma una fila al final de la tabla con su fecha y su commit si cambian. Puede haber pruebas de otros agentes corriendo en la misma Mac a la vez: cada fila dice la carga (promedio de 1 min de `uptime`) de ese momento; Release salvo que la fila diga otra cosa.

| Tarea | Qué | Comando | Medida | Meta | Carga |
|---|---|---|---|---|---|
| 8 | Rearmar los caminos de una hora con `cardZoom` (`MotionPaths` entero, mediana de 5 después de uno para calentar): el puntero a 60 Hz sin parar, un clic cada 5 s, los 719 bloques de zoom automáticos sobre ellos (`follow`, 1,5 s cada uno: 30 % de la hora), una Dividida, cursor suavizado | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter rebuildingAnHourOfPathsFitsTheBudget` | **206 ms** (otra corrida: 196 ms), de los que `CardZoomPath` 87 ms (82 ms), `ZoomCameraPath` 82 ms (85 ms) y `CursorPath` 31 ms (31 ms): el camino de la tarjeta cuesta lo mismo que el del escenario, unos 40 ns por paso de 1/600 s. **No llega a la meta**: los caminos de 1b solos ya pasan de 110 ms por hora; la reconstrucción incremental desde el primer instante cambiado y el costo por paso son de 1b Task 31 | ≤ 30 ms | La primera, 7,5 al empezar y 38 al terminar (otras pruebas empezaron durante ella); la segunda, 38 |

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

### El export (Task 30)

```
swift build --package-path Packages/RecorderKit -c release --product recorder-dev
Packages/RecorderKit/.build/release/recorder-dev bench-export --synthetic                                 # 4K60
Packages/RecorderKit/.build/release/recorder-dev bench-export --synthetic --width 1920 --height 1080      # 1080p60
Packages/RecorderKit/.build/release/recorder-dev bench-export --synthetic --background-image              # 4K60, imagen de 7680 px
```

Apple M5 Pro, macOS 26.6.2, 16 de noviembre de 2026; Release; con los cambios de Task 30 sobre `e8e456e` (la rama de Task 27) y, después, sobre `6157f1d` (`hito-1b` con Task 27 unida): las cifras de los dos árboles son las mismas dentro de la dispersión. `bench-export --synthetic` graba una toma sintética de 10 s (`synth-record --camera`: la pantalla al tamaño pedido a 60 fps y una cámara de 1280 × 720 a 30 fps) y la exporta en otro proceso con el documento de las medidas, todo prendido: el fondo de pantalla `aurora-1`, sombra 0,6, el marco de macOS con título, la pantalla con mipmaps, el cursor suavizado con desenfoque de un cuadro entero, la cámara y una cámara del zoom que nunca para (bloques de 0,25 s a profundidad 3 entre dos puntos lejanos) con desenfoque de un cuadro entero: 16 submuestras en el 95 % de los cuadros (585 de 613; los demás, 15 o 10). La velocidad es segundos de video sobre segundos de export (de `MP4Exporter.export` entero: la mezcla de audio, el dibujo, el encoder y el archivo); la memoria, la huella física máxima del proceso que exporta (`ledger_phys_footprint_peak`: la de la GPU y los decodificadores incluida; el encoder H.264 trabaja en `VTEncoderXPCService`, otro proceso, y no cuenta). Entre paréntesis, la carga de la Mac (promedio de 1 min) al empezar cada corrida: había pruebas de otros agentes corriendo.

| Caso | Velocidad | Memoria máxima | Meta (diseño §7.9) |
|---|---|---|---|
| 4K60 (3840 × 2160), todo prendido | 1,17× (8), 1,19× (17), 1,01× (7), 1,19× (15) | 868 MB, 881 MB, 876 MB, 870 MB | ≥ 1×; < 1,5 GB |
| 1080p60 (1920 × 1080), todo prendido | 3,38× (8), 4,17× (13), 3,57× (33); 2,40× (12) y 2,01× (18) | 344 a 351 MB | ≥ 3× |
| 1080p60, la misma exportación de una toma ya grabada (`bench-export <toma> --all-on --width 1920 --height 1080`; 10 s y 40 s) | 3,70×, 3,19×, 2,99× (13); 3,36× con 40 s (13) | 347 a 352 MB | ≥ 3× |
| 4K60 con una imagen de 7680 × 4320 de fondo (en lugar del fondo de pantalla) | 1,15× (14), 1,14× (12) | 1 251 MB, 1 264 MB | < 1,5 GB |

**El encoder manda, y lo comparten todos los procesos.** El export dibuja muy por delante de lo que el H.264 codifica: con la Mac cargada, el dibujo solo, sin el encoder, iba a unos 220 cuadros por segundo a 4K, y en un perfil del export de 40 s a 1080p (`sample`) la cola del export pasa el 94 % del tiempo esperando un cuadro y el hilo del encoder el 85 % dentro de `VTCompressionSessionEncodeFrame`, la mitad de eso esperando que el motor de video tome otro cuadro. Ese motor es uno para toda la Mac: con otras pruebas grabando HEVC a la vez, la velocidad baja (las corridas de 2,0× a 2,4× a 1080p) y, si el motor no toma la sesión, VideoToolbox codifica en software (`VTEncoderXPCService` a más del 100 % de CPU): así dieron 0,04× a 4K con carga 33 a 58 y 0,20× y 0,16× a 1080p con carga 17 y 21. El export no exige el encoder de hardware (así codifica cada tamaño de la hoja, `everyExportSizeEncodes`), así que con el motor ocupado sigue, más lento. Las metas valen para la Mac del dueño sin otro trabajo de video: 4K60 las cumple en todas las corridas con el motor libre; 1080p60, en las de carga más baja, con dos por debajo de 3× mientras otras pruebas codificaban.

Cómo se llega:

- **En tubería** (diseño §7.9): el export deja hasta 3 cuadros dibujándose a la vez (`FrameRenderer.render(at:into:completion:)`, que encola y vuelve) y agrega a `AVAssetWriterInput`, en su cola y en orden, cada uno recién cuando la GPU lo terminó; mientras, el encoder trabaja con los de antes y el audio se mezcla. Cada pista de video tiene un `FramePrefetcher` que decodifica por adelantado, en su propia cola, los instantes de la fuente de los 8 cuadros siguientes de la grilla del export (no más de 300 MB por pista): un cuadro casi nunca espera al decodificador. Los bytes son los de dibujar de a un cuadro (`pipelinedExportGivesTheSameFramesAsSerial`).
- **La malla del fondo de pantalla bajo el desenfoque, también en el export** (Task 20, Task 26): el export dibuja por el mismo `FrameRenderer` que la vista previa, y su `backgroundTexture(of:images:outputSize:)` da, para un cuadro con submuestras, la malla en una textura del tamaño de la salida, hecha una vez, que cada submuestra lee. Calcularla 16 veces a 4K costaría 22,5 ms de GPU por cuadro (medida de Task 26), más que los 16,7 ms de un cuadro a 60 fps: con 16 submuestras en el 95 % de los cuadros, el export de arriba no llegaría a 1× sin eso.
- **Una imagen de fondo de 7680 px** (Task 21): el export hace un solo `FrameRenderer`, así que la imagen se decodifica una vez (unos 127 MB en la caché del proceso) y tiene una sola textura con mipmaps (unos 170 MB); no hay otra que compartir. Con ella, la memoria máxima del export 4K sube de unos 870 MB a 1 251 MB, debajo de 1,5 GB.

## Medidas del agente (M5 Pro), hito 1c

Las metas de la columna "La Mac del dueño (M5 Pro)" de diseño §15 del hito 1c, que mide un agente en esta Mac (el modelo de la del dueño); al dueño le queda el piso M1. Sección abierta por Task 8 el 16 de noviembre de 2026, Apple M5 Pro, macOS 26.6.2 (`sw_vers -productVersion`), sobre `864b5f7` (el árbol de `hito-1c`) con los cambios de Task 8 (`feat(analysis): the card zoom path inside a split screen`). Cada tarea suma una fila al final de la tabla con su fecha y su commit si cambian. Puede haber pruebas de otros agentes corriendo en la misma Mac a la vez: cada fila dice la carga (promedio de 1 min de `uptime`) de ese momento; Release salvo que la fila diga otra cosa.

| Tarea | Qué | Comando | Medida | Meta | Carga |
|---|---|---|---|---|---|
| 8 | Armar en frío los caminos de una hora con `cardZoom` (`MotionPaths` entero, desde nada; mediana de 5 después de uno para calentar, por turnos): el puntero a 60 Hz sin parar, un clic cada 5 s, los 719 bloques de zoom automáticos sobre ellos (`follow`, 1,5 s cada uno: 30 % de la hora), una Dividida, cursor suavizado | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter rebuildingAnHourOfPathsFitsTheBudget` | **180 ms** con la Dividida (114 ms sin ella), de los que `CardZoomPath` 67 ms, `ZoomCameraPath` 79 ms y `CursorPath` 29 ms (dos corridas, ±1,5 ms). La prueba afirma solo lo de esta tarea: la cámara de la tarjeta no cuesta más que la del escenario (≤ 1,25 veces); el armado en frío se anota sin meta. La de diseño §15 (≤ 30 ms) es la del rearmado después de una edición, que mide Task 13 | La cámara de la tarjeta ≤ 1,25 × la del escenario | 5,4 a 5,6 |
| 34 | Buscar mientras se escribe en 1 000 proyectos (`LibraryListing.items`: sección Todos, búsqueda por nombre y carpeta con `localizedStandardContains`, orden por fecha; mediana de 100 después de 5 para calentar, alternando "demo r" y "revision"; 31 resultados) | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter searchAThousandWhileTyping` | **1,23 ms** en Release (máximo 1,41 ms); **1,85 ms** en Debug, el comando del plan (máximo 2,54 ms) | ≤ 8 ms | 35 a 40 (Mac muy cargada), sobre `955ac1b` con los cambios de Task 34 |
| 35 | Una miniatura nueva de una fuente 4K (`LibraryThumbnails.render`: una toma de la pantalla en 3840 × 2160 a 30 fps, de un minuto, sin ediciones; su cuadro de 6 s a 520 × 292, de la clave a la HEIC escrita en la caché; mediana de 10, cada una en una caché vacía, después de una para calentar) | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter newThumbnailFromA4KSourceIsFast` | **37,9 ms** en Release (mínimo 36,0, máximo 45,4); **47,2 ms** en Debug, el comando del plan (mínimo 44,6, máximo 50,2). Por pasos (Debug, medidos aparte): decodificar desde el cuadro clave anterior y dibujar ~22 ms, la HEIC ~10 ms, armar el `FrameRenderer` ~4,6 ms, la clave y el documento < 1 ms. Cerrar los lectores del renderer (`AVAssetReader.cancelReading`, ~20 ms) queda después de entregar la miniatura | ≤ 80 ms | 7,4 a 5,1 en Release; 9,5 a 6,9 en Debug; sobre `cbb8c62` con los cambios de Task 35 |

### La vista previa (Task 31)

```
swift build --package-path Packages/RecorderKit -c release --product recorder-dev
Packages/RecorderKit/.build/release/recorder-dev bench-preview --synthetic                                 # fuente 4K60, dibujada a 4K
Packages/RecorderKit/.build/release/recorder-dev bench-preview --synthetic --width 1920 --height 1080      # fuente 4K60, dibujada a 1080p (la medida del piso M1)
```

`bench-preview --synthetic` graba la misma toma sintética de `bench-export --synthetic` (10 s, la pantalla en 4K a 60 fps, o el tamaño de `--source-width` y `--source-height`, y una cámara de 1280 × 720 a 30 fps) y la muestra al tamaño de `--width` y `--height` (el del export; dice `source:` y `playing at`), en otro proceso, con el documento de las medidas (todo prendido, como el export de arriba) en un `PreviewEngine` que dibuja a una `CAMetalLayer` de 2560 × 1440 píxeles (`--view-width`, `--view-height`; ninguna ventana la muestra), pidiéndole cuadros desde el hilo principal 60 veces por segundo, como un display link: reproduce la toma entera, después la arrastra 12 veces de punta a punta (1,5 s cada vez) y la suelta. Mide:

- **reproduciendo**: los cuadros distintos que se vieron (y los tarde) y, para cada uno, desde el primer pedido que lo pidió hasta que la GPU terminó de dibujarlo (el "cuadro": el trabajo del motor, el dibujo y la reducción al tamaño de la capa);
- **el hilo principal**: lo más que tardó un pedido en volver;
- **al arrastrar**: los cuadros nuevos por segundo;
- **al soltar**: desde la pausa pedida hasta que la GPU terminó el cuadro exacto. Las 6 primeras veces el arrastre frena hacia donde termina, como lo hace una mano, y se suelta donde terminó (`release:`); las otras 6 siguen a toda velocidad hasta el final y se sueltan de golpe (`released moving:`, el peor caso: arrastrando a unas 6,7 veces el tiempo real).

Apple M5 Pro, macOS 26.6.2, 16 de noviembre de 2026; Release; con los cambios de Task 31 sobre `6822cd7`. Entre paréntesis, la carga de la Mac (promedio de 1 min) al empezar: había pruebas de otros agentes corriendo.

| Caso | Fuente 4K60 dibujada a 4K (3840 × 2160): tres corridas (8,9), (12,5), (8,8) | Fuente 4K60 dibujada a 1080p (1920 × 1080, capa de 1920 × 1080) (7,4) | Meta, la Mac del dueño (diseño §7.9) |
|---|---|---|---|
| Reproduciendo, todo prendido: cuadros vistos | 609 de 609, 608 de 608, 613 de 613 (60,0 por segundo), ninguno tarde | 609 de 609 (60,0 por segundo), ninguno tarde | 60 fps a 4K |
| Reproduciendo: el cuadro, p50 / p95 / máximo | 12,07 / 13,06 / 28,60 ms; 9,67 / 10,39 / 23,62 ms; 7,51 / 8,11 / 14,65 ms | 6,51 / 7,72 / 12,00 ms | p95 ≤ 16,7 ms |
| La espera más larga del hilo principal | 1,540 ms; 0,199 ms; 0,318 ms | 0,418 ms | ninguna > 4 ms |
| Arrastrando: cuadros nuevos por segundo | 59,7; 59,9; 60,0 | 60,0 | ≥ 30 |
| Al soltar (arrastre que frena): el exacto, mediana y máximo de 6 | 11,7 y 37,7 ms; 9,9 y 13,8 ms; 7,6 y 8,4 ms | 6,5 y 8,5 ms | ≤ 80 ms |
| Al soltar a toda velocidad (el peor caso), mediana y máximo de 6 | 40,5 y 148,4 ms; 36,2 y 146,4 ms; 43,0 y 169,1 ms | 69,2 y 137,0 ms | ≤ 80 ms: **no se cumple** soltando hacia atrás a toda velocidad (146 a 169 ms a 4K) |
| Memoria máxima del proceso | 457, 471, 481 MB | 392 MB | acotada |

Una cuarta corrida a 4K, después de los cambios de la revisión (carga 7,1), dio lo mismo: 609 de 609 cuadros (8 tarde: ninguna medio segundo seguido, así que no bajó de tamaño: `playing at 3840 × 2160`), p95 12,21 ms, arrastre 59,8, al soltar 9,0 y 11,1 ms, a toda velocidad 52,5 y 148,1 ms.

Soltar a toda velocidad hacia adelante cae siempre en lo decodificado (de 5 a 12 ms); los máximos son de soltar a toda velocidad hacia atrás, donde el exacto se decodifica desde su cuadro clave (hasta un grupo de cuadros entero: unos 60 cuadros de 4K).

Cómo se llega:

- **Nada en el hilo principal.** `request(_:)` guarda el pedido bajo un `Mutex` y, si la cola del motor está libre, la despierta; `setScene(_:)` igual (la escena se le pasa al renderer en la cola del motor, no en el hilo que la da). Con un cuadro en curso solo queda el último pedido: nunca se encola trabajo viejo (por eso el motor no usa `render(at:into:completion:)`, cuyos cuadros encolados no se pueden cancelar).
- **Reproduciendo, decodificado por adelantado.** El motor dibuja el cuadro de la grilla en o antes del instante y, a medida que avanza, agenda en el `FramePrefetcher` de cada pista los instantes de la fuente de los 8 cuadros siguientes, que se decodifican en la cola del prefetcher. `latest(atSource:)` nunca espera: si el cuadro no llegó, queda el anterior y el cuadro cuenta como tarde (`PreviewQuality`). Un cuadro ya presentado no se vuelve a dibujar.
- **Al arrastrar, el cuadro clave.** `FramePrefetcher.keyFrame(atSource:)` ubica el cuadro clave en o antes del instante con un `AVSampleCursor` y decodifica solo esa muestra (leída con un `AVSampleBufferGenerator` sincrónico) con una `VTDecompressionSession` que se conserva, sin `AVAssetReader`; mientras el cuadro clave es el mismo, no decodifica nada. El archivo del segmento se recuerda, así que el arrastre no espera al lector de la pista mientras este decodifica.
- **Al soltar, el exacto ya decodificado.** Mientras se arrastra, el prefetcher de cada pista decodifica en segundo plano, como el export (`TrackFrameReader`), el cuadro de la grilla más cercano al cabezal y el anterior; el último arrastre reemplaza lo pedido antes, salvo que pida lo mismo. Arrastrando hacia atrás empieza tanto más atrás como se movió el arrastre desde el anterior, porque un decodificador no retrocede sin volver a un cuadro clave. La pausa toma lo decodificado, o espera lo que se está decodificando, con la pantalla y la cámara a la vez. Soltar a toda velocidad hacia adelante también cae en lo decodificado (el lector queda antes del cuadro y lee unos pocos más); hacia atrás, el exacto se decodifica desde su cuadro clave.
- **Saltos del lector más baratos** (`TrackFrameReader`): un salto abre el lector en el cuadro presentado en o antes del instante, que da el `AVSampleCursor` del archivo, en lugar de 1 s antes (decodificaba hasta 2 s de 4K, 322 ms de mediana al soltar), y el lector que deja se cancela en una cola aparte: `cancelReading()` esperaba lo que ese lector decodificaba por adelantado, de 6 a 74 ms a 4K. Un paso atrás que queda en el cuadro que el lector ya tiene no salta. Los bytes no cambian (`make golden`): se decodifica el mismo cuadro, desde el mismo cuadro clave.
- **Al tamaño de la capa, en la GPU.** El motor dibuja en una textura propia al tamaño de la escena y la reduce con un filtro de caja (cada píxel, el promedio de los texeles que cubre, en su parte) a la capa; ampliando, bilineal.
- **Un renderer, cualquier tamaño.** La escena (`FrameEvaluator`) lleva su tamaño: la pausa al tamaño del export, la mitad del lado al reproducir tarde (`FrameEvaluator.resized(to:)`, que solo rehace lo que depende del tamaño) y otro formato dibujan con los mismos lectores; el fondo desenfocado o el fondo de pantalla y el título de la ventana se guardan para los dos últimos tamaños.

**Pendientes medidos de tareas anteriores**

- *Rearmar los caminos de movimiento de una hora* (diseño §7.9, ≤ 20 ms en esta Mac; Tasks 18 y 19): `bench-preview` construye `MotionPaths` de una hora hecha repitiendo el cursor y los clics de la toma sintética (222 953 eventos) con un bloque de zoom de 4 s cada 10 s, la mitad siguiendo al cursor: de 110 a 162 ms (lo mejor de 3 en cada corrida: 119,7; 134,1; 125,4; 116,3; 118,5 ms con carga de 6 a 12, una de 162,0 ms con carga 7, y de 109,6 a 115,0 ms con carga de 1 a 5). **No llega a la meta**, y pasa los 50 ms por hora con los que Task 18 pedía rehacer solo desde el primer instante afectado. Lo que se hizo: una revisión que no cambia nada de lo que los caminos leen (el fondo, la sombra, las esquinas, el desenfoque del fondo, el muestreo) se queda con los caminos de la anterior (`MotionPaths.areThePaths(of:)`, 0 ms); el editor (Task 34) arma la escena con ellos. **Seguido, pendiente:** una edición que sí los cambia (un corte, un zoom, el cursor, el margen) en una toma de 1 h los rehace enteros, en 116 a 134 ms (de 110 a 162 ms según la carga; meta ≤ 20 ms). El rearmado incremental desde el primer instante afectado (diseño §8.6) pasa al hito 1c, donde Task 8 ya separó el motor de `ZoomCameraPath` (hacerlo acá sería portarlo dos veces; decisión del controlador).
- *El recorrido de una ráfaga de cambios de forma por cuadro* (Task 27): evaluar un cuadro al final de una ráfaga de 600 cambios de forma (10 s de una ventana que cambia de forma en cada cuadro) cuesta 5,8 µs en Release (1,8 µs sin ráfaga; 258 µs en Debug): no hace falta otra estructura.
- *La copia con mipmaps de un recorte que cambia de tamaño* (Tasks 22 y 27): la midió Task 27 (1,84 ms de GPU por cuadro mientras el resorte cambia el recorte, 0,39 ms reusando una copia, el doble en un fundido cruzado, hasta 6 copias libres de unos 45 MB a 4K). **La memoria, arreglada:** el compositor guarda solo las copias de los dos últimos tamaños pedidos (la pantalla y la que se deja en un fundido cruzado) y suelta las demás, así que mientras un resorte mueve el recorte no se juntan copias de tamaños viejos (`mipmappedCopiesOfOldSizesAreLetGo`). **Postergado (decisión del controlador): reusar copias entre tamaños** (en cubetas de tamaño, o una caché por pista e instante, sin que ningún texel de fuera del recorte llegue a ningún nivel de mipmap). Cuesta unos 1,5 ms de GPU de más por cuadro, solo mientras dura un resorte de geometría (a lo sumo 1,5 s); el p95 de la vista previa a 4K de arriba queda de 8 a 13 ms, dentro de los 16,7.
- *Abrir un registro de edición largo* (Task 13): reproducir el registro ya no recorre todos los grupos por cada grupo nuevo (`replayIsLinearInTheGroups`): pasar las líneas antes de la instantánea de 10 000 grupos tardaba 1,21 s y 20 000, 4,75 s (cuadrático, Debug); ahora, los dos juntos con su armado, 0,1 s.
| 33 | Renombrar, mandar a la papelera y restaurar un proyecto (`LibraryOperations.rename`, `moveToTrash`, `restore`) en el disco interno: un paquete con una toma de 8 MB en una subcarpeta de la carpeta de proyectos, cinco veces cada una, cada vez un proyecto nuevo; de la llamada a la respuesta, con la consulta de sus locks, el bookmark de su carpeta y `trashOrigins`. Debug, sobre `955ac1b` (Task 31) con los cambios de Task 33 | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit --filter renameTrashAndRestoreAreQuick` | renombrar 0,32 a 0,55 ms; a la papelera 8,5 a 9,1 ms y 24,9 ms la primera (que además crea `Trash/`); restaurar 7,4 a 9,0 ms | ≤ 100 ms cada una (diseño §15) | 5,8 a 5,9 |
| 32 | La biblioteca con 1 000 proyectos `.synthetic` de `LibraryFixtures` (los de Task 31 después de su arreglo: manifiesto, `events.jsonl` de unas 61 líneas por segundo, 30 s en promedio, y registro de edición), en el disco interno: indexar sin índice (`reconcile` desde un índice vacío hasta `.finished`; los tamaños después) y reconciliar sin cambios con el índice que dejó. Para separar el recorrido de la lectura, la prueba mide además las mismas 1 000 lecturas de `ProjectReader.summary` solas, una tras otra en el hilo de la prueba. Con `TOMA_BENCH_DIR`, los 1 000 y su `index.json` quedan en esa carpeta (Task 36) | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter reconcileAndIndexAThousand`; en Debug, el de la tarea sin `-c release` | Release (6 corridas): indexar **3,06 a 3,41 s**, lo mismo que las lecturas solas (3,04 a 3,23 s; el recorrido, de −3 a +6 %); los tamaños de los 1 000 terminan 64 a 79 ms después; reconciliar sin cambios **18 a 20 ms**. Debug: indexar 3,65 y 3,72 s con carga 4,6 y 4,7 (las lecturas solas 3,67 s; reconciliar 21 y 23 ms), y 6,4 y 10,1 s con más carga (las lecturas solas 5,3 y 3,8 s): las colas de la biblioteca son `.utility`, que el sistema corre sobre todo en los núcleos de eficiencia y posterga con la Mac cargada. De cada proyecto, decodificar su `events.jsonl` entero (`EditSession.readDocumentWithDiskVersion` → `LoadedProject.load`) es unos 2,6 de los 3,2 ms que cuesta leerlo (perfil de 300, Release): sin eso serían unos 0,6 ms por proyecto. Indexar **no llega a la meta**; con grabaciones reales, de registros mucho más largos, tardaría más | Indexar ≤ 2 s; reconciliar ≤ 0,4 s (diseño §15, Mac del dueño) | 4,9 a 8,0 en Release; 4,6 a 15 en Debug |
| 22 | El GIF de 60 s a 15 fps, Equilibrada, con tramado, de una fuente 4K60 con cámara: `bench-gif --synthetic` graba con `synth-record` 60 s de 3840 × 2160 a 60 fps con una cámara de 1280 × 720 a 30 fps y la exporta en otro proceso con el documento de las medidas, todo prendido (el de `bench-export`: la cámara del zoom que nunca para y el cursor suavizado, los dos con desenfoque de un cuadro entero, el fondo de pantalla `aurora-1`, sombra, el marco de macOS, la pantalla con mipmaps, la cámara); el tiempo es el de `GIFExporter.export` entero (dibujo, histograma, paleta, mapeo, composición, LZW y archivo), la memoria la huella física máxima del proceso. Además, para el peor caso de la paleta (la cámara a pantalla completa con ruido en cada cuadro: hasta que el render dibuje los layouts, Tasks 10 y 11, una pantalla de ruido de 1280 × 720 que llena la salida, 20 s), `bench-gif <toma de ruido>`; y en `make crash-test` (Debug), la memoria de `export-gif` de 10 s y de 60 s a 800 px | `swift build --package-path Packages/RecorderKit -c release --product recorder-dev`; `Packages/RecorderKit/.build/release/recorder-dev bench-gif --synthetic` y `… --long-side 1920` | 800 px (800 × 450; 902–903 cuadros, 1,8 MB): **9,03 a 9,33 s**, memoria 264 a 270 MB. 1920 px (1920 × 1080, 5,5 MB): **8,59 a 8,65 s**, memoria 358 a 403 MB. Lo limita decodificar la fuente: cada cuadro del GIF decodifica 4 cuadros de la pantalla 4K60 y 2 de la cámara en la cola que dibuja (unos 9,6 ms por cuadro, la cola ocupada todo el export); el MP4 de la misma toma al mismo tamaño y ritmo (`bench-export <toma> --all-on --width 800 --height 450 --fps 15`) tarda lo mismo, 8,73 s. La paleta se rehízo en 880 de 903 cuadros (la cámara del zoom no para), 0,2 ms cada una; el mapeo, 1,1 ms a 800 px. Sin vaciar el *autorelease pool* de esa cola en cada cuadro, la memoria llegaba a 1,3 GB. Ruido (20 s, 300 cuadros): 800 px **0,78 s** (53 paletas nuevas, 5,8 ms cada una); 1920 px **3,37 y 3,54 s**, unos 10,5 s para 60 s (206 paletas nuevas, 13,7 ms cada una, y mapeos de 6 ms), con carga 16 y 17. Ahí manda la cadena de paletas, un cuadro tras otro: mientras los cuadros piden paletas nuevas, las de los cuadros ya dibujados adelante se arman en paralelo (la misma paleta: es función del histograma) y la cadena solo las espera; sin eso, 1920 px tardaba 6,89 a 7,13 s, unos 21 s para 60 s, más que la meta (con carga 2 y 57 a 61), y 800 px 1,08 a 1,31 s. Memoria de `export-gif` a 800 px en `make crash-test` (Debug, tomas de `synth-record` de 640 × 360, cada una en su proceso, `/usr/bin/time -l`): 186 MB de huella máxima con 10 s y 187 MB con 60 s (máximo residente 54 y 60 MB), con carga 7 a 9: no crece con la duración | ≤ 10 s a 800 px y ≤ 20 s a 1920 px; memoria < 1 GB que no crece con la duración (diseño §15) | 3,7 a 15,9 en las de 4K60 (las más tranquilas, 3,7 a 4,8: 800 px 9,03 a 9,33 s, 1920 px 8,63 y 8,64 s); 2 a 61 en las de ruido; sobre `1fa4db4` con los cambios de Task 22 |


### La línea de tiempo (Task 40)

```
make build
swift run --package-path Packages/RecorderKit recorder-dev synth-record "$TMPDIR/bench-timeline" --duration 3
TOMA_BENCH_TIMELINE=1 build/Build/Products/Debug/Toma.app/Contents/MacOS/Toma -TomaDumpEditorStructure "$TMPDIR/bench-timeline/"*.toma
```

Solo en Debug. Abre el paquete en el editor (como `-TomaDumpEditorStructure`, sin la incorporación ni avisos), dice cuánto mide su línea de tiempo (`editor timeline:`) y, en una ventana propia de 1440 pt de ancho (1352 pt de pistas), muestra una toma de una hora armada en código: una pantalla, una cámara, un micrófono y el audio del sistema; 500 tramos de 7 s con 0,2 s cortados entre ellos (uno de cada diez a 2× y algunos a 0,5×: 3465 s de salida); 300 zooms de 3 s, la mitad automáticos; 100 cambios de la cámara; 40 marcadores; dos partes rayadas, y la forma de onda de una hora en las dos pistas de audio. Para cada cuadro arma lo que está a la vista y lo manda al servidor de render (`CATransaction.flush()`) en el hilo principal, y mide eso, en cinco movimientos de 600 cuadros: ajustada a la ventana cambiando la escala (los 500 tramos y los 300 zooms a la vista), un pellizco de ajustada a 600 pt/s y de vuelta, y desplazarla 40 pt por cuadro a 3,9, 60 y 600 pt/s; y mover solo el cabezal. Después, durante 4 s, un pellizco al ritmo del display link de la vista (`paced pinch`): cuántos refrescos hubo y cuántos llegaron más de 1,5 períodos después del anterior. Con `TOMA_BENCH_TIMELINE_SNAPSHOTS=<carpeta>` deja además un PNG de la línea de tiempo del editor y de la de una hora a cuatro escalas.

Apple M5 Pro, macOS 26.6.2, 16 de noviembre de 2026, compilación Debug, sobre `1b/t40`. Entre paréntesis, la carga de la Mac (promedio de 1 min) al empezar cada corrida: había pruebas de otros agentes. p50 / p95 / máximo del cuadro en el hilo principal, en ms.

| Movimiento | Corrida 1 (8,07) | Corrida 2 (9,08) | Corrida 3 (8,80) | Capas de elementos a la vista |
|---|---|---|---|---|
| Ajustada, todo a la vista, cambiando la escala | 4,48 / 4,76 / 16,65 | 4,54 / 4,84 / 17,16 | 4,37 / 4,62 / 15,90 | hasta 921 |
| Pellizco de ajustada (0,39 pt/s) a 600 pt/s y de vuelta | 3,26 / 4,40 / 4,92 | 3,34 / 4,39 / 5,44 | 3,14 / 4,10 / 5,00 | hasta 921 |
| Desplazar a 3,9 pt/s | 3,18 / 3,52 / 4,74 | 3,22 / 3,54 / 4,86 | 3,03 / 3,26 / 4,90 | hasta 113 |
| Desplazar a 60 pt/s | 3,13 / 3,47 / 4,24 | 2,94 / 3,26 / 4,02 | 2,93 / 3,17 / 4,21 | hasta 29 |
| Desplazar a 600 pt/s | 2,31 / 2,58 / 3,84 | 2,26 / 2,48 / 3,30 | 2,17 / 2,30 / 3,05 | hasta 23 |
| Solo el cabezal | 0,03 / 0,03 / 0,21 | 0,03 / 0,04 / 0,22 | 0,03 / 0,03 / 0,46 | — |

La meta (diseño §7.9) es 120 fps en esta Mac (8,33 ms por cuadro) y 60 fps en la M1 (16,7 ms): el p95 del hilo principal, en Debug y con la Mac cargada, queda entre 2,3 y 4,8 ms, y el máximo pasa de 8,33 ms solo en el primer cuadro con la secuencia entera a la vista, cuando se crean sus capas (de 16 a 17 ms, una vez: al abrir un proyecto así). Una compilación Release es más rápida.

**Sin medir acá: la frecuencia real de la pantalla.** La pantalla de esta Mac estaba apagada y el display link no llamó ni una vez (`paced pinch: the display did not refresh`), así que no se midió lo que compone el servidor de render por cuadro ni si se pierde algún refresco: queda para el dueño (`docs/release.md`, "La línea de tiempo (40)"), con la pantalla encendida, en su Mac y en la M1.

Cómo se llega:

- **Una capa por elemento a la vista, reciclada.** Tramos, bloques, tramos de pantalla, rombos, rayados, mosaicos de miniaturas y etiquetas de la regla salen de un pozo por pista: el elemento que sale de la vista le deja su capa al que entra, que solo cambia de lugar, de texto y de color; nada se crea ni se destruye al desplazar. Los elementos a la vista se encuentran con una búsqueda binaria sobre la lista ordenada (con el fin más lejano hasta cada uno, por si se superponen), así que una hora con 500 tramos no cuesta más que lo que se ve.
- **El cabezal es una capa aparte.** Reproduciendo, en cada refresco solo cambia su posición (0,03 ms); la página pasa sola cuando llega al borde derecho.
- **Miniaturas en la grilla de cada tramo.** Cada tramo tiene sus mosaicos desde su comienzo, a un paso que es una potencia de dos de nanosegundos de salida (de media a una miniatura de ancho), cada uno con el cuadro de su tramo en su borde izquierdo y cortado en el final del tramo (`TimelineLayout.thumbnailTiles`). Mientras la escala cambia dentro de una potencia de dos, los mosaicos conservan su cuadro y se corren con el tramo (al pasar una, la mitad lo conserva), y una edición que corre un tramo no los cambia (`aSmallScaleStepKeepsTheThumbnails`, `aCutBeforeTheViewKeepsTheThumbnailsAfterIt`). Un pedazo de menos de 16 pt no muestra miniatura: con la hora entera ajustada (tramos de menos de 3 pt), ninguna. Se ven solo dentro de los tramos (una máscara con sus rectángulos). Las hace `ThumbnailCache` fuera del hilo principal, una a la vez; las que salen de la vista antes de hacerse se cancelan. (Hasta la revisión de Task 40 los mosaicos seguían una grilla de toda la salida y cambiaban de cuadro con casi cualquier cambio de escala y con cualquier corte anterior; las corridas de la tabla de arriba son de esa versión.)
- **Formas de onda por columna de un punto.** La de cada pista se reduce una vez, fuera del hilo principal, a mínimos y máximos de cada potencia de dos de sus pares de 10 ms: cada columna lee unos pocos valores, a cualquier escala, y la pista entera es un solo trazado.

Con los arreglos de la revisión (las miniaturas en la grilla de cada tramo; ⇧Z escala alrededor del instante que queda en el mismo lugar, `TimelineLayout.fitAnchor`), el mismo comando, tres corridas con carga 3,60, 3,29 y 4,31 (p50 / p95 / máximo en ms):

| Movimiento | Corrida 1 (3,60) | Corrida 2 (3,29) | Corrida 3 (4,31) | Capas de elementos a la vista |
|---|---|---|---|---|
| Ajustada, todo a la vista, cambiando la escala | 3,62 / 3,78 / 13,93 | 3,67 / 3,79 / 13,13 | 3,55 / 3,64 / 13,33 | hasta 904 (ninguna miniatura) |
| Pellizco de ajustada a 600 pt/s y de vuelta | 2,59 / 3,37 / 4,14 | 2,67 / 3,71 / 7,13 | 2,53 / 3,37 / 4,04 | hasta 904 |
| Desplazar a 3,9 pt/s | 2,48 / 2,68 / 3,78 | 2,76 / 3,16 / 6,01 | 2,52 / 2,71 / 3,75 | hasta 141 |
| Desplazar a 60 pt/s | 2,41 / 2,57 / 3,42 | 2,76 / 3,08 / 5,24 | 2,41 / 2,56 / 3,45 | hasta 36 |
| Desplazar a 600 pt/s | 1,79 / 1,93 / 2,54 | 2,06 / 2,40 / 3,67 | 1,78 / 2,00 / 2,63 | hasta 40 |
| Solo el cabezal | 0,02 / 0,03 / 0,45 | 0,03 / 0,03 / 0,24 | 0,02 / 0,03 / 0,55 | — |

Con menos carga que la primera vez, todo queda debajo de los 8,33 ms salvo el primer cuadro con la secuencia entera a la vista (13 a 14 ms, una vez). La frecuencia de la pantalla sigue sin medirse (`paced pinch: the display did not refresh`).
| 24 | La vista previa (3 s desde la mitad) y enseguida la estimación (7 muestras de 1 s repartidas más la vista previa, codificadas de verdad con `GIFExporter.encodeInMemory`), de la fuente 4K60 con cámara de 60 s a 800 px, Equilibrada, con el documento de las medidas todo prendido: `bench-gif --synthetic --estimate` (misma toma y proceso hijo que la fila 22; el tiempo es de la primera vista previa a la estimación terminada, con un `GIFExporter` nuevo por tramo) | `swift build --package-path Packages/RecorderKit -c release --product recorder-dev`; `Packages/RecorderKit/.build/release/recorder-dev bench-gif --synthetic --estimate` (dos corridas) | Primera medida (un renderizador por tramo): vista previa 0,65 y 0,60 s; vista previa y estimación juntas 2,41 y 2,36 s. Con la estimación progresiva (`GIFEstimate.estimates`: la primera sale de la vista previa sola) y un solo `FrameRenderer` para todos los tramos: vista previa **0,56 y 0,63 s**, primera estimación **0,56 y 0,64 s**, estimación refinada **2,22 y 2,12 s**; memoria 320 y 311 MB. La estimación dio 1,7 y 1,6 MB para el GIF de 60 s que la fila 22 exporta en 1,8 MB. **No llega a la meta**: cada tramo paga lo suyo de abrir (un `FrameRenderer` nuevo, los decodificadores de 4K y de la cámara que buscan el cuadro clave) y decodifica en la cola que dibuja, así que el tiempo es casi el de los 10 s de GIF que se codifican (3 s + 7 × 1 s) | vista previa y estimación seguidas ≤ 0,6 s (diseño §15) | 2,8 y 21,2 (1 min) la segunda medida, sobre `4e2c497` con los cambios de Task 24 |
| 25 | El corpus fijo del GIF y las constantes de `gifQuant-1` (diseño §15 y §16.1; decisiones 17, 18 y 39): cuatro tomas de 10 s hechas en código (`GIFCorpusTests`; la pantalla de 1280 × 720 a 30 fps, grabada siempre con el codificador HEVC de hardware para que los cuadros sean siempre los mismos): un tutorial (una ventana clara donde el texto aparece por líneas, un cursor que hace clic, el estilo de Toma y un zoom mientras escribe), el scroll de un artículo con fotos en un navegador, un editor oscuro sobre `aurora-1` con la burbuja de una cámara de ruido suave, y la cámara a pantalla completa (hasta que el render dibuje los layouts, Tasks 10 y 11, la misma cámara grabada como pantalla, llenando la salida). A 800 px, 15 fps, Equilibrada con tramado: nuestro GIF (`GIFExporter.encodeInMemory`) contra el de `CGImageDestination` con los mismos cuadros (`renderBytes`), con el error medio en OKLab de lo que muestra cada GIF contra esos cuadros; la estimación (`GIFEstimate.estimates`, con la vista previa desde el comienzo) contra el tamaño real; y la memoria de ImageIO (bytes en uso de malloc) | `TOMA_BENCH=1 swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter gifCorpusBeatsImageIO` (dos corridas: los mismos bytes); el barrido que eligió las constantes: `TOMA_BENCH=1 TOMA_GIF_TUNING=1` (y `TOMA_GIF_QUALITY=high` o `light`) `… --filter gifCorpusTuning` | Con `gifQuant-1` (Bayer 8 × 8; tramado Liviana 0,75, Equilibrada 0,5 y Alta 0,75; reusar la paleta con error medio ≤ 0,025, 0,015 y 0,015 y menos del 3 % de los píxeles a más de 0,06): tutorial **1850 KB contra 1251 KB de ImageIO (148 %)**, error 0,00354 contra 0,00519; scroll **2699 contra 1876 KB (144 %)**, 0,00622 contra 0,00669; burbuja **741 contra 515 KB (144 %)**, 0,00597 contra 0,00431; cámara **16 573 contra 13 270 KB (125 %)**, 0,00757 contra 0,00442. La estimación se pasa en +19 %, +37 %, +103 % y +9 %: cada muestra de 1 s empieza con un cuadro entero, y en lo que casi no se mueve eso pesa más que todo el resto. **No se cumple**: ninguna combinación del barrido (los dos mapas por tres valores alrededor de cada constante de la decisión 17 y, más allá, menos tramado o ninguno) llega al 50 %; lo más chico, sin tramado, queda en 101 a 125 % (con un error menor que el de ImageIO en las cuatro). En macOS 26.6 ya no vale lo que supuso diseño §4.3: el GIF de ImageIO recorta cada cuadro al rectángulo que cambió, deja transparente lo que no cambió (disposición 1) y usa una sola tabla de colores global, sin tramado. Contra las constantes provisionales: el tramado de 0,5 da GIFs de 1 a 8 % más chicos en las cuatro tomas y con menos error; el 3 % en lugar del 2 % decide solo en el scroll (entra contenido nuevo), de 1,6 a 6 % más chico; el ruido azul de 64 × 64 da el mismo error con 2 a 19 % más de bytes (hasta 25 % con tramado 1,0); y la Alta provisional (tramado 1,0, reusar ≤ 0,010) quedaba debajo del error de su propio tramado en la cámara y la burbuja y armaba una paleta nueva en cada cuadro (178 % y 995 % de ImageIO). ImageIO **retiene los cuadros hasta `CGImageDestinationFinalize`**: 216,5 MB en uso con los 150 cuadros agregados (1,44 MB cada uno, lo que pesa un cuadro de 800 × 450 en BGRA, aunque cada uno se suelta apenas se agrega) y de 596 a 643 MB mientras finaliza; con 900 cuadros de 1080p serían unos 7,5 GB y unos 20 GB | ≤ 50 % del tamaño de ImageIO con un error medio en OKLab igual o menor, y la estimación ± 30 % (diseño §15 y §16.1) | 3,6 a 4,8 el banco; 3,4 a 4,6 el barrido de Equilibrada; sobre `f074d6e` con los cambios de Task 25 |

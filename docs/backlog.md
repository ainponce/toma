# Pendientes para la fase 1

Lo que la revisión final de la fase 0 decidió no corregir todavía, con el motivo y el momento en que hay que hacerlo. Nada de esto es un defecto conocido de lo que la fase 0 graba; son huecos de cobertura, deudas de mantenimiento y endurecimientos que tienen su momento.

## Grabación

- **Retener el acuse del reposo hasta que la pausa cerró los segmentos** (`IORegisterForSystemPower` con `IOAllowPowerChange`, o una espera acotada en el observador de `willSleep`). *Por qué después:* todavía no hay evidencia de que `finishWriting` falle atravesando un reposo, y bloquear el hilo que avisa arriesga un deadlock. *Cuándo:* después de la comprobación del dueño con la tapa cerrada (`docs/release.md`, comprobación 2 de la revisión final).
- **Cambio rápido de usuario** (`sessionDidResignActive`): pausar la toma como con el bloqueo. *Por qué después:* hace falta un cambio de usuario real para ver qué notificaciones llegan. *Cuándo:* después de una comprobación del dueño.
- **Borrar un `.reserve` huérfano** de una carpeta de toma cuyo lock está libre, la liste o no el manifiesto. *Por qué después:* la ventana de crash entre crear la reserva y agregar la toma es de microsegundos, y que falle un `unlink` es muy improbable; desde la revisión final esas carpetas, si tienen un segmento o un lock, aparecen como *para reparar*.
- **Variantes Int16 e Int24 intercaladas en `SampleFactory`** para las pruebas de canales del escritor. *Por qué después:* la capa de dispositivo entrega Float32 en la práctica; la revisión final agregó los casos baratos de 3 y 6 canales.

## Lo que deja abierto el hito 1a

Lo que la captura completa (hito 1a) deja para hitos o fases posteriores. Los dos últimos de esta lista dependen de pruebas que todavía no se hicieron: no son trabajo decidido.

- **Animación de los cambios de geometría.** Cuando la pantalla o la ventana grabada cambia de marco a mitad de toma (eventos `displayGeometry` y `windowGeometry`), el render pasa al marco nuevo sin transición. *Cuándo:* hito 1b, con el editor con estilo.
- **Pista "Pantalla" editable.** Con varias pantallas, el render muestra toda la toma la que contiene el primer cursor (`ScreenChoice`); elegir en la línea de tiempo qué pantalla se ve en cada tramo es del editor. *Cuándo:* hito 1b.
- **Imágenes y hotspot del cursor (`cursors/<hash>.png`) y el scroll en `events.jsonl`** (spec §7.2 y §7.4). El hito 1a no los graba (decisión 20 del plan). *Cuándo:* antes del editor del hito 1b, que los necesita para el cursor con estilo.
- **"Ventana con menús".** El modo Ventana graba con `desktopIndependentWindow`, y los menús y popovers (ventanas aparte) no salen; la columna Ventana sugiere Área o Pantalla. Una opción que grabe la pantalla de la ventana con `SCContentFilter(display:including:)`: la ventana y las del mismo PID con `windowLayer ≥ kCGPopUpMenuWindowLevel`. *Cuándo:* cuando se pida.
- **Espejo y layouts de la cámara** (la cámara a pantalla completa, al lado de la pantalla). Hoy el video de la cámara no se espeja y va siempre en su burbuja. *Cuándo:* hito 1c.
- **Ver, ajustar y borrar en el editor los cambios de estilo de la cámara** (los eventos `cameraStyle` de la toma; diseño del notch §5.6). *Cuándo:* hitos 1b y 1c.
- **Papelera en la biblioteca.** Reiniciar una toma manda el proyecto viejo a `~/Movies/Toma/Trash`, que hoy solo se ve en Finder. *Cuándo:* hito 1c, con la biblioteca.
- **El guion del teleprompter por proyecto**, con su avance en la línea de tiempo (diseño del notch §5.4). Hoy hay un solo guion, en los ajustes. *Cuándo:* fase 3.
- **Confirmar las claves de `CGSCopyManagedDisplaySpaces` con cada macOS nuevo** (`SpacesReader`, la excepción de APIs privadas). Si cambian, no hay lista de escritorios y la isla muestra ← → y Mission Control. *Cuándo:* con cada beta de macOS.
- **Una pista de audio del sistema por app.** Hoy "Por app" graba las apps elegidas en una sola pista `system-audio`. *Cuándo:* fase 3.
- **El limitador de la mezcla.** El export suma las pistas de audio a ganancia 1 y recorta a [−1, 1]; el limitador y el volumen por pista llegan con la pestaña Audio del editor. *Cuándo:* con la pestaña Audio.
- **Quitar el marcador del audio del sistema por app** — *pendiente de una prueba*: un agente prepara una rama de prueba con `SystemAudioSelection.targets` en `.only([])` y el dueño graba `--system-audio com.google.Chrome` con Chrome cerrado, anotando si la toma arranca y graba silencio. Mientras ninguna app elegida está abierta, `SystemAudioSelection.targets` nombra el proceso propio (`.only([ownObjectID])`) y `ProcessTapSource` graba silencio, porque no se sabe si Core Audio acepta un tap sin procesos (`.only([])`). *Cuándo:* solo si esa comprobación muestra que `[]` funciona.
- **Tap con la salida como sub-dispositivo, o audio del sistema con ScreenCaptureKit como respaldo** — *pendiente de las comprobaciones del dueño en `docs/release.md`* ("Pendientes del dueño del hito 1a", Desde Terminal: si `verify` dice que `system-audio` no tiene medios con el permiso dado). Si el agregado sin sub-dispositivo no entrega audio con el permiso dado, el respaldo de `ProcessTapSource`: la salida por defecto como sub-dispositivo principal, tomando del IOProc solo el búfer del stream del tap, y un cambio de la salida por defecto termina la corrida. Si las taps no sirven en esa Mac, el audio del sistema con ScreenCaptureKit, con lo observado. *Cuándo:* solo si esa comprobación lo pide.

### Lo que el usuario ve y el hito 1a deja así

- **Las esquinas transparentes toman clics.** Fuera del círculo o del rectángulo redondeado de la burbuja, y en las cuñas de las esquinas redondeadas de la isla, un clic llega a Toma (arrastra la burbuja) en lugar de a la app de abajo (decisión 22: el marco es la forma visible, salvo esas esquinas). *Cuándo:* si el dueño lo anota como molesto.
- **La tapa de "Ocultar íconos" se ve un poco más apagada en pantallas P3:** se dibuja desde una captura en sRGB (el video y el PNG no cambian). *Cuándo:* con la comprobación del dueño.
- **⌘Q y ⌘W con la isla abierta se reconocen por el carácter** (`charactersIgnoringModifiers`), así que en un teclado no latino pueden no cerrar la isla ni dejar de salir. *Arreglo barato:* comparar los `keyCode` 12 y 13.
- **La burbuja de una ventana de otro escritorio** se muestra sobre el escritorio actual, en el marco que la ventana tiene en el suyo, flotando sobre contenido que no se graba. *Cuándo:* cuando se pida.

### Grabación y pruebas del hito 1a

- **Una toma de varias pantallas que las pierde todas sigue sin ninguna y no reintenta** (`RestartPolicy`, `isSoleScreen` se fija al arrancar). La spec (§7) dice que, sin pantalla, la toma se pausa y sigue al volver; hoy una pausa y reanudación del usuario devuelve las pistas perdidas. *Arreglo:* que la última pantalla no perdida siga reintentando, preguntando al coordinador cuántas quedan vivas.
- **Una prueba de integración del filtro de pantalla** (`RECORDER_INTEGRATION=1`): una `NSWindow` propia de un color único sobre la pantalla grabada no sale en el cuadro, y sí sale incluida por `includedWindowIDs` (las tapas). Hoy lo cubren las funciones puras y las comprobaciones del dueño.
- **El lector de `wallpapers/` del hito 1b** tiene que abrir cada `display-<id>.png` con `O_NOFOLLOW`: `checkLayout` comprueba la carpeta, no los archivos, y el editor no llama a `checkLayout`.

### Menores diferidos del hito 1a que pueden esperar

Los que las revisiones finales marcaron "can wait", uno por línea.

- *Ciclo de la toma (AppSupport):* ninguna prueba fija el drenaje de `warnings`; `diskAutoStopRacingUserStopOpensEditorOnce` no fuerza su intercalado; `removeIfUnused` corre en el actor principal; `AwaitPoint` sigue a nivel de módulo; `RecordingController.swift` volvió a crecer (más de 700 líneas); un stop durante el pedido del micrófono espera la respuesta; cuatro setters quedaron `internal(set)`; `// MARK: - Microphone level` duplicado en sus pruebas.
- *Avisos (AppSupport):* los avisos del arranque se muestran desde `.starting`; un reinicio que falla no dice que la toma anterior quedó; un `stopped` sin stop espera detrás de los ámbar; un `closedWithError` en espera se pierde si no hay vista guardada.
- *No Molestar:* faltan pruebas de un reinicio cuyo arranque falla y de Cmd-Q con el gancho suspendido; `theShortcutNeverRunsTwiceAtOnce` usa una espera fija de 100 ms para lo que no pasa.
- *Escritorios:* un salto que no publica nada rearma la gracia de `SpaceSwitchGrace` o corta su ventana de 1 s; una línea larga en la doc de `SpaceJump.swift`; el observador de `DesktopsModel` no se quita (una sola instancia).
- *Salida (5b):* las ramas del export con el plazo de salida están probadas a medias; `settle()` de 10 cesiones en las pruebas; `isPoweringOff` no se reinicia si se cancela el cierre de sesión; un Stop del usuario en curso con "Abrir el editor" abre el editor durante la salida (Ruling: dejarlo así).
- *Ventana:* `WindowCatalog` arma un grupo sin nombre para ventanas sin app y junta dos apps del mismo nombre; `windowMoved()` asigna la región sin `CameraBubbleLayout.region` (hoy da lo mismo).
- *Foto del fondo (17b):* una captura colgada queda abandonada (una tarea trabada por cada vencimiento); la prueba de exFAT monta una imagen con `hdiutil` en `make test` sin compuerta.
- *App:* el aviso "appintentsmetadataprocessor … Metadata extraction skipped" en `make build`; el ciclo `CADisplayLink` ↔ `IslandPanel` y observadores que no se sueltan (viven lo que la app); VoiceOver lee "Sin señal" dos veces; la isla abierta puede caer en la pantalla que el puntero acaba de dejar dentro del fundido de 100 ms; la cápsula cuelga 2 s bajo una píldora escondida al volver al reposo en pantallas sin notch; `ProgressView` gira con "Reducir movimiento" (control del sistema); el alto de la vista "guardada" en barras de menús de 38 pt (comprobación del dueño); `mic.slash` un instante en las alas con la cuenta en 0.
- *Teleprompter:* las teclas escritas durante los 170 ms del fundido al editar se pierden; `observe()` sigue todo `setting.value` (reinicia fundidos); "\(size) pt" de VoiceOver sin localizar; `TeleprompterPanel.swift` largo.
- *Tamaño de archivos:* `IslandPanel.swift`, `CameraBubblePanel.swift` (con su ayudante de `CASpringAnimation`) e `IslandOpenPanel.swift` son largos.
- *Herramientas:* `DEBUG_SIGN_IDENTITY ?=` del `Makefile` corre `security find-identity` dos veces por build (solo lectura; `:=` lo resuelve).
- *Captura:* las `static let` de `FragmentedTrackWriter` entre propiedades de instancia; la doc de `RecordingTicks.every` no dice que el handler corre en un bloque de dispatch de la cola; la aserción de snapshot de `RecordingCoordinatorTests` puede pasar vacía y la suite creció (partirla); la versión del paquete se mira después del chequeo de disco; el orden de los imports.
- *Cámara:* la comparación exacta de `CMTime` y del formato al chequear la deriva; un lease que solo corrige la deriva falla si otro proceso tiene el lock del dispositivo (toma sin cámara, con su aviso); los cuadros que AVFoundation descarta no se cuentan en `droppedFrames`; el log de `enforceConfiguration` dice "as the session started" también desde `attach`; `setOnCameraChange` guarda un solo manejador (hay un cliente); los errores de la sesión compartida no se oyen cuando solo la tiene la burbuja; `.points` mantiene `captureResolution = .best` (lo decide la comprobación de rendimiento).
- *Audio del sistema:* la guarda de búfer vacío del catálogo de procesos nunca dispara; los saltos del IOProc no tienen tope mientras el pipeline está trabado (unos 0,4 MB/s, acotado por la espera del escritor); el literal del `trackID` duplicado.
- *Pantallas:* un doble `stopCapture` estrecho solo deja un log; la notificación y el KVO de `runningApplications` refrescan los dos el filtro (es idempotente).
- *Formato y pruebas (Tasks 2 y 4):* `MetalCondition.isAvailable || isRequired` repetido en cada prueba de Metal; los guards de `TakeBuilder` sin prueba; ayudantes duplicados entre las pruebas de Export y Render; `removeEventLog` fija `take-001`; `classify` usa `lstat` e `inspect` usa `stat` (un enlace colgado se ve distinto antes de recuperar); `TakeBuilder` ordena en línea en vez de `sortedByTime()`; `ProjectFormat` importa AVFoundation por `SegmentMedia`.
- *Export (Task 13):* `channelCount` vuelve a abrir cada segmento e ignora la cancelación; ninguna prueba comprueba que los huecos del micrófono llevan la pista `"mic"`; el caso 3 del crash test recupera unos 9 s de 10 (dentro de un fragmento).
- *Render:* `ScreenChoice` puede elegir una pantalla cuyos segmentos no se pueden leer en vez de otra legible (la pista "Pantalla" editable de 1b lo resuelve).

## Editor y export

- **Exportar una toma cuya pista de pantalla no tiene segmentos** (el audio sobre el fondo) en lugar de lanzar `noDisplayTrack`. *Por qué después:* raro en la fase 0 (la toma no arranca si la pantalla no arranca) y toca el contrato de render. *Cuándo:* con el trabajo del editor de la fase 1.
- **La decodificación de la vista previa en el hilo principal al arrastrar la barra de tiempo**, y un `loadTracks` trabado que bloquea el hilo principal hasta 10 s cada 2 s. *Por qué después:* ya estaba postergado en el registro para el rediseño del editor (1b); su lado del export lo cubre `missingVideo` desde la revisión final.

## Releases

- **Verificar el código anidado con `SecStaticCodeCheckValidity` antes de cargar Sparkle dinámicamente** (opción a del entitlement). *Por qué después:* la revisión final dejó `disable-library-validation` como riesgo aceptado de la fase 0 (`docs/release.md`, "Riesgos aceptados"). *Cuándo:* si algún día hay un Team ID, o antes del primer release público.
- **Endurecer el feed.** Que `release.yml` se niegue (o deje en borrador) cuando `SUFeedURL` es `localhost`; que `IdentityTests` y `release.sh` exijan https salvo para `localhost`; `SURequireSignedFeed` y `SUVerifyUpdateBeforeExtraction`. *Por qué después:* el feed `localhost` de la fase 0 es una decisión documentada (`docs/release.md`, "Feed de la fase 0"). *Cuándo:* al elegir la URL del feed público.
- **Reproducibilidad de `release.sh`.** Fallar con `git status --porcelain` salvo `ALLOW_DIRTY=1`, no pisar un DMG que ya existe, cambiar `dist/` de forma atómica, y exigir que el número de build supere el `sparkle:version` más alto del appcast. *Por qué después:* solo afecta el camino local (los checkouts de CI están limpios y traen el historial de los Releases); el registro ya los guardaba. *Cuándo:* antes del primer release público.

## Del registro de las tareas 1 a 13 de la fase 0

- Cada línea "minor (deferred)" del registro que la revisión de calidad de las pruebas marcó **KEEP**, y las que marcó **RESOLVED**, quedan como estaban, con los motivos de esa revisión. Sus cuatro **FIX** entraron en la revisión final: cantidades impares de canales (F24), la ventana del cursor (F13), el texto de `MissingAudio.end` (F22) y la clave de la release ad hoc (F8).

## Residuos de la revisión final de la fase 0

Lo que la nueva revisión de la revisión final dejó abierto: hallazgos menores sin corregir y cosas que quedaron fuera de su alcance. Ninguno cambia lo que la fase 0 graba.

- **`RecoveryScanner.swift:66-76` (`needsRepair`):** `needsRepair` puede esconder tomas recuperables del mismo paquete cuando un paquete tenga varias tomas (hoy una por paquete). *Arreglo:* devolver también las tomas `.recoverable` listadas junto al motivo.
- **`docs/release.md:224`:** la sección vieja apunta a "Prueba en seco después de la revisión final", que no existe; falta el registro de la release ad hoc posterior a los arreglos de F8. *Arreglo:* agregarla al final (shasums de `dist/` sin cambios, `build/adhoc-dist/`, 0 llamadas a `security`, comprobación de LICENSE) o quitar el puntero.
- **`docs/release.md:73-76` (con `scripts/release.sh:144-148`):** el plan B sin CI no pasa `SOURCE_CODE_URL`, así que un DMG público sale con `SourceCodeURL` vacío (hueco de GPLv3 §6 que F25 cerró solo en CI). *Arreglo:* agregar `SOURCE_CODE_URL=…` al comando, o que `release.sh` falle (no avise) en un build firmado sin ella.
- **`scripts/create-signing-cert.sh:124-128` (`docs/release.md:85, 95-101`):** los `gh secret set … --env release` impresos no llevan `-R <owner>/<repo>` ni dicen que hay que correrlos dentro del clon, y fallan (sin filtrar nada) mientras la imagen sigue montada. *Arreglo:* imprimir con `-R` (de `gh repo view --json nameWithOwner`) o indicar el directorio en los pasos 1/3.
- **`docs/release.md:29, 37` (`scripts/release.sh:186-231`):** el appcast ad hoc "con una clave descartable" falla en el paso Appcast una vez que se commitea la `SPARKLE_PUBLIC_KEY` real, porque la clave descartable no coincide con `SUPublicEDKey`. *Arreglo:* documentar que hace falta la mitad pública descartable en `SPARKLE_PUBLIC_KEY` (en un clon de prueba) o que solo vale antes de commitear la real.
- **`scripts/check-workflows.sh:17`:** el lint solo recorre `*.yml`; un workflow `*.yaml` se saltaría las comprobaciones de SHA, `persist-credentials`, permisos y SPDX. *Arreglo:* recorrer `*.yml` y `*.yaml` (con `nullglob`).
- **`docs/release.md:196` (comprobación 13 del dueño):** dice que salir e "Instalar y reiniciar" durante un export "pregunta primero", pero el relanzamiento de Sparkle espera en silencio a que termine el export (`UpdaterController.swift:95-104`, `UpdateRelaunchGate`). *Arreglo:* decir que el relanzamiento espera al export.
- **`docs/superpowers/plans/2026-11-13-fase-0-base-que-no-falla.md:723, 728`:** todavía describen el flujo viejo de `create-signing-cert` ("SHA-1 y .p12 en base64", `generate_keys -x sparkle_ed.key`), que contradice F9. *Arreglo:* actualizar el plan al flujo actual.
- **`scripts/release.sh`, traza con `bash -x`:** la línea `ed_key=${SPARKLE_ED_PRIVATE_KEY:-}` deja la clave privada en la traza (ya pasaba antes). *Arreglo:* envolverla en `{ set +x; } 2>/dev/null`; mientras tanto, nunca trazar con la clave real.
- **Incógnitas de CI que solo la primera corrida en GitHub resuelve:** si los runners macOS-26 exponen un dispositivo Metal (`TOMA_CI` ahora hace fallar 28 pruebas de render/export en vez de saltarlas), cuánto tarda y qué tan estable es TSan en 3 vCPU, y cuánto suma compilar XcodeGen desde el código fuente. *Arreglo:* ajustar con la primera corrida real.

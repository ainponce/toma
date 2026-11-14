# Pendientes para la fase 1

Lo que la revisión final de la fase 0 decidió no corregir todavía, con el motivo y el momento en que hay que hacerlo. Nada de esto es un defecto conocido de lo que la fase 0 graba; son huecos de cobertura, deudas de mantenimiento y endurecimientos que tienen su momento.

## Antes de construir sobre lo que hay

- **El ciclo de vida de la toma de `RecordingController`, a `AppSupport`.** Con fábricas inyectadas del coordinador, las fuentes, los permisos y las alertas, y pruebas de: un stop en cada punto de espera, el bucle de respaldo del micrófono, el auto-stop por disco compitiendo con un stop del usuario, y salir mientras se arranca o se graba. *Por qué después:* es un hueco de cobertura, no un defecto, y un refactor grande para una sola ronda de correcciones; las comprobaciones del dueño de la Task 12 cubren la fase 0. *Cuándo:* temprano en la fase 1, antes de que la barra flotante y "reiniciar toma" se apoyen en el controlador.
- **Reloj y ticks inyectables en `TrackPipeline` y `RecordingCoordinator`.** Partir su `State` en tipos de valor (`RestartPolicy`, `WriterFailureBackoff`, `SegmentAccounting`, `AudioClockAnchors`) con pruebas síncronas, y llevar la extensión de `Duration` a su propio archivo. *Por qué después:* mantenimiento; la ronda final ya quitó la inestabilidad de las pruebas que medían contra el tiempo dormido. *Cuándo:* antes de que la fase 1a sume las pistas de cámara y de audio del sistema.
- **Sacar la lógica duplicada.** El reintento ante `EWOULDBLOCK` dentro de `RecordingLock.acquire(retries:)`, un solo ayudante para ordenar `InputEvent` por tiempo, y un único abridor de medios de segmento con una sola clasificación. *Por qué después:* nada se comporta mal hoy. *Cuándo:* junto con el trabajo de lectores de la fase 1, para que la recuperación, `verify` y el export sigan de acuerdo.
- **Un target `RecorderKitTestSupport`.** Carpetas temporales, constructores de paquetes y tomas, escritores de segmentos sin terminar, decodificadores, la condición de Metal y el ayudante de `hdiutil`, hoy repetidos en cada target de pruebas. *Cuándo:* antes de que los cambios de formato de la fase 1 multipliquen los manifiestos armados a mano.

## Grabación

- **Retener el acuse del reposo hasta que la pausa cerró los segmentos** (`IORegisterForSystemPower` con `IOAllowPowerChange`, o una espera acotada en el observador de `willSleep`). *Por qué después:* todavía no hay evidencia de que `finishWriting` falle atravesando un reposo, y bloquear el hilo que avisa arriesga un deadlock. *Cuándo:* después de la comprobación del dueño con la tapa cerrada (`docs/release.md`, comprobación 2 de la revisión final).
- **Cambio rápido de usuario** (`sessionDidResignActive`): pausar la toma como con el bloqueo. *Por qué después:* hace falta un cambio de usuario real para ver qué notificaciones llegan. *Cuándo:* después de una comprobación del dueño.
- **Borrar un `.reserve` huérfano** de una carpeta de toma cuyo lock está libre, la liste o no el manifiesto. *Por qué después:* la ventana de crash entre crear la reserva y agregar la toma es de microsegundos, y que falle un `unlink` es muy improbable; desde la revisión final esas carpetas, si tienen un segmento o un lock, aparecen como *para reparar*.
- **Variantes Int16 e Int24 intercaladas en `SampleFactory`** para las pruebas de canales del escritor. *Por qué después:* la capa de dispositivo entrega Float32 en la práctica; la revisión final agregó los casos baratos de 3 y 6 canales.

## Editor y export

- **Exportar una toma cuya pista de pantalla no tiene segmentos** (el audio sobre el fondo) en lugar de lanzar `noDisplayTrack`. *Por qué después:* raro en la fase 0 (la toma no arranca si la pantalla no arranca) y toca el contrato de render. *Cuándo:* con el trabajo del editor de la fase 1.
- **La decodificación de la vista previa en el hilo principal al arrastrar la barra de tiempo**, y un `loadTracks` trabado que bloquea el hilo principal hasta 10 s cada 2 s. *Por qué después:* ya estaba postergado en el registro para el rediseño del editor (1b); su lado del export lo cubre `missingVideo` desde la revisión final.

## Releases

- **Verificar el código anidado con `SecStaticCodeCheckValidity` antes de cargar Sparkle dinámicamente** (opción a del entitlement). *Por qué después:* la revisión final dejó `disable-library-validation` como riesgo aceptado de la fase 0 (`docs/release.md`, "Riesgos aceptados"). *Cuándo:* si algún día hay un Team ID, o antes del primer release público.
- **Endurecer el feed.** Que `release.yml` se niegue (o deje en borrador) cuando `SUFeedURL` es `localhost`; que `IdentityTests` y `release.sh` exijan https salvo para `localhost`; `SURequireSignedFeed` y `SUVerifyUpdateBeforeExtraction`. *Por qué después:* el feed `localhost` de la fase 0 es una decisión documentada (`docs/release.md`, "Feed de la fase 0"). *Cuándo:* al elegir la URL del feed público.
- **Reproducibilidad de `release.sh`.** Fallar con `git status --porcelain` salvo `ALLOW_DIRTY=1`, no pisar un DMG que ya existe, cambiar `dist/` de forma atómica, y exigir que el número de build supere el `sparkle:version` más alto del appcast. *Por qué después:* solo afecta el camino local (los checkouts de CI están limpios y traen el historial de los Releases); el registro ya los guardaba. *Cuándo:* antes del primer release público.

## Del registro de las tareas 1 a 13

- Cada línea "minor (deferred)" del registro que la revisión de calidad de las pruebas marcó **KEEP**, y las que marcó **RESOLVED**, quedan como estaban, con los motivos de esa revisión. Sus cuatro **FIX** entraron en la revisión final: cantidades impares de canales (F24), la ventana del cursor (F13), el texto de `MissingAudio.end` (F22) y la clave de la release ad hoc (F8).

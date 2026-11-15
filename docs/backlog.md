# Pendientes para la fase 1

Lo que la revisión final de la fase 0 decidió no corregir todavía, con el motivo y el momento en que hay que hacerlo. Nada de esto es un defecto conocido de lo que la fase 0 graba; son huecos de cobertura, deudas de mantenimiento y endurecimientos que tienen su momento.

## Antes de construir sobre lo que hay

- **Reloj y ticks inyectables en `TrackPipeline` y `RecordingCoordinator`.** Partir su `State` en tipos de valor (`RestartPolicy`, `WriterFailureBackoff`, `SegmentAccounting`, `AudioClockAnchors`) con pruebas síncronas, y llevar la extensión de `Duration` a su propio archivo. *Por qué después:* mantenimiento; la ronda final ya quitó la inestabilidad de las pruebas que medían contra el tiempo dormido. *Cuándo:* antes de que la fase 1a sume las pistas de cámara y de audio del sistema.

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

## Residuos de la revisión final de la fase 0

Lo que la nueva revisión de la revisión final dejó abierto: hallazgos menores sin corregir y cosas que quedaron fuera de su alcance. Ninguno cambia lo que la fase 0 graba.

- **`writersThatKeepFailingWaitBeforeReopening`, rama else** (`RecordingCoordinatorTests.swift:623-626`): con menos de 30 muestras descartadas acepta el aviso con o sin él. *Arreglo:* exigir que no haya aviso en esa rama.
- **`RecoveryScanner.swift:63-66` (con `:83`):** una carpeta de toma sin listar que solo tiene un `recording.lock` viejo se reporta como si tuviera archivos grabados que el manifiesto no lista, y `needsRepair` oculta las tomas `.recoverable` listadas del mismo paquete (hoy no ocurre: una toma por paquete). *Arreglo:* redactar el motivo según lo hallado (segmento o solo lock) y, si hace falta, devolver también las tomas recuperables.
- **`docs/release.md:224`:** la sección vieja apunta a "Prueba en seco después de la revisión final", que no existe; falta el registro de la release ad hoc posterior a los arreglos de F8. *Arreglo:* agregarla al final (shasums de `dist/` sin cambios, `build/adhoc-dist/`, 0 llamadas a `security`, comprobación de LICENSE) o quitar el puntero.
- **`docs/format/README.md:313`:** el punto "Un `.reserve` que quedó en disco…" quedó suelto bajo `## Cierre de una toma`. *Arreglo:* devolverlo al final de la sección `## .reserve` (después de `:301`).
- **`docs/release.md:73-76` (con `scripts/release.sh:144-148`):** el plan B sin CI no pasa `SOURCE_CODE_URL`, así que un DMG público sale con `SourceCodeURL` vacío (hueco de GPLv3 §6 que F25 cerró solo en CI). *Arreglo:* agregar `SOURCE_CODE_URL=…` al comando, o que `release.sh` falle (no avise) en un build firmado sin ella.
- **`scripts/create-signing-cert.sh:124-128` (`docs/release.md:85, 95-101`):** los `gh secret set … --env release` impresos no llevan `-R <owner>/<repo>` ni dicen que hay que correrlos dentro del clon, y fallan (sin filtrar nada) mientras la imagen sigue montada. *Arreglo:* imprimir con `-R` (de `gh repo view --json nameWithOwner`) o indicar el directorio en los pasos 1/3.
- **`docs/release.md:29, 37` (`scripts/release.sh:186-231`):** el appcast ad hoc "con una clave descartable" falla en el paso Appcast una vez que se commitea la `SPARKLE_PUBLIC_KEY` real, porque la clave descartable no coincide con `SUPublicEDKey`. *Arreglo:* documentar que hace falta la mitad pública descartable en `SPARKLE_PUBLIC_KEY` (en un clon de prueba) o que solo vale antes de commitear la real.
- **`scripts/check-workflows.sh:17`:** el lint solo recorre `*.yml`; un workflow `*.yaml` se saltaría las comprobaciones de SHA, `persist-credentials`, permisos y SPDX. *Arreglo:* recorrer `*.yml` y `*.yaml` (con `nullglob`).
- **`docs/release.md:196` (comprobación 13 del dueño):** dice que salir e "Instalar y reiniciar" durante un export "pregunta primero", pero el relanzamiento de Sparkle espera en silencio a que termine el export (`UpdaterController.swift:95-104`, `UpdateRelaunchGate`). *Arreglo:* decir que el relanzamiento espera al export.
- **`docs/superpowers/plans/2026-11-13-fase-0-base-que-no-falla.md:723, 728`:** todavía describen el flujo viejo de `create-signing-cert` ("SHA-1 y .p12 en base64", `generate_keys -x sparkle_ed.key`), que contradice F9. *Arreglo:* actualizar el plan al flujo actual.
- **`scripts/release.sh`, traza con `bash -x`:** la línea `ed_key=${SPARKLE_ED_PRIVATE_KEY:-}` deja la clave privada en la traza (ya pasaba antes). *Arreglo:* envolverla en `{ set +x; } 2>/dev/null`; mientras tanto, nunca trazar con la clave real.
- **`SyntheticSources.swift:220-234` (`maximumBlocksPerTick`):** sin prueba de regresión; con inanición fuerte, un atraso mayor a 0,5 s se descarta al parar y los segmentos de micrófono sintético pueden terminar algo antes (solo afecta fuentes sintéticas). *Arreglo:* agregar la prueba.
- **Incógnitas de CI que solo la primera corrida en GitHub resuelve:** si los runners macOS-26 exponen un dispositivo Metal (`TOMA_CI` ahora hace fallar 28 pruebas de render/export en vez de saltarlas), cuánto tarda y qué tan estable es TSan en 3 vCPU, y cuánto suma compilar XcodeGen desde el código fuente. *Arreglo:* ajustar con la primera corrida real.

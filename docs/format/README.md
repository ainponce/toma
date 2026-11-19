# Formato de proyecto de Toma

**Versión 3 (`formatVersion: 3`), inestable hasta la fase 4.** Los nombres y campos todavía pueden cambiar. A partir del primer release público, cada cambio de formato viene con su migración y sus pruebas de compatibilidad. Los lectores de esta versión leen también los paquetes de las versiones 1 y 2, que se quedan en su versión hasta que el usuario los edita (ver [Cambios de la versión 3](#cambios-de-la-versión-3)).

El formato es público para que cualquier herramienta pueda leer, verificar o recuperar una grabación sin la app. Las reglas de este documento son las que sigue el código de `Packages/RecorderKit/Sources/ProjectFormat`.

## El paquete

Un proyecto es una carpeta con extensión `.toma` que Finder muestra como un solo documento:

```
MiVideo.toma/
  manifest.json                versión de formato, id del proyecto, app, fecha, tomas, pistas y segmentos
  edit.json                    decisiones del usuario (línea de tiempo, estilos); lo escribe el editor (versión 3)
  edit-log.jsonl               el registro de cambios del editor (versión 3)
  edit.lock                    lock del editor que escribe el paquete (versión 3)
  assets/                      imágenes propias del fondo, copiadas al paquete (versión 3)
  takes/
    take-001/
      display-1/               una carpeta por pista, con el id de la pista (display-<CGDirectDisplayID>)
        seg-0001.mov           un archivo por segmento (QuickTime fragmentado)
        seg-0002.mov
      window-4242/             una ventana, en vez de las pantallas (window-<CGWindowID>; versión 2)
        seg-0001.mov
      camera/                  la cámara (versión 2)
        seg-0001.mov
      mic/
        seg-0001.mov
      system-audio/            el audio del sistema (versión 2)
        seg-0001.mov
      events.jsonl             un evento por línea: cursor, clics, cortes de stream, pausas
      recording.lock           lock de la grabación en curso (ver más abajo)
      .reserve                 espacio reservado mientras se graba (ver más abajo)
      wallpapers/              opcional: el fondo de cada pantalla grabada, al empezar la toma (versión 2)
        display-1.png          uno por pantalla (display-<CGDirectDisplayID>.png)
      cursors/                 opcional: las imágenes del cursor de la toma (versión 3)
        3f2a9c0e….png          una por imagen distinta (<hash>.png, ver el evento cursorImage)
  cache/                       reservada para cachés que convenga llevar con el proyecto (el editor guarda las suyas fuera del paquete)
```

- Las tomas se llaman `take-001`, `take-002`, … Un número nunca se reutiliza: la toma nueva recibe el número siguiente al más alto del manifiesto y salta cualquier carpeta que ya exista en `takes/`.
- **Rutas.** Un paquete puede venir de cualquier lado (una carpeta compartida, una descarga), así que ninguna herramienta sigue una ruta del manifiesto sin comprobarla. El `id` de una toma es `take-` y tres o más dígitos; el de una pista, solo letras ASCII, dígitos y `-`; el `file` de un segmento es exactamente `takes/<toma>/<pista>/seg-NNNN.mov` para su `index`; el `projectID`, si está, son exactamente 32 dígitos hexadecimales en minúscula (nombra la carpeta de cachés del proyecto, fuera del paquete). Dentro de una toma, `takes/`, la carpeta de la toma, su `wallpapers/`, las de sus pistas, `recording.lock`, `events.jsonl` y `.reserve` no pueden ser enlaces simbólicos ni de otro tipo (carpetas las carpetas, archivos comunes los archivos). Un paquete que no cumple algo de esto es *para reparar*: la recuperación no lo toca. El editor y el export no abren un paquete cuyo manifiesto tiene una ruta inválida (`validatePaths`), pero no comprueban los enlaces de dentro de una toma (`checkLayout` lo usa solo la recuperación). El export nunca escribe nada en el paquete, y el editor solo sus propios archivos (ver [Cambios de la versión 3](#cambios-de-la-versión-3)). La ruta del paquete en sí sí puede pasar por enlaces (`/var` es uno, o una carpeta Movies enlazada): solo se comprueba lo que está dentro.
- Los segmentos se numeran desde 1 con cuatro dígitos (`seg-0001.mov`). Cada pista abre un segmento nuevo cada vez que su captura se interrumpe (pausa, error del stream, cambio de formato), así un corte nunca daña lo grabado antes.
- Los segmentos son películas fragmentadas, con fragmentos de 1 s: si la app, el sistema o la batería se apagan de golpe, se puede leer todo hasta el último fragmento escrito.
- Los segmentos de micrófono guardan todos los canales del dispositivo, en su orden: ALAC hasta 8 canales y LPCM Float32 con distribución discreta (`kAudioChannelLayoutTag_DiscreteInOrder`) desde 9. La distribución de canales que declara un archivo de 3 a 8 canales es la que ALAC exige para esa cantidad (por ejemplo `MPEG_5_1_D` para 6) y es solo una etiqueta: el canal *n* del archivo es la entrada *n* del dispositivo, no el altavoz que la etiqueta nombra.
- Las pistas de iPhone/iPad llegan en fases posteriores.

## `manifest.json`

Ejemplo completo de un proyecto con una toma terminada: la pantalla tuvo un corte del stream (error `-3821`) y siguió en un segundo segmento; la cámara, el micrófono y el audio del sistema grabaron sin cortes, y la cámara empezó con el estilo por defecto.

```json
{
  "app" : {
    "name" : "Toma",
    "version" : "0.1.0"
  },
  "createdAt" : "2026-11-13T16:00:00Z",
  "formatVersion" : 3,
  "projectID" : "9d4f3b2a7c1e48d6b05a2f9e3c7d1a84",
  "takes" : [
    {
      "cameraStyle" : {
        "anchor" : "bottomTrailing",
        "shape" : "circle",
        "size" : 0.24
      },
      "id" : "take-001",
      "startedAt" : "2026-11-13T16:00:12Z",
      "status" : "complete",
      "tracks" : [
        {
          "id" : "display-1",
          "kind" : "display",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81276901234567,
              "endReason" : {
                "code" : -3821,
                "domain" : "SCStreamErrorDomain",
                "type" : "streamError"
              },
              "file" : "takes/take-001/display-1/seg-0001.mov",
              "heartbeatFrames" : 312,
              "index" : 1,
              "startHostTime" : 81234567890123
            },
            {
              "droppedFrames" : 3,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/display-1/seg-0002.mov",
              "heartbeatFrames" : 0,
              "index" : 2,
              "startHostTime" : 81277458000000
            }
          ],
          "source" : {
            "displayID" : 1,
            "globalFrame" : {
              "height" : 982,
              "width" : 1512,
              "x" : 0,
              "y" : 0
            },
            "name" : "Built-in Retina Display",
            "pixelScale" : 2
          }
        },
        {
          "id" : "camera",
          "kind" : "camera",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/camera/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234590000000
            }
          ],
          "source" : {
            "deviceUniqueID" : "0x1420000005ac8600",
            "name" : "FaceTime HD Camera"
          }
        },
        {
          "id" : "mic",
          "kind" : "microphone",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/mic/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234570000000
            }
          ],
          "source" : {
            "deviceUniqueID" : "BuiltInMicrophoneDevice",
            "name" : "MacBook Pro Microphone"
          }
        },
        {
          "id" : "system-audio",
          "kind" : "systemAudio",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/system-audio/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234575000000
            }
          ],
          "source" : {
            "excludedBundleIDs" : [
              "dev.toma.Toma",
              "com.apple.notificationcenterui",
              "com.apple.UserNotificationCenter",
              "systemsoundserverd",
              "com.apple.systemsoundserverd"
            ],
            "name" : "System Audio"
          }
        }
      ]
    }
  ]
}
```

Reglas de escritura:

- JSON UTF-8 con claves en orden alfabético, indentado y sin escapar `/`.
- Los campos opcionales se omiten cuando no tienen valor (nunca se escribe `null`).
- El archivo se reemplaza entero en cada cambio: se borra un `manifest.json.tmp` que haya quedado (aunque sea un enlace simbólico, que nunca se sigue), se crea uno nuevo con `O_CREAT | O_EXCL | O_NOFOLLOW`, se fuerza a disco con `F_FULLFSYNC`, se renombra sobre `manifest.json` con `rename(2)` y se fuerza a disco también la carpeta del paquete con `F_FULLFSYNC`, para que el cambio de nombre sobreviva a un corte de energía. Si el volumen no admite `F_FULLFSYNC`, se usa `fsync`. Un lector ve siempre el manifiesto anterior o el nuevo, nunca uno a medias.
- Después de un corte de energía puede quedar un `manifest.json.tmp` más nuevo que `manifest.json` (completo en disco, pero sin el cambio de nombre). Los lectores lo ignoran y usan `manifest.json`; la recuperación puede revisarlo más adelante. La próxima escritura lo borra y crea uno nuevo.
- Una toma entra al manifiesto, ya `recording`, antes de que se grabe nada: si esa primera escritura no llega al disco (después de un reintento con el espacio del `.reserve` si faltó espacio), la toma no empieza, y se sueltan el lock y el `.reserve`. Una carpeta de `takes/` que el manifiesto no lista pero que tiene un segmento o un `recording.lock` que nadie tiene hace que el paquete sea *para reparar*, y el motivo dice cuál de las dos cosas encontró (archivos grabados, o solo un `recording.lock` que quedó).
- Un solo proceso escribe el manifiesto de un paquete por vez, porque todas las escrituras usan el mismo `manifest.json.tmp`.
- `formatVersion` se decide al crear el paquete y solo lo cambia la primera edición del usuario, que pasa un paquete v1 o v2 a v3 (ver [Cambios de la versión 3](#cambios-de-la-versión-3)). La grabación y la recuperación nunca lo cambian: un paquete de la versión 1 se reescribe como versión 1.

### Campos

| Campo | Tipo | Significado |
|---|---|---|
| `formatVersion` | entero | Versión del formato del paquete: `3` en los paquetes nuevos, `2` y `1` en los de antes. Cambia solo con la primera edición de un paquete v1 o v2, que lo pasa a `3` (ver [Cambios de la versión 3](#cambios-de-la-versión-3)). |
| `app` | objeto | `name` y `version` de la app que creó el proyecto. |
| `createdAt` | fecha | Creación del proyecto. |
| `takes` | lista | Tomas en el orden en que se grabaron. |
| `projectID` | texto | Desde la versión 3. El id estable del proyecto: 32 dígitos hexadecimales en minúscula, que no cambian al renombrar ni al mover el paquete. Al azar en un paquete creado en la versión 3; el derivado en uno que pasó a la versión 3 con su primera edición. Si falta (siempre en las versiones 1 y 2), el id es el derivado (ver [Cambios de la versión 3](#cambios-de-la-versión-3)). |
| `upgradedFrom` | entero | Desde la versión 3, solo en un paquete que se creó en la versión `1` o `2` y pasó a la versión 3 con su primera edición: la versión en que se creó. Falta en un paquete creado en la versión 3. |

**Toma** (`takes[]`)

| Campo | Tipo | Significado |
|---|---|---|
| `id` | texto | `take-001`, … Es también el nombre de su carpeta en `takes/`. |
| `status` | texto | `recording` (se está grabando, o la app murió sin cerrarla), `complete` (la cerró la app) o `recovered` (la cerró la recuperación tras un crash). |
| `startedAt` | fecha | Inicio de la toma. |
| `tracks` | lista | Pistas de la toma. |
| `cameraStyle` | objeto | Desde la versión 2, solo en tomas con cámara: cómo se ve la cámara desde el principio de la toma (ver abajo). Los eventos `cameraStyle` lo cambian durante la toma. Si falta (una toma sin cámara o un paquete v1), la cámara es un círculo mediano abajo a la derecha, `{"anchor":"bottomTrailing","shape":"circle","size":0.24}`. |

**Estilo de la cámara** (`cameraStyle`, en la toma y en el evento del mismo nombre)

| Campo | Tipo | Significado |
|---|---|---|
| `shape` | texto | `circle`, `roundedSquare` (cuadrado con las esquinas redondeadas), `portrait` (vertical, 3:4) o `landscape` (horizontal, 16:9). |
| `size` | número | El lado de la cámara como fracción del alto de la salida, así no depende de la pantalla: `0.17` (chica), `0.24` (mediana) o `0.33` (grande). |
| `anchor` | texto | Uno de los 8 lugares, en las esquinas y en el medio de los bordes de lo que se graba: `topLeading`, `top`, `topTrailing`, `leading`, `trailing`, `bottomLeading`, `bottom` o `bottomTrailing` (`leading` es siempre la izquierda y `trailing` la derecha). Se guarda el lugar, no coordenadas. |

Dónde se dibuja, en una región de ancho `W` y alto `H` (en el video, la salida entera; la burbuja en vivo usa la misma regla sobre lo que se graba): con `s = size × H` y `a` el ancho sobre el alto de la forma (1 para `circle` y `roundedSquare`, 3/4 para `portrait`, 16/9 para `landscape`), una caja con el área del cuadrado de lado `s`, de ancho `s·√a` y alto `s/√a`; a `0.032 × H` de los bordes de su anclaje y centrada en el otro eje (`top` y `bottom` a lo ancho, `leading` y `trailing` a lo alto). El radio de las esquinas es la mitad del lado menor en `circle`, `0.26 × s` en `roundedSquare`, `20/750 × H` en `portrait` y `18/750 × H` en `landscape`. Es `CameraStyle.frame(in:)` de `ProjectFormat`.

**Pista** (`tracks[]`)

| Campo | Tipo | Significado |
|---|---|---|
| `id` | texto | Identificador único dentro de la toma y nombre de su carpeta: `display-<CGDirectDisplayID>` (por ejemplo `display-1`), `window-<CGWindowID>`, `camera`, `mic` o `system-audio`. |
| `kind` | texto | Qué graba la pista (ver abajo). |
| `source` | objeto | Qué se grabó (ver abajo). |
| `segments` | lista | Segmentos en orden de `index`. |

**Tipo de pista** (`kind`)

| `kind` | Qué graba | Segmentos | Campos de `source` |
|---|---|---|---|
| `display` | Una pantalla entera. En modo Área también graba la pantalla entera, y el área elegida va en `captureArea`. | video | `name`, `displayID`, `globalFrame`, `pixelScale`, `captureArea` |
| `window` | Una ventana (desde la versión 2). Una toma graba pantallas o una ventana. | video | `name`, `windowID`, `bundleIdentifier`, `globalFrame`, `pixelScale` |
| `camera` | Una cámara (desde la versión 2). | video | `name`, `deviceUniqueID` |
| `microphone` | Un micrófono. | audio | `name`, `deviceUniqueID` |
| `systemAudio` | El sonido que reproduce la Mac (desde la versión 2). | audio | `name`, `includedBundleIDs` o `excludedBundleIDs` |

Una toma puede tener varias pistas `systemAudio`, con ids distintos. En la fase 1a la app graba una, `system-audio`, que mezcla las apps elegidas; la fase 3 agrega una por app.

**Fuente** (`source`): solo están los campos que corresponden al tipo de pista.

| Campo | Tipo | Pistas | Significado |
|---|---|---|---|
| `name` | texto | todas | Nombre visible de la pantalla, de la ventana (su app y su título) o del dispositivo. |
| `displayID` | entero | `display` | `CGDirectDisplayID` de la pantalla. |
| `deviceUniqueID` | texto | `microphone`, `camera` | `uniqueID` del micrófono o de la cámara. |
| `globalFrame` | objeto | `display`, `window` | `x`, `y`, `width`, `height` en puntos globales, con el origen arriba a la izquierda de la pantalla principal. En una ventana, dónde estaba al empezar la toma; después, ver el evento `windowGeometry`. |
| `pixelScale` | número | `display`, `window` | Píxeles por punto de lo grabado (2 en una pantalla Retina grabada a resolución nativa, 1 con la escala Puntos). |
| `windowID` | entero | `window` | `CGWindowID` de la ventana (desde la versión 2). |
| `bundleIdentifier` | texto | `window` | Bundle identifier de la app de la ventana (desde la versión 2). |
| `captureArea` | objeto | `display` | Solo en pantallas grabadas en modo Área: el área elegida, en puntos globales como `globalFrame` (desde la versión 2). La pista graba la pantalla entera; el área es lo que se muestra. |
| `includedBundleIDs` | lista de textos | `systemAudio` | Las apps elegidas que se pueden grabar: se graba solo su sonido. Es lo que eligió el usuario sin la propia Toma ni las apps de los sonidos de notificaciones y alertas (las de `excludedBundleIDs` en modo "todas"), que nunca se graban. Si falta, se graban todas las apps menos las de `excludedBundleIDs` (desde la versión 2). |
| `excludedBundleIDs` | lista de textos | `systemAudio` | Las apps cuyo sonido no se graba cuando se graban todas. La app escribe siempre la propia Toma y las de los sonidos de notificaciones y alertas: `com.apple.notificationcenterui`, `com.apple.UserNotificationCenter`, `systemsoundserverd` y `com.apple.systemsoundserverd` (desde la versión 2). |

**Segmento** (`segments[]`)

| Campo | Tipo | Significado |
|---|---|---|
| `index` | entero | Número del segmento dentro de la pista, desde 1. |
| `file` | texto | Ruta del archivo relativa a la raíz del paquete. |
| `startHostTime` | `HostTime` | Instante del primer cuadro o muestra del archivo. |
| `endHostTime` | `HostTime` | Instante en que se cerró. Falta mientras el segmento está abierto. |
| `endReason` | objeto | Por qué se cerró. Falta mientras el segmento está abierto. |
| `droppedFrames` | entero | Cuadros (o bloques de audio) que llegaron de la captura y no se escribieron: porque el escritor no daba abasto, o porque lo rechazó o no se pudo abrir (en ese caso se cuentan en el segmento siguiente, o en el último si no hay otro). En un segmento que cerró la recuperación, es el último `droppedSamples` de `events.jsonl` para ese segmento (0 si no hay), así que pueden faltar los de los últimos 2 s antes del crash. |
| `heartbeatFrames` | entero | Cuadros repetidos para que el tiempo siga corriendo con la pantalla quieta. La recuperación no los conoce y escribe 0. |

**Motivo de cierre** (`endReason`): un objeto plano con `type` y, según el tipo, otros campos al mismo nivel.

| `type` | Campos extra | Significado |
|---|---|---|
| `stopped` | | La grabación se detuvo de forma ordenada. |
| `paused` | | Pausa: reposo de la Mac, pantalla bloqueada, pantallas apagadas o la pausa del usuario (ver el evento `paused`). |
| `streamError` | `domain`, `code` | El stream de captura falló; la pista sigue en un segmento nuevo. |
| `writerError` | `domain`, `code` | El escritor del archivo falló. |
| `formatChanged` | | Cambió el formato de la fuente (por ejemplo, la resolución). |
| `diskFull` | | Se cerró la toma por falta de espacio. |
| `recoveredAfterCrash` | | Lo cerró la recuperación; `endHostTime` es el final de lo legible. |
| `empty` | | La recuperación encontró el archivo vacío o sin ninguna muestra; `endHostTime` es igual a `startHostTime`. |
| `unreadable` | `bytes` | La recuperación no pudo leer un archivo no vacío de `bytes` bytes. El archivo queda intacto. |

## `events.jsonl`

Todo lo que pasa durante la toma además de los cuadros y el audio: el cursor, los clics, la geometría de las pantallas y el ciclo de vida de la grabación (segmentos, cortes del stream, pausas). Un evento por línea ([JSON Lines](https://jsonlines.org)). Por ejemplo, el comienzo de la toma del manifiesto de arriba, con su corte del stream:

```
{"displayID":1,"frame":{"height":982,"width":1512,"x":0,"y":0},"scale":2,"t":81234567000000,"type":"displayGeometry"}
{"index":1,"t":81234567890123,"track":"display-1","type":"segmentStarted"}
{"index":1,"t":81234570000000,"track":"mic","type":"segmentStarted"}
{"index":1,"t":81234575000000,"track":"system-audio","type":"segmentStarted"}
{"index":1,"t":81234590000000,"track":"camera","type":"segmentStarted"}
{"t":81234600000000,"type":"cursor","x":640.5,"y":402}
{"t":81234608333333,"type":"cursor","x":642.25,"y":401}
{"button":"left","t":81234650000000,"type":"mouseDown","x":642.25,"y":401}
{"button":"left","t":81234720000000,"type":"mouseUp","x":642.25,"y":401}
{"code":-3821,"domain":"SCStreamErrorDomain","t":81276901234567,"track":"display-1","type":"streamInterrupted"}
{"index":2,"t":81277458000000,"track":"display-1","type":"segmentStarted"}
{"style":{"anchor":"topLeading","shape":"circle","size":0.24},"t":81290000000000,"type":"cameraStyle"}
{"t":81300000000000,"type":"marker"}
```

Reglas de escritura:

- UTF-8. Cada línea es un objeto JSON compacto (sin espacios) que termina en `\n`, con las claves en orden alfabético y sin escapar `/`. Un salto de línea dentro de un texto se escribe escapado (`\n`), así que nunca corta la línea.
- Todo evento tiene `t`, su instante como `HostTime`, y `type`. Los demás campos dependen del tipo y van al mismo nivel.
- Los números que son enteros se escriben sin decimales (`20`, no `20.0`), aunque el campo admita fracciones; los demás, con la forma decimal más corta que vuelve al mismo valor (`10.5`). Un lector acepta las dos formas. Nunca se escriben `NaN` ni infinitos: un evento con uno de esos valores no se registra y quien graba recibe el error.
- El archivo solo crece por el final (`O_APPEND`); una línea escrita no se reescribe. Los eventos se juntan en memoria y se escriben cada 250 ms; cada 2 s lo escrito se ordena en disco con `F_BARRIERFSYNC`, y al cerrar la toma se escribe lo que falta y se fuerza a disco con `F_FULLFSYNC` (con `fsync` si el volumen no los admite). Mientras las escrituras funcionan, si la app muere se pierden como mucho los eventos de los últimos 250 ms, más lo que tarde el sistema en disparar el temporizador. Si las escrituras fallan (por ejemplo, con el disco lleno), los eventos esperan en memoria y se pierden si la app muere antes de que un reintento funcione.
- Una escritura que falla se reintenta desde el byte donde quedó, así las líneas siguen enteras, y una sincronización que falla se reintenta a los 250 ms. Quien graba recibe siempre el error de la primera escritura o sincronización que falló, aunque un reintento posterior funcione: que una sincronización posterior funcione no prueba que lo escrito antes haya llegado al disco.
- Las líneas van en el orden en que se registraron, que no siempre es el orden de `t`: un clic llega con el instante que le puso el sistema y el cursor se muestrea en otra cola. Quien necesite orden temporal ordena por `t`.
- Un solo proceso escribe el archivo de una toma por vez.

**Coordenadas.** `x`, `y` (cursor, clics y `scroll`) y `frame` (`displayGeometry` y `windowGeometry`) están en puntos globales, el espacio de `CGEvent.location` y de `globalFrame` en el manifiesto: el origen está arriba a la izquierda de la pantalla principal, `y` crece hacia abajo, y una pantalla a la izquierda o arriba de la principal tiene coordenadas negativas. La posición dentro de la grabación de una pantalla es `(x − globalFrame.x, y − globalFrame.y)` en puntos, o eso por `pixelScale` en píxeles. macOS da el cursor con fracciones de punto, así que `x` e `y` no siempre son enteros.

### Tipos

| `type` | Campos además de `t` | Significado |
|---|---|---|
| `cursor` | `x`, `y` | Posición del puntero. La grabación la muestrea a 120 Hz y escribe una línea solo cuando cambia. |
| `mouseDown` | `button`, `x`, `y` | Se presionó un botón del mouse (`left`, `right` u `other` para cualquier otro) en esa posición. |
| `mouseUp` | `button`, `x`, `y` | Se soltó un botón del mouse en esa posición. |
| `displayGeometry` | `displayID`, `frame`, `scale` | Una pantalla grabada: su `CGDirectDisplayID`, su rectángulo en puntos globales (`x`, `y`, `width`, `height`) y los píxeles por punto grabados. Se escribe al empezar la toma para cada pantalla y, desde la fase 1a, cada vez que cambia el marco o la escala de una pantalla grabada (resolución, disposición); un cambio hecho en pausa se escribe al reanudar. El render usa el último de la pantalla con `t` hasta el instante que dibuja, o `globalFrame` si no hay ninguno (ver [Interfaz de render](#interfaz-de-render-congelada)). |
| `segmentStarted` | `track`, `index` | La pista `track` (su `id` en el manifiesto) abrió el segmento `index`. `t` es el `startHostTime` del segmento; la recuperación lo usa si el archivo quedó en disco pero el segmento no llegó al manifiesto. |
| `streamInterrupted` | `track`, `domain`, `code` | El stream de captura de la pista falló con ese error (dominio y código del `NSError`). La pista sigue en un segmento nuevo, que tiene su propio `segmentStarted`. |
| `paused` | `reason` | La captura se detuvo en todas las pistas, que cierran su segmento como `paused`. `reason` es `willSleep` (la Mac va a entrar en reposo), `screenLocked`, que cubre dos cosas: la pantalla se bloqueó, o las pantallas se apagaron (las dos se pliegan en un solo estado, que termina solo cuando la pantalla está desbloqueada y encendida, así encender las pantallas sobre la pantalla de bloqueo no reanuda nada), o `user` (desde la fase 1a: el usuario pausó la toma, que sigue en pausa hasta que la reanuda, aunque mientras tanto se bloquee y desbloquee la pantalla). Mientras se graba, la app no deja que las pantallas se apaguen solas por inactividad, así que eso pasa solo si el usuario las apaga o bloquea la Mac. Con varios motivos a la vez hay un solo `paused`, con el `reason` del que empezó la pausa, y un solo `resumed`, cuando ya no queda ninguno. Un lector no falla ante un `reason` que no conoce. |
| `resumed` | | La captura volvió después de `paused`; cada pista abre un segmento nuevo. Entre un `paused` y su `resumed` no se graba nada: tampoco hay eventos `cursor`, `mouseDown`, `mouseUp`, `windowGeometry`, `cameraStyle`, `cursorImage`, `scroll` ni `keyActivity` (privacidad: ni la pantalla de bloqueo ni sus clics). |
| `deviceChanged` | `track`, `deviceUniqueID` | La pista siguió grabando desde otro dispositivo (el `uniqueID` del micrófono o de la cámara), por ejemplo porque se desconectó el micrófono o la cámara. |
| `marker` | | Una marca que el usuario puso mientras grababa. La app la escribe desde la fase 1a; nunca entre un `paused` y su `resumed`, donde no se graba nada. |
| `droppedSamples` | `track`, `count` | Total de muestras (cuadros o bloques de audio) que la pista `track` perdió hasta ahora en su segmento actual, el que abrió su último `segmentStarted`. Se escribe cada 2 s mientras se graba, solo si cambió, y no toca el manifiesto: es lo que la recuperación usa como `droppedFrames` de un segmento que la app no llegó a cerrar. |
| `audioClock` | `track`, `frame` | La muestra número `frame` del archivo del segmento actual de la pista de audio `track` (contando desde 0, la muestra de `startHostTime`) se capturó en `t`. El archivo de audio solo cuenta muestras y el reloj del dispositivo no va exactamente al ritmo del host, así que la grabación escribe uno cada 5 s de audio de cada segmento, con el instante del bloque que empieza en esa muestra, y el export ubica el audio por host time interpolando entre ellos (ver [Tiempos](#tiempos)). `frame` cuenta solo las muestras escritas en el archivo, así que el audio que el escritor descarta en tiempo real (su cola llena) no corre las anclas: cada una nombra una muestra que está en el archivo. Un lector descarta un ancla que no avanza en `frame` y en `t` respecto de la última que usa, o que se aparta más de 5000 ppm de la frecuencia del archivo respecto de la anterior. |
| `windowGeometry` | `track`, `frame`, `onScreen` | Desde la versión 2. Dónde está la ventana de la pista `window` `track`: su rectángulo en puntos globales (`x`, `y`, `width`, `height`) y si macOS la tiene en pantalla. `onScreen` es `false` tanto con la ventana minimizada u oculta como en otro Space, donde se sigue grabando. Se escribe al empezar la toma y cada vez que cambia el marco o `onScreen`. El render usa el último con `t` hasta el instante que dibuja, o `globalFrame` si no hay ninguno. |
| `cameraStyle` | `style` | Desde la versión 2. La cámara se ve con el estilo `style` (`shape`, `size`, `anchor`, como el `cameraStyle` de la toma) desde `t`: el usuario movió la burbuja o le cambió la forma o el tamaño mientras grababa. El `cameraStyle` de la toma es el estilo de antes del primero. Un cambio hecho en pausa se escribe en el instante de reanudar, justo después de `resumed`, y un estilo igual al último escrito no se escribe. |
| `cursorImage` | `hash`, `hotspot`, `size`, `kind` | Desde la versión 3. macOS muestra este cursor desde `t`. Su imagen es `takes/<toma>/cursors/<hash>.png` (ver [`cursors/`](#cursors)), y la línea se escribe recién cuando la imagen está en el disco. `hotspot`: dónde está el puntero dentro de la imagen, como fracción de su ancho (`x`) y de su alto (`y`) desde arriba a la izquierda. `size`: el tamaño del cursor en puntos (`width`, `height`). `kind`, opcional: el cursor del sistema cuyos píxeles tiene en esa Mac, si es uno de `arrow`, `iBeam`, `pointingHand`, `openHand`, `closedHand`, `crosshair`, `resizeLeftRight`, `resizeUpDown` o `notAllowed`; si falta, o es uno que el lector no conoce (una versión más nueva puede sumar formas), se usa la imagen grabada y la línea vale igual. La grabación mira el cursor cada 1/30 s y escribe una línea solo cuando cambia. |
| `scroll` | `dx`, `dy`, `x`, `y` | Desde la versión 3. El usuario hizo scroll `dx`, `dy` puntos (los de `scrollingDeltaX` y `scrollingDeltaY` de macOS; con un mouse que cuenta líneas, 10 puntos por línea), la suma de cada 1/30 s en una línea, con el puntero en (`x`, `y`) al final. |
| `keyActivity` | | Desde la versión 3. Se apretó al menos una tecla en los 250 ms que empiezan en `t` (un múltiplo de 250 ms de `HostTime`): una línea por ventana con al menos una tecla. Es actividad, nunca contenido: ni qué teclas, ni sus códigos, ni los modificadores, ni cuántas, y la ventana fija borra el ritmo entre teclas. Nunca se escribe con la entrada segura de macOS activa (los campos de contraseña, la entrada segura de Terminal) ni si el usuario lo apagó en los ajustes. |

Una línea de cada tipo, exactamente como se escribe:

```
{"t":123,"type":"cursor","x":10.5,"y":20}
{"button":"left","t":5,"type":"mouseDown","x":1,"y":2}
{"button":"right","t":5,"type":"mouseUp","x":-1920,"y":340.25}
{"displayID":1,"frame":{"height":982,"width":1512,"x":0,"y":0},"scale":2,"t":5,"type":"displayGeometry"}
{"index":2,"t":5,"track":"display-1","type":"segmentStarted"}
{"code":-3821,"domain":"SCStreamErrorDomain","t":5,"track":"display-1","type":"streamInterrupted"}
{"reason":"screenLocked","t":5,"type":"paused"}
{"t":5,"type":"resumed"}
{"deviceUniqueID":"BuiltInMicrophoneDevice","t":5,"track":"mic","type":"deviceChanged"}
{"t":5,"type":"marker"}
{"count":12,"t":5,"track":"display-1","type":"droppedSamples"}
{"frame":240000,"t":5,"track":"mic","type":"audioClock"}
{"frame":{"height":600,"width":800,"x":100,"y":80},"onScreen":true,"t":5,"track":"window-4242","type":"windowGeometry"}
{"style":{"anchor":"topLeading","shape":"landscape","size":0.17},"t":5,"type":"cameraStyle"}
{"hash":"3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e","hotspot":{"x":0.16,"y":0.12},"kind":"arrow","size":{"height":32,"width":24},"t":5,"type":"cursorImage"}
{"dx":0,"dy":-42.5,"t":5,"type":"scroll","x":640.5,"y":402}
{"t":5,"type":"keyActivity"}
```

### Lectura después de un crash

- Una línea está completa cuando termina en `\n`.
- Si la última línea no termina en `\n` pero es un objeto JSON completo, solo le faltó el salto de línea, porque una escritura cortada a la mitad nunca es un objeto completo: se lee como cualquier otra línea (y si es de un `type` que esta versión no conoce, se saltea y se cuenta). Si no es un objeto JSON completo, es una escritura que un crash cortó a la mitad y se descarta.
- Una línea completa que no es un evento legible (dañada, vacía o de un `type` que esta versión no conoce) se saltea y se cuenta, y el resto del archivo se lee igual. Así una versión vieja puede abrir un archivo con tipos nuevos.
- Antes de seguir escribiendo en un archivo que ya existe (al reabrirlo o en la recuperación), se lo hace terminar en un límite de línea: la línea cortada del final se trunca, y una última línea que es un objeto JSON completo sin `\n` recibe el suyo, aunque esta versión no conozca su `type`, así nunca se borra un evento. Después se fuerza a disco con `F_FULLFSYNC`. Las líneas completas nunca se tocan.

## Tiempos

- Todos los instantes son `HostTime`: nanosegundos de `CLOCK_UPTIME_RAW`, guardados como un entero JSON. Es el mismo reloj de `CMClockGetHostTimeClock()`, de los timestamps de ScreenCaptureKit y AVFoundation, y de `NSEvent.timestamp`, así que pistas y eventos quedan alineados sin estimar nada.
- El tiempo 0 de cada archivo de segmento es su `startHostTime`. En video, un cuadro en el segundo `t` del archivo ocurrió en `startHostTime + t × 1 000 000 000`.
- En audio no: el archivo guarda las muestras una detrás de otra, sin los huecos ni la deriva del reloj del dispositivo (con un reloj de dispositivo que se aparta 2000 ppm del host, el audio se corre 56 ms en 28 s). El instante de la muestra `n` de un segmento sale de interpolar linealmente entre sus anclas: la muestra 0 en `startHostTime` y cada `audioClock` del segmento (el de su pista con `t` entre el `startHostTime` del segmento y el del siguiente), y después de la última, al ritmo del último tramo entre dos anclas (o al nominal si no hay ninguna).
- El reloj vuelve a cero en cada arranque de la Mac, así que los `HostTime` solo se comparan dentro de una misma toma.

## Fechas

Las fechas (`createdAt`, `startedAt`) son ISO 8601 en UTC y sin fracción de segundo, por ejemplo `"2026-11-13T16:00:12Z"`. Se redondean hacia abajo al segundo entero cuando se crean, así lo que se lee del disco es exactamente lo que se escribió.

## `recording.lock`

Mientras se graba una toma existe `takes/<toma>/recording.lock`, y el proceso que graba lo mantiene abierto con un lock `flock` exclusivo.

- **Lo que cuenta es el lock, no el archivo.** Una toma se está grabando si y solo si alguien tiene el lock. Para saberlo se abre el archivo con `open(ruta, O_RDONLY | O_EXLOCK | O_NONBLOCK)`: si falla con `EWOULDBLOCK`, está tomado; si abre (o el archivo no existe), está libre y hay que cerrarlo enseguida.
- El kernel suelta el lock cuando muere el proceso, aun con `kill -9` o un corte de energía. Un `recording.lock` que quedó en disco después de un crash no significa que se esté grabando.
- El lock pertenece al archivo abierto, no al proceso: un segundo `open` con `O_EXLOCK` dentro del mismo proceso también falla con `EWOULDBLOCK`.
- El que graba lo toma con `open(ruta, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW, 0644)` antes de marcar la toma como `recording`, y comprueba que es un archivo común (`fstat`) y que sigue siendo el de la ruta (`lstat`). Nunca sigue un enlace simbólico: un `recording.lock` que apunta a otro archivo hace fallar la toma de lock, y el archivo apuntado no se toca. Quien solo pregunta si está tomado abre también con `O_NOFOLLOW`. Al terminar borra el archivo y después lo cierra, en ese orden, para que nadie pueda quedarse con el lock de un archivo ya borrado.
- La recuperación toma el mismo lock mientras trabaja, así dos procesos nunca recuperan la misma toma a la vez ni recuperan una toma que sigue grabándose.
- El contenido es **solo informativo** y ninguna decisión depende de él:

```json
{
  "bootSessionUUID" : "5B1C3F0E-7C55-4E0F-9B67-3D1E2A9C8F10",
  "pid" : 4242,
  "startedAt" : "2026-11-13T16:00:12Z"
}
```

`bootSessionUUID` es `kern.bootsessionuuid`, que cambia en cada arranque de la Mac.

## `.reserve`

Mientras se graba una toma existe `takes/<toma>/.reserve`: 8 MiB de ceros escritos (bloques realmente asignados) y sincronizados con `F_FULLFSYNC` al empezar, antes de marcar la toma como `recording`.

- Es espacio de reserva, no datos de la toma. Si el disco se llena (el monitor de espacio pide parar, o una escritura de un segmento, del manifiesto o de `events.jsonl` falla con `ENOSPC`, o falla de otra forma con menos de 16 MiB libres en el volumen), la grabación lo borra primero y recién después hace las escrituras finales: cerrar los segmentos como `diskFull`, cerrar `events.jsonl` y marcar la toma `complete`. Al cerrar una toma por cualquier otro motivo también se borra.
- Una toma no empieza si el volumen tiene menos espacio libre que el que la detendría (1 GB disponibles ahora, sin contar el espacio purgable), aunque el espacio para uso importante sea mayor.
- Un `.reserve` que quedó en disco después de un crash no significa nada: la recuperación lo ignora y lo borra.

## `wallpapers/`

Opcional (versión 2). `takes/<toma>/wallpapers/display-<CGDirectDisplayID>.png` es una foto del fondo de pantalla de una pantalla que graba la toma, sacada al empezar a grabar: una por pantalla grabada (en modo Área, la del área; en modo Ventana, la que tiene la mayor parte de la ventana en ese momento). Es el fondo tal como se ve en el escritorio de ese momento (dinámico, en mosaico o el propio de ese escritorio), sin los íconos, los widgets, el Dock, la barra de menús ni ninguna ventana, con los píxeles de la pantalla, en sRGB. La captura incluye solo las ventanas que están al nivel del escritorio o por debajo (las del fondo): una ventana que aparece mientras se saca la foto (una notificación, por ejemplo) nunca queda en ella. Si ninguna ventana está a ese nivel, no hay foto. Es para el fondo "blur del escritorio original" del editor (spec §13), que llega con el editor con estilo.

- Es una carpeta común, nunca un enlace simbólico (ver [Rutas](#el-paquete)).
- Cada foto se escribe una sola vez y nunca sobre otra: `display-<id>.png.tmp` forzado a disco con `F_FULLFSYNC`, movido con `renamex_np(2)` y `RENAME_EXCL` (si ya hay algo con ese nombre, no se toca y el temporal se borra), y la carpeta forzada a disco.
- Puede faltar la carpeta, o la foto de alguna pantalla: en una toma de la versión 1, en las de `recorder-dev`, o si la foto no se pudo sacar en 3 s, no había ventana del fondo o no se pudo guardar (la toma sigue igual y la app lo anota en su registro). Nada depende de ella para leer o exportar una toma.
- En un volumen sin `RENAME_EXCL` (exFAT o SMB, por ejemplo) `renamex_np` da `ENOTSUP`: ninguna foto se guarda, no queda ningún archivo a medias, la app lo anota y la toma sigue igual.
- La recuperación no la toca.

## `cursors/`

Opcional (versión 3). `takes/<toma>/cursors/<hash>.png` es una imagen del cursor que mostró macOS durante la toma, la que nombra un evento `cursorImage`: una por imagen distinta, aunque el cursor vaya y vuelva entre dos formas muchas veces.

- La imagen está dibujada a `escala` píxeles por punto de su tamaño (`size` del evento): `escala = min(4, 512 / el lado más largo en puntos)`. Un cursor de hasta 128 pt sale a 4 píxeles por punto, así se ve nítido con zoom; uno más grande (el puntero más grande de Accesibilidad, un pincel grande) sale a menos, para que ningún lado pase de 512 píxeles, que es lo que lee el editor. Quien lee la imagen saca su escala de su ancho en píxeles dividido por el ancho en puntos del evento (≤ 4).
- **El nombre.** `<hash>` son los primeros 16 bytes, en 32 dígitos hexadecimales en minúscula, de SHA-256 sobre estos bytes, en este orden: el ancho de la imagen en píxeles (`Int32`, little-endian, 4 bytes), su alto en píxeles (`Int32`, little-endian, 4 bytes), la `x` y la `y` del hotspot en puntos desde arriba a la izquierda (cada una un `Float64` IEEE 754 en little-endian, 8 bytes: sus 64 bits tal cual) y los píxeles de la imagen: RGBA de 8 bits con alfa premultiplicado, sRGB, la fila de arriba primero, `ancho × 4` bytes por fila y sin relleno. El `hotspot` del evento es ese mismo punto como fracción del tamaño en puntos. Como el nombre es el contenido, la misma imagen con el mismo hotspot es siempre el mismo archivo.
- Una imagen cuyo PNG pasa de 1 MiB no se escribe (la app lo anota en su registro, y el evento tampoco).
- Cada imagen se escribe una sola vez y nunca sobre otra: si ya hay una con ese nombre, se deja.
- Es una carpeta común y sus imágenes, archivos comunes con un nombre exactamente `<hash>.png`. Un lector las abre sin seguir enlaces simbólicos y trata como ausente la que no cumple.
- Puede faltar la carpeta, o la imagen de algún evento: en una toma de las versiones 1 o 2, en las de `recorder-dev`, o si macOS no dio la imagen del cursor. Sin ella se dibuja el cursor de Toma; nada depende de ella para leer o exportar una toma.
- La recuperación no la toca.

## Cierre de una toma

La regla es la de los segmentos: el manifiesto dice que algo terminó solo cuando eso ya está en el disco. Al cerrar una toma, en este orden:

1. se detienen las fuentes y el registro de cursor y clics, y cada pista cierra su segmento (forzado a disco con `F_FULLFSYNC` antes de anotar su `endHostTime` y `endReason`);
2. se escriben las últimas líneas de `events.jsonl`, que se fuerza a disco con `F_FULLFSYNC` y se cierra;
3. la toma se marca `complete` en el manifiesto;
4. se suelta el lock (se borra `recording.lock` y se cierra).

La recuperación nunca toca una toma `complete`, así que si la app muere entre 2 y 3 la toma queda `recording` y se recupera con su `events.jsonl` entero; al revés, se perderían para siempre sus últimas líneas.

## Recuperación después de un crash

Una toma con `status` `recording` cuyo `recording.lock` no tiene nadie quedó abierta porque la app murió. La recuperación la cierra con lo que hay en el disco, sin borrar ni reescribir datos crudos:

- Antes de tocar nada comprueba las rutas (ver [Rutas](#el-paquete)): con un `id`, un `file` o un enlace simbólico que podrían sacarla del paquete, no cambia nada y no crea nada fuera de él. `events.jsonl` se abre con `O_NOFOLLOW` y tiene que ser un archivo común.
- Toma el lock de la toma mientras trabaja. No recupera nada mientras otra toma del mismo paquete se está grabando (su grabador es quien escribe `manifest.json`), y lo vuelve a comprobar, junto con que el manifiesto no haya cambiado, justo antes de escribirlo. Las tomas de un paquete se recuperan de a una y antes de grabar algo nuevo en él.
- No toca un manifiesto de un `formatVersion` que no lee (uno mayor que el que conoce). Al escribir el manifiesto conserva su `formatVersion`, su `projectID` y su `upgradedFrom`: un paquete v1 recuperado sigue siendo v1.
- Hace terminar `events.jsonl` en un límite de línea, como antes de agregarle líneas (ver arriba).
- Cierra cada segmento abierto (sin `endHostTime` o sin `endReason`) según lo que se puede leer de su archivo:
  - `recoveredAfterCrash`, con `endHostTime` igual a `startHostTime` más la duración legible, que llega hasta el último fragmento completo;
  - `empty` si el archivo tiene 0 bytes, no tiene ninguna muestra del tipo de su pista (video en `display`, `window` y `camera`; audio en `microphone` y `systemAudio`) o ya no existe;
  - `unreadable` con `bytes` si el archivo no está vacío pero su contenido no se puede leer; el archivo queda intacto;
  - en `empty` y `unreadable`, `endHostTime` es igual a `startHostTime`;
  - `droppedFrames` es el último `droppedSamples` del segmento (0 si no hay) y `heartbeatFrames` es 0.
- Si un archivo de segmento existe pero no se puede examinar ni abrir (por ejemplo, por permisos), se detiene sin cambiar el manifiesto (puede haber borrado `.reserve` y cortado la cola de `events.jsonl`): la toma sigue `recording` y se puede recuperar cuando el archivo se pueda leer.
- Un archivo de una carpeta de pista que el manifiesto no lista se agrega como segmento solo si su nombre es exactamente el de un segmento (`seg-0002.mov`) y `events.jsonl` tiene su `segmentStarted`, cuyo `t` pasa a ser su `startHostTime`. Si no, nada dice cuándo empieza: queda fuera del manifiesto y sin tocar.
- Borra el `.reserve` de la toma.
- Marca la toma `recovered` y escribe el manifiesto una sola vez, con todo. Recuperar una toma que ya no está `recording` no cambia nada.

## Interfaz de render (congelada)

La vista previa del editor y el export MP4 dibujan con el mismo código, y desde la fase 0 su interfaz no cambia sin una migración: lo que un proyecto muestra hoy lo vuelve a mostrar igual una versión nueva. **Un proyecto de la versión 1 o 2 sin editar da los mismos bytes que en la versión 2** (la última antes del editor), en los cuadros y en la mezcla de audio. Lo comprueban dos pruebas que comparan contra archivos grabados antes del primer cambio de render del hito 1b:

- `goldenFramesMatch` dibuja a 1280 × 720 los cuadros de cada caso de `GoldenProjects` (`phaseZero`, `windowMoving`, `areaOnDisplay`, `cameraWithStyleChanges`, `geometryChange` y `pausedTake`: v1 y v2, con una pantalla, una ventana que se mueve, un área, una cámara con cambios de estilo, un cambio de geometría y una pausa) y exige los mismos bytes; `goldenMixMatches`, lo mismo con las muestras de audio que recibe el codificador AAC a 60 cuadros por segundo, que incluye `twoAudioTracks`, el caso de dos pistas de audio.
- Los archivos (`frames.bin` y `frames.bin.mix`, con `VERSION`, la huella del sistema en que se grabaron, y `COMMIT`, el commit del que salieron) viven fuera de git, en `build/golden-1b/` del checkout principal, porque los bytes dependen de la GPU, del compilador de Metal del sistema y de VideoToolbox. `make golden` los compara. Nunca se regraban desde código posterior (`make golden-record` solo sirve desde ese commit): si cambia el sistema, `make golden` lo dice y se vuelven a grabar desde el commit original, no desde el código de ahora. Eso pasa con cada actualización de macOS, porque la huella incluye el build.
- Cada corrida vuelve a escribir el video de los casos, solo con el codificador HEVC de hardware, y dibuja desde ese video. El media engine de la Mac acepta pocas sesiones del codificador, compartidas por todos los procesos: cuando otros procesos las ocupan, el codificador por software escribe otro video, que se decodifica a píxeles distintos, sin que el render cambie. Por eso `goldenFramesMatch` espera al de hardware y distingue las dos causas:
  - `fixtures.sha`, al lado de los archivos, guarda el digest del video de cada caso (sin las NAL SEI, que cambian en cada archivo). Se graba una vez con `make golden-fixtures`, desde una corrida cuyos cuadros coinciden.
  - Si los cuadros difieren y el video es el de los digests, cambió el render: falla de inmediato. Si el video es otro, es el codificador: vuelve a escribir los casos, hasta tres veces, y lo anota en la salida.
  - Ante una diferencia, también vuelve a dibujar los mismos paquetes: si da otros bytes, el render no es determinista, y falla de inmediato.
  - Un cambio real del render falla los tres intentos, así que la prueba sigue probando lo mismo.
- Riesgo al regrabar: el commit de origen escribe el video de los casos con cualquier codificador. Si el media engine está ocupado mientras se graba, los cuadros grabados salen del video por software y ninguna corrida posterior coincide. Por eso hay que grabar con la Mac sin otro trabajo de video, y `make golden-accept`, el último paso de la receta que muestra `make golden`, corre `make golden` tres veces con el código de ahora: si alguna falla, aparta los archivos recién grabados (`build/golden-1b.rejected-<fecha>`); si no, graba `fixtures.sha`.
- Además: `legacyDocumentDrawsWhatTheOldInitDraws` (el documento legado dibuja lo que dibuja el inicializador de antes), `previewSnapshotEqualsTheExportFrame` (la vista previa en pausa y el cuadro del export son los mismos bytes en la misma Mac) y `nothingCutReachesTheExport` (lo cortado no llega al export, ni imagen ni sonido).

### De dónde sale el cuadro

Un cuadro es una función pura de (paquete, documento de edición, tiempo de salida, tamaño de salida, cuadros por segundo de salida): nada lee un reloj, un número al azar ni estado de interfaz. `FrameRenderer(project:outputSize:)` equivale a `FrameRenderer(project:document: .legacy(for: project), outputSize:)`.

**El documento legado** (`EditDocument.legacy`) es lo que dibujan las fases 0 y 1a: un solo tramo a 1× (`c-00000001`) sobre la línea de tiempo de siempre (con las pausas como cuadro quieto), la pantalla que elige `ScreenChoice` sin cambios, el degradado Toma clásico a 135° con el margen de la fase 0 (0,08) y las esquinas (0,012), sin desenfoque, sombra ni marco, el cursor de Toma de 24 pt interpolado como se grabó, el zoom sin bloques, la cámara tal como la grabó la toma (cada evento `cameraStyle`, un cambio con id `k-0000000N`) y cada pista de audio a ganancia 1 sin limitador. Un v3 con `upgradedFrom` y sin registro se abre con él. No se escribe nunca hasta la primera edición, así que sus ids son fijos.

**Cada valor nuevo tiene un valor legado exacto**: con él, el compositor hace las mismas llamadas de dibujo, en el mismo orden y con los mismos valores que la versión 2.

| Valor del documento | Valor legado (dibuja lo de siempre) |
|---|---|
| `style.background` | `gradient` con los colores de Toma clásico |
| `style.backgroundBlur` | 0 |
| `style.shadow` | 0 (no se dibuja nada) |
| `style.frame` | `none` |
| `style.screenSampling` | `bilinear` |
| `style.geometryTransition` | `none` (salta) |
| `cursor.style`, `cursor.scale` | `toma` a escala 1 (24 pt de alto) |
| `cursor.smoothing` | `off` (la regla de siempre; sin el achique de 0,85 al apretar) |
| `cursor.hideWhenIdle`, `clickEffect`, `clickSound` | apagados, `none`, `none` |
| `cursor.motionBlur`, `zoom.motionBlur` | 0 |
| `zoom.regions` | sin bloques (el zoom en reposo) |
| `screens` | una sola pantalla, sin cambios |
| `audio` | ganancias 1, sin silenciar, sin limitador |
| `sequence` | un solo tramo a 1× |

El video grabado no tiene canal alfa, así que la pantalla se dibuja siempre opaca y el documento no tiene un campo para eso.

### El mapeo de tiempo y los cuadros

`TimeMap` convierte entre el tiempo de salida y el de la fuente (el `HostTime` de la toma) con enteros de nanosegundos, así no se acumula error. Con tramos `k` de fuente `[s_k, e_k)` y velocidad `v_k` (leída con `ClipSpeed.clamped`: de 0,25 a 16, y 1 si no es un número, así un documento editado a mano nunca frena el render):

- La duración de salida de un tramo es `D_k = round((e_k − s_k) / v_k)` ns; el tramo empieza en `O_0 = 0`, `O_{k+1} = O_k + D_k`; la duración total es `D = O_n`. Un tramo cuyo `D_k` da 0 nunca se muestra.
- **Salida → fuente:** el tiempo `τ` se recorta a `[0, D − 1]` ns; con `k` el tramo con `O_k ≤ τ < O_k + D_k`, la fuente es `s_k + round((τ − O_k) × v_k)` recortada a `[s_k, e_k − 1]`. Una salida de 0 ns solo dibuja el fondo.
- **Fuente → salida:** si `s_k ≤ x < e_k`, `O_k + round((x − s_k) / v_k)`; si no, `x` está cortado y no tiene salida. Un rango de la fuente `[a, b)` (un zoom) se ve en el rango de salida que va de la imagen del primer instante conservado a la del final del último, así que los cortes de adentro se cierran y un bloque partido por un corte sigue siendo uno.
- **El cuadro `n`** está en `round(n / fps × 10⁹)` ns, calculado en `Double` como lo cuenta el export desde la fase 0; el export tiene `max(1, round(D / 10⁹ × fps))` cuadros. En el documento legado esto da exactamente `timelineStart.adding(seconds:)` y los mismos cuadros que antes.
- **Antes del primer tramo.** Una muestra del cursor (`cursor`, `mouseDown`, `mouseUp`) que la grabación tomó antes del `startHostTime` del primer tramo cuenta en su tiempo de salida extrapolado por ese tramo (negativo), no se descarta: el cursor ya estaba ahí en el cuadro 0. Un cambio de la cámara anterior al primer tramo está en marcha en el instante 0 de salida (su transición se mide desde su tiempo extrapolado); uno dentro de un corte rige desde el primer instante conservado después, y uno posterior al último tramo nunca rige. Una muestra del cursor dentro de un corte entre dos tramos se descarta; un cambio (de la cámara o de la pantalla) dentro de un corte rige desde el primer instante conservado después.

### El orden de dibujo

Todo pasa por `FrameRenderer.encode(at:into:commandBuffer:)` y `Compositor.encode`, que dibuja en una textura `.bgra8Unorm` (nunca `_srgb`: la vista previa y el export escriben los mismos bytes) del tamaño de salida, con mezcla premultiplicada "over", siempre en este orden:

1. **Dentro del escenario** (lo que la cámara del zoom transforma), para cada submuestra del desenfoque de movimiento: el fondo, la sombra, el marco de ventana, la pantalla (si se está cambiando de pantalla, primero la que se deja, abajo, y encima la nueva con su opacidad), el cursor y, una sola vez por cuadro, los efectos de clic (el zoom los agranda; nunca se desenfocan).
2. **En el espacio de salida:** la cámara (la burbuja).

Con una sola submuestra, todo se dibuja directo en el destino, en un solo pase. Con varias, siguen siendo un solo pase: cada submuestra se suma con peso `1/N` en una textura `rgba16Float` que vive en la memoria de los tiles, en orden fijo, y un último dibujo escribe el promedio al destino antes de los efectos de clic y la cámara. Misma GPU, mismos bytes.

### Cada capa

- **Fondo** (`style.background`). `gradient`: el shader de siempre, con sus dos colores y su ángulo (`angle` en grados como en CSS: 0 va hacia arriba, 90 a la derecha, 135 abajo a la derecha). `color`: un degradado de dos colores iguales, escritos tal cual a la salida (valores sRGB de 0 a 1). `wallpaper`: uno de los 12 fondos de Toma, procedurales (`aurora-1`, `dune-1`, `lake-1`, `ember-1`, `mist-1`, `forest-1`, `lavender-1`, `midnight-1`, `coral-1`, `ice-1`, `graphite-1`, `sand-1`; sus colores y posiciones se congelan con su id): una malla de 1 a 6 puntos de color (en fracciones del escenario), donde cada color pesa `exp((d²_mín − d²) / 0,06)` con `d²` la distancia al cuadrado al punto, en unidades del lado más largo del escenario, normalizado por la suma de los pesos; más un **grano** de ±2 % sacado de un hash entero (lowbias32, de Chris Wellons) de las coordenadas del píxel *de salida* (`hash32(x ^ hash32(y))`), no del punto del escenario: el zoom agranda la malla y no el grano, y el desenfoque la suaviza y no el grano, a cualquier tamaño. `image`: la imagen del paquete (`assets/<sha>.<ext>`, ya reducida a 7680 px de lado como mucho y en el sentido de su orientación EXIF) cubriendo el escenario, aspect fill y centrada. `desktop`: la foto del escritorio de la primera pantalla que se ve (`wallpapers/`), igual que una imagen; una ventana no tiene. Un fondo de pantalla que esta versión no conoce, una imagen que falta o no se puede leer, y `desktop` sin foto dibujan el degradado Toma clásico.
- **Desenfoque del fondo** (`style.backgroundBlur`, 0 a 1): σ = valor × 0,04 × el ancho de salida, en píxeles. Se hace una vez por (fondo, tamaño de salida, σ) y la textura se reusa (el fondo no cambia con el tiempo): un gaussiano separable (`MPSImageGaussianBlur`, y el del shader donde MPS no existe) **con el borde `clamp`**: el valor por defecto, `zero`, traería negro de afuera y, con σ de cientos de píxeles, oscurecería todo el borde del escenario. En un fondo de pantalla se desenfoca la malla sola y el grano se suma después, nítido.
- **Pantalla y marco.** La pantalla ocupa el rectángulo más grande con la proporción de lo que se muestra, centrado dentro del margen (`style.padding` es una fracción del ancho de salida), con esquinas de `style.cornerRadius × ancho`. Con `style.frame` = `macWindow`, el rectángulo es el de la ventana entera (barra y pantalla): una barra de título arriba de alto `max(0,032 × ancho de la ventana, 18 px)`, clara (#ECECEC) u oscura (#2B2B2E); con `buttons`, tres círculos genéricos (rojo #FF5F57, amarillo #FEBC2E, verde #28C840) de diámetro 0,42 del alto de la barra, con centros a 0,66 de distancia, el primero a 0,6 del borde izquierdo y a la mitad de la barra; y el título, centrado en la ventana, en **la fuente del sistema para títulos de ventana** (CoreText con `CTFontCreateUIFontForLanguage(.windowTitle)`, con el idioma fijado en `en` para que los glifos chinos, japoneses y coreanos no cambien con el idioma del sistema), a 13/28 del alto de la barra, negro (claro) o blanco (oscuro) al 85 %, cortado con «…» donde se acerque a los botones. La textura del título se dibuja con CoreText sin suavizado de fuente ni posicionamiento subpíxel, así no depende de los ajustes del Mac ni de la pantalla; **pero la fuente cambia de un macOS a otro, y sus bytes con ella**: los cuadros con un título cambian de bytes con el sistema (la dorada no tiene marco). Las esquinas de la ventana son las del estilo pero nunca más de 1,3 veces el alto de su barra, para que no corten el primer botón; la pantalla va sin esquinas arriba, bajo la barra. Una captura de ventana trae las esquinas redondeadas de la ventana en negro, con un radio que depende del macOS que grabó y que el formato no guarda: un proyecto nuevo de una toma de ventana empieza con unas esquinas que tapan 26 pt de la ventana (`WindowCornerCover.blackCornerPoints`, provisional hasta medirlas en macOS 15 y 26). Con el marco puesto, alrededor de una ventana grabada las de abajo llevan el radio del estilo y las de arriba de la pantalla, redondas, con la barra detrás.
- **Sombra** (`style.shadow = s`, de 0 a 1): bajo el rectángulo de la pantalla (o de la ventana entera con marco), con sus esquinas inferiores: opacidad `0,55 · s`, σ `(0,004 + 0,016 · s) × ancho de salida` y un desplazamiento hacia abajo de `0,010 · s × ancho`. Con `s = 0` no se dibuja nada. La sombra de un rectángulo redondeado desenfocado por un gaussiano se calcula en un solo pase, sin texturas, con la fórmula de Evan Wallace («Fast Rounded Rectangle Shadows»): a lo largo de x, exacta, `½ (erf((x + a) k) − erf((x − a) k))` con `k = 0,70710678 / σ` y `a` el semiancho de la caja en esa fila (más angosto en las esquinas redondeadas); a lo largo de y, esa fila integrada contra el gaussiano en **`ShadowMath.ySamples` = 4 muestras** al medio de pasos iguales sobre `[−3σ, 3σ]` recortado a la caja. Como Metal no tiene `erf`, el shader y `ShadowMath` (la referencia en CPU, en `Float` y en el mismo orden) usan la aproximación de Abramowitz y Stegun 7.1.26: `erf(x) = signo(x) · (1 − (a₁t + a₂t² + a₃t³ + a₄t⁴ + a₅t⁵) e^(−x²))` con `t = 1 / (1 + 0,3275911 |x|)`, `a₁ = 0,254829592`, `a₂ = −0,284496736`, `a₃ = 1,421413741`, `a₄ = −1,453152027` y `a₅ = 1,061405429`, a menos de 1,5 × 10⁻⁷ del `erf` exacto.
- **Muestreo de la pantalla** (`style.screenSampling`). `bilinear`: el de siempre. `mipmapped` (proyectos nuevos): el recorte del cuadro (los píxeles enteros de lo que se muestra, redondeado hacia adentro) se copia en la GPU a una textura con mipmaps, que se generan en cada cuadro, y se muestrea trilineal: el texto de una captura Retina no titila al achicarse. Ni la copia ni ninguno de sus niveles tiene un solo texel de fuera del recorte: nunca se ve lo que un área dejó afuera. El nivel se elige con la velocidad con que cambian las coordenadas antes de recortarlas.
- **Cursor** (`cursor`). Su lugar sale del camino simulado (abajo), en lo que se muestra de la pantalla; no se dibuja fuera de eso, ni mientras la ventana no está en pantalla. Su imagen, con la del último evento `cursorImage` en o antes del instante de la fuente: en `system`, la imagen grabada (`cursors/<hash>.png`, una textura con mipmaps por imagen), y la flecha de Toma antes del primer evento, si la imagen falta o no se puede leer, o si no tiene un tamaño usable; en `toma`, el cursor de Toma del `kind` grabado (dibujados en código, negros con un contorno blanco, originales, sin arte de Apple: `arrow`, `iBeam`, `pointingHand`, `openHand`, `closedHand`, `crosshair`, `resizeLeftRight`, `resizeUpDown`, `notAllowed`, cada uno una textura de 128 px de alto que equivale a 24 pt), la imagen grabada si el evento no tiene `kind`, y la flecha si la toma no tiene imágenes (v1 y v2). El alto dibujado es `cursor.scale × alto en puntos × alto del rectángulo de la pantalla / alto de lo que se muestra en puntos`: 24 pt en `toma`, el `size.y` del evento en `system`. El hotspot de la imagen cae en la posición simulada. Al apretar un botón (con suavizado distinto de `off`), el cursor se achica hacia 0,85 con un resorte 0,70 · 0,18 s y vuelve igual al soltar.
- **Efectos de clic** (`cursor.clickEffect`, congelados con su id). `ripple-1`: durante 0,5 s desde cada `mouseDown` conservado, τ segundos después, un anillo de radio `h × (0,25 + 1,35 × easeOutCubic(τ / 0,5))` y `0,08 h` de grosor, blanco con opacidad `0,55 × (1 − τ / 0,5)²` y un contorno de 1 px negro al 25 % que se apaga con el blanco, con `h` el alto del cursor dibujado en el clic. `circle-1`: mientras el botón está apretado, un círculo blanco al 22 % de radio `0,9 h`, que entra escalando de 0,6 a 1 en 0,12 s y sale linealmente en 0,20 s desde que se suelta (un soltar que los eventos perdieron nunca lo sostiene más allá del clic siguiente). Cada efecto queda donde fue el clic, en la pantalla y en el rectángulo que se veían entonces, y no cambia de tamaño si la imagen del cursor cambia; no hay efecto para un clic fuera de lo que se muestra ni con la ventana fuera de pantalla. Un id que esta versión no conoce no dibuja nada.
- **La cámara de zoom** (`zoom`, diseño §7.4). El escenario mide `W × H` (la salida). El estado de la cámara es `u = ln z` (con `z` la profundidad, 1 en reposo) y el centro `c` del recorte visible, que mide `(W, H) / z`; la transformación es `salida = (escenario − c) × z + (W, H) / 2`. **Acomodo:** el recorte nunca sale del escenario y, en cada eje en que ya cabe en el rectángulo de la pantalla (o de la ventana con marco), tampoco sale de él: con el zoom adentro no se ve fondo de un costado. El camino se simula en unidades del escenario (alto = 1) y la profundidad se acomoda otra vez, al dibujar, sobre el rectángulo de la pantalla en este tamaño (`StageCrop`), porque el camino sitúa la ventana a una referencia de 1080 px que unos píxeles abajo de eso no calza. El enfoque `follow` va con zona muerta: si el cursor suavizado sale de la caja central del recorte (el 60 % en cada eje), el objetivo se corre lo que se salió más el 15 % del recorte, y un cursor que queda debajo de la burbuja de la cámara (su rectángulo agrandado un 8 %) cuenta como salido hacia su lado, para que la burbuja nunca tape el cursor. El resorte de la cámara (`zoom.spring`, 1,0 · 0,70 s por defecto) es el mismo para `u` y para cada eje del centro; un bloque `instant` salta al objetivo con velocidad 0. Sin bloques o con `zoom.show` apagado, la cámara está en reposo y no se dibuja ninguna transformación.
- **Desenfoque de movimiento** (`zoom.motionBlur` y `cursor.motionBlur`, de 0 a 1: el obturador, como fracción de un cuadro del `frameRate` con que se dibuja). Con `N = clamp(ceil(d / 1,5 px), 1, 16)`, donde `d` es lo que se mueve en píxeles de salida entre `t − σ/2` y `t + σ/2` la esquina del escenario que más se mueve (para el cursor, su hotspot por la profundidad del zoom), las submuestras están en `τ_j = t + (j / (N − 1) − ½) · σ · (duración de un cuadro)`, en tiempo de salida, así que ninguna lee lo que un corte dejó afuera; el contenido de la pantalla, la imagen del cursor y los efectos son los de `t` en todas: se desenfoca el movimiento, no el video. Si solo se mueve el cursor, el escenario se dibuja una vez y el cursor `N` veces. **Se acumula en un solo pase** (ver arriba). Con obturador 0, o `N = 1`, no hay submuestras: un solo dibujo, como sin desenfoque.
- **La cámara (burbuja).** Como en la versión 2 (ver más abajo), con `camera.show` y el estilo de `camera.initial` y `camera.changes` en tiempo de salida; los cambios se transicionan con el resorte de forma y tamaño de siempre.
- **Cambios de pantalla y de geometría** (`style.geometryTransition`, diseño §7.6). Con `none`, saltan (legado). Con `spring`, un cambio de pantalla mostrada (`screens.changes`) o de la forma de lo que se muestra (un `displayGeometry` o `windowGeometry` que cambia la proporción a mitad de toma) mueve el rectángulo de la pantalla (y el de la ventana y su barra) del viejo al nuevo por `1 − (1 + ωt) e^(−ωt)` con ω = 2π / 0,30 s (un resorte crítico: el 90 % a los ~0,2 s; 1 desde 1,5 s), y el video llena el rectángulo intermedio sin estirarse (aspect fill: recortado a su forma, y nunca más allá de su recorte, así que un área nunca muestra lo que dejó afuera). Un cambio de pantalla también funde el contenido en 0,25 s: la pantalla que se deja queda abajo, en el mismo instante de la fuente y el mismo rectángulo, y la nueva entra encima con opacidad de 0 a 1. Un cambio que llega mientras otro se mueve parte del rectángulo que se veía. El cursor y los efectos pasan a la pantalla nueva desde el instante del cambio.
- **La cámara del video** (la burbuja) y **la pantalla** conservan las reglas de la versión 2 (abajo).

### El movimiento: la simulación a 600 Hz

El cursor dibujado y la cámara del zoom se simulan en tiempo de salida, desde el instante 0, con un paso fijo de 1/600 s (Euler semi-implícito, el de `SpringValue`: `a = −ω²(x − objetivo) − 2ζωv`, `v += a·dt`, `x += v·dt`, con ω = 2π / response y ζ = damping). Se elige 600 Hz porque todos los `frameRate` del documento (24, 25, 30, 50 y 60) caen exactos: el paso del cuadro `n` es `n × 600 / frameRate`, en enteros. Cada resorte pasa por `StepGrid.stable` (una respuesta de al menos 0,06 s y un damping de 0 a 2) para que un documento editado a mano nunca diverja.

- **Puntos de control.** Se guarda el estado entero cada 600 pasos (1 s). Evaluar un instante toma el punto de control anterior y simula hasta él (a lo sumo 600 pasos): sobre la grilla da los mismos bits desde cualquier punto de control, que es lo que hace iguales la vista previa y el export. Un tiempo fuera de la grilla mezcla linealmente las muestras de los dos pasos de al lado; pasado el final, el estado queda como en el último paso. Los objetivos se leen en cada paso (lo que cambia entre dos pasos se toma en el siguiente); primero se mueve el cursor y después la cámara, que lo sigue. Se rearman una vez por revisión del documento, fuera del hilo principal, y una revisión que no cambia nada de lo que leen (fondo, sombra, esquinas, desenfoque del fondo, muestreo) se queda con los caminos de la anterior.
- **`StepGrid.position(ofOutput:)`** dice dónde cae un tiempo de salida `τ` (ns) sobre la grilla, en enteros: con `r = (τ × 600) mod 10⁹`, es el paso exacto `round(τ × 600 / 10⁹)` con fracción 0 si `r ≤ 600` o `r ≥ 10⁹ − 600`, y si no, el paso de abajo con fracción `r / 10⁹`. Como redondear el tiempo de un cuadro a nanosegundos lo mueve a lo sumo 1/3 ns (200 de esas unidades), **todo cuadro de 24 a 60 fps de `TimeMap.frameTime` cae exactamente en su paso** y el export y la vista previa en pausa leen ese paso, no una mezcla de dos.
- **Cursor.** Con `smoothing` `off`: la regla de siempre en el instante exacto de salida (la última posición cruda en o antes de él, movida hacia la siguiente si llega a menos de 50 ms). Con un resorte: zona muerta de 1,5 pt contra el temblor (el objetivo no se mueve mientras la posición cruda esté a menos de eso); **aterrizar en el clic** (con el próximo `mouseDown` a 0,5 s o menos, el objetivo es el punto del clic y en sus últimos 0,175 s el `response` baja linealmente a 0,06 s: en el paso del clic el cursor está exactamente en el clic, en reposo); con un botón apretado, el objetivo es la posición cruda con 1,0 · 0,06 s, para que un arrastre se vea preciso. Con `hideWhenIdle`, la opacidad baja en 0,30 s (ease in-out) cuando la posición cruda no se mueve más de 3 pt durante `idleDelay` y vuelve en 0,15 s, empezando 0,10 s antes de que se mueva (0,15 s antes de un clic); nunca se oculta a menos de 0,5 s de un clic ni con un botón apretado. Lo cortado no existe: las muestras de un corte se descartan y el resorte sigue desde donde estaba.

### El audio

Una sola función de mezcla (`EditedMix`) a 48 kHz para el export y la vista previa: para cada tramo, cada pista lee el rango de la fuente que el tramo conserva (ubicada por host time con sus propias anclas `audioClock`, como siempre), con su ganancia de `audio.tracks` (de 0 a 2; 0 si está silenciada; 1 para una pista que el plan no nombra); las pistas se suman con los sonidos de clic, pasan por el limitador si `audio.limiter` y se recortan a [−1, 1]. La mezcla es mono si todas las pistas lo son, y estéreo si no.

- **Largo.** El tramo `k` ocupa los cuadros de audio `round(O_k × 48 000 / 10⁹) ..< round(O_{k+1} × 48 000 / 10⁹)`, y la mezcla dura `round(frameCount / fps × 48 000)` cuadros, lo que dura el video: después del contenido, silencio; antes de su final, el contenido se corta.
- **Bordes de los cortes.** Donde dos tramos se encuentran y el sonido saltaría (un corte, otra toma, otra velocidad), el de antes baja y el de después sube linealmente en 192 cuadros (4 ms). Donde el tramo siguiente sigue la fuente del anterior (una división sin corte, a la misma velocidad) no hay fundido y la mezcla es la del tramo sin dividir. La salida nunca se funde al principio ni al final: el documento legado, de un tramo, mezcla las mismas muestras que siempre.
- **Velocidad.** Hasta 4× se estira conservando el tono con `AVAudioUnitTimePitch` en render manual sin conexión (`SpeedStretch`), pista por pista y antes de la ganancia, desde el comienzo del tramo (o de la corrida de tramos contiguos de la misma toma a la misma velocidad), hasta el largo exacto de muestras que da el mapeo. **Se compensa la latencia del estirador** (la que informa el efecto, 0 en macOS 26: se descartan sus primeras `round(latencia × 48 000)` muestras y se lo alimenta más allá del final del tramo) y cada bloque se renderiza a la tasa del paso entero que más acerca lo que toma de entrada a `velocidad × salida`, así el sonido queda a menos de 8 cuadros de entrada de donde lo pone el mapeo por largo que sea el tramo. Por encima de 4× el tramo va en silencio. Al estirar solo se alimenta lo que se oye junto con el tramo: nunca lo que se cortó.
- **Limitador** («Evitar la saturación»): un limitador de picos determinista, con 5 ms de anticipación, una liberación de 50 ms y un techo de −1 dBFS, la misma ganancia en todos los canales. Sin él, el recorte de siempre.
- **Sonidos de clic** (`cursor.clickSound`, **sintetizados en código**, sin ningún archivo de audio: mono a 48 kHz, de 60 ms como mucho, con picos de a lo sumo 0,5, empiezan y terminan en 0 y su media es 0; el ruido sale de un hash entero del índice de la muestra, nunca de un número al azar). `soft-1`: un golpe suave de 45 ms (ruido por dos filtros pasa-bajos de un polo a 1,8 kHz con un decaimiento de 6 ms, sobre un tono grave de 140 Hz que decae en 11 ms). `mechanical-1`: una tecla de 55 ms (un golpe al bajar y otro más suave 29 ms después al subir, cada uno una ráfaga de ruido diferenciado que resuena a 2,35 y 2,9 kHz sobre el cuerpo de la tecla a 620 Hz). Suena uno por cada `mouseDown` izquierdo o derecho que los tramos conservan, en su cuadro de salida, a `clickSoundGain`, sin estirar; dos a menos de 40 ms suenan una vez.

### Lo que dibuja el documento legado (versiones 1 y 2)

Las reglas de abajo son las de siempre: el documento legado las cumple tal cual y los documentos nuevos las generalizan con los valores de arriba. Una toma de la versión 2 de una sola pantalla, sin cámara ni área, se dibuja como una de la versión 1 mientras su `displayGeometry` no cambia; si cambia a mitad de la toma, desde ahí se dibuja con la geometría nueva (la fase 0 la habría estirado), saltando al marco nuevo.
Una toma sin segmentos de pantalla sigue fallando con `noDisplayTrack` en el documento legado; en uno editado se exporta el fondo, la cámara y el audio.

- **Pantalla** (`ScreenChoice`). Las candidatas son las pistas de pantalla (`display` o `window`) con al menos un segmento. Con una sola, esa, esté donde esté entre las pistas de la toma: una `display-1` sin segmentos no deja la toma en blanco. Con varias, la que contiene en su `globalFrame` la primera posición del puntero de la toma (el primer evento `cursor`, `mouseDown` o `mouseUp` por `t`); si ninguna la contiene o no hay eventos, la primera candidata. Sin candidatas, la primera pista de pantalla, como en la versión 1, y el export falla con `noDisplayTrack`. Con una sola pantalla grabada (siempre en la versión 1), es la misma que antes.
- **Línea de tiempo** (`FrameEvaluator`). El tiempo de salida 0 es el `startHostTime` del primer segmento de la pantalla. La línea de tiempo termina en el final más tardío (el inicio, si el segmento sigue abierto) de un segmento de esa pantalla o de cualquiera de las pistas de audio que el export mezcla (todas las `microphone` y `systemAudio`): el audio grabado después del último segmento de la pantalla (una pantalla que no volvió) se exporta sobre el último cuadro de la pantalla. Una toma sin segmentos de pantalla tiene una línea de tiempo de 0 s. Los tiempos de salida se recortan a `[0, duración]`. El cuadro de un tiempo es una función pura de la toma, sus eventos, el documento y el tamaño de salida.
- **Geometría de la pantalla.** Dónde está la pantalla en un instante, en puntos globales: en una `display`, el último evento `displayGeometry` de su `displayID` con `t` hasta ese instante; en una `window`, el último `windowGeometry` de su pista; antes del primero, su `globalFrame`. Un `displayGeometry` con un `frame` que no es finito y de tamaño positivo se ignora; un `windowGeometry` así deja la ventana donde estaba, pero su `onScreen` cuenta (ver **Cursor**). Una toma v1 tiene un solo `displayGeometry` por pantalla, el del inicio, igual a su `globalFrame`: no cambia nada.
- **Lo que se muestra de la pantalla.** En una pantalla grabada en modo Área, el `captureArea` como recorte del cuadro (`ScreenLayer.crop`). El área queda donde estaba en la pantalla al empezar la toma: su desplazamiento se mide desde el origen de `globalFrame` (el marco de la pantalla cuando se eligió el área) y su tamaño, contra la geometría de la pantalla en ese instante (`gf`): `((area.x − globalFrame.x) / gf.width, (area.y − globalFrame.y) / gf.height, area.width / gf.width, area.height / gf.height)`, recortado a `[0, 1]`. Así, si la pantalla se mueve (otra disposición, o un modo que corre su origen), el área se mueve con ella. Mientras ninguna parte del área cae en la pantalla, y en toda la toma si el área no se puede ubicar (un `captureArea` con algún valor que no es finito o con un tamaño que no es positivo, igual que un área fuera de la pantalla; o una pantalla sin un `globalFrame` finito y de tamaño positivo), no se dibujan ni la pantalla ni el cursor (el fondo, y la cámara si hay): nunca se muestra lo que el usuario dejó fuera del área. Sin área, el cuadro entero. El rectángulo de la pantalla en la salida es el más grande con la proporción de lo que se muestra (el área recortada, la pantalla o el marco de la ventana) centrado dentro del margen. El cuadro grabado llena ese rectángulo con los píxeles que tenga: los píxeles por punto de cada segmento salen de su propio tamaño, nunca de `pixelScale`, así que una ventana que pasa a una pantalla de otra escala (un segmento con otros píxeles por punto) se sigue dibujando entera.
- **Cursor.** Se ubica en lo que se muestra (el área recortada en puntos globales, `gf.origin + (area.origin − globalFrame.origin)` con el tamaño del área recortada; la pantalla; o el marco de la ventana) y no se dibuja fuera de eso; su alto es `cursorPointHeight` (24) puntos de eso. Una ventana con `onScreen` en `false` se sigue dibujando, sin cursor; un `windowGeometry` con un `frame` que no se puede usar deja la ventana donde estaba, pero su `onScreen` cuenta.
- **Cámara.** La primera pista `camera` con segmentos, desde el `startHostTime` de su primer segmento; antes no se dibuja. Su cuadro es el del mismo instante que la pantalla; entre dos segmentos, y después del último, se mantiene el último cuadro. No alarga la línea de tiempo. Su estilo es el `cameraStyle` de la toma o, sin él (siempre en la versión 1), `CameraStyle.default`: un círculo mediano abajo a la derecha. Su lugar es `CameraStyle.frame(in:)` con la salida entera `(0, 0, W, H)` como región: un lado de `size × H`, un ancho de `lado · √proporción` y un alto de `lado / √proporción`, a `0,032 × H` de los bordes de su anclaje y centrada en el otro eje; de radio, la mitad del lado más corto en el círculo, el 26 % del lado en el cuadrado redondeado, y `20 / 750 × H` y `18 / 750 × H` en el vertical 3:4 y el horizontal 16:9. En cada evento `cameraStyle`, x, y, ancho, alto y radio van del valor que se veía en ese instante (con la transición anterior, así una ráfaga de cambios no salta) al del estilo nuevo, por `progress(t − t_evento)` (`CameraStyleTimeline`): la respuesta al escalón del resorte de forma y tamaño, `1 − e^(−ζωt)(cos(ω_d t) + (ζω/ω_d) sin(ω_d t))` con ζ = 0,95 (damping), ω = 2π / 0,5 s (response) y ω_d = ω√(1 − ζ²); 0 hasta 0 s y 1 desde 1,5 s. El cuadro de la cámara llena su rectángulo sin estirarse (se recorta al centro hasta su proporción), con esas esquinas redondeadas; el video no se espeja.
- **Cuadros de la pantalla y de la cámara** (`TrackFrameReader`, uno por pista). En un tiempo se muestra el último cuadro presentado en ese instante o antes. Un segmento `empty` o `unreadable`, un archivo que falta, uno que no se puede abrir o leer, y lo que no se pudo decodificar son huecos: se mantiene el cuadro anterior (o nada de esa pista, antes de su primer cuadro legible), y cada hueco se informa con su pista (`MissingVideo.track`, en `FrameRenderer.missingVideo` y `ExportSummary.missingVideo`). Si la lectura se corta con un error a mitad de un segmento, se vuelve a abrir justo después del último cuadro y, si se corta en el mismo lugar, cada vez `preroll` (1 s) más adelante, hasta decodificar o llegar al final del segmento.
- **Dibujo** (`FrameRenderer`, `Compositor`). Todo pasa por `FrameRenderer.encode(at:into:commandBuffer:)`, que dibuja con `Compositor.encode` en una textura `.bgra8Unorm` del tamaño de salida, con el documento legado siempre en este orden: el degradado, la pantalla, el cursor y la cámara (el orden de los documentos nuevos está arriba). `render(at:into:)` (un `CVPixelBuffer` 32BGRA, para el export) y `renderBytes(at:)` (bytes BGRA sin relleno) lo usan, igual que la vista previa. Mismo proyecto, mismo tiempo y mismo tamaño dan los mismos bytes en la vista previa y en el export.
- **Audio** (`AudioTrackTimeline`, `AudioMix`). El MP4 tiene una sola pista AAC: la mezcla de todas las pistas `microphone` y `systemAudio` de la toma (en la fase 1a, a lo sumo una de cada), o ninguna si la toma no tiene pistas de audio. Cada pista se ubica en la línea de tiempo por host time con sus propias anclas `audioClock` (ver [Tiempos](#tiempos)), así dos relojes que derivan distinto no se corren uno respecto del otro; antes del primer segmento de una pista, entre segmentos y después del último, esa pista es silencio. Las pistas se suman a ganancia 1 y la suma se recorta a [−1, 1], nunca da la vuelta. La mezcla es mono si todos los segmentos que se pueden abrir, de todas las pistas, lo son, y estéreo si no: un segmento mono va a los dos canales, uno estéreo queda como está y uno de más canales se mezcla con todos sus canales a ganancia 1 en cada canal, recortado. La línea de tiempo llega hasta el final de la pista de audio que termina más tarde (ver **Línea de tiempo**). Lo que no se pudo usar queda en silencio en su pista y se informa con ella (`ExportSummary.missingAudio`, `MissingAudio.track`).

### Lo que suma el hito 1c: la segunda dorada y los layouts

**La segunda dorada.** Desde el hito 1c hay otra pareja de pruebas que fija lo que dibujaba 1b, ahora para los documentos de edición de 1b (`documentVersion` 1) que 1c migra al documento 2:

- `golden1cFramesMatch` dibuja a 1280 × 720 los cuadros de seis documentos de `GoldenDocuments` (`backgroundsAndFrame`, `cameraChanges`, `cutsAndSpeed`, `portraitBubble`, `twoScreens` y `zoomWithBlur`: fondos y marco, cámara con cambios de estilo, cortes y velocidad, burbuja en 9:16, dos pantallas, zoom con desenfoque), **migrados a la versión 2**, y exige los mismos bytes que dibujó 1b; `golden1cMixMatches`, lo mismo con las muestras de audio de la mezcla.
- Los archivos (`frames.bin`, `frames.bin.mix`, `documents/<caso>.json` con los documentos tal como los escribe 1b, `fixtures.sha`, `VERSION` y `COMMIT`) viven fuera de git, en `build/golden-1c/` del checkout principal, por la misma razón que los de 1b. Se grabaron una sola vez, desde el commit que cierra 1b (`f3e2da0`: solo suma pruebas y el `Makefile`), y `make golden-1c` los compara. **Nunca se regraban desde código posterior**: con otro macOS, `make golden-1c` lo dice y da la receta, que vuelve a grabar desde el commit de `COMMIT` en un worktree aparte. `make golden` (la de 1b, fijada en `b04e0c3`) sigue corriendo: las dos dicen lo mismo de lo que 1b dibujaba.
- Con la dorada de 1c, un proyecto de 1b migrado al documento 2 da **los mismos bytes** en los cuadros y en la mezcla, y la vista previa sigue siendo el cuadro del export (`previewSnapshotEqualsTheExportFrameWithLayouts` suma los cinco layouts, las transiciones, el zoom en la tarjeta y el espejo).

**Cada valor nuevo tiene su valor legado exacto**, como los de arriba: con `layouts` vacío, `layout` Burbuja, `mirror` en `false`, `border.width` 0, `shadow` 0 y `sizeReference` `height`, el compositor hace las mismas llamadas de dibujo, en el mismo orden y con los mismos valores que en 1b. No agrega pases para un borde o una sombra en 0, no muestrea distinto por el espejo y no mezcla por una opacidad de 1.

**`cameraLayout-1`** (`camera.layoutRules`) son las reglas de geometría, de transición y de zoom de los layouts, un aspecto definido en código y congelado: el código conserva las versiones viejas, y un cambio se publica como `cameraLayout-2`, nunca como un cambio de la 1. Notación: salida `W × H`, lado corto `s = min(W, H)`, margen `m = padding × W` en cada lado, área útil `A` (la salida menos el margen), `aₛ` la proporción de lo que se muestra de la pantalla (con el marco de ventana de macOS, la ventana entera con su barra).

- **Burbuja.** `CameraStyle.frame(in:)` sobre la salida entera, con una longitud de referencia `ref`: `H` con `sizeReference` `height` (lo de 1a y 1b) y `s` con `shortSide` (los proyectos nuevos de 1c). El lado (`size × ref`), el margen (`0,032 × ref`) y los radios de las formas vertical y horizontal (`20/750 × ref` y `18/750 × ref`) usan `ref` en lugar de `H`. En 16:9, 4:3 y 1:1 las dos referencias dan lo mismo. **Solo pantalla:** la pantalla como en 1b y la cámara sin verse.
- **Pantalla dividida.** Orientación: al lado si `W > H`; apiladas si `W ≤ H` (el 1:1 incluido); sale del formato, no se elige. Separación `g = 0,025 × s` (`gapFraction`). En el eje de la división el largo disponible es `L` (el lado de `A` en ese eje menos `g`) y de través `C` (el otro lado de `A`). La parte de la cámara `k`: la del bloque (`share`, de 0,25 a 0,60) o, sin ella, la automática: al lado `clamp(1 − C·aₛ / L, 0,30, 0,50)`; apiladas `clamp(1 − (C / aₛ) / L, 0,30, 0,60)`. La tarjeta de la pantalla es la más grande de proporción `aₛ` dentro de `(1 − k)·L` por `C` (**la pantalla nunca se recorta**); la de la cámara mide `k·L` en el eje y, de través, lo mismo que la de la pantalla, y si su proporción queda fuera de 9:16–16:9 (`cameraAspectRange`) se achica el lado que sobra (nunca se agranda nada). `side` `start` pone la cámara primero (a la izquierda o arriba); `end` (el valor por defecto), segunda. El grupo (tarjeta, separación, tarjeta) se centra en `A`. Las dos tarjetas usan las esquinas del estilo (`cornerRadius × W`); la de la pantalla lleva la sombra del estilo y su marco de ventana, y la de la cámara su borde y su sombra. La cámara llena su tarjeta recortada al centro.
- **Solo cámara.** La tarjeta es `A`, con la proporción llevada a 9:16–16:9 si se sale (achicando, centrada), las esquinas del estilo, el borde y la sombra de la cámara.
- **Cámara a pantalla completa.** La cámara ocupa `(0, 0, W, H)` con radio 0, sin borde ni sombra (sus pesos son 0); cuando la transición terminó no se dibuja nada debajo.
- **Lo que un layout no muestra** queda donde estaría en Burbuja, al 90 % de su tamaño (`hiddenScale`) alrededor de su centro, con sus esquinas, y con opacidad 0.
- **Antes del primer cuadro de la cámara**, Solo cámara y Cámara a pantalla completa muestran ese primer cuadro (la Burbuja sigue sin dibujarse antes, como en 1b); sin cuadros legibles de la cámara en toda la toma, los layouts que la necesitan se ven como Solo pantalla.
- **Transiciones.** En cada borde de bloque, en tiempo de salida; el bloque empieza donde empieza el movimiento. Cada layout tiene en cada instante una geometría viva `G_L(t)`: el rectángulo, el radio y la opacidad de la tarjeta de la pantalla, la transformación de su contenido y la del fondo, y el rectángulo, el radio, la opacidad y el peso del borde y de la sombra de la cámara. Lo que se ve es la mezcla lineal de esos números entre el layout anterior y el nuevo por `p(t − t_borde)`, la respuesta al escalón del resorte de `camera.spring` (la de `CameraStyleTimeline`: amortiguación 0,95, respuesta 0,5 s; 0 en 0 s y 1 desde 1,5 s). Un borde que llega antes de que termine la transición anterior arranca desde lo que se veía (se toma la primera transición de la ráfaga y se mezclan en orden): nada salta. Una transición `instant` salta en el borde, sin mezcla. Un bloque que empieza en el primer instante ya está puesto en el primer cuadro. Reducir movimiento no cambia nada de esto: son contenido del video.
- **Zoom y cursor según el layout.** *Modo escenario* (Burbuja, Solo pantalla): el zoom de 1b sin cambios (`ZoomCameraPath` sobre todo el escenario). *Modo tarjeta* (Pantalla dividida): el fondo queda quieto y el zoom actúa dentro de la tarjeta de la pantalla, recortado a ella con sus esquinas; la cámara del zoom de la tarjeta es **`cardZoom`**: la misma simulación que el zoom del escenario sobre otro encuadre, con los mismos bloques de zoom, el mismo resorte (`zoom.spring`), el mismo paso fijo de 600 Hz con puntos de control cada 600 pasos (1 s) y las reglas de 1b §8.3, pero en fracciones del contenido de la pantalla: el recorte mide `1/z` de la pantalla en cada eje y su centro no sale de `[1/(2z), 1 − 1/(2z)]` (nunca se ve fondo dentro de la tarjeta); el seguimiento usa la caja central del 60 % de ese recorte (`ZoomCameraPath.deadZone` = 0,60) y pasos del 15 % (`followStep` = 0,15); un enfoque fijo es el punto guardado, en fracciones de lo que se muestra de la pantalla; no hay zona a evitar (la cámara está al lado, no encima); un zoom instantáneo salta. Como la tarjeta tiene la proporción de la pantalla, el camino no depende de dónde está la tarjeta: se simula una vez para toda la salida, solo si el documento tiene alguna Pantalla dividida, y se simula también donde rige otro layout, así al volver el zoom está donde tiene que estar. Solo cámara y Cámara a pantalla completa dejan el fondo quieto. El cursor y los efectos de clic, en modo tarjeta, van por la transformación del contenido de la tarjeta y recortados a ella, con su tamaño multiplicado por la escala de esa transformación; con la pantalla oculta no se dibujan. Un **sonido de clic suena solo si la opacidad de la pantalla en su instante de salida es ≥ 0,5** (`EditedMix` mira la línea de tiempo de layouts del documento; un clic mudo no deja callado al siguiente dentro de los 40 ms; con layouts triviales nada cambia). Durante una transición entre modos, las transformaciones del fondo y del contenido y el recorte se mezclan por `p` como el resto.
- **Un bloque dentro de un tramo cortado no cambia ningún cuadro**: los bloques se guardan en tiempo de la fuente y siguen las reglas de los zooms ante cortes y velocidades (sus bordes pasan a tiempo de salida con `TimeMap`).

**El orden de dibujo con layouts.** Una sola composición, con los números mezclados en una transición (dos composiciones fundidas costarían el doble y se verían como un doble contorno):

1. Fondo, con su transformación (la del zoom en modo escenario; la identidad en modo tarjeta; la mezcla en una transición).
2. Sombra de la pantalla, bajo su rectángulo.
3. Marco de ventana, pegado arriba del rectángulo de la pantalla (en modo tarjeta, quieto sobre el contenido que se agranda).
4. Pantalla o pantallas; 5. cursor; 6. efectos de clic: con la transformación del escenario (modo escenario) o con la del contenido de la tarjeta, recortados a ella con sus esquinas (modo tarjeta), con la opacidad de la pantalla.
7. Cámara, en espacio de salida: su sombra, el video (espejado si toca) recortado a su rectángulo redondeado, y su borde.

Las submuestras del desenfoque de movimiento (1b §7.2) siguen igual, con el camino que corresponde al modo.

**Espejo, borde y sombra de la cámara.**

- **Espejo:** el video se invierte en horizontal dentro de su rectángulo: la coordenada `u` pasa a `1 − u` *después* de elegir el recorte centrado. El lugar de la burbuja no se espeja.
- **Borde:** un trazo interior a lo largo del rectángulo redondeado, de ancho `border.width × 0,012 × s` px (`CameraBorder.widthFactor`), con el mismo antialias de las esquinas; no agranda la cámara ni la mueve. El color se escribe a la salida tal cual (sRGB de 0 a 1). En una transición el ancho se multiplica por el peso del borde (0 en Cámara a pantalla completa).
- **Sombra** (`k` = `shadow` por su peso): la sombra analítica de la pantalla (ver **Sombra** arriba) con el lado corto de la salida en lugar del ancho: opacidad `0,55 · k`, σ `(0,004 + 0,016 · k) × s` y un desplazamiento hacia abajo de `0,010 · k × s`. Con `k = 0` no se dibuja nada; un círculo es un rectángulo redondeado con radio de medio lado, con la misma fórmula.
- La opacidad de la cámara y los pesos del borde y de la sombra se recortan a `[0, 1]` (el resorte se pasa un poco, del orden de 7·10⁻⁵), y nunca se decide mezclar preguntando si una opacidad vale 1.

**Lectura de video según el layout.** La pantalla no se decodifica mientras su opacidad es 0 en el cuadro (Solo cámara y Cámara a pantalla completa, asentados), ni la cámara mientras está oculta. Con Cámara a pantalla completa asentada no se dibuja nada debajo: la cámara es opaca y cubre cada píxel, así que el cuadro es el mismo. Cada lector secuencial recibe los cuadros de los próximos 8 cuadros de salida y, para una pista que no tiene nada pendiente, su primer cuadro dentro de 1 s de salida (`FramePrefetcher.borderLookahead`): la pantalla o la cámara que un borde de bloque trae de vuelta empieza a decodificarse antes del borde, así la transición no se saltea cuadros. Nunca se pide dos veces el mismo cuadro y cada lector los recibe en orden: se decodifican los mismos cuadros y se registran los mismos huecos que dibujando de a uno.

## Cambios de la versión 2

La versión 2 llega con la fase 1a. Los paquetes nuevos se crean con `formatVersion: 2`.

- Tipos de pista nuevos: `window` (una ventana, en `window-<CGWindowID>/`), `camera` (en `camera/`) y `systemAudio` (en `system-audio/`). La recuperación y la verificación leen video en `display`, `window` y `camera`, y audio en `microphone` y `systemAudio`.
- Campos nuevos de `source`, después de `pixelScale`: `windowID`, `bundleIdentifier`, `captureArea`, `includedBundleIDs` y `excludedBundleIDs`.
- El campo `cameraStyle` de la toma: el estilo inicial de la cámara.
- La carpeta opcional `takes/<toma>/wallpapers/`, con la foto del fondo de cada pantalla grabada (ver [`wallpapers/`](#wallpapers)).
- Eventos nuevos: `windowGeometry` y `cameraStyle`.

Compatibilidad:

- Un lector de la versión 2 lee las versiones 1 y 2 (`Manifest.supportedFormatVersions`, `1...2`) y rechaza cualquier otra antes de decodificar el manifiesto: un paquete de una versión más nueva es *para reparar* y no se toca. Un lector de la versión 1 rechaza así los paquetes v2.
- Un paquete v1 se lee como siempre: no tiene ninguno de los campos nuevos, y su toma no tiene `cameraStyle`.
- **Un paquete v1 se queda en v1 hasta que el usuario lo edita.** La versión se decide al crear el paquete y la grabación y la recuperación nunca la reescriben: nada cambia un proyecto viejo en silencio, y nada que la versión 1 no define se escribe en un paquete v1. Desde la versión 3, la primera edición del usuario lo pasa a la versión 3 (ver [Cambios de la versión 3](#cambios-de-la-versión-3)).

## Cambios de la versión 3

La versión 3 llega con el hito 1b, el editor con estilo, cursor y zoom. Los paquetes nuevos se crean con `formatVersion: 3`. Un lector de la versión 3 lee las versiones 1, 2 y 3.

### Lo que suma el manifiesto y la captura

- El campo `projectID` del manifiesto: el id estable del proyecto, al azar al crear el paquete. **Id derivado**, el de un paquete sin `projectID` (versiones 1 y 2): los primeros 16 bytes, en 32 dígitos hexadecimales en minúscula, de SHA-256 sobre el UTF-8 de `createdAt` como se escribe en el manifiesto (ISO 8601, en segundos) seguido de `\n` y, por cada toma en orden, su `id`, `\n`, su `startedAt` en ISO 8601 y `\n`. Por ejemplo, con `createdAt` `2026-11-15T20:00:00Z` y una toma `take-001` de `startedAt` `2026-11-15T20:00:01Z`, SHA-256 de `"2026-11-15T20:00:00Z\ntake-001\n2026-11-15T20:00:01Z\n"`. Ninguno de los dos cambia al renombrar o mover el paquete, y una copia en Finder tiene el mismo id que el original (comparten la carpeta de cachés, que no daña nada: son cachés de las mismas tomas).
- El campo `upgradedFrom` del manifiesto: la versión en que se creó un paquete que pasó a la versión 3 con su primera edición.
- La carpeta opcional `takes/<toma>/cursors/`, con las imágenes del cursor (ver [`cursors/`](#cursors)).
- Eventos nuevos: `cursorImage`, `scroll` y `keyActivity`. Como los demás, nunca entre un `paused` y su `resumed`, una línea por evento y con las claves en orden alfabético:

  ```
  {"hash":"3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e","hotspot":{"x":0.16,"y":0.12},"kind":"arrow","size":{"height":32,"width":24},"t":5,"type":"cursorImage"}
  {"dx":0,"dy":-42.5,"t":5,"type":"scroll","x":640.5,"y":402}
  {"t":5,"type":"keyActivity"}
  ```

  Un `kind` de `cursorImage` que el lector no conoce se lee como ausente: se usa la imagen grabada y la línea vale igual.
- Nombres reservados en la raíz del paquete, para el editor: `edit.json`, `edit-log.jsonl`, `edit.lock` y `assets/` (abajo). El editor escribe solo esos y el manifiesto, una vez, al pasar un paquete v1 o v2 a la versión 3; **en un paquete v1 o v2 sin editar no escribe nada**, y nunca toca `takes/`. Tampoco escribe ahí el export.
- La carpeta `cache/` sigue reservada para cachés que convenga llevar con el proyecto; el editor de 1b no escribe en ella.

### El documento de edición: `edit.json`

Un documento por proyecto, en la raíz del paquete: la instantánea del estado de la edición (qué se ve, en qué orden y con qué aspecto). JSON con las reglas de escritura del manifiesto (`ProjectJSON.encoder()`: UTF-8, claves en orden alfabético, indentado con dos espacios y `" : "` entre clave y valor, una clave por línea, sin `/` escapadas, opcionales omitidos, nunca `null`), escrito de una vez con `DurableFile.writeAtomically` (temporal, `F_FULLFSYNC`, `rename` y sincronización de la carpeta). Este es el texto exacto que escribe un documento con dos tramos (el segundo a 2×), un cambio de pantalla, un zoom automático, uno manual y uno automático borrado; lo guarda `documentExampleRoundTripsByteForByte`, que lo lee y lo vuelve a escribir byte por byte:

```json
{
  "aspect" : "16:9",
  "audio" : {
    "limiter" : true,
    "tracks" : {
      "take-001/mic" : {
        "gain" : 1,
        "muted" : false
      },
      "take-001/system-audio" : {
        "gain" : 0.8,
        "muted" : false
      }
    }
  },
  "camera" : {
    "changes" : [
      {
        "id" : "k-1c2d0a9e",
        "origin" : "recorded",
        "style" : {
          "anchor" : "topLeading",
          "shape" : "circle",
          "size" : 0.24
        },
        "t" : 81290000000000,
        "take" : "take-001"
      }
    ],
    "initial" : {
      "take-001" : {
        "anchor" : "bottomTrailing",
        "shape" : "circle",
        "size" : 0.24
      }
    },
    "show" : true
  },
  "cursor" : {
    "clickEffect" : "ripple-1",
    "clickSound" : "none",
    "clickSoundGain" : 0.5,
    "hideWhenIdle" : true,
    "idleDelay" : 2,
    "motionBlur" : 0.5,
    "scale" : 1.5,
    "show" : true,
    "smoothing" : {
      "damping" : 1,
      "response" : 0.16
    },
    "style" : "system"
  },
  "documentVersion" : 1,
  "frameRate" : 60,
  "logSequence" : 128,
  "screens" : {
    "changes" : [
      {
        "id" : "p-9a01b2c3",
        "origin" : "auto",
        "t" : 81260000000000,
        "take" : "take-001",
        "track" : "display-2"
      }
    ],
    "initial" : {
      "take-001" : "display-1"
    },
    "planner" : "screenFollow-1"
  },
  "sequence" : [
    {
      "end" : 81276901234567,
      "id" : "c-00a1b2c3",
      "speed" : 1,
      "start" : 81234567890123,
      "take" : "take-001"
    },
    {
      "end" : 81334000000000,
      "id" : "c-00d4e5f6",
      "speed" : 2,
      "start" : 81277458000000,
      "take" : "take-001"
    }
  ],
  "style" : {
    "background" : {
      "type" : "wallpaper",
      "wallpaper" : "aurora-1"
    },
    "backgroundBlur" : 0,
    "cornerRadius" : 0.012,
    "frame" : {
      "type" : "none"
    },
    "geometryTransition" : "spring",
    "padding" : 0.08,
    "screenSampling" : "mipmapped",
    "shadow" : 0.6
  },
  "zoom" : {
    "auto" : {
      "depth" : 2,
      "enabled" : true,
      "follow" : true,
      "groupGap" : 2.5,
      "holdWhileTyping" : true,
      "leadIn" : 0.5,
      "leadOut" : 1,
      "planner" : "autoZoom-1",
      "triggers" : "clicks"
    },
    "motionBlur" : 0.5,
    "regions" : [
      {
        "end" : 81245000000000,
        "focus" : {
          "type" : "follow"
        },
        "id" : "z-3fa2b1c0",
        "instant" : false,
        "origin" : "auto",
        "start" : 81241000000000,
        "take" : "take-001"
      },
      {
        "depth" : 1.6,
        "end" : 81300000000000,
        "focus" : {
          "type" : "fixed",
          "x" : 0.31,
          "y" : 0.72
        },
        "id" : "z-7e11d0aa",
        "instant" : false,
        "origin" : "user",
        "start" : 81296000000000,
        "take" : "take-001"
      }
    ],
    "show" : true,
    "spring" : {
      "damping" : 1,
      "response" : 0.7
    },
    "suppressed" : [
      {
        "end" : 81320000000000,
        "start" : 81318000000000,
        "take" : "take-001"
      }
    ]
  }
}
```

Las claves de `audio.tracks`, `camera.initial` y `screens.initial` son por toma (`<toma>/<pista>` en el audio), así la fase 3 puede poner varias tomas en una secuencia; en 1b hay una sola.

| Campo | Significado |
|---|---|
| `documentVersion` | La versión del documento dentro del formato v3: 1 en 1b. Un lector que conoce hasta la `n` rechaza uno mayor (`EditDocumentError.newerVersion`) antes de leer lo demás, esté donde esté (un archivo propio o el `create` del registro) |
| `logSequence` | El `seq` de la última línea del registro que esta instantánea ya incluye |
| `aspect` | `16:9`, `9:16` o `1:1` |
| `frameRate` | 24, 25, 30, 50 o 60: la grilla de cuadros del editor y los cuadros por segundo por defecto de la hoja de exportar. Exportar a otros no lo toca |
| `sequence` | Los tramos, en el orden de salida y, en 1b, en el de la fuente, sin superponerse: `id` (`c-` y 8 hex), `take`, `start` y `end` (`HostTime` de la toma, `end` excluido) y `speed` (de 0,25 a 16) |
| `screens` | Qué pantalla se ve: `initial` por toma (el id de la pista); `changes` (`id` `p-…`, `take`, `t` de la fuente, `track` y `origin`, `auto` o `user`), desde `t` se ve `track`; `planner` si los hizo un planificador (`screenFollow-1`) |
| `style.background` | `{"type":"gradient","start":[r,g,b,a],"end":[r,g,b,a],"angle":135}`, `{"type":"color","color":[r,g,b,a]}`, `{"type":"wallpaper","wallpaper":"<id>"}`, `{"type":"image","file":"assets/<sha>.<ext>"}` o `{"type":"desktop"}` (la foto del escritorio de la primera pantalla que se ve). Los colores son valores sRGB de 0 a 1 que se escriben tal cual a la salida |
| `style.backgroundBlur` | 0 a 1 (σ = valor × 0,04 × el ancho de salida) |
| `style.padding`, `style.cornerRadius` | Fracciones del ancho de salida (0,08 y 0,012 en el estilo de siempre) |
| `style.shadow` | 0 a 1 |
| `style.frame` | `{"type":"none"}` o `{"type":"macWindow","appearance":"light"\|"dark","title":"…","buttons":true}` |
| `style.screenSampling` | `bilinear` (el de las fases 0 y 1a) o `mipmapped` |
| `style.geometryTransition` | `none` (salta, como siempre) o `spring` |
| `cursor` | `show`; `style` (`toma` o `system`); `scale` (multiplica el tamaño real; en `toma`, 1 son 24 pt de alto); `smoothing` (`"off"` o `{"damping","response"}`); `hideWhenIdle` e `idleDelay` (s); `clickEffect` (`none`, `ripple-1`, `circle-1`); `clickSound` (`none`, `soft-1`, `mechanical-1`); `clickSoundGain` (0 a 1); `motionBlur` (0 a 1, la fracción de un cuadro que dura el obturador) |
| `zoom` | `show`; `auto` (los ajustes del planificador: `enabled`, `triggers` `clicks` o `clicksAndPauses`, `holdWhileTyping`, `depth` de 1,25 a 4, `groupGap`, `leadIn`, `leadOut`, `follow`, y su versión en `planner`, `autoZoom-1`); `spring` de la cámara; `motionBlur`; `regions`; `suppressed` |
| `zoom.regions[]` | `id` (`z-` y 8 hex, o un hash del planificador, la toma, el inicio y el fin en los automáticos), `take`, `start` y `end` (fuente), `origin` (`auto` o `user`), `depth` (opcional en un automático: usa `auto.depth`), `focus` (`{"type":"follow"}` o `{"type":"fixed","x","y"}`, fracciones de lo que se muestra de la pantalla) e `instant` |
| `zoom.suppressed[]` | Rangos de la fuente (`take`, `start`, `end`) donde el usuario borró un automático: el planificador no vuelve a poner ahí uno que se superponga en un 50 % o más |
| `camera` | `show`; `initial` por toma (un `CameraStyle`: `shape`, `size` y `anchor`; en el documento, `size` va de 0,10 a 0,45); `changes` (`id` `k-…`, `take`, `t` de la fuente, `style` y `origin`, `recorded` si lo grabó la toma o `user`) |
| `audio` | `tracks` por `<toma>/<pista>` con `gain` (0 a 2) y `muted`; `limiter` |

Reglas:

- **Todo lo que tiene un aspecto definido en código lleva la versión en su nombre** (`aurora-1`, `ripple-1`, `circle-1`, `soft-1`, `mechanical-1`, `autoZoom-1`, `screenFollow-1`), y el código conserva las versiones viejas. Los resortes y las medidas se guardan como números, no como un nombre («Media»). Así una actualización nunca cambia en silencio un proyecto viejo: retocar las Ondas crea `ripple-2`.
- Los ids tienen un prefijo por tipo (`c-` tramo, `z-` zoom, `k-` cambio de la cámara, `p-` cambio de pantalla) y 8 hex al azar; los de los zooms automáticos salen de un hash, así regenerar sin cambios da los mismos ids.
- **Los instantes de la fuente** (`start`, `end`, `t`) son enteros de nanosegundos de `HostTime` y se escriben como enteros, también por encima de 2⁵³ (unos 104 días de arranque), donde un `Double` ya no guardaría cada nanosegundo: un lector tiene que leerlos como enteros de 64 bits sin pasarlos por un número de punto flotante (la prueba `hostTimesAbove2To53RoundTrip` los lee y vuelve a escribir sin cambiarlos, hasta 2⁶⁴ − 1).
- Un lector que encuentra un valor que ninguna versión puede dibujar lo lee igual y lo acota: una velocidad fuera de 0,25 a 16 se acota a ese rango (una que no es un número, a 1), una profundidad de zoom se lee de 1 a 16, un obturador de 0 a 1 y un resorte con `response` menor de 0,06 s o un `damping` fuera de 0 a 2 se lee dentro de lo estable. Un `frameRate` que no es uno de la lista, o una velocidad fuera de rango, abre el proyecto solo para ver. Una pantalla que el documento nombra y la toma no tiene no se dibuja.
- Un fondo `wallpaper` cuyo id esta versión no conoce, una imagen que falta o no se puede leer y un `desktop` sin foto se dibujan como Toma clásico.

### El registro: `edit-log.jsonl`

El registro es la verdad ante un crash: una línea por entrada, con las reglas de `events.jsonl` (JSON compacto, claves en orden alfabético, `\n` al final, solo se agrega por el final con `O_APPEND`). Toda entrada tiene `seq` (un entero que crece de línea en línea y puede tener huecos) y `type`. La primera línea es siempre un `create`, y solo ahí.

| `type` | Campos además de `seq` | Significado |
|---|---|---|
| `create` | `document`, `app` (`name` y `version`) | El documento inicial entero (el legado, o el de un proyecto nuevo) |
| `do` | `group`, `label`, `changes`, `at` | Un cambio. `label` nombra la acción para el menú (`split`, `style.padding`…); `group` es el paso de deshacer al que pertenece; `at` es una fecha ISO 8601 en segundos enteros |
| `undo` | `group` | Deshace todas las entradas `do` de ese grupo, de la última a la primera |
| `redo` | `group` | Las rehace, en orden |
| `migrate` | `from`, `to` | El documento pasó de una `documentVersion` a otra. Desde el hito 1c existe la de 1 a 2, aditiva (ver [Cambios del documento 2](#cambios-del-documento-2)): la reproducción la aplica al JSON en ese punto y sigue. **La regla de `migrate`:** uno a una versión mayor que la de la app se rechaza como un documento más nuevo (lo escribió una app más nueva, no es un daño); uno que sigue (`to = from + 1`, `from` es la versión que tiene el documento en ese punto y la migración es aditiva) se aplica; cualquier otro (un paso que no existe, un `from` que no es la versión del documento) detiene la reproducción ahí, como en 1b. Un `migrate` que es la última línea del registro, sin nada después, es la escritura cortada de la primera edición y se trunca |

Cada `changes` es una lista de operaciones sobre el documento, todas invertibles porque guardan lo que reemplazan. Una ruta es un puntero JSON (RFC 6901: `~1` para una `/` y `~0` para una `~` dentro de un nombre, así `/audio/tracks/take-001~1mic/gain`):

| `op` | Campos | Inversa |
|---|---|---|
| `set` | `path`, `before`, `after` | `set` con `before` y `after` intercambiados. El valor de `path` existe; para sumar o quitar un campo opcional se usan las otras |
| `insert` | `collection`, `index`, `value` | `remove` |
| `remove` | `collection`, `index`, `value` (lo que había) | `insert` |
| `replace` | `collection`, `id`, `before`, `after` (el elemento entero, con el mismo `id`) | `replace` con los dos intercambiados |

Las colecciones son `/sequence`, `/zoom/regions`, `/zoom/suppressed`, `/camera/changes`, `/camera/layouts` (desde el documento 2) y `/screens/changes`. Una línea de cada tipo, exactamente como se escribe (la primera, con un documento mínimo):

```
{"app":{"name":"Toma","version":"0.2.0"},"document":{"aspect":"16:9","audio":{"limiter":false,"tracks":{}},"camera":{"changes":[],"initial":{},"show":true},"cursor":{"clickEffect":"none","clickSound":"none","clickSoundGain":0.5,"hideWhenIdle":false,"idleDelay":2,"motionBlur":0,"scale":1,"show":true,"smoothing":"off","style":"toma"},"documentVersion":1,"frameRate":60,"logSequence":0,"screens":{"changes":[],"initial":{"take-001":"display-1"}},"sequence":[{"end":2000,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"}],"style":{"background":{"type":"wallpaper","wallpaper":"aurora-1"},"backgroundBlur":0,"cornerRadius":0.012,"frame":{"type":"none"},"geometryTransition":"none","padding":0.08,"screenSampling":"bilinear","shadow":0},"zoom":{"auto":{"depth":2,"enabled":false,"follow":true,"groupGap":2.5,"holdWhileTyping":true,"leadIn":0.5,"leadOut":1,"planner":"autoZoom-1","triggers":"clicks"},"motionBlur":0,"regions":[],"show":true,"spring":{"damping":1,"response":0.7},"suppressed":[]}},"seq":1,"type":"create"}
{"at":"2026-11-15T20:12:03Z","changes":[{"after":0.1,"before":0.08,"op":"set","path":"/style/padding"}],"group":2,"label":"style.padding","seq":2,"type":"do"}
{"group":2,"seq":3,"type":"undo"}
{"group":2,"seq":4,"type":"redo"}
{"from":1,"seq":9,"to":2,"type":"migrate"}
{"at":"2026-11-15T20:12:03Z","changes":[{"collection":"/zoom/suppressed","index":0,"op":"insert","value":{"end":6,"start":5,"take":"take-001"}}],"group":5,"label":"zoom.delete","seq":7,"type":"do"}
{"at":"2026-11-15T20:12:03Z","changes":[{"collection":"/zoom/suppressed","index":0,"op":"remove","value":{"end":6,"start":5,"take":"take-001"}}],"group":5,"label":"zoom.delete","seq":7,"type":"do"}
{"at":"2026-11-15T20:12:03Z","changes":[{"after":{"end":1500,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"},"before":{"end":2000,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"},"collection":"/sequence","id":"c-00000001","op":"replace"}],"group":5,"label":"zoom.delete","seq":7,"type":"do"}
```

(Las últimas tres, con una operación de cada tipo, repiten `group`, `label` y `seq` del ejemplo de arriba solo para mostrar la forma; en un registro real cada `seq` es nuevo.)

Lo que significa cada una:

- **Qué escribe cada acción.** Dividir un tramo es un `replace` del tramo (que termina en el corte) más un `insert` del nuevo; borrar un rango son hasta dos `replace` y los `remove` de los tramos del medio; recortar y cambiar la velocidad son `replace`; borrar un zoom automático es un `remove` más un `insert` en `suppressed`; regenerar son los `remove` de los automáticos sin tocar, los `insert` de los nuevos y el `set` de los ajustes; cambiar el margen es un `set`.
- **Grupos.** Un `do` de un grupo nuevo después de un `undo` vacía lo que se podía rehacer (la historia es lineal). Varios `do` seguidos con el mismo `group` son un solo paso de deshacer; el grupo de un `do` es su `seq` si abre uno. Arrastrar (una barra, un recorte, un bloque, la burbuja) escribe un solo `do` al soltar, con el valor del comienzo del gesto como `before`.
- **Verificación al aplicar.** Cada operación comprueba lo que reemplaza: el `before` de un `set` o de un `replace`, el `value` de un `remove`, y que el `index` de un `insert` sea un lugar libre (de 0 a la cantidad). Si algo no coincide, o si el documento que queda deja de ser uno (o no tiene algo que una línea escribió), el registro dejó de ser coherente en esa línea. La reproducción también se detiene en la primera línea que no sigue a las de antes: un `create` que no es la primera línea, un `do` de un grupo que está deshecho, un `undo` de uno que no está aplicado, un `redo` de uno que no está deshecho, un `seq` que no crece, o un `migrate` que no sigue, según la regla de la tabla (nada anterior a uno de esos se puede deshacer; el que sigue y es aditivo no corta la historia, ver [Cambios del documento 2](#cambios-del-documento-2)).
- **Abrir.** Se lee `edit.json` y se aplican las entradas del registro con `seq` mayor que su `logSequence`; el registro entero se recorre (sin aplicar) para rearmar las pilas de deshacer y rehacer. Sin `edit.json` o con uno ilegible, se reproduce desde el `create`. Con `edit.json` y sin registro, se abre esa instantánea con la historia vacía y se empieza un registro con un `create` de ese estado. Un `create` de un documento más nuevo, o un `edit.json` con una `documentVersion` mayor, no se abre ni se toca: la app dice que el proyecto se editó con una versión más nueva de Toma.
- **Después de un crash.** Una última línea cortada (sin `\n` y que no es un objeto JSON completo) se trunca y se fuerza a disco antes de seguir escribiendo; truncar el archivo en cualquier byte de la última línea da el estado de antes o el de después, nunca otro (`truncatingTheLastLineAtEveryByteGivesBeforeOrAfter`). Una línea dañada en el medio, o una que no coincide al aplicarse, corta la reproducción ahí: se abre el estado de la última línea buena, el archivo entero se copia a `edit-log.jsonl.damaged-<aaaammdd-hhmmss>` (con `-2`, `-3`… si ya existe; nunca se borra ni se pisa) y el registro se reescribe hasta la última línea buena. Si `edit.json` es más nuevo que toda línea buena (el registro se dañó después de una instantánea válida), no se pierde nada: se abre la instantánea y el registro pasa a ser un solo `create` de ella (se pierde el historial de deshacer anterior, nunca una edición).
- **Cada cambio es durable al terminar**: la línea se agrega y se fuerza a disco con `F_FULLFSYNC` (con `fsync` si el volumen no lo admite) en una cola propia; si llegan varias mientras tanto, una sola sincronización las cubre. Si una escritura falla (disco lleno), las líneas esperan en memoria, en orden, y se reintenta cada 2 s desde el byte donde quedó.
- **La instantánea.** `edit.json` se reescribe 2 s después del último cambio, cada 200 entradas y al cerrar, y solo cuando el registro ya confirmó en disco la línea que dice su `logSequence`. Sirve para no reproducir todo el registro: nada depende de que sea reciente.
- **Compactación.** Cuando el registro pasa de 8 MiB (8 × 1 048 576 bytes) o de 20 000 entradas, al abrir o al cerrar (nunca mientras se edita): primero se escribe la instantánea del estado actual y después el registro equivalente, con los mismos `seq` finales para que la instantánea siga valiendo: el mismo `create`, los grupos de la pila de hechos como un `do` cada uno (los `set` seguidos sobre la misma ruta se funden en uno) y los de la pila de deshechos como sus `do` seguidos de sus `undo` en orden inverso (`do` y `undo` de a uno no se podrían reproducir si hay dos grupos deshechos). Se escribe a un temporal, `F_FULLFSYNC`, `rename(2)` y sincronización de la carpeta, y mientras el diario sigue abierto lo cambia él, así las líneas siguientes no van a un archivo sin nombre. Conserva el mismo estado y las mismas pilas (`compactionKeepsStateAndStacks`). Con `migrate` aditivos en el registro también compacta (los `migrate` quedan en orden justo después del `create`); ver la regla en [Cambios del documento 2](#cambios-del-documento-2).

### El paso a la versión 3

La primera edición de un paquete v1 o v2 lo pasa a la versión 3, **en este orden**, de modo que un crash en cualquier punto deja un paquete que se abre con el aspecto que tenía:

1. El editor toma `edit.lock`. Si no puede, porque otro proceso llegó antes, descarta la edición, pasa a solo para ver y lo dice. Si puede, vuelve a leer el manifiesto (sin seguir enlaces ni trabarse en un FIFO) y, si ya no es el que abrió (otro proceso lo pasó a la versión 3, lo editó y lo soltó, o lo cambió), descarta la edición, suelta el lock y vuelve a abrir el proyecto desde el disco.
2. El manifiesto se reescribe con `formatVersion: 3`, `upgradedFrom` (la versión de antes) y el `projectID` derivado, y **nada más cambia**: las tomas conservan su contenido v1 o v2, que la versión 3 sabe leer. Así su carpeta de cachés sigue siendo la misma.
3. Se escribe `edit-log.jsonl` con el `create` del documento legado (`seq` 1) y la primera edición (`seq` y `group` 2).

Un crash entre 2 y 3 deja un v3 con `upgradedFrom` y sin registro, que se abre con el documento legado: nada se ve distinto, y ningún lector viejo puede mostrar una edición, porque las ediciones solo existen después del cambio de versión. **En un paquete v1 o v2 sin editar no se escribe nada**: abrirlo, reproducirlo y exportarlo (con cualquier opción de la hoja de exportar) no crean `edit.lock`, ni cachés, ni estado de interfaz, que van a la carpeta de cachés (abajo); un hash de todos sus archivos es el mismo antes y después (`openingALegacyPackageWritesNothing`, `exportingALegacyPackageWritesNothingInIt`). Un v3 sin editar sí tiene lock mientras está abierto en el editor.

### `edit.lock`

El lock del editor que escribe, con las reglas de [`recording.lock`](#recordinglock): un lock `flock` exclusivo sobre el archivo abierto con `O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW`, que el kernel suelta cuando muere el proceso, con el mismo contenido informativo (`pid`, `startedAt`, `bootSessionUUID`). Se toma al abrir un v3; en un v1 o v2 el editor no lo toma al abrir (no escribe nada): solo pregunta si está tomado, abriéndolo sin crearlo (`O_RDONLY | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW`), y si lo está abre solo para ver; lo toma con la primera edición (arriba). Dentro de la app, abrir dos veces el mismo proyecto trae la ventana que ya está. Un `edit.lock` que es un enlace o un archivo que no es común, o un volumen sin `flock`, abre el proyecto solo para ver. Una futura CLI usará el mismo lock.

### `assets/`

Las imágenes propias del fondo, copiadas al paquete (con un clon de APFS cuando se puede): `assets/<sha>.<ext>`, donde `<sha>` son 32 dígitos hexadecimales en minúscula (los primeros 16 bytes de SHA-256 del archivo) y `<ext>` es `png`, `jpg` o `heic` (la importación solo ofrece esas tres; un nombre `.tiff` es válido, pero no se decodifica). El documento las nombra con `{"type":"image","file":"assets/<sha>.<ext>"}`. No se borran en 1b: deshacer puede volver a necesitarlas. Es una carpeta común y sus archivos, archivos comunes.

### Las cachés, fuera del paquete

Todo lo regenerable va a `~/Library/Caches/dev.toma.Toma/Projects/<projectID>/`, para todas las versiones del formato (el id es el del manifiesto o el derivado): `thumbnails/` (las miniaturas de la línea de tiempo), `waveforms/` (las formas de onda), `suggestions/` (reservada: en 1b nada la escribe) y `editor-state.json` (el estado de la ventana, la pestaña del panel, el cabezal y la escala de la línea de tiempo). Nunca hace falta para abrir ni para exportar, y macOS puede vaciarla. Como el `projectID` nombra una carpeta, un id que no son exactamente 32 dígitos hexadecimales en minúscula nunca se usa como nombre (el manifiesto que lo trae es inválido; en la carpeta se reemplaza por un hash). La app borra al arrancar las carpetas que no se usan hace 30 días.

### Los lectores seguros

Un paquete puede venir de cualquier lado, así que lo que el editor lee de él no sigue enlaces ni se traba:

- **`edit.json`, `edit-log.jsonl` y el manifiesto que se vuelve a leer al pasar a la versión 3** se abren con `SafeRead.regularFile`: `open` con `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` y `fstat` para comprobar que es un archivo común (`S_IFREG`) antes de leer del descriptor; un enlace da `ELOOP` y un FIFO o cualquier otra cosa, `EFTYPE`, al instante. Nunca `Data(contentsOf:)`, que sigue enlaces y se traba en un FIFO. Un `edit.json`, un registro o un `edit.lock` que son enlaces o no son archivos comunes abren el proyecto con lo que se pueda leer sin riesgo, solo para ver.
- **Las imágenes** (`SafePackageFile`): cada componente de la ruta dentro del paquete se abre con `openat` y `O_NOFOLLOW` desde la carpeta anterior (la ruta del paquete en sí puede pasar por enlaces), el nombre se valida exacto y se comprueba el tipo, el tamaño del archivo y su contenido antes de decodificar con ImageIO. Lo que no cumple se trata como ausente (el cursor de Toma, sin foto del escritorio, la imagen ilegible), nada se sigue y nada falla.

| Qué | Dónde, y el nombre exacto | Límite antes de decodificar | Formatos |
|---|---|---|---|
| Imagen del cursor | `takes/<toma>/cursors/<hash>.png`, `[0-9a-f]{32}\.png` | 1 MiB y 512 px por lado | PNG |
| Foto del escritorio | `takes/<toma>/wallpapers/display-<id>.png`, `display-[0-9]+\.png` | 64 MiB y 16 384 px por lado; se decodifica reducida a 7 680 px de lado como mucho | PNG |
| Imagen propia | `assets/<sha>.<ext>`, `[0-9a-f]{32}\.(png\|jpg\|heic\|tiff)` | 100 MiB y 16 384 px por lado; se decodifica reducida a 7 680 px de lado como mucho (dos veces el 4K de salida), derecha según su orientación EXIF | PNG, JPEG, HEIC |

Un formato se reconoce por el contenido, no por el nombre (un `.png` que es un BMP no se decodifica), y un PNG cortado, que ImageIO decodificaría con las filas que faltan rellenas, se rechaza. Un JPEG o un HEIC cortados sí se decodifican con la zona que falta rellena: son archivos del propio usuario.

### Compatibilidad

- Un lector de la versión 3 lee las versiones 1, 2 y 3 (`Manifest.supportedFormatVersions`, `1...3`) y rechaza cualquier otra antes de decodificar el manifiesto. Un lector de la versión 2 rechaza así los paquetes v3: un paquete v3 es *para reparar* para la app de la versión 2, que no lo toca, así nunca muestra sin sus ediciones lo que el usuario cortó. La recuperación tampoco toca un manifiesto de una versión que no lee.
- Un paquete v1 o v2 se lee como siempre: no tiene `projectID` ni `upgradedFrom`, y su id es el derivado.
- **Un paquete v1 o v2 se queda en su versión hasta que el usuario lo edita**, con el orden de arriba. Es lo que cambió respecto de la regla de la versión 2 («un paquete v1 se queda en v1»): el espíritu, nunca cambiar nada en silencio, se mantiene, porque lo cambia una acción del usuario.
- Un `kind` de `cursorImage` desconocido se lee como ausente.

## Cambios del documento 2

El documento de edición (`edit.json`, y el documento del `create` de `edit-log.jsonl`) tiene su propia versión, `documentVersion`, dentro de la versión 3 del formato. El hito 1b escribe la 1; desde el hito 1c es la 2 (`EditDocument.currentVersion`), que suma a la cámara los layouts (en la interfaz, «disposiciones») y su aspecto. El paquete sigue en `formatVersion: 3`.

La sección `camera` de un proyecto nuevo con tres bloques (el segundo fue Burbuja antes de pasar a Dividida, y el layout del proyecto estuvo un rato en Dividida: los dos conservan esos ajustes), como la escribe `ProjectJSON.encoder()`:

```json
{
  "border" : {
    "color" : [
      1,
      1,
      1,
      1
    ],
    "width" : 0
  },
  "changes" : [
    {
      "id" : "k-1c2d0a9e",
      "origin" : "recorded",
      "style" : {
        "anchor" : "topLeading",
        "shape" : "circle",
        "size" : 0.24
      },
      "t" : 81290000000000,
      "take" : "take-001"
    }
  ],
  "initial" : {
    "take-001" : {
      "anchor" : "bottomTrailing",
      "shape" : "circle",
      "size" : 0.24
    }
  },
  "layout" : {
    "kind" : "bubble",
    "split" : {
      "side" : "end"
    }
  },
  "layoutRules" : "cameraLayout-1",
  "layouts" : [
    {
      "end" : 81239567890123,
      "id" : "l-5b0e19c2",
      "instant" : false,
      "kind" : "cameraFull",
      "start" : 81234567890123,
      "take" : "take-001"
    },
    {
      "bubble" : {
        "style" : {
          "anchor" : "bottomTrailing",
          "shape" : "circle",
          "size" : 0.24
        }
      },
      "end" : 81300000000000,
      "id" : "l-0a77de31",
      "instant" : false,
      "kind" : "split",
      "split" : {
        "share" : 0.34,
        "side" : "end"
      },
      "start" : 81280000000000,
      "take" : "take-001"
    },
    {
      "bubble" : {
        "style" : {
          "anchor" : "topLeading",
          "shape" : "roundedSquare",
          "size" : 0.33
        }
      },
      "end" : 81320000000000,
      "id" : "l-c4e2a913",
      "instant" : true,
      "kind" : "bubble",
      "start" : 81310000000000,
      "take" : "take-001"
    }
  ],
  "mirror" : true,
  "shadow" : 0.4,
  "show" : true,
  "sizeReference" : "shortSide",
  "spring" : {
    "damping" : 0.95,
    "response" : 0.5
  }
}
```

| Campo | Significado |
|---|---|
| `show`, `initial`, `changes` | Como en el documento 1 |
| `layout` | El layout del proyecto, el que rige fuera de los bloques: `kind` (`bubble`, `screenOnly`, `split`, `cameraOnly` o `cameraFull`) y, opcional, `split`. Su Burbuja es siempre la de la toma (`initial` y `changes`): no tiene subobjeto `bubble` |
| `layouts[]` | Los bloques: `id` (`l-` y 8 hex al azar), `take`, `start` y `end` (`HostTime` de la fuente, `end` excluido), `kind`, `instant` y los subobjetos opcionales `bubble` y `split`. Ordenados y sin superponerse dentro de cada toma |
| `bubble` (en un bloque) | `style`, un `CameraStyle` completo. Está desde que el bloque fue Burbuja por primera vez y nunca se borra; un bloque con `kind: bubble` sin `bubble` es un documento inválido |
| `split` (en un bloque o en `layout`) | `side` (`start` o `end`) y, opcional, `share` (de 0,25 a 0,60; sin él, la parte automática). Se escribe la primera vez que el bloque o el proyecto pasa a Dividida, con `side: end`, y nunca se borra |
| `mirror` | Espejar la cámara |
| `border` | `width` de 0 a 1 (ancho = `width × 0,012 ×` lado corto de la salida) y `color` (RGBA sRGB de 0 a 1, escrito tal cual, como los colores del fondo) |
| `shadow` | Sombra de la cámara, de 0 a 1 |
| `sizeReference` | `height` (la burbuja medida contra el alto de la salida, lo de 1a y 1b) o `shortSide` (contra el lado corto) |
| `spring` | El resorte de las transiciones de layout, guardado en números como todos |
| `layoutRules` | La versión de las reglas de geometría, transiciones y zoom de los layouts (`cameraLayout-1`); el código conserva las versiones viejas |

- Los ocho campos nuevos son obligatorios en un documento 2, y los opcionales (`split`, `share`, `bubble`) se omiten cuando no están, nunca se escriben como `null`.
- **Un `kind` desconocido hace inválido el documento** (no se adivina), lo mismo que un `side` o un `sizeReference` desconocidos: el documento está dañado, no es más nuevo. Un layout nuevo en el futuro suma su propio subobjeto y su `kind`, y sube `documentVersion`.
- El registro suma la colección `/camera/layouts` para `insert`, `remove` y `replace`, como `/zoom/regions`.

**Migración desde el documento 1.** Una función pura sobre el JSON: agrega a `camera` `layout = {"kind":"bubble"}`, `layouts = []`, `mirror = false`, `border = {"width":0,"color":[1,1,1,1]}`, `shadow = 0`, `sizeReference = "height"`, `spring = {"damping":0.95,"response":0.5}` y `layoutRules = "cameraLayout-1"` (los pisa si ya estaban) y pone `documentVersion` en 2. Nada más cambia: con esos valores, el render es el de 1b byte a byte.

- Un lector del documento 2 lee uno del documento 1 migrándolo, esté donde esté (el `edit.json` o el `create` del registro), y rechaza uno más nuevo antes de leer el resto, como 1b: una app de 1b rechaza así un documento 2: dice que el proyecto es de una versión más nueva y no escribe nada en el paquete.
- La migración es aditiva: solo agrega campos, así que una operación de 1b significa lo mismo antes y después de migrar. Ninguna escribe un campo agregado ni uno que lo contenga o que la migración lea (la raíz, `/documentVersion` o `/camera` entera): ver [Reproducir, deshacer y compactar a través de una migración aditiva](#reproducir-deshacer-y-compactar-a-través-de-una-migración-aditiva).
- **Antes de la primera edición, en el disco sigue siendo v1.** Un proyecto de 1b que en 1c solo se abre, se reproduce o se exporta no cambia, y la app de 1b lo sigue abriendo: la versión 2 existe en memoria hasta que el usuario edita.

### El registro con el documento 2

- **La colección y las etiquetas.** `/camera/layouts` admite `insert`, `remove` y `replace`. Las etiquetas nuevas (`label`) son doce: `layout.add`, `layout.change`, `layout.move`, `layout.trim`, `layout.delete`, `camera.layout`, `camera.split`, `camera.mirror`, `camera.border`, `camera.shadow`, `camera.changes.deleteAll` y `style.apply` (aplicar un estilo con nombre: un solo paso, que nunca toca bloques, formato ni burbuja).
- **Qué escribe cada una.** Crear un bloque es un `insert`, borrarlo un `remove`. **Mover, recortar o cambiar el `kind` de un bloque es un `replace` del bloque entero**, con todos sus subobjetos (`bubble`, `split`), así deshacer recupera todo lo que el bloque recordaba. Cambiar el layout del proyecto (`/camera/layout`, que se escribe entero porque su `split` es una clave opcional que un `set` no puede sumar), el espejo (`/camera/mirror`), el borde (`/camera/border/width` y `/camera/border/color`) y la sombra (`/camera/shadow`) es un `set`. Borrar todos los cambios de la burbuja son los `remove` de `/camera/changes`, en un solo grupo.
- **La migración y el paso se escriben juntos.** La primera edición de un proyecto cuyo documento en el disco es el 1 agrega al final del registro, en **una sola escritura** (un búfer, un `write`, un `F_FULLFSYNC`), la línea `{"from":1,"seq":N,"to":2,"type":"migrate"}` y la del `do` de la edición. Si el registro termina en un `migrate` sin nada después, es la escritura cortada de esa primera edición: al leer se trunca y el proyecto vuelve a abrirse como v1, como si la edición no hubiera llegado (lo mismo que pierde un crash a mitad de un gesto en 1b). Truncar el archivo en cualquier byte de esa línea da el estado de antes o el de después (`cutAtEveryByteOfTheFirstEditOpensBeforeOrAfter`).
- **Mientras no hubo una primera edición, toda escritura es v1.** La sesión guarda el estado tal como está en el disco (el JSON v1 de la reproducción, con una marca `pendingMigration`) y el documento v2 migrado en memoria. Con la marca puesta, la instantánea de recuperación al cerrar, la compactación y la reparación del registro (truncar una última línea cortada, reescribir hasta la última línea buena, o el `create` de una instantánea más nueva) se hacen con ese JSON v1 y con las líneas tal como están: por eso abrir un proyecto de 1b en 1c y cerrarlo sin editar no escribe nada v2 y la app de 1b lo sigue abriendo (`openingA1bProjectWritesNothing`).

### Reproducir, deshacer y compactar a través de una migración aditiva

Antes del documento 2, todo `migrate` era un límite: la reproducción se detenía, las pilas de deshacer se vaciaban y el registro no se compactaba. Desde el 1c, la migración 1 → 2 es **aditiva** (`DocumentMigration.isAdditive`): solo agrega campos de `camera` con valores que no cambian el render, así que cada operación de 1b significa lo mismo antes y después de migrar. Hay tres reglas, una en cada lugar que antes trataba a todo `migrate` como un límite:

| Lugar | Regla |
|---|---|
| Reproducir (`EditReplay.replay`, `EditLog.swift`) | Un `migrate` de 1 a 2 sobre un documento que está en la versión 1 aplica la migración al JSON en ese punto y sigue. Uno que va más allá de `currentVersion` lanza `newerVersion` (el documento es más nuevo, no está dañado). Cualquier otro (un paso que no existe, o un `from` que no es la versión del documento) detiene la reproducción ahí, como en 1b. Un `migrate` final sin nada después se trunca |
| Pilas (`UndoHistory.swift`) | Un `migrate` aditivo conserva las pilas y los grupos: deshacer un paso de antes del `migrate` aplica su inversa sobre el documento v2, y deshacer nunca «desmigra». Uno no aditivo las vacía, como en 1b |
| Compactar (`LogCompaction.compact`, `LogCompaction.swift`) | Con solo migraciones aditivas, el registro compactado es el mismo `create` (v1), los `migrate` en orden justo después y los grupos de las pilas como en 1b: vale porque 1 → 2 conmuta con toda operación de 1b, así cada grupo se aplica igual antes o después de migrar. Con una no aditiva no se compacta, como en 1b. Mientras `pendingMigration` está puesta no hay `migrate` y se compacta como en 1b |

**Cuándo la migración deja de conmutar y se cae a la regla de 1b.** Las tres reglas valen solo si ninguna línea de antes del `migrate` escribe un lugar que la migración lee o agrega, ni uno que lo contenga. `DocumentMigration.touchesAddedFields` es verdadero para una operación cuyo camino es: **la raíz del documento, `/documentVersion` (la migración lo lee y lo escribe), `/camera` entera, o cualquiera de los ocho campos que la migración agrega** (`/camera/border`, `layout`, `layoutRules`, `layouts`, `mirror`, `shadow`, `sizeReference` o `spring`, y todo lo que está debajo). Con una línea así antes del `migrate` (hecha a mano: ninguna acción de 1b escribe esos lugares, que `TrackCommands` solo toca `/camera/show`, `/camera/initial/<toma>` y elementos de `/camera/changes`, y `applyDefaultStyle` solo `/style`, `/cursor` y `/zoom`), ese `migrate` sigue la regla de 1b: corta la historia y el registro no se compacta. Lo mismo vale para una migración futura que no sea aditiva. Un `migrate` que sobrescribiría un campo que una línea hecha a mano de v1 escribió se rechaza.

### Documento legado, de 1b y nuevo

| | Legado (v1/v2 sin edición) | De 1b (`documentVersion` 1, migrado) | Nuevo (v3 recién grabado en 1c) |
|---|---|---|---|
| Se escribe | Nunca, hasta la primera edición | En v1 hasta la primera edición; ahí, `migrate` y el paso juntos | Al abrir por primera vez, con el estilo de los proyectos nuevos |
| `layout`, `layouts` | Burbuja, sin bloques | Burbuja, sin bloques | Burbuja (o el del estilo), sin bloques |
| `mirror` | no | no | sí (o el del estilo) |
| `border`, `shadow` | 0, 0 | 0, 0 | 0, 0,4 (o los del estilo) |
| `sizeReference` | `height` | `height` | `shortSide` |
| Lo demás | como siempre | lo que tenía | como los proyectos nuevos de 1b |

«Aplicar un estilo» pone el `sizeReference` del estilo; como todo estilo guardado en 1c tiene `shortSide`, aplicarlo a un proyecto viejo pasa su burbuja a medirse contra el lado corto. Es una acción del usuario y se deshace.

**Un borde conocido: la toma v3 de una build de 1b sin publicar.** «Nuevo» se decide por lo que hay en el paquete, no por la versión de la app que lo grabó: un v3 sin registro, sin instantánea y sin `upgradedFrom` (una toma que ningún editor abrió todavía) toma el camino del documento nuevo. La versión de la app (`MARKETING_VERSION`) es 0.0.0 en todas las builds de 1a, 1b y 1c, así que no sirve para distinguir cuál lo grabó. Consecuencia: **una toma v3 grabada por una build de 1b sin publicar y que nunca se abrió se abre con el aspecto nuevo de la cámara** (espejada, con sombra y con la burbuja medida contra el lado corto). Las grabaciones reales del dueño son del hito 1a (formato v1): son el documento legado y no cambian. Un v3 que ya se abrió en 1b tiene registro y no entra en este caso.

### Lo que guarda la biblioteca, fuera de los paquetes

La biblioteca nunca escribe dentro de un paquete (abrirla, generar miniaturas, marcar favoritos, renombrar, mandar a la papelera y restaurar dejan igual el hash del contenido de cada uno; renombrar cambia solo su nombre; lo comprueba `nothingWritesInsideAPackage`). Lo suyo vive en estos lugares; el formato interno de cada archivo es un detalle de la app y puede cambiar sin tocar el de los paquetes:

| Dónde | Qué | Si se pierde |
|---|---|---|
| `~/Library/Application Support/Toma/Library/library.json` | Favoritos, el último abierto, Otros lugares (un bookmark y la última ruta conocida) y de dónde salió cada proyecto de la papelera, todo por la identidad del paquete (`PackageIdentity`: el UUID del volumen y el identificador de archivo de la carpeta del paquete, escrita `<volumen>:<archivo>`; sigue a un paquete que se renombra o se mueve dentro de su disco, y una copia es otro; nunca es el `projectID` del manifiesto, que una copia comparte) | Se pierden esos datos, nunca un proyecto; por eso no está en Caches |
| `~/Library/Caches/dev.toma.Toma/Library/index.json` | El índice: por paquete, lo que la ventana muestra (nombre, fecha, duración de salida, formato, si tiene cámara, versiones, estado, tamaño) y las firmas (tamaño y fecha) de `manifest.json`, `edit.json` y `edit-log.jsonl` con las que se sabe si hay que volver a leerlo | Se reconstruye |
| `~/Library/Caches/dev.toma.Toma/Library/thumbnails/<clave>.heic` | Las miniaturas (hasta 500 MB; se borran primero las menos usadas) | Se regeneran |
| `~/Library/Application Support/Toma/Styles/<id>.tomastyle/` | Los estilos con nombre | Se pierden los estilos |
| Ajustes de la app | El estilo de los proyectos nuevos, la vista, el orden y la sección de la biblioteca, las opciones de la hoja de exportar | Valores por defecto |

Se escriben con `DurableFile.writeAtomically`, fuera del hilo principal, a lo sumo cada 2 s. Lo que la papelera hace con un proyecto (mover, restaurar, eliminar) está en la biblioteca; para el formato, un paquete en la papelera es un paquete como cualquier otro.

## Cambios del documento 3

Desde la fase 2, el documento de edición es la versión 3 (`EditDocument.currentVersion`): una sola versión nueva con todos los campos de la fase 2 (diseño de la fase 2, §4.5 y §8), así las funciones de la voz, la imagen y la privacidad trabajan sobre los mismos tipos y hay una sola migración. Suma la transcripción, los subtítulos, los bloques de privacidad, las teclas en pantalla y campos nuevos del escenario, la cámara y el sonido. El paquete sigue en `formatVersion: 3`; un lector del documento 3 lee los documentos 1 y 2 migrándolos y rechaza el 4 o uno más nuevo (`newerVersion`), esté en `edit.json` o en el `create` del registro.

| Lugar | Qué es | Legado (lo que escribe la migración) |
|---|---|---|
| `transcript` | La transcripción, opcional: `language` (BCP 47), `engine` (`speechTranscriber-1`) y `takes[]`, cada una con `take`, `track` y `words[]`: `start` y `end` (`HostTime` de la fuente, `end` excluido), `text` (con la puntuación pegada) y `breakBefore` (un subtítulo empieza en esa palabra) | Ausente |
| `captions` | `show` y `style`: `preset` (`classic`, `bold` = «Destacado», `minimal`), `size` (`small`, `medium`, `large`), `position` (`bottom`, `top`), `uppercase`, `highlight` y `highlightColor` (RGBA sRGB de 0 a 1) | `show: false`; `bold`, `medium`, `bottom`, `uppercase: false`, `highlight: true`, `highlightColor: [1, 0.8392156862745098, 0.0392156862745098, 1]` (#FFD60A) |
| `privacy` | `blocks[]`: `id` (`p-` y 8 hex al azar), `take`, `start` y `end`, `effect` (`blur`, `pixelate`, `fill`), `strength` (0 a 1), `color` (RGBA, el del relleno), `rect`, `keys[]` (`t` y `rect`, en orden de tiempo) y `origin` (`manual`, `email`, `phone`, `card`, `secret`, `face`) | `{"blocks": []}` |
| `keys` | Las teclas en pantalla: `mode` (`off`, `shortcuts`, `all`), `position` (`bottomCenter`, `bottomLeading`, `bottomTrailing`, `top`) y `size` (`small`, `medium`, `large`) | `off`, `bottomCenter`, `medium` |
| `style.reframe` | `fit` (la pantalla entera, lo de la fase 1) o `followCursor` | `fit` |
| `style.frame` | Suma `{"type":"device","model":…,"finish":…}`: `model` `iPhone`, `iPad` o `macBook`, `finish` `dark` o `light` | Lo que tenía (`none` o `macWindow`) |
| `camera.background` | `original`, `blurred` o `removed` | `original` |
| `camera.framing` | `mode` (`center`, `face`, `manual`), `center` (`x` e `y`, fracciones de la imagen de la cámara) y `zoom` (1 a 2,5; 1,4 al elegir Seguir la cara) | `center`, `{"x": 0.5, "y": 0.5}`, `1` |
| `camera.look` | `preset` (`natural`, `warm`, `cool`, `vivid`, `soft`, `mono`, `custom`), `lut` opcional (el `.cube` de `custom`, copiado a `assets/<sha256>.cube`) e `intensity` (0 a 1) | `natural`, sin `lut`, `1` |
| `camera.syncOffset` | Cuánto más tarde se dibuja la cámara contra el sonido, en ns (entero; positivo, más tarde) | `0` |
| `audio.normalize` | Normalizar el volumen | `false` |
| `audio.tracks.<toma>/<pista>.cleanup` | La limpieza de ruido de la pista, de 0 a 1 | `0`, en cada pista |

- Un `rect` es `{x, y, width, height}`, en fracciones del contenido de la pantalla, de 0 a 1, con `y` hacia abajo.
- **Lo que se omite.** `transcript` mientras no hay transcripción, `lut` sin LUT y `breakBefore` cuando es `false` (una transcripción tiene miles de palabras): nunca se escriben como `null`. Una palabra que deja de empezar un subtítulo se escribe entera, o se le saca `breakBefore` con un `set` a `null` (abajo). Todo lo demás se escribe siempre, como los campos del documento 2.
- **Un valor desconocido hace inválido el documento** (un `preset`, un `model`, un `effect` que no son estos): está dañado, no es más nuevo. Lo mismo la falta de un campo obligatorio, con una excepción: un `style` sin `reframe` se lee como `fit`, porque así lo guardan la fase 1 y sus estilos (`default-style.json` y el `style.json` de un `.tomastyle`); en un documento 3 siempre está, y un cambio que lo saca se rechaza.

El documento de diseño §6.2 con todos los campos de la fase 2 lejos de su valor legado (una transcripción de dos palabras, la segunda empieza un subtítulo; subtítulos Clásico arriba; un bloque de privacidad con dos claves; todas las teclas; la pantalla siguiendo al cursor en un iPhone claro; la cámara sin fondo, encuadrada a mano, con un color propio y 40 ms tarde; el volumen normalizado y el micrófono limpio), como lo escribe `ProjectJSON.encoder()`; lo guarda `version3ExampleRoundTripsByteForByte`, que lo lee y lo vuelve a escribir byte por byte:

```json
{
  "aspect" : "16:9",
  "audio" : {
    "limiter" : true,
    "normalize" : true,
    "tracks" : {
      "take-001/mic" : {
        "cleanup" : 0.6,
        "gain" : 1,
        "muted" : false
      },
      "take-001/system-audio" : {
        "cleanup" : 0,
        "gain" : 0.8,
        "muted" : false
      }
    }
  },
  "camera" : {
    "background" : "removed",
    "border" : {
      "color" : [
        1,
        1,
        1,
        1
      ],
      "width" : 0
    },
    "changes" : [
      {
        "id" : "k-1c2d0a9e",
        "origin" : "recorded",
        "style" : {
          "anchor" : "topLeading",
          "shape" : "circle",
          "size" : 0.24
        },
        "t" : 81290000000000,
        "take" : "take-001"
      }
    ],
    "framing" : {
      "center" : {
        "x" : 0.4,
        "y" : 0.35
      },
      "mode" : "manual",
      "zoom" : 1.8
    },
    "initial" : {
      "take-001" : {
        "anchor" : "bottomTrailing",
        "shape" : "circle",
        "size" : 0.24
      }
    },
    "layout" : {
      "kind" : "bubble"
    },
    "layoutRules" : "cameraLayout-1",
    "layouts" : [

    ],
    "look" : {
      "intensity" : 0.75,
      "lut" : "assets/5f0c3a2e9b1d4c7a8e6f0b2d4a6c8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c0d.cube",
      "preset" : "custom"
    },
    "mirror" : false,
    "shadow" : 0,
    "show" : true,
    "sizeReference" : "height",
    "spring" : {
      "damping" : 0.95,
      "response" : 0.5
    },
    "syncOffset" : 40000000
  },
  "captions" : {
    "show" : true,
    "style" : {
      "highlight" : false,
      "highlightColor" : [
        0.2,
        0.6,
        1,
        1
      ],
      "position" : "top",
      "preset" : "classic",
      "size" : "large",
      "uppercase" : true
    }
  },
  "cursor" : {
    "clickEffect" : "ripple-1",
    "clickSound" : "none",
    "clickSoundGain" : 0.5,
    "hideWhenIdle" : true,
    "idleDelay" : 2,
    "motionBlur" : 0.5,
    "scale" : 1.5,
    "show" : true,
    "smoothing" : {
      "damping" : 1,
      "response" : 0.16
    },
    "style" : "system"
  },
  "documentVersion" : 3,
  "frameRate" : 60,
  "keys" : {
    "mode" : "all",
    "position" : "top",
    "size" : "small"
  },
  "logSequence" : 128,
  "privacy" : {
    "blocks" : [
      {
        "color" : [
          0.1,
          0.1,
          0.1,
          1
        ],
        "effect" : "pixelate",
        "end" : 81253000000000,
        "id" : "p-5e1d0c2a",
        "keys" : [
          {
            "rect" : {
              "height" : 0.25,
              "width" : 0.4,
              "x" : 0.1,
              "y" : 0.2
            },
            "t" : 81250000000000
          },
          {
            "rect" : {
              "height" : 0.25,
              "width" : 0.4,
              "x" : 0.3,
              "y" : 0.5
            },
            "t" : 81252000000000
          }
        ],
        "origin" : "email",
        "rect" : {
          "height" : 0.25,
          "width" : 0.4,
          "x" : 0.1,
          "y" : 0.2
        },
        "start" : 81250000000000,
        "strength" : 0.8,
        "take" : "take-001"
      }
    ]
  },
  "screens" : {
    "changes" : [
      {
        "id" : "p-9a01b2c3",
        "origin" : "auto",
        "t" : 81260000000000,
        "take" : "take-001",
        "track" : "display-2"
      }
    ],
    "initial" : {
      "take-001" : "display-1"
    },
    "planner" : "screenFollow-1"
  },
  "sequence" : [
    {
      "end" : 81276901234567,
      "id" : "c-00a1b2c3",
      "speed" : 1,
      "start" : 81234567890123,
      "take" : "take-001"
    },
    {
      "end" : 81334000000000,
      "id" : "c-00d4e5f6",
      "speed" : 2,
      "start" : 81277458000000,
      "take" : "take-001"
    }
  ],
  "style" : {
    "background" : {
      "type" : "wallpaper",
      "wallpaper" : "aurora-1"
    },
    "backgroundBlur" : 0,
    "cornerRadius" : 0.012,
    "frame" : {
      "finish" : "light",
      "model" : "iPhone",
      "type" : "device"
    },
    "geometryTransition" : "spring",
    "padding" : 0.08,
    "reframe" : "followCursor",
    "screenSampling" : "mipmapped",
    "shadow" : 0.6
  },
  "transcript" : {
    "engine" : "speechTranscriber-1",
    "language" : "es-AR",
    "takes" : [
      {
        "take" : "take-001",
        "track" : "mic",
        "words" : [
          {
            "end" : 81235400000000,
            "start" : 81235000000000,
            "text" : "Hola,"
          },
          {
            "breakBefore" : true,
            "end" : 81236000000000,
            "start" : 81235500000000,
            "text" : "mundo."
          }
        ]
      }
    ]
  },
  "zoom" : {
    "auto" : {
      "depth" : 2,
      "enabled" : true,
      "follow" : true,
      "groupGap" : 2.5,
      "holdWhileTyping" : true,
      "leadIn" : 0.5,
      "leadOut" : 1,
      "planner" : "autoZoom-1",
      "triggers" : "clicks"
    },
    "motionBlur" : 0.5,
    "regions" : [
      {
        "end" : 81245000000000,
        "focus" : {
          "type" : "follow"
        },
        "id" : "z-3fa2b1c0",
        "instant" : false,
        "origin" : "auto",
        "start" : 81241000000000,
        "take" : "take-001"
      },
      {
        "depth" : 1.6,
        "end" : 81300000000000,
        "focus" : {
          "type" : "fixed",
          "x" : 0.31,
          "y" : 0.72
        },
        "id" : "z-7e11d0aa",
        "instant" : false,
        "origin" : "user",
        "start" : 81296000000000,
        "take" : "take-001"
      }
    ],
    "show" : true,
    "spring" : {
      "damping" : 1,
      "response" : 0.7
    },
    "suppressed" : [
      {
        "end" : 81320000000000,
        "start" : 81318000000000,
        "take" : "take-001"
      }
    ]
  }
}
```

**Migración desde el documento 2.** Una función pura sobre el JSON: escribe (encima de lo que hubiera) los valores de la columna «Legado» de la tabla en `/captions`, `/keys`, `/privacy`, `/style/reframe`, `/camera/background`, `/camera/framing`, `/camera/look`, `/camera/syncOffset` y `/audio/normalize`, y `cleanup = 0` en cada pista de `/audio/tracks`, y pone `documentVersion` en 3. Nada más cambia: con esos valores, el render y la mezcla son los de la fase 1 byte a byte (`make golden-2`). Un documento sin `style`, `camera`, `audio` o `audio.tracks` (o con una pista que no es un objeto) no migra: es inválido. Un documento 1 migra a 2 y después a 3.

- **Una tabla, un algoritmo.** Cada migración es una fila de una tabla (`DocumentMigration.addedPlaces`: por versión de origen, los lugares que agrega como punteros JSON, `*` = cada miembro de ese objeto, con sus valores congelados en el código, nunca tomados de los valores por defecto de los tipos). Con la misma tabla se migra (`migrate`), se vuelve atrás (`reverted`) y se decide qué conmuta con la migración (`touchesAddedFields`). Las dos migraciones, 1 → 2 y 2 → 3, son aditivas.
- **Volver atrás, de a una versión.** `reverted(_:to: 2)` saca los lugares agregados si cada uno tiene su valor legado y pone `documentVersion` en 2; a 1 sigue bajando (3 → 2 → 1). Un documento que usa la fase 2 no tiene versión 2: da `nil` si algún lugar agregado tiene otro valor o falta, si tiene `transcript` o si `style.frame` es `device`. Un caso nuevo de un tipo que ya estaba en el documento 2 (como los formatos nuevos de `aspect`, diseño de la fase 2 §6.4) se suma a esa lista de valores que el 2 no puede tener.
- **Qué no conmuta con 2 → 3.** `touchesAddedFields(_:from: 2)` es verdadero para una operación cuyo camino es la raíz, `/documentVersion`, un prefijo de un lugar agregado (`/style`, `/camera`, `/audio`, `/audio/tracks` y cada `/audio/tracks/<clave>` enteros) o algo debajo de uno (`/captions/show`, `/camera/look/intensity`, un `insert` en `/privacy/blocks`…). Con una línea así antes del `migrate`, ese `migrate` corta la historia y el registro no se compacta, como en 1b. **Ojo: la fase 1 sí escribe dos de esos lugares enteros**: el volumen y el silencio de una pista (`/audio/tracks/<clave>`, una sola línea con su `TrackGain`, o `/audio/tracks` entero para una pista sin entrada) y «Aplicar el estilo por defecto» o «Aplicar un estilo» (`/style` entero). En un proyecto de 1b o 1c con una de esas ediciones, después de la primera edición en la fase 2 Deshacer no vuelve a los pasos de antes, y su registro ya no se compacta.
- **Antes de la primera edición, en el disco sigue en su versión.** Un proyecto de 1b (documento 1) o de 1c (documento 2) que en la fase 2 solo se abre, se reproduce o se exporta no cambia, y la app de la fase 1 lo sigue abriendo; la instantánea al cerrar, la compactación y la reparación del registro se escriben en su versión (`openingAVersion2ProjectWritesNothing`, `openingAVersion1ProjectWritesNothing`). La primera edición agrega en **una sola escritura** el `migrate` de cada versión que falta y el paso: `{"from":2,"seq":N,"to":3,"type":"migrate"}` y el `do` en un proyecto de 1c; `1 → 2`, `2 → 3` y el `do` en uno de 1b. Un registro que termina en uno o más `migrate` sin nada después es esa escritura cortada: al leer se truncan y el proyecto abre como antes de la edición (`cutAtEveryByteOfTheFirstEditOpensBeforeOrAfterTo3`, `diskFullOnTheFirstEditTo3NeverLeavesMigrateAlone`).

### El registro con el documento 3

- **Un `set` agrega y saca un miembro opcional.** Un miembro que no está se lee como `null`: un `set` con `before: null` sobre un miembro de un objeto que existe lo agrega, y uno con `after: null` lo saca. Así van y vienen `transcript`, `lut` y `breakBefore`, y su inversa los deshace; el documento nunca tiene un `null`. Un `before` distinto de `null` sobre un miembro que no está es un `mismatch`; sacar un miembro obligatorio, o agregar uno que el documento no tiene, deja un documento inválido y se rechaza. Solo vale para miembros de un objeto: nunca para un elemento de un arreglo, que se agrega y se saca con `insert` y `remove`.
- **Las colecciones.** `/privacy/blocks` admite `insert`, `remove` y `replace` (por `id`), como `/zoom/regions`. `/transcript/takes` existe solo con una transcripción y admite `insert` y `remove` (sus elementos no tienen `id`); una palabra se corrige con un `set` por puntero (`/transcript/takes/<i>/words/<j>/text`).
- **Las etiquetas** (`label`) nuevas son veinticinco, después de las de la fase 1: `transcript.create`, `transcript.cut`, `transcript.restore`, `transcript.word`, `transcript.break`, `transcript.fillers`, `transcript.pauses`, `captions.show`, `captions.style`, `camera.hideSilences`, `camera.background`, `camera.framing`, `camera.look`, `camera.sync`, `audio.cleanup`, `audio.normalize`, `style.reframe`, `privacy.add`, `privacy.change`, `privacy.move`, `privacy.trim`, `privacy.delete`, `privacy.auto`, `keys.overlay` y `speed.typing`.

### Las cachés de análisis

Lo que calcula el análisis de la fase 2 (diseño de la fase 2, §10) va a la carpeta de cachés del proyecto, fuera del paquete, junto a `thumbnails/` y `waveforms/`: `~/Library/Caches/dev.toma.Toma/Projects/<projectID>/`. Como el resto de esa carpeta, se puede borrar entera o en parte: lo que falta se vuelve a calcular (y el export espera a que esté), y nada de lo que hay en el paquete depende de ella. La transcripción no es una caché: va al documento (`transcript`).

| Carpeta | Qué guarda | Nombre |
|---|---|---|
| `masks/` | La máscara de la persona de cada segmento de la cámara | `<take>/<track>/<segmento>-personMask-1.mov` |
| `faces/` | La cara de cada segmento de la cámara | `<take>/<track>/<segmento>-faceTrack-1.json` |
| `clean/` | El sonido sin ruido de cada segmento del micrófono | `<take>/<track>/<segmento>-soundIsolation-1.caf` |
| `loudness/` | La sonoridad de cada segmento de una pista de audio | `<take>/<track>/<segmento>-loudness-1.json` |
| `scan/` | Los datos sensibles encontrados en la pantalla de una toma | `<take>-sensitiveScan-1.json` |

- **`<segmento>` es la identidad del archivo fuente** (`SegmentIdentity`): la raíz de su nombre, su tamaño en bytes y su fecha de modificación en nanosegundos desde 1970, leídos con `lstat` (un enlace no se sigue: un segmento que es un enlace no tiene identidad ni caché). Por ejemplo `masks/take-001/camera/seg-0001-48213377-1763561234123456789-personMask-1.mov`. Un segmento que se reescribe (la recuperación que lo cierra, una copia que no conservó la fecha) cambia de nombre y se vuelve a analizar; nada compara contenidos. El último guion separa el id del algoritmo, que lleva su versión: un algoritmo nuevo es otro archivo, nunca uno reescrito.
- **Nombres que no salen de la carpeta.** El `take`, el `track` y el nombre del archivo tienen que ser cada uno un solo nombre (no vacío, ni `.` ni `..`, sin `/` ni NUL); si no, no hay archivo (`ProjectCaches.analysisFile` y `scanFile` dan `nil`).
- **Enteras o ausentes.** Cada archivo se escribe entero en un temporal oculto de la misma carpeta (`.<nombre>.<UUID>.tmp.<extensión>`, con la extensión al final para los escritores que se guían por ella), con sus bytes ordenados antes del `rename(2)` que lo pone en su nombre (`F_BARRIERFSYNC`): un lector ve el archivo anterior o el nuevo entero, nunca una parte, y tras un corte de luz el nombre tiene los bytes enteros o no existe. Si macOS vació la carpeta, se vuelve a crear. Un temporal que dejó un crash nadie lo lee, y se va con la carpeta del proyecto. Se leen sin seguir enlaces (`SafeRead`).
- **La cola** (`ProjectJobs`, un actor por proyecto abierto en el editor) corre los trabajos que las escriben de a uno, con QoS `utility`, y los frena mientras se graba: el que corría vuelve a empezar al terminar la toma y encuentra lo que ya había escrito.

## Los datos crudos nunca se borran

Los segmentos y `events.jsonl` de una toma son los datos crudos, y ningún componente los borra ni los reescribe sin que el usuario lo pida: ni la grabación, ni la recuperación, ni una actualización de la app. Un archivo que no se puede leer se marca como `unreadable` en el manifiesto y queda en el disco tal cual estaba. La única excepción es la línea cortada al final de `events.jsonl` (ver arriba): son los bytes de una escritura que no terminó, no un evento, y se truncan antes de seguir escribiendo. Lo único que se puede borrar sin perder nada es `cache/` y la carpeta de cachés del proyecto fuera del paquete, porque todo lo que contienen se vuelve a calcular, y el `.reserve` de una toma, que es espacio vacío.

## Cambios de la versión 4

La versión 4 llega con la fase 2, para las tomas que graban un iPhone o un iPad por cable o las teclas. Los paquetes nuevos se siguen creando con `formatVersion: 3` (`Manifest.currentFormatVersion`); la versión más nueva que escribe y lee esta versión es la 4 (`Manifest.newestFormatVersion`).

- Tipos de pista nuevos, al final de la lista:

  | `kind` | Qué graba | Segmentos | Campos de `source` |
  |---|---|---|---|
  | `device` | La pantalla de un iPhone o un iPad conectado por cable: es la pantalla de la toma, como `display` o `window`. | video | `name`, `deviceUniqueID` |
  | `deviceAudio` | El sonido de ese iPhone o iPad, en una pista aparte. | audio | `name`, `deviceUniqueID` |

  La recuperación y la verificación leen video en `device` y audio en `deviceAudio`.
- Evento nuevo, `keyPress`: una tecla que bajó, solo en las tomas en que el usuario eligió grabar las teclas y nunca con la entrada segura de macOS activa. `code` es el código virtual de la tecla (`kCGKeyboardEventKeycode`, de 0 a 65535), `chars` lo que escribe sin modificadores (falta en una tecla que no escribe nada, como una flecha o una tecla de función), `mods` los modificadores (`CGEventFlags`, sus 32 bits bajos, de 0 a 4294967295) y `repeat` si es la repetición automática de la tecla. Convive con `keyActivity`, que sigue igual y es lo único que usa la actividad de tipeo:

  ```
  {"chars":"a","code":0,"mods":256,"repeat":false,"t":5,"type":"keyPress"}
  {"code":123,"mods":0,"repeat":true,"t":7,"type":"keyPress"}
  ```

Cuándo un paquete pasa a la versión 4:

- **Un paquete pasa a 4 solo cuando una toma los usa**: la grabación sube el manifiesto a 4 (`ManifestStore.raiseFormatVersion(to: 4)`, una escritura) antes de sumar la primera pista `device` o `deviceAudio` o de escribir la primera línea `keyPress`. Si no, sigue en 3 y lo abre la app de la fase 1. Un manifiesto de una versión anterior a 4 nunca se escribe con una pista `device` o `deviceAudio` (`ManifestStoreError.needsFormatVersion(4)`), y una subida que no se pudo escribir deja la versión como estaba.
- La versión solo sube, y solo desde 3: un paquete v1 o v2 pasa a 3 con su primera edición y no se graba en él (`Manifest.recordableFormatVersions`, `3...4`), así que nunca salta a 4.
- Una vez en 4, el paquete se queda en 4: nada lo baja, y las tomas siguientes y la recuperación lo escriben en 4 aunque no tengan pistas de dispositivo ni teclas. El documento de edición no cambia por la versión 4.

Compatibilidad:

- **El lector acepta 1…4** (`Manifest.supportedFormatVersions`, `1...4`) y rechaza cualquier otra antes de decodificar el manifiesto: un manifiesto de la versión 5 o más es de una Toma más nueva (*versión más nueva* en la biblioteca, *para reparar* en la recuperación, que no lo toca).
- La app de la fase 1 (lector de `1...3`) dice que un paquete v4 es de una versión más nueva, nunca que está dañado, y no lo toca. Un paquete de la fase 2 sin iPhone ni teclas sigue en 3 y lo abre igual.
- Un lector que no conoce `keyPress` salta esas líneas, como cualquier línea que no entiende; la versión 4 del manifiesto ya avisa antes.

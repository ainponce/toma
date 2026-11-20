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
| `aspect` | `16:9`, `9:16` o `1:1`; desde el documento 3 también `4:5`, `4:3`, `3:4` y `auto` (como la grabación) |
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

Las imágenes propias del fondo, copiadas al paquete (con un clon de APFS cuando se puede): `assets/<sha>.<ext>`, donde `<sha>` son 32 dígitos hexadecimales en minúscula (los primeros 16 bytes de SHA-256 del archivo) y `<ext>` es `png`, `jpg` o `heic` (la importación solo ofrece esas tres; un nombre `.tiff` es válido, pero no se decodifica). El documento las nombra con `{"type":"image","file":"assets/<sha>.<ext>"}`. No se borran en 1b: deshacer puede volver a necesitarlas. Es una carpeta común y sus archivos, archivos comunes. Desde el documento 3 guarda también los `.cube` del color de la cámara, `assets/<sha>.cube`, copiados igual (ver «Cambios del documento 3»).

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
| LUT propia (documento 3) | `assets/<sha>.cube`, `[0-9a-f]{32}\.cube` | 16 MiB; nunca se decodifica como imagen, se interpreta con `CubeLUT.parse` | `.cube` 3D |

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

**Cuándo la migración deja de conmutar y se cae a la regla de 1b.** (Desde la fase 2, una línea que escribe `/camera` entera ya no corta: se lleva a través de la migración, ver «Cambios del documento 3».) Las tres reglas valen solo si ninguna línea de antes del `migrate` escribe un lugar que la migración lee o agrega, ni uno que lo contenga. `DocumentMigration.touchesAddedFields` es verdadero para una operación cuyo camino es: **la raíz del documento, `/documentVersion` (la migración lo lee y lo escribe), `/camera` entera, o cualquiera de los ocho campos que la migración agrega** (`/camera/border`, `layout`, `layoutRules`, `layouts`, `mirror`, `shadow`, `sizeReference` o `spring`, y todo lo que está debajo). Con una línea así antes del `migrate` (hecha a mano: ninguna acción de 1b escribe esos lugares, que `TrackCommands` solo toca `/camera/show`, `/camera/initial/<toma>` y elementos de `/camera/changes`, y `applyDefaultStyle` solo `/style`, `/cursor` y `/zoom`), ese `migrate` sigue la regla de 1b: corta la historia y el registro no se compacta. Lo mismo vale para una migración futura que no sea aditiva. Un `migrate` que sobrescribiría un campo que una línea hecha a mano de v1 escribió se rechaza.

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
| `aspect` | Suma `4:5`, `4:3`, `3:4` y `auto` (como la grabación) a `16:9`, `9:16` y `1:1`. Un documento que usa uno no vuelve a la versión 2 ni a la 1 | Lo que tenía |

- Un `rect` es `{x, y, width, height}`, en fracciones del contenido de la pantalla, de 0 a 1, con `y` hacia abajo.
- **Tamaño de salida de los formatos nuevos** (`StageLayout.outputSize(aspect:shortSide:contentRatio:)`). 16:9, 9:16 y 1:1 como siempre. Para `4:5`, `4:3` y `3:4` el lado corto es el de la hoja (720, 1080, 1440 o 2160) y el largo `round(corto × r / 2) × 2`, con `r` el largo sobre el corto (1080: 4:5 = 1080 × 1350, 4:3 = 1440 × 1080, 3:4 = 1080 × 1440). `auto` usa la proporción de lo que muestra el primer tramo (con el recorte de Área) si es finita, positiva y se aparta un 1 % o más de 16:9; si no, es 16:9. El GIF pone `longSide` en el lado largo y el otro en proporción, redondeado a un número par (800: 4:5 = 640 × 800, 4:3 = 800 × 600).
- **Lo que se omite.** `transcript` mientras no hay transcripción, `lut` sin LUT y `breakBefore` cuando es `false` (una transcripción tiene miles de palabras): nunca se escriben como `null`. Una palabra que deja de empezar un subtítulo se escribe entera, o se le saca `breakBefore` con un `set` a `null` (abajo): `EditDocument.setChange` da ese `set` a `null` cuando el valor pedido es uno que el JSON omite. Todo lo demás se escribe siempre, como los campos del documento 2.
- **Un valor desconocido hace inválido el documento** (un `preset`, un `model`, un `effect` que no son estos): está dañado, no es más nuevo. Lo mismo la falta de un campo obligatorio, con una excepción: un `style` sin `reframe` se lee como `fit`, porque así lo guardan la fase 1 y sus estilos (`default-style.json` y el `style.json` de un `.tomastyle`); en un documento 3 siempre está, y un cambio que lo saca se rechaza.
- **El `.cube` de `camera.look.lut`** es `assets/<sha>.cube`, `[0-9a-f]{32}\.cube` (los primeros 16 bytes de SHA-256 de sus bytes, en minúscula), copiado por contenido como las imágenes de `assets/` (`AssetImport.copyLUT`, `EditSession.importAsset(_:kind: .lut)`): se lee entero (hasta 16 MiB), se interpreta antes de nombrarlo, se clona sin seguir enlaces, se vuelve a hashear y se nombra con `renameat`, así lo que queda es lo que se interpretó. Se lee con `SafePackageFile` (`PackageFileKind.lut`: solo en `assets/`, sin enlaces, archivo común de 16 MiB como mucho, nunca decodificado como imagen) y `CubeLUT.parse`; uno que falta o no se lee se dibuja Natural. El formato aceptado es el `.cube` 3D de Adobe/Iridas, estricto: UTF-8 (sin caracteres de control salvo tabulador, LF y CR; una marca de orden de bytes se saltea), líneas con LF, CRLF o CR, líneas vacías y comentarios `#` ignorados; antes de la tabla, `TITLE`, `LUT_3D_SIZE` de 2 a 65 (una vez), `DOMAIN_MIN` y `DOMAIN_MAX` (una vez cada uno, cada canal con su comienzo menor que su fin; por defecto 0 y 1) o `LUT_3D_INPUT_RANGE` de Resolve (el mismo dominio en los tres canales), y una palabra clave de otra herramienta (mayúsculas, dígitos y `_`, con algún `_`) se ignora; después, exactamente `tamaño³` filas de tres decimales finitos, rojo el más rápido. Se rechaza con su motivo (`CubeLUTError`) y sin escribir nada: no es texto (`notText`), es 1D o tiene una parte 1D (`oneDimensional`), no tiene tamaño antes de la tabla (`missingSize`), tamaño fuera de 2…65 (`sizeOutOfRange`), filas de más o de menos (`wrongCount`), una línea que no es de un `.cube`: `nan`, infinito, hexadecimal, coma decimal, la cantidad de números equivocada, una palabra clave repetida o entre las filas (`badNumber`, con su línea), dominio vacío o al revés (`badDomain`), más de 16 MiB (`tooLarge`, sin leerlo).
- **`cameraLook-1`, los looks de la cámara** (diseño de la fase 2, §6.3; decisión 7 del plan 2b). Natural es la identidad y no dibuja nada; cada uno de los otros cinco es una LUT 3D de 33³ generada en código (`CameraLooks.lut`), con dominio 0…1, que el render sube como textura `rgba16Float` y lee trilineal con `uvw = c (N − 1) / N + 0,5 / N`. Cada punto `(r, g, b) / 32` pasa, recortado a 0…1, a lineal (IEC 61966-2-1); se multiplica por su balance de blancos (una ganancia por canal en lineal: el negro sigue negro); se aleja o se acerca a su gris con la saturación `L + s (c − L)` (`L` la luma Rec. 709 en lineal); vuelve a sRGB; se le aplica el contraste `0,5 + k (c − 0,5)` alrededor del gris medio y por último los negros: lo que el contraste hizo del negro, `c₀ = max(0; 0,5 − 0,5 k)`, va a `n` y el 1 queda en 1 (`n + (c − c₀) (1 − n) / (1 − c₀)`, la identidad con `n` y `c₀` en 0); cada paso, recortado a 0…1. Cálido: `R × 1,06`, `B × 0,95`, saturación 1,05. Frío: `R × 0,96`, `B × 1,06`. Vívido: saturación 1,3, contraste 1,1. Suave: saturación 0,9, contraste 0,9 (el negro a 0,05, el blanco a 0,95) y negros 0,04 (el negro queda en 0,04 exacto, el blanco en 0,9495). Blanco y negro: saturación 0 (la luma) y contraste 1,05. La intensidad mezcla `mix(c, LUT(c), i)`. Los SHA-256 de las cinco tablas en `Float16` están congelados en `cameraLook1IsFrozen`: un look distinto es un id nuevo.
- **`faceFraming-1`, Seguir la cara** (diseño de la fase 2, §6.2; decisión 3 del plan 2b; `FaceFramingPath`). Con `camera.framing.mode` `face`, el centro del recorte sale de las caras de `faceTrack-1` (abajo, en las cachés), simulado en tiempo de salida en la grilla de 600 Hz, con un punto de control cada 600 pasos (los mismos bits desde cualquiera). En cada paso se lee la cara del cuadro de la cámara que se dibuja ahí: el del instante de la fuente menos `camera.syncOffset`, con la cara de la última muestra en o antes de ese instante dentro de su segmento; no hay ninguna antes de la primera muestra de un segmento, entre dos segmentos, en un segmento sin su archivo (o de otro algoritmo, o con un `frameSize` que no son dos números positivos) ni en un clip de otra toma. El objetivo es el centro de la cara subido un 10 % de su alto; una cara lo mueve solo si está a un 6 % o más del ancho del recorte de la forma cuadrada a ese zoom (`min(ancho, alto) / zoom` píxeles del cuadro, uno solo para todas las disposiciones), en distancia euclídea en píxeles, y entonces el objetivo pasa a ser el de esa cara; sin cara, el tiempo que sea, se queda donde está. El centro lo sigue con un resorte por eje críticamente amortiguado de respuesta 1,2 s (`damping` 1, `response` 1,2, la integración de `StepGrid.spring`) y arranca quieto en el objetivo de la primera cara que muestra la salida. Sin ninguna cara en la salida (también mientras la caché no está), no hay camino y la cámara se encuadra al medio, como Centrado al mismo zoom.
- **El recorte de la cámara** (`CameraFramingGeometry.crop`, decisión 2 del plan 2b): la parte del cuadro que llena la forma sin estirar (la de la fase 1), dividida por `camera.framing.zoom` (de 1 a 2,5; 1 si no es un número), centrada en el centro (el de la cara, el de `camera.framing.center` en Manual o el medio en Centrado) y corrida para no salirse del cuadro, en fracciones del cuadro. Centrado a 1× da los mismos números que el llenado de la fase 1.
- **`reframe-1`, Seguir el cursor** (diseño de la fase 2, §6.5; decisión 9 del plan 2b; `ReframePath`). Se ofrece cuando la proporción del contenido (`StagePoints.contentRatio`) es al menos 1,3 veces la de la salida (`ReframePath.isOffered`; nunca con `auto`). Con `style.reframe` `followCursor`, una vista de la pantalla cuya región es más ancha que el lugar dentro del margen (`StagePoints.room`, `isReframed`) llena todo el lugar con una ventana de la región de todo su alto y `w = aspecto del lugar / aspecto de la región` de su ancho; una vista no más ancha que el lugar (una ventana vertical) se dibuja entera, como con `fit`. Con `followCursor` nunca se dibuja el marco de ventana ni el de dispositivo. El centro horizontal de la ventana, en fracciones de la región, se simula en tiempo de salida en la grilla de 600 Hz, con un punto de control cada 600 pasos (los mismos bits desde cualquiera): en cada paso se lee la vista que se muestra (solo donde puede cambiar: el inicio de cada clip y, en un clip de la toma, los cambios de pantalla y los eventos de geometría) y, si está reencuadrada y en pantalla, el cursor suavizado de `CursorPath` en ese paso, en fracciones de la región; fuera de la región no mueve nada. Mientras el cursor está a menos de `0,25 w` del objetivo, el objetivo se queda; si no, pasa adonde deja al cursor en el borde de esa zona, y se sostiene en `[w/2, 1 − w/2]`. El centro lo sigue con un resorte críticamente amortiguado de respuesta 0,9 s (`damping` 1, `response` 0,9, `StepGrid.spring`), que en un corte, el borde de un clip o un cambio de pantalla sigue como los de la cámara del zoom; arranca quieto en el primer cursor que la salida muestra en una vista reencuadrada (sostenido en `[w/2, 1 − w/2]`) y está ahí en cada paso antes; sin cursor, en 0,5. La parte que se dibuja (`ReframePath.part`) es `x = c − w/2` corrida para quedar en `[0, 1 − w]`, `y = 0`, `w` de ancho y todo el alto. El zoom actúa dentro de la pantalla reencuadrada: su rectángulo es el lugar, un foco fijo es un punto del lugar y el cursor que sigue un bloque es el de la ventana en ese paso (`StagePoints.stagePoint(global:at:part:)`, ninguno afuera de ella); en Pantalla dividida, el zoom de la tarjeta está en fracciones de la ventana. Con `followCursor`, el zoom automático hace todos sus bloques `follow`. Cambiar `style.reframe` rehace todos los caminos del movimiento.
- **Seguir el cursor en el dibujo** (`reframe-1`, decisión 17 del plan 2b; `FrameEvaluator`). Una vista reencuadrada se dibuja en todo el lugar dentro del margen, con su recorte y su región cortados a la ventana de ese instante de salida (`ReframePath.part`): `ScreenLayer.crop` es lo que se dibuja (el `layerCrop` de la privacidad, cuyo `contentCrop` sigue siendo el de la vista), así los rectángulos de privacidad, el cursor y los efectos de clic quedan sobre el mismo contenido mientras la ventana se mueve, y fuera de ella el cursor y los efectos de clic no se dibujan. Mientras un cambio de forma mueve el rectángulo (`geometryTransition` `spring`), se muestra la parte de la forma del rectángulo centrada en el centro de la ventana (corrida para quedar en la región), que es la ventana al llegar: nada salta. Una vista no más ancha que el lugar se dibuja entera, como con `fit` y sin marco; nunca hay marco de ventana ni de dispositivo. El movimiento de la ventana no lleva desenfoque de movimiento: el contenido de un cuadro es el de su instante y las submuestras del cursor se colocan en esa ventana.

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

**Migración desde el documento 2.** Una función pura sobre el JSON: escribe (encima de lo que hubiera) los valores de la columna «Legado» de la tabla en `/captions`, `/keys`, `/privacy`, `/style/reframe`, `/camera/background`, `/camera/framing`, `/camera/look`, `/camera/syncOffset` y `/audio/normalize`, y `cleanup = 0` en cada pista de `/audio/tracks`, y pone `documentVersion` en 3. Nada más cambia: con esos valores, el render y la mezcla son los de la fase 1 byte a byte (`make golden-2`). Un documento sin `style`, `camera`, `audio` o `audio.tracks` (o con una pista que no es un objeto) no migra: es inválido. Tampoco uno 2 con lo que solo el 3 puede tener, una `transcript` o un `style.frame` `device` (hecho a mano): está dañado, no es un documento 3, y `reverted` lo rechaza igual. Un documento 1 migra a 2 y después a 3.

- **Una tabla, un algoritmo.** Cada migración es una fila de una tabla (`DocumentMigration.addedPlaces`: por versión de origen, los lugares que agrega como punteros JSON, `*` = cada miembro de ese objeto o cada elemento de ese arreglo, con sus valores congelados en el código, nunca tomados de los valores por defecto de los tipos). Con la misma tabla se migra (`migrate`), se vuelve atrás (`reverted`), se llevan los cambios de antes a través de la migración (`carried`) y se decide qué conmuta con ella (`touchesAddedFields`). Las dos migraciones, 1 → 2 y 2 → 3, son aditivas.
- **Volver atrás, de a una versión.** `reverted(_:to: 2)` saca los lugares agregados si cada uno tiene su valor legado y pone `documentVersion` en 2; a 1 sigue bajando (3 → 2 → 1). Un documento que usa la fase 2 no tiene versión 2: da `nil` si algún lugar agregado tiene otro valor o falta, si tiene `transcript` o si `style.frame` es `device`. Un caso nuevo de un tipo que ya estaba en el documento 2 (como los formatos nuevos de `aspect`, diseño de la fase 2 §6.4) se suma a esa lista de valores que el 2 no puede tener.
- **Los cambios de antes, llevados a través de la migración.** Una línea de la versión vieja que escribe entero un objeto que contiene un lugar agregado no conmuta tal cual con la migración: la fase 1 escribe así el volumen y el silencio de una pista (`/audio/tracks/<clave>`, su `TrackGain` entero, o `/audio/tracks` entero para una pista sin entrada) y «Aplicar el estilo por defecto» o «Aplicar un estilo» (`/style` entero); a mano, `/camera` o `/audio` enteros. Cuando la reproducción, las pilas de deshacer, la compactación o el editor la usan después del `migrate`, la llevan a través de la migración con la misma tabla (`DocumentMigration.carried`): para un cambio en un camino P que es prefijo de un lugar agregado P + S, sus valores (`before` y `after` de un `set` o un `replace`, `value` de un `insert` o un `remove`, en el elemento de la colección) ganan S con su valor congelado (`cleanup = 0` en el `TrackGain`, `reframe = "fit"` en el `style`); un valor `null` (un miembro que no está) sigue `null`. Así deshacer o rehacer después de la primera edición en la fase 2 llega a los pasos de la fase 1, y la compactación pone esos grupos después de los `migrate`, ya llevados. Vale igual para 1 → 2 (una línea de 1b que escribe `/camera` entera). Nunca hace falta el camino inverso: un documento nunca «desmigra» y un cambio nunca se aplica a una versión más vieja que la que lo escribió.
- **Qué no conmuta con 2 → 3.** `touchesAddedFields(_:from: 2)` es verdadero para lo que no se puede llevar: la raíz, `/documentVersion`, un lugar agregado o algo debajo de uno (`/captions/show`, `/style/reframe`, `/camera/look/intensity`, `/audio/tracks/<clave>/cleanup`, un `insert` en `/privacy/blocks`…), y un valor en el que la migración no puede escribir (no es un objeto en el camino, o ya tiene el lugar con otro valor). Ninguna acción de la fase 1 escribe algo así; con una línea así antes del `migrate`, hecha a mano, ese `migrate` corta la historia y el registro no se compacta, como en 1b.
- **Antes de la primera edición, en el disco sigue en su versión.** Un proyecto de 1b (documento 1) o de 1c (documento 2) que en la fase 2 solo se abre, se reproduce o se exporta no cambia, y la app de la fase 1 lo sigue abriendo. Una toma de formato 3 que ningún editor abrió (grabada en la fase 1, o en la fase 2 sin nada que solo el documento 3 tenga) escribe al abrirse su documento nuevo, el `create` y la instantánea, en la versión más vieja que lo contiene y nunca debajo de 2 (`DocumentMigration.oldestVersion`): en la práctica el 2, así la app de la fase 1 la abre hasta la primera edición, que la migra como a cualquier proyecto de la fase 1 (`aTakeNeverEditedStaysOfVersion2UntilItsFirstEdit`). Hasta la primera edición, la instantánea al cerrar, la compactación y la reparación del registro se escriben en la versión del disco (`openingAVersion2ProjectWritesNothing`, `openingAVersion1ProjectWritesNothing`). La primera edición agrega en **una sola escritura** el `migrate` de cada versión que falta y el paso: `{"from":2,"seq":N,"to":3,"type":"migrate"}` y el `do` en un proyecto de 1c; `1 → 2`, `2 → 3` y el `do` en uno de 1b. Un registro que termina en uno o más `migrate` sin nada después es esa escritura cortada: al leer se truncan y el proyecto abre como antes de la edición (`cutAtEveryByteOfTheFirstEditOpensBeforeOrAfterTo3`, `diskFullOnTheFirstEditTo3NeverLeavesMigrateAlone`).

### El registro con el documento 3

- **Un `set` agrega y saca un miembro opcional.** Un miembro que no está se lee como `null`: un `set` con `before: null` sobre un miembro de un objeto que existe lo agrega, y uno con `after: null` lo saca. Así van y vienen `transcript`, `lut` y `breakBefore`, y su inversa los deshace; el documento nunca tiene un `null`. Un `before` distinto de `null` sobre un miembro que no está es un `mismatch`; sacar un miembro obligatorio, o agregar uno que el documento no tiene, deja un documento inválido y se rechaza. Solo vale para miembros de un objeto: nunca para un elemento de un arreglo, que se agrega y se saca con `insert` y `remove`.
- **Las colecciones.** `/privacy/blocks` admite `insert`, `remove` y `replace` (por `id`), como `/zoom/regions`. `/transcript/takes` existe solo con una transcripción y admite `insert` y `remove` (sus elementos no tienen `id`); una palabra se corrige con un `set` por puntero (`/transcript/takes/<i>/words/<j>/text`).
- **Las etiquetas** (`label`) nuevas son veinticinco, después de las de la fase 1: `transcript.create`, `transcript.cut`, `transcript.restore`, `transcript.word`, `transcript.break`, `transcript.fillers`, `transcript.pauses`, `captions.show`, `captions.style`, `camera.hideSilences`, `camera.background`, `camera.framing`, `camera.look`, `camera.sync`, `audio.cleanup`, `audio.normalize`, `style.reframe`, `privacy.add`, `privacy.change`, `privacy.move`, `privacy.trim`, `privacy.delete`, `privacy.auto`, `keys.overlay` y `speed.typing`.

### El orden de dibujo con el documento 3

Un cuadro se dibuja en este orden (diseño de la fase 2, §11); lo nuevo, en negrita:

1. El fondo, la sombra y el marco de ventana **o de dispositivo** (`style.frame` `device`, después del de ventana).
2. La pantalla a través del zoom **y del reencuadre** (`style.reframe`), con **los desenfoques de privacidad** (`privacy.blocks`) en su shader.
3. El cursor y los efectos de clic.
4. La cámara, con **el recorte de su encuadre** (`camera.framing`), **su color** (`camera.look`), **su fondo** y **su máscara** (`camera.background`), tomada en **`t − syncOffset`** (`camera.syncOffset`).
5. **Las teclas en pantalla** (`keys`).
6. **Los subtítulos** (`captions`, sobre la transcripción).

Es el mismo orden en los dos caminos de la fase 1 (el de 1b y el de los layouts) y en cada forma de dibujar un cuadro: directo, con el desenfoque de movimiento del zoom o del cursor, con el zoom dentro de la tarjeta y con la cámara a pantalla completa asentada (ahí, la cámara y encima las teclas y los subtítulos). El render y la mezcla nunca llaman a Vision, Speech ni a un Audio Unit: leen lo que guardan las cachés de análisis, que les llega como `AnalysisInputs` (vacío en la fase 1).

**Con los valores legados, cada capa nueva vale `nil` o vacía y no cambia ninguna llamada**: sin marco de dispositivo, sin regiones de privacidad, con la cámara entera, natural, con su fondo original y en el mismo instante, sin teclas y sin subtítulos, el compositor hace las mismas llamadas, en el mismo orden y con los mismos uniforms que la fase 1, y el shader es el de la fase 1. Un documento 1 o 2 migrado se dibuja byte por byte como antes (la dorada 2, `make golden-2`).

### Las cachés de análisis

Lo que calcula el análisis de la fase 2 (diseño de la fase 2, §10) va a la carpeta de cachés del proyecto, fuera del paquete, junto a `thumbnails/` y `waveforms/`: `~/Library/Caches/dev.toma.Toma/Projects/<projectID>/`. Como el resto de esa carpeta, se puede borrar entera o en parte: lo que falta se vuelve a calcular (y el export espera a que esté), y nada de lo que hay en el paquete depende de ella. La transcripción no es una caché: va al documento (`transcript`).

| Carpeta | Qué guarda | Nombre |
|---|---|---|
| `masks/` | La máscara de la persona de cada segmento de la cámara | `<take>/<track>/<segmento>-personMask-1.mov` |
| `faces/` | La cara de cada segmento de la cámara | `<take>/<track>/<segmento>-faceTrack-1.json` |
| `clean/` | El sonido sin ruido de cada segmento del micrófono | `<take>/<track>/<segmento>-soundIsolation-2.caf` |
| `loudness/` | La sonoridad de cada segmento de una pista de audio | `<take>/<track>/<segmento>-loudness-1.json` |
| `scan/` | Los datos sensibles encontrados en la pantalla de una toma | `<take>-sensitiveScan-1.json` |

- **`<segmento>` es la identidad del archivo fuente** (`SegmentIdentity`): la raíz de su nombre, su tamaño en bytes y su fecha de modificación en nanosegundos desde 1970, leídos con `lstat` (un enlace no se sigue: un segmento que es un enlace no tiene identidad ni caché). Por ejemplo `masks/take-001/camera/seg-0001-48213377-1763561234123456789-personMask-1.mov`. Un segmento que se reescribe (la recuperación que lo cierra, una copia que no conservó la fecha) cambia de nombre y se vuelve a analizar; nada compara contenidos. El último guion separa el id del algoritmo, que lleva su versión: un algoritmo nuevo es otro archivo, nunca uno reescrito.
- **Nombres que no salen de la carpeta.** El `take`, el `track` y el nombre del archivo tienen que ser cada uno un solo nombre (no vacío, ni `.` ni `..`, sin `/` ni NUL); si no, no hay archivo (`ProjectCaches.analysisFile` y `scanFile` dan `nil`).
- **Enteras o ausentes.** Cada archivo se escribe entero en un temporal oculto de la misma carpeta (`.<nombre>.<UUID>.tmp.<extensión>`, con la extensión al final para los escritores que se guían por ella), con sus bytes ordenados antes del `rename(2)` que lo pone en su nombre (`F_BARRIERFSYNC`): un lector ve el archivo anterior o el nuevo entero, nunca una parte, y tras un corte de luz el nombre tiene los bytes enteros o no existe. Si macOS vació la carpeta, se vuelve a crear. Un temporal que dejó un crash nadie lo lee, y se va con la carpeta del proyecto. Se leen sin seguir enlaces (`SafeRead`).
- **La cola** (`ProjectJobs`, un actor por proyecto abierto en el editor) corre los trabajos que las escriben de a uno, con QoS `utility`, y los frena mientras se graba: el que corría vuelve a empezar al terminar la toma y encuentra lo que ya había escrito.
- **`faceTrack-1`, el JSON de `faces/`** (`CameraFaceTrack`, escrito entero con `ProjectJSON.encoder()`): `{"algorithm": "faceTrack-1", "frameSize": [ancho, alto], "samples": [{"face": {"height", "width", "x", "y"}, "t": …}, …]}`, con las claves en orden. `frameSize` es el cuadro de la cámara en píxeles; cada muestra, una cada 100 ms de la fuente del segmento y en orden de tiempo, lleva su instante `t` (`HostTime`, entero de ns) y la cara más grande del cuadro en fracciones de él, con el origen arriba a la izquierda e `y` hacia abajo; sin cara, `face` se omite (nunca es `null`). Llega al render en `AnalysisInputs.faceTracks`, por segmento (`CameraSegment`: la toma, la pista de cámara y el `index` del segmento), como las máscaras en `AnalysisInputs.personMasks`.
  Lo calcula `FaceTrackEngine` con `VNDetectFaceRectanglesRequest` (revisión 3) sobre el primer cuadro presentado en o después de cada 100 ms desde el inicio del segmento (el tiempo 0 de su archivo: el primer cuadro, después el primero en o después de 100 ms, y así; donde los cuadros están más separados, un cuadro es una muestra). `t` es el inicio del segmento más el tiempo de presentación del cuadro, donde el render lo pone. La cara es la de mayor área entre las que encuentra Vision, cada una recortada al cuadro.
- **`personMask-1`, el video de `masks/`** (`PersonMaskEngine`, decisión 4 del plan 2b): la máscara de la persona de cada cuadro del segmento de cámara, de `VNGeneratePersonSegmentationRequest` (revisión 1, calidad `balanced`, 8 bits), con un `VNSequenceRequestHandler` y un mismo pedido para todos los cuadros del segmento, en orden. Es una película QuickTime HEVC Main (8 bits) con el gris de la máscara en R = G = B (255 la persona, 0 el resto), que el codificador pasa a 4:2:0 (BT.709), un cuadro clave por segundo, al tamaño de la primera máscara de Vision redondeado a pares (cada lado `round(n / 2) × 2`; una máscara de otro tamaño se escala bilineal a ese). Cada cuadro de la máscara tiene el tiempo de presentación de su cuadro de cámara en el archivo del segmento, la sesión empieza en 0 como la de la cámara y termina donde termina su pista: la máscara del cuadro de cámara que se ve en un instante es el cuadro de la máscara que se ve en ese instante. El render la lee como la cámara (`TrackFrameReader`, en BGRA) y usa su canal R. Se calcula leyendo de a un cuadro, en una cola propia de QoS `utility`, sin tener nunca más de un cuadro en memoria. Las dos cachés se piden por segmento presente de la pista de cámara que dibuja la burbuja (la primera pista de cámara con un segmento; ninguna con la cámara oculta): las máscaras con `camera.background` distinto de `original`, las caras con `camera.framing.mode` `face`. Sin la máscara de un segmento, ese segmento se dibuja Original; el export espera a que estén las dos, salvo lo que esta Mac no puede hacer (Vision no disponible) o un segmento que no se puede leer, que se dibujan como en la vista previa.
- **La búsqueda de datos sensibles** (`scan/<take>-sensitiveScan-1.json`, `ScanResult`) es un JSON por toma, con las claves ordenadas: `algorithm` (`sensitiveScan-1`), `findings`, `samples`, `segments`, `take` y `version` (1). Cada hallazgo guarda su tipo (`kind`: `email`, `phone`, `card`, `secret`, `token` o `face`), el texto **enmascarado** (`masked`: `an•••@g•••.com`, `•••• 4242`, `sk-•••`; vacío para una cara), la toma, su tramo de fuente `[start, end)` y sus claves (`keys`, rectángulos en fracciones del contenido de la pantalla, como los de un bloque de privacidad). **El texto encontrado nunca se escribe**: vive solo en memoria mientras corre la búsqueda. Como su nombre no lleva la identidad de un segmento, el archivo dice de qué salió: `segments` es la identidad de cada segmento de las pistas de pantalla de la toma al empezar, `<track>/<segmento>` en el orden del manifiesto (`<track>/<raíz del nombre>` para uno sin identidad: sin archivo o un enlace), y `samples` es el SHA-256 en hex de los cuadros que miró (el instante, la pista y el recorte de cada muestra), que el documento decide al elegir qué pantalla se ve y cuándo. Vale mientras el algoritmo, la versión, la toma, `segments` y `samples` son los de ahora; si no, se busca de nuevo y se reescribe entero. Un segmento que está en el paquete pero no se puede decodificar hace fallar la búsqueda (`sourceUnreadable`) sin escribir nada; uno vacío, ausente o que la recuperación marcó ilegible no, porque la salida muestra ahí el cuadro anterior, que es el que se mira.
- **`soundIsolation-2`, el CAF de `clean/`** (`SoundIsolation`, diseño de la fase 2, §5.6; decisión 14 del plan 2a). La voz sin ruido de un segmento de un micrófono: CAF de Float32 LPCM, mono, a 48 kHz, con exactamente los cuadros de la línea de tiempo de la mezcla en los que se oye ese segmento (`TrackAudio.spans`: el cuadro `i` del archivo es el cuadro `inicio + i` de la toma, con la latencia del AU compensada). Un archivo de otro largo, de otro formato o que no es un archivo común (un enlace no se sigue) es viejo: no se usa y se vuelve a hacer. Una pista se mezcla limpia solo cuando todos los segmentos que se oyen tienen su archivo (`AnalysisInputs.cleanVoice`); mientras, seca. Si macOS lo borra mientras suena, la pista sigue seca desde ahí.
- **`loudness-1`, el JSON de `loudness/`** (`SegmentLoudness`, escrito entero con `ProjectJSON.encoder()`; §5.7, decisión 15). La sonoridad de un segmento de una pista de audio: `{"algorithm": "loudness-1", "channels": n, "clean": "<bytes>-<fecha en ns>", "cross": […], "dry": […], "wet": […]}`, con las claves en orden. `dry` es la energía ponderada K (BS.1770-4) de cada bloque de 400 ms, uno cada 100 ms desde el primer cuadro del segmento (solo bloques enteros), del sonido tal como se grabó, sumada sobre sus `channels` (1 o 2); `wet`, la de la voz limpia (mono), y `cross`, la suma sobre los canales de la voz limpia por la seca; estos dos y `clean` (el tamaño y la fecha, por `lstat`, del CAF de `clean/` medido) solo si estaba ese archivo, y si no se omiten (nunca `null`). Una medida de otro algoritmo, de otros canales que la pista, de otra cantidad de bloques que su tramo o, con limpieza, sin `wet` o de otro CAF que el que está, es vieja y se vuelve a medir. La pista entera es la unión de los bloques de sus segmentos (`AnalysisInputs.loudness`); sin todos, la vista previa suena sin normalizar.
- **Se pueden borrar y se regeneran.** Los trabajos de voz (`VoiceJobs`: la limpieza por segmento, `soundIsolation`, y la sonoridad por pista, `loudness`) piden lo que falta o está viejo, y el export espera a que esté: si falta el aislamiento de voz en esta Mac (un proyecto limpiado en otra), exporta seco y lo dice.

**`auto` («Como la grabación»).** El `aspect` `auto` usa la proporción del contenido: la región de la pantalla de `screens.initial` (con el recorte de Área) en el inicio de su primer segmento, ancho sobre alto. A menos del 1 % de 16:9, es 16:9; sin pantalla o sin región, también. Los cambios posteriores de ventana o de pantalla no la mueven. Los siete formatos (`16:9`, `9:16`, `1:1`, `4:5`, `4:3`, `3:4` y `auto`) están en la barra y en Proyecto ▸ Formato.

### El marco de dispositivo (`deviceFrame-1`)

`style.frame` `{"type":"device","model":…,"finish":…}` dibuja un iPhone, un iPad o una MacBook alrededor de la pantalla, con vectores propios (distancias con signo a rectángulos redondeados, con el borde antialiasado como las esquinas de la pantalla; sin imágenes ni arte de Apple). Las medidas son fracciones de la pantalla de adentro (`DeviceMeasures`, `StageLayout.deviceRects(around:model:)`), y quedan congeladas:

| | iPhone (`w` y `h`: su ancho y su alto, el lado corto y el largo de la pantalla) | iPad (`s`: el lado corto de la pantalla) | MacBook (`w`: el ancho de la pantalla) |
|---|---|---|---|
| Bisel | negro, `0,045 w` | negro, `0,05 s` | `#0A0A0A`, `0,02 w` a los lados y abajo, `0,035 w` arriba |
| Banda o canto (afuera del bisel) | `0,012 w`, `#2C2C2E` (oscuro) o `#D9D9DE` (claro) | `0,01 s`, los colores del iPhone | canto de la tapa de `0,004 w`, `#2E2F33` o `#D7D8DC` |
| Esquinas del cuerpo | `0,16 ×` el ancho del cuerpo | `0,06 ×` el lado corto del cuerpo | tapa: `0,02 w` arriba, `0,004 w` abajo |
| Esquinas de la pantalla | concéntricas: las del cuerpo menos bisel y banda | concéntricas | cuadradas |
| Sobre la pantalla | la isla, una cápsula de `0,30 w × 0,034 h`, centrada, a `0,018 h` del borde de arriba | — | el notch de `0,11 w × 0,025 w`, centrado arriba, con las esquinas de abajo de `0,28 ×` su alto y esquinas cóncavas de `0,18 ×` su alto donde toca el borde de la pantalla |
| Afuera del cuerpo | botones de `0,008 w` de ancho desde el borde de arriba del cuerpo: a la izquierda en `0,13 h` (`0,04 h` de largo), `0,20 h` y `0,29 h` (`0,07 h`); a la derecha en `0,24 h` (`0,11 h`) | — | la base debajo de la tapa: `1,12 ×` su ancho y `0,035 ×` su alto, centrada, del color de la tapa, con el frente redondeado por la mitad de su alto y una muesca (media elipse) de `0,16 ×` su ancho por `0,35 ×` su alto en el medio de su borde de arriba, del color de la base `× 0,8` |

- **Se adapta a la proporción del contenido.** La pantalla del dispositivo tiene la proporción de la región que muestra la pantalla de la toma; el dispositivo es el más grande cuyos límites (el cuerpo, los botones y la base) entran en el margen del estilo, centrado (`StageLayout.deviceRects(contentAspect:padding:outputSize:model:)`). Un iPhone con un contenido más ancho que alto está acostado, con su parte de arriba a la izquierda: la isla a la izquierda, los botones de la izquierda abajo y el de la derecha arriba.
- **El orden.** El cuerpo se dibuja con el fondo, la sombra y el marco de ventana (paso 1, después del de ventana), opaco también debajo de la pantalla, así el borde antialiasado de la pantalla cae sobre el bisel y no se ve el fondo entre los dos. La isla o el notch, después del escenario, una vez y sin el desenfoque de movimiento, sobre el cursor y debajo de los efectos de clic.
- **La sombra del estilo** la proyecta el cuerpo, con sus esquinas (en la MacBook, la tapa); la base de la MacBook proyecta la misma, debajo de ella.
- **El zoom** se queda dentro de los límites del dispositivo, como dentro de una ventana, y lo mueve junto con la pantalla. En las disposiciones de tarjetas (Pantalla dividida), el dispositivo entero entra en la tarjeta de la pantalla; en Solo cámara no se ve. **Con Seguir el cursor** (`style.reframe` `followCursor`) no hay marco: la pantalla está recortada.
- **El acabado (oscuro o claro) solo se dibuja**: cambiarlo no rehace los caminos del movimiento; cambiar el modelo, sí.

## Cambios del documento 4

Desde la fase 3, el documento de edición es la versión 4 (`EditDocument.currentVersion`): una sola versión nueva con todos los campos de la fase 3 (diseño de la fase 3, §10), así las capas, el zoom tranquilo, el audio y las tomas trabajan sobre los mismos tipos y hay una sola migración. Suma las anotaciones, la música, los marcadores, los clips con contenido (cuadro congelado, placa de título y clip importado), el corte del audio de cada clip, el modo del zoom con su lupa y el volumen por tramo de cada pista. La versión del documento no cambia la del paquete; un lector del documento 4 lee los documentos 1, 2 y 3 migrándolos y rechaza el 5 o uno más nuevo (`newerVersion`), esté en `edit.json` o en el `create` del registro.

| Lugar | Qué es | Legado (lo que escribe la migración) |
|---|---|---|
| `annotations` | `items[]`, cada anotación con `id` (`a-` y 8 hex al azar), `anchor`, `layer` (entero; más alto, más arriba, dentro de las pegadas a la grabación y dentro de las de la salida), `kind`, `rect` (`{x, y, width, height}`: anclada a la toma, en fracciones del rectángulo del contenido del escenario; si no, del cuadro de salida), `rotation` (grados; 0), `opacity` (0 a 1; 1), `enter` (`none`, `fade`, `pop`, `draw`; `fade`) y `exit` (`none`, `fade`; `fade`) | `{"items": []}` |
| `annotations.items[].anchor` | Plano con su `type`: `content` con `take`, `start` y `end` (`HostTime` de la fuente: pegada a la grabación), `output` con `start` y `end` (ns de salida: fija en la salida) o `whole` (todo el video) | — |
| `annotations.items[].kind` | Plano: los campos de su valor junto a `type`. `text`: `string`, `preset` (`plain`, `label`, `lowerThird`, `title`), `font` (`system`, `rounded`, `serif`, `mono`; `system`), `weight` (`regular`, `semibold`, `bold`, `heavy`; `semibold`), `size` (fracción del alto de su espacio; 0,05), `color` (RGBA; blanco), `fill` (RGBA, opcional; negro al 70 % en `label` y `lowerThird`, ninguno en los otros) y `align` (`leading`, `center`, `trailing`; `center`). `arrow`: `from` y `to` (`{x, y}`, en el espacio de su anclaje; el `rect` sale de los extremos), `curve` (−1 a 1; 0), `color` (#FF453A), `width` (0,006) y `head` (`filled`, `open`, `none`). `shape`: `shape` (`rect`, `roundedRect`, `ellipse`), `stroke` (#FF453A), `width` (0,004) y `fill` opcional. `callout`: `text` (un texto como el de `text`, sin `type`) y `target` (`{x, y}`). `step`: `color` (#FF453A; el número sale del orden en la secuencia). `image`: `asset`, `fit` (`fit`, `fill`), `corner` (0) y `shadow` (`false`). `clip`: `asset`, `start` y `end` (ns del archivo), `volume` (dB; 0), `muted` (`false`), `corner` (0) y `shadow` (`false`); solo con anclaje `output` o `whole` | — |
| `music` | `items[]`, cada tema con `id` (`mu-` y 8 hex), `source` (`library:music-1/<id>` o su camino `assets/…`), `start` y `end` (ns de salida), `offset` (ns dentro del tema; 0), `gain` (dB; −14), `fadeIn` (ns; 1 s), `fadeOut` (ns; 2 s) y `loop` (`true`); y `ducking`: `enabled`, `amount` (dB), `attack` y `release` (s) | `{"ducking": {"amount": -12, "attack": 0.3, "enabled": true, "release": 0.8}, "items": []}` |
| `markers` | `items[]`, cada marcador con `id` (`m-` y 8 hex), `take`, `t` (`HostTime`), `name` (`""`), `origin` (`recorded`, `added`) y `hidden` (`false`). Un marcador grabado sin entrada se muestra sin nombre; nombrarlo, moverlo o esconderlo agrega su entrada con `origin` `recorded` y el mismo `take` y `t` | `{"items": []}` |
| `sequence[].content` | Opcional: lo que muestra el clip en lugar de un tramo de su toma, plano con su `type`: `freeze` con `duration`, `card` con `card` y `duration`, o `media` con `media`. Con contenido, `start == end`: el punto de la toma donde está. `duration` en ns de salida (2 s un cuadro congelado nuevo, 3 s una placa nueva; de 0,1 a 60 s). La placa: `title`, `subtitle` (`""`), `style` (`centered`, `leading`, `large`, `minimal`), `background` (plano: `stage`, `color` con `color`, o `blurredFrame`) y `textColor` (blanco). El clip importado: `asset` (`assets/<32 hex>.<mov\|mp4\|m4v>`), `start` y `end` (ns del archivo), `speed` (1) y `volume` (dB; 0) | Ausente: un tramo de la toma |
| `sequence[].audioShift` | Dónde corta el audio contra la imagen al empezar el clip, en ns de salida con signo: negativo antes (corte J, el clip se oye antes de verse), positivo después (corte L, se sigue oyendo el de antes) | `0`, en cada clip |
| `zoom.auto.mode` | El modo de los bloques automáticos sin uno propio: `classic`, `highlight`, `dim` o `loupe` | `classic` |
| `zoom.regions[].mode` | Opcional: el modo del bloque; sin él, `classic` en uno manual y `zoom.auto.mode` en uno automático | Ausente |
| `zoom.regions[].loupe` | Opcional: la lente del bloque en `loupe`, `radius` (fracción del lado corto de la salida, de 0,06 a 0,4) y `shape` (`circle`, `roundedRect`); sin ella, 0,16 y `circle` | Ausente |
| `audio.tracks.<toma>/<pista>.ranges` | Los tramos de la pista a otro volumen, anclados a la fuente: `id` (`g-` y 8 hex), `take`, `start` y `end` (`HostTime`) y `gain` (dB; −120 es −∞) | `[]`, en cada pista |

- **Las formas planas** (decisión 2 del plan de la base de la fase 3), en el JSON compacto del registro: `{"duration":2000000000,"type":"freeze"}`, `{"card":{…},"duration":3000000000,"type":"card"}`, `{"media":{…},"type":"media"}`; `{"type":"stage"}`, `{"color":[0,0.5,1,1],"type":"color"}`, `{"type":"blurredFrame"}`; `{"end":9,"start":5,"take":"take-001","type":"content"}`, `{"end":9,"start":5,"type":"output"}`, `{"type":"whole"}`; `{"color":[1,1,1,1],"type":"step"}`, `{"target":{"x":0.5,"y":0.25},"text":{…},"type":"callout"}`. Ninguno de los valores de una anotación tiene un campo `type`.
- **Lo que se omite.** `content` en un clip que es un tramo de la toma, `mode` y `loupe` en un bloque sin ellos y `fill` en un texto o una forma sin fondo: nunca se escriben como `null`. Todo lo demás se escribe siempre, como los campos de los documentos 2 y 3. Un `zoom.auto` sin `mode` se lee como `classic`, porque así lo guardan las fases 1 y 2 en sus estilos (`default-style.json` y el `style.json` de un `.tomastyle`); en un documento 4 siempre está, y un cambio que lo saca se rechaza.
- **El modo y la lente de un bloque de zoom** (`ZoomRegion+Mode.swift`). El modo es `mode ?? (origin == auto ? zoom.auto.mode : classic)`; un bloque del usuario guarda `classic` como `mode` ausente. La lente es `loupe ?? {radius: 0,16, shape: circle}`, con el radio leído entre 0,06 y 0,4 (0,16 si no es un número); una lente igual a la de por defecto no se escribe. Un bloque hecho a mano nace con el `zoom.auto.mode` del momento (ausente si es `classic`). Tocar un bloque automático (recortarlo, moverlo, cambiarle la profundidad, el foco, la animación, el modo o la lente) lo hace del usuario **con su modo de ese momento escrito**, así nunca cambia de modo al cambiar de dueño; cambiar `zoom.auto.mode` no toca ningún bloque.
- **Un valor desconocido hace inválido el documento** (un `type` de contenido, de fondo, de anclaje o de anotación, un `mode`, un `preset`, una `font`… que no son estos): está dañado, no es más nuevo. Lo mismo la falta de un campo obligatorio (`audioShift`, `ranges`, `annotations`…).
- **#FF453A** es `[1, 0.27058823529411763, 0.22745098039215686, 1]` (`RGBA.annotationRed`).

El ejemplo del documento 3 de arriba con todos los campos de la fase 3 lejos de su valor legado (después del primer clip, el segundo con su audio 120 ms antes; al final de ese, un cuadro congelado de 2 s, una placa sobre un color y un clip importado a 1,5×; el segundo zoom con una lupa redondeada de 0,2 y los automáticos atenuando; el micrófono en silencio 2 s; una anotación de cada tipo: un tercio inferior con su fondo, una flecha curva, una forma con relleno, un globo, un paso, una imagen sobre todo el video y un clip sobre la salida; un tema de la biblioteca sin bajada; un marcador con nombre, escondido), como lo escribe `ProjectJSON.encoder()`; lo guarda `version4ExampleRoundTripsByteForByte`, que lo lee y lo vuelve a escribir byte por byte:

```json
{
  "annotations" : {
    "items" : [
      {
        "anchor" : {
          "end" : 81240000000000,
          "start" : 81236000000000,
          "take" : "take-001",
          "type" : "content"
        },
        "enter" : "fade",
        "exit" : "fade",
        "id" : "a-1a2b3c4d",
        "kind" : {
          "align" : "center",
          "color" : [
            1,
            1,
            1,
            1
          ],
          "fill" : [
            0,
            0,
            0,
            0.7
          ],
          "font" : "system",
          "preset" : "lowerThird",
          "size" : 0.05,
          "string" : "Ana Pérez",
          "type" : "text",
          "weight" : "semibold"
        },
        "layer" : 0,
        "opacity" : 1,
        "rect" : {
          "height" : 0.12,
          "width" : 0.4,
          "x" : 0.05,
          "y" : 0.78
        },
        "rotation" : 0
      },
      {
        "anchor" : {
          "end" : 81244000000000,
          "start" : 81241000000000,
          "take" : "take-001",
          "type" : "content"
        },
        "enter" : "draw",
        "exit" : "none",
        "id" : "a-2b3c4d5e",
        "kind" : {
          "color" : [
            1,
            0.27058823529411763,
            0.22745098039215686,
            1
          ],
          "curve" : 0.4,
          "from" : {
            "x" : 0.2,
            "y" : 0.3
          },
          "head" : "filled",
          "to" : {
            "x" : 0.45,
            "y" : 0.5
          },
          "type" : "arrow",
          "width" : 0.006
        },
        "layer" : 1,
        "opacity" : 1,
        "rect" : {
          "height" : 0.2,
          "width" : 0.25,
          "x" : 0.2,
          "y" : 0.3
        },
        "rotation" : 0
      },
      {
        "anchor" : {
          "end" : 8000000000,
          "start" : 5000000000,
          "type" : "output"
        },
        "enter" : "fade",
        "exit" : "fade",
        "id" : "a-3c4d5e6f",
        "kind" : {
          "fill" : [
            1,
            1,
            1,
            0.25
          ],
          "shape" : "roundedRect",
          "stroke" : [
            1,
            1,
            1,
            1
          ],
          "type" : "shape",
          "width" : 0.005
        },
        "layer" : 2,
        "opacity" : 0.9,
        "rect" : {
          "height" : 0.2,
          "width" : 0.3,
          "x" : 0.6,
          "y" : 0.1
        },
        "rotation" : 0
      },
      {
        "anchor" : {
          "end" : 81249000000000,
          "start" : 81246000000000,
          "take" : "take-001",
          "type" : "content"
        },
        "enter" : "pop",
        "exit" : "fade",
        "id" : "a-4d5e6f70",
        "kind" : {
          "target" : {
            "x" : 0.62,
            "y" : 0.41
          },
          "text" : {
            "align" : "leading",
            "color" : [
              0.1,
              0.1,
              0.1,
              1
            ],
            "fill" : [
              1,
              1,
              1,
              0.9
            ],
            "font" : "rounded",
            "preset" : "label",
            "size" : 0.04,
            "string" : "Acá",
            "weight" : "bold"
          },
          "type" : "callout"
        },
        "layer" : 3,
        "opacity" : 1,
        "rect" : {
          "height" : 0.08,
          "width" : 0.2,
          "x" : 0.5,
          "y" : 0.2
        },
        "rotation" : 0
      },
      {
        "anchor" : {
          "end" : 81249000000000,
          "start" : 81246000000000,
          "take" : "take-001",
          "type" : "content"
        },
        "enter" : "fade",
        "exit" : "fade",
        "id" : "a-5e6f7081",
        "kind" : {
          "color" : [
            1,
            0.27058823529411763,
            0.22745098039215686,
            1
          ],
          "type" : "step"
        },
        "layer" : 4,
        "opacity" : 1,
        "rect" : {
          "height" : 0.07,
          "width" : 0.04,
          "x" : 0.6,
          "y" : 0.38
        },
        "rotation" : 0
      },
      {
        "anchor" : {
          "type" : "whole"
        },
        "enter" : "fade",
        "exit" : "fade",
        "id" : "a-6f708192",
        "kind" : {
          "asset" : "assets/0f1e2d3c4b5a69788796a5b4c3d2e1f0.png",
          "corner" : 0.02,
          "fit" : "fit",
          "shadow" : true,
          "type" : "image"
        },
        "layer" : 0,
        "opacity" : 0.8,
        "rect" : {
          "height" : 0.1,
          "width" : 0.1,
          "x" : 0.85,
          "y" : 0.05
        },
        "rotation" : -5
      },
      {
        "anchor" : {
          "end" : 14000000000,
          "start" : 10000000000,
          "type" : "output"
        },
        "enter" : "fade",
        "exit" : "fade",
        "id" : "a-708192a3",
        "kind" : {
          "asset" : "assets/9a8b7c6d5e4f30211203f4e5d6c7b8a9.mov",
          "corner" : 0.03,
          "end" : 5000000000,
          "muted" : false,
          "shadow" : true,
          "start" : 1000000000,
          "type" : "clip",
          "volume" : -3
        },
        "layer" : 1,
        "opacity" : 1,
        "rect" : {
          "height" : 0.3,
          "width" : 0.3,
          "x" : 0.65,
          "y" : 0.6
        },
        "rotation" : 0
      }
    ]
  },
  "aspect" : "16:9",
  "audio" : {
    "limiter" : true,
    "normalize" : true,
    "tracks" : {
      "take-001/mic" : {
        "cleanup" : 0.6,
        "gain" : 1,
        "muted" : false,
        "ranges" : [
          {
            "end" : 81252000000000,
            "gain" : -120,
            "id" : "g-4b5c6d7e",
            "start" : 81250000000000,
            "take" : "take-001"
          }
        ]
      },
      "take-001/system-audio" : {
        "cleanup" : 0,
        "gain" : 0.8,
        "muted" : false,
        "ranges" : [

        ]
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
  "documentVersion" : 4,
  "frameRate" : 60,
  "keys" : {
    "mode" : "all",
    "position" : "top",
    "size" : "small"
  },
  "logSequence" : 128,
  "markers" : {
    "items" : [
      {
        "hidden" : true,
        "id" : "m-0a1b2c3d",
        "name" : "Demo",
        "origin" : "recorded",
        "t" : 81262000000000,
        "take" : "take-001"
      }
    ]
  },
  "music" : {
    "ducking" : {
      "amount" : -12,
      "attack" : 0.3,
      "enabled" : false,
      "release" : 0.8
    },
    "items" : [
      {
        "end" : 60000000000,
        "fadeIn" : 500000000,
        "fadeOut" : 3000000000,
        "gain" : -18,
        "id" : "mu-1f2e3d4c",
        "loop" : false,
        "offset" : 15000000000,
        "source" : "library:music-1/calma",
        "start" : 0
      }
    ]
  },
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
      "audioShift" : 0,
      "end" : 81276901234567,
      "id" : "c-00a1b2c3",
      "speed" : 1,
      "start" : 81234567890123,
      "take" : "take-001"
    },
    {
      "audioShift" : -120000000,
      "end" : 81334000000000,
      "id" : "c-00d4e5f6",
      "speed" : 2,
      "start" : 81277458000000,
      "take" : "take-001"
    },
    {
      "audioShift" : 0,
      "content" : {
        "duration" : 2000000000,
        "type" : "freeze"
      },
      "end" : 81334000000000,
      "id" : "c-00f0e1d2",
      "speed" : 1,
      "start" : 81334000000000,
      "take" : "take-001"
    },
    {
      "audioShift" : 0,
      "content" : {
        "card" : {
          "background" : {
            "color" : [
              0.1,
              0.1,
              0.12,
              1
            ],
            "type" : "color"
          },
          "style" : "large",
          "subtitle" : "Lo que sigue",
          "textColor" : [
            1,
            1,
            1,
            1
          ],
          "title" : "Capítulo 2"
        },
        "duration" : 3000000000,
        "type" : "card"
      },
      "end" : 81334000000000,
      "id" : "c-01a2b3c4",
      "speed" : 1,
      "start" : 81334000000000,
      "take" : "take-001"
    },
    {
      "audioShift" : 0,
      "content" : {
        "media" : {
          "asset" : "assets/1d2c3b4a59687766554433221100ffee.mp4",
          "end" : 4000000000,
          "speed" : 1.5,
          "start" : 0,
          "volume" : -6
        },
        "type" : "media"
      },
      "end" : 81334000000000,
      "id" : "c-02b3c4d5",
      "speed" : 1,
      "start" : 81334000000000,
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
      "mode" : "dim",
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
        "loupe" : {
          "radius" : 0.2,
          "shape" : "roundedRect"
        },
        "mode" : "loupe",
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

### La migración del documento 3 al 4

- **La migración 3 → 4 es aditiva**: una fila más de la tabla de `DocumentMigration` (`isAdditive(from: 3)`). Agrega, en este orden y con estos valores congelados (`addedPlaces[3]`): `/annotations` `{"items":[]}`, `/markers` `{"items":[]}`, `/music` `{"ducking":{"amount":-12,"attack":0.3,"enabled":true,"release":0.8},"items":[]}`, `/sequence/*/audioShift` `0` (en cada clip), `/zoom/auto/mode` `"classic"` y `/audio/tracks/*/ranges` `[]` (en cada pista), sobre lo que ya hubiera ahí, y nada más. Sin ninguna otra edición, el documento migrado dibuja y suena exactamente lo que dibujaba y sonaba en la fase 2 (`make golden-3`).
- Lo que el documento 4 deja ausente en su valor legado, `/sequence/*/content`, `/zoom/regions/*/mode` y `/zoom/regions/*/loupe`, no existe en un documento 3: uno hecho a mano con alguno está dañado, la migración lo rechaza en el primero que encuentra (`invalidDocument` en `/sequence/1/content`, por ejemplo) y se lee como `DecodingError`, nunca como más nuevo. Las filas de la tabla aceptan `*` (cada miembro o elemento) también en lo ausente y en los valores nuevos, como en lo agregado.
- `DocumentMigration.reverted` baja de 4 a 3 (y de ahí a 2 y a 1) solo si cada lugar agregado tiene su valor legado y no hay ninguno de los ausentes: un documento que usa algo de la fase 3 no tiene versión 3.
- **Qué no conmuta con 3 → 4.** `touchesAddedFields(_:from: 3)` es verdadero para la raíz, `/documentVersion`, un lugar agregado o algo debajo de uno (`/annotations`, `/music/ducking/amount`, un `insert` en `/markers/items`, `/sequence/<i>/audioShift`, `/zoom/auto/mode`, `/audio/tracks/<clave>/ranges`), y para un valor que tiene uno de esos lugares con otro valor. Un cambio de la fase 2 que escribe un objeto que contiene un lugar agregado se lleva a través del `migrate` (`carried`), con ese lugar en su valor congelado: un clip entero (un `insert` o un `replace` en `/sequence`, o la secuencia entera, como al cortar o cambiar la velocidad) gana `audioShift: 0`, un `TrackGain` entero (el volumen de una pista) gana `ranges: []` y `/zoom/auto` entero (aplicar un estilo) gana `mode: "classic"`. Ninguna acción de la fase 2 escribe un lugar agregado, así que deshacer cruza la migración.
- **Antes de la primera edición, en el disco sigue en su versión.** Un proyecto de la fase 2 (documento 3), de 1c (2) o de 1b (1) que en la fase 3 solo se abre, se reproduce o se exporta no cambia, y la app de la fase 2 lo sigue abriendo (`openingAVersion3ProjectWritesNothing`, `openingVersion1And2ProjectsWriteNothing`). Hasta la primera edición, la instantánea al cerrar, la compactación y la reparación del registro se escriben en la versión del disco. Una toma que ningún editor abrió escribe al abrirse su documento nuevo en la versión más vieja que lo contiene, nunca debajo de 2: en la práctica el 2, o el 4 si el estilo por defecto ya usa algo de la fase 3 (un zoom automático que atenúa). La primera edición agrega en **una sola escritura** el `migrate` de cada versión que falta y el paso: `{"from":3,"seq":N,"to":4,"type":"migrate"}` y el `do` en un proyecto de la fase 2; `2 → 3`, `3 → 4` y el `do` en uno de 1c o en una toma nueva; `1 → 2`, `2 → 3`, `3 → 4` y el `do` en uno de 1b (`firstEditWritesEveryMigrateAndTheStepInOneWrite`). Un registro que termina en uno o más `migrate` sin nada después es esa escritura cortada: al leer se truncan y el proyecto abre como antes de la edición (`cutAtEveryByteOfTheFirstEditOpensBeforeOrAfterTo4`, `diskFullOnTheFirstEditTo4NeverLeavesMigrateAlone`). La compactación de un registro de la fase 2 deja el `create` en la versión 3 y el `migrate` justo después (`compactionKeepsTheV3CreateAndTheMigrate`).

### El registro con el documento 4

- **Las colecciones.** `/annotations/items`, `/music/items` y `/markers/items` admiten `insert`, `remove` y `replace` (por `id`), como `/zoom/regions`. Los tramos de volumen de una pista son la colección `/audio/tracks/<clave>/ranges`, con la clave escapada (`/audio/tracks/take-001~1mic/ranges`), y existen mientras existe la pista (`EditCollection.gainRanges(track:)`). `EditCollection` pasa a ser una estructura con su puntero (`pointer`), que se lee con `JSONPointer` y nunca partiendo su texto por `/`; los nombres y los textos de las colecciones de antes no cambian.
- **Las etiquetas** (`label`) nuevas son veinticinco, después de las de la fase 2: `annotation.add`, `annotation.change`, `annotation.move`, `annotation.trim`, `annotation.layer`, `annotation.delete`, `clip.freeze`, `clip.card`, `clip.media`, `clip.content`, `zoom.mode`, `audio.range`, `audio.shift`, `music.add`, `music.change`, `music.move`, `music.trim`, `music.delete`, `music.ducking`, `take.rerecord`, `take.use`, `marker.add`, `marker.rename`, `marker.move` y `marker.delete`.

### La secuencia con contenido, el corte del audio y la validación

- **Un clip con contenido es un punto que dura** (diseño de la fase 3, §4.1; decisión 7 del plan de la base). Su `start` es el punto de su toma donde está; su `end` y su `speed` no se leen. Dura en la salida `ClipContent.outputDuration`: el `duration` de un cuadro congelado o de una placa acotado a 0,1…60 s al leerlo (un documento hecho a mano nunca para el render), y en un clip importado `round((end − start) / v)` ns con su velocidad leída como la de un clip (`ClipSpeed.clamped`), 0 (nunca se muestra) con `end <= start`. Ningún instante de la toma cae en él: el mapeo de la fuente a la salida no lo ve (`output(atSource:take:)` da el clip siguiente de la toma), y cada instante de salida dentro de él muestra su punto (`TimeMap.source(atOutput:)`) con su desplazamiento dentro del contenido (`TimeMap.contentOffset(atOutput:)`, de 0 a `D_k − 1`; `nil` en un tramo de la toma). En la mezcla, un clip con contenido calla, con el fundido de 192 cuadros a cada lado; el sonido de un clip importado es de su costura. Sin clips con contenido y sin cortes del audio movidos, `TimeMap` da exactamente los valores de la fase 2 (`make golden-3`).
- **El invariante de cada toma** (§9, `SequenceRules.firstOutOfOrder(in:)`): dentro de cada toma, cada clip empieza en o después del fin de todos los clips de su toma anteriores en la secuencia (un `end` antes del `start` se lee como el `start`, como en `TimeMap`); un punto respeta ese orden. Así cada instante de una toma aparece a lo sumo una vez, más los puntos, y el mapeo de la fuente a la salida es una función. Un cuadro congelado en el borde entre dos clips de su toma está en orden; uno dentro de un clip anterior de su toma, no.
- **El corte del audio** (§7.3, `Clip.audioShift`). El sonido del clip `k` empieza en `TimeMap.audioStarts[k]`, `O_k` movido por su corte tal como lo lee `SequenceRules.audioShift(of:at:)`; la imagen, y la cámara, siguen en `O_k`. El corte se lee acotado por `SequenceRules.audioShiftRange(of:at:)`: `0...0` en el primer clip, en un clip con contenido y en el que sigue a uno con contenido; si no, `±min(D_{k−1}, D_k) / 2` (truncado), la mitad del más corto de los dos clips del borde. Con los límites de cada toma (`takeBounds`), además, un corte J nunca hace oír el clip `k` desde antes del comienzo de su toma ni un corte L el clip `k − 1` después del fin de la suya. Lo que se oye de la toma de un clip en un instante de salida es `TimeMap.audioSource(ofClip:atOutput:)`, `s_k + round((τ − O_k) × v_k)` ns de host con signo, también fuera del clip.
- **Los comandos de la secuencia con contenido.** Partir nunca corta un clip con contenido (en sus bordes, como en los de cualquiera); sus bordes no lo recortan (`trimLimits` da su punto solo y `trim` no hace nada: su largo es el de su contenido) y ninguna velocidad lo cambia; borrarlo lo saca entero, y borrar un rango lo saca solo si el rango lo cubre entero. Los comandos que editan los tramos de la toma (recortar, borrar por la transcripción y devolver, acelerar lo tecleado) dejan cada punto donde está: un recorte no pasa el punto de un clip con contenido de su toma, y lo que se devuelve a cada lado de un punto va del lado suyo. Un clip que hace un comando (un pedazo de un corte) empieza su sonido con su imagen (`audioShift` 0), y un corte del audio que un paso deja fuera de sus límites, porque los clips de su borde son más cortos u otros, se acota en el mismo paso.
- **La validación** (§10, `DocumentRules.problems(in:)`, decisión 6 del plan de la base), además de lo que el `decode` rechaza: un clip con contenido con `start != end` (`contentNotAPoint`), el invariante roto (`outOfOrder`), un `audioShift` fuera de sus límites (`audioShiftOutOfRange`), la duración de un `freeze` o un `card` fuera de 0,1…60 s o un `media` con `end <= start` (`contentDuration`), el `asset` de un clip importado o de un clip anotación que no es un video de `assets/`, el de una imagen que no es una imagen de `assets/`, o la `source` de un tema que no es un sonido de `assets/` ni uno de la biblioteca (`library:music-1/` y un id de letras ASCII, dígitos y `-`) (`assetOutsideAssets`; cada uno con el nombre de su tipo, `PackageFileKind.isValidName`: `.video`, `.asset` y `.audio`), y un clip anotación anclado a la toma (`clipAnnotationAnchoredToContent`). El editor rechaza un paso que deja uno, sin escribir nada; un documento hecho a mano con uno abre de solo lectura (`unsafeEditFiles`), mostrado como se puede dibujar: cada clip con contenido en su punto (`end = start`) con su duración acotada, cada corte del audio acotado, y sin las anotaciones y los temas con un archivo fuera de `assets/` ni los clips anotación anclados a la toma. Una secuencia fuera de orden se muestra como la lee `TimeMap`. Ningún documento de las fases 1 y 2 tiene un problema mientras su secuencia está en orden, como la deja todo editor de esas fases.

### La caché de la música

Los temas de la biblioteca de música (`music-1`, diseño de la fase 3, §7.6) no van en el paquete ni en la carpeta de cachés del proyecto: van en la caché de la app, una vez para todos los proyectos, en `~/Library/Caches/dev.toma.Toma/Music/music-1/<id>-<huella>.caf` (`MusicLibrary`), con `<id>` uno de `calm`, `focus`, `drive`, `piano`, `pulse` y `breeze`. Un documento nombra un tema por su fuente, `library:music-1/<id>`, nunca por la ruta del archivo.

- **La huella** (`MusicScore.fingerprint`) son 16 dígitos hexadecimales en minúscula: los primeros 8 bytes del SHA-256 de `music-1/engine-<versión del motor>/` y la partitura del tema en JSON con las claves ordenadas. Cambia con cualquier nota, preset o ajuste de la partitura y con la versión del motor (`MusicSynth.engineVersion`), así que un archivo hecho con otra partitura (un marcador, una afinación anterior del tema, un motor anterior) nunca pasa por el tema: el tema se hace de nuevo con su nombre nuevo y los archivos de sus otras versiones (`<id>-<16 hex>.caf`) se borran.
- **Un marcador no se guarda nunca.** Un tema que todavía es un marcador (`isPlaceholder`) se hace una vez por cada `MusicLibrary`, en una carpeta propia dentro de la carpeta temporal del sistema que se borra cuando la biblioteca se va, y la próxima lo hace otra vez.

- **Se rehace igual si falta.** Un tema se sintetiza la primera vez que se lo pide (`MusicSynth`, código determinista: los mismos bytes en toda Mac y en cada corrida) y se guarda. Si macOS vacía la caché, o el archivo no está, se vuelve a sintetizar, idéntico, y quien lo necesita (el export) espera; nada del paquete depende de esa carpeta.
- **Entero y atómico.** Se escribe en un temporal oculto de la misma carpeta (`.<id>.<UUID>.tmp.caf`) que se mueve sobre `<id>-<huella>.caf` con `rename(2)` (`ProjectCaches.temporaryFile(for:)` y `commit(_:to:)`), fuera del hilo principal: el nombre tiene el archivo entero o no está. Una síntesis que se cancela (todos los que la pidieron se fueron) no deja ni el archivo ni el temporal.
- **El archivo es un CAF propio:** PCM lineal en `Float32` little-endian, dos canales intercalados, 48 kHz, con solo sus bloques `desc` y `data` (`MusicFile`). Cada tema dura exactamente 5 760 000 cuadros (120 s), así que el archivo mide 68 + 8 × 5 760 000 = 46 080 068 bytes. Los 68 bytes de antes de las muestras (en big-endian, como pide CAF, salvo las muestras):

  | Bytes | Qué |
  |---|---|
  | 0–7 | `caff`, versión 1, flags 0 |
  | 8–19 | el tipo del bloque `desc` y su tamaño, 32 |
  | 20–51 | 48 000,0 (`Float64`), `lpcm`, flags 3 (float, little-endian), 8 bytes por paquete, 1 cuadro por paquete, 2 canales, 32 bits por canal |
  | 52–63 | el tipo del bloque `data` y su tamaño, 4 + 8 × cuadros |
  | 64–67 | su contador de ediciones, 0 |

- **Un archivo con otro tamaño o encabezado no es el tema** y se rehace: uno cortado, otro CAF, uno de otra cantidad de cuadros. Con el nombre de la huella, eso basta: las muestras no se comparan. Un enlace en su lugar no se sigue nunca (`O_NOFOLLOW`): no es el tema, y el tema nuevo lo reemplaza a él, no a lo que apunta.
- El id del algoritmo lleva su versión: los bytes de cada tema se fijan en sus pruebas y pueden cambiar hasta el merge de la fase 3 a `main`; después, otro sonido es `music-2`, en otra carpeta, y `library:music-1/<id>` sigue sonando igual. Ver `docs/music.md`.

Lo demás que la mezcla lee de la música va a la carpeta de cachés del proyecto (`~/Library/Caches/dev.toma.Toma/Projects/<projectID>/`, la de [Las cachés de análisis](#las-cachés-de-análisis)), en dos carpetas más (`AnalysisCacheFolder.music` y `.ducking`). Las hace `MusicAnalysis` (plan 3c, decisiones 6, 8 y 18); la mezcla nunca decodifica un audio importado ni busca la voz: lee lo que hay (`AnalysisInputs.musicFiles` y `.voiceActivity`).

| Carpeta | Qué guarda | Nombre |
|---|---|---|
| `music/` | El audio importado de un tema (`assets/<32 hex>.<ext>`, un sonido de `PackageFileKind.audio`), decodificado | `<nombre del asset>-importedAudio-1.caf`, por ejemplo `0123456789abcdef0123456789abcdef.m4a-importedAudio-1.caf` |
| `ducking/` | Dónde tiene voz cada pista de voz de una toma | `<toma>/<pista>-ducking-1.json` |

- **`importedAudio-1`** (`ImportedAudio`): la primera pista de audio del asset, decodificada una vez con `AVAssetReader` al mismo CAF propio de los temas (`MusicFile`: `Float32` little-endian, estéreo intercalado, 48 kHz, solo `desc` y `data`), hasta los primeros 30 min (86 400 000 cuadros). Una mono va a los dos canales, una estéreo tal cual y una de más canales se mezcla con cada canal a ganancia 1 en los dos, recortada a escala completa (como lee un archivo `AudioTrackTimeline`). El decodificador la remuestrea a 48 kHz y su remuestreador deja afuera sus últimos cuadros (17 desde 44,1 kHz y 33 desde 22,05 kHz, en macOS 26): un sonido que termina a 4 096 cuadros o menos de su largo (la duración precisa de su pista) queda exactamente de ese largo, completado con silencio o cortado, así la vuelta de un archivo propio dura lo que dura el sonido. El asset tiene el nombre de su contenido, así que el nombre basta; la mezcla nunca lee el asset. Un asset que no se puede leer (no está, es un enlace, no es audio, se corta al leerlo) no tiene archivo y ese tema calla, sin parar a los demás.
- **`ducking-1`, el JSON de `ducking/`** (escrito entero con `ProjectJSON.encoder()`): `{"algorithm": "ducking-1", "segments": [...], "spans": [[inicio, fin], ...]}`. `segments` son los `SegmentIdentity.name` de los segmentos de la pista que estaban cuando se buscó la voz, en el orden del manifiesto (uno que no está no figura); `spans`, los tramos con voz (`VoiceActivityFinder`: lo que no es silencio de `SilenceFinder` dentro de donde se oye la pista), en orden y separados, en ns de host. Uno cuyos `segments` no son los de ahora (un segmento reescrito, uno que falta o volvió) o de otro algoritmo está viejo y se vuelve a buscar. Se busca solo con un tema en el documento y el ducking prendido, en cada `microphone` y `deviceAudio` con segmentos de cada toma que muestra la secuencia; si la pista está silenciada o con ganancia 0 no importa acá: eso lo decide la mezcla.
- **Se rehacen si faltan; el export espera.** Como el resto de la carpeta del proyecto y los temas de la biblioteca, se pueden borrar: `MusicAnalysis.prepare` rehace lo que falta (un tema con la biblioteca, que lo vuelve a sintetizar idéntico; un tema que desaparece justo después de hacerse se vuelve a pedir una vez) y el export lo espera; la vista previa lee solo lo que hay (`cached`) y calla lo que falta. Cada archivo se hace una vez aunque lo pidan dos a la vez, entero y atómico (un temporal oculto de la misma carpeta y `rename(2)`), fuera del hilo principal, y la decodificación y la lectura del audio fuera del pool cooperativo; un trabajo cancelado (todos los que lo pedían se fueron) no deja ni el archivo ni el temporal.

### El orden de dibujo con el documento 4

Un cuadro se dibuja en este orden (diseño de la fase 3, §12); lo nuevo, en negrita:

1. El fondo, la sombra y el marco de ventana o de dispositivo.
2. La pantalla a través del zoom y del reencuadre, con los desenfoques de privacidad, **o el clip importado de la secuencia** (`sequence[].content` `media`) en su lugar.
3. El cursor y los efectos de clic.
4. **El zoom tranquilo** (`zoom.regions[].mode` `highlight`, `dim` o `loupe`: resaltar, atenuar o la lupa, que muestrea lo dibujado de 1 a 3).
5. **Las anotaciones pegadas a la grabación** (`annotations` con anclaje `content`), por capa, dentro del escenario: el zoom las transforma.
6. La cámara.
7. **Las anotaciones de la salida** (anclaje `output` o `whole`), por capa, con sus imágenes y sus clips.
8. Las teclas en pantalla.
9. Los subtítulos.

**Una placa** (`content` `card`) reemplaza 1 a 6 y no tiene teclas ni subtítulos; las anotaciones de la salida se dibujan encima, así se puede anotar una placa (decisión 9 del plan de la base): al final del cuadro van la placa, las anotaciones de la salida, las teclas y los subtítulos, en ese orden. **Un cuadro congelado** (`content` `freeze`) es el cuadro de su toma en el comienzo de su clip y en su punto, entero (pantalla, cursor, zoom, cámara, anotaciones pegadas), sin desenfoque de movimiento e igual en toda su duración (decisión 8). Las anotaciones de la salida son las de cada instante de salida, también sobre un cuadro congelado, una placa o un clip importado. Es el mismo orden en cada forma de dibujar un cuadro: directo, con el desenfoque de movimiento del zoom o del cursor, con el zoom dentro de la tarjeta y con la cámara a pantalla completa asentada (ahí no hay escenario ni paso 4: la cámara y encima los pasos 7 a 9). Cuando atenuar o la lupa tienen que leer lo ya dibujado del escenario, terminan el pase y lo que sigue (5 a 9) se dibuja en un pase nuevo sobre el destino.

**Con los valores legados, cada capa nueva vale `nil` o vacía y no cambia ninguna llamada**: sin clips con contenido, sin zoom tranquilo y sin anotaciones, el compositor hace las mismas llamadas, en el mismo orden y con los mismos uniforms que la fase 2, y el shader es el de la fase 2 (las partes de las capas nuevas, vacías en la base, van después de las de la fase 2 en el orden de arriba). Un documento 1, 2 o 3 migrado se dibuja byte por byte como antes (la dorada 3, `make golden-3`).

### Las anotaciones (`annotation-1`)

Cómo se dibuja cada anotación de `annotations` (diseño de la fase 3, §5.1 y §5.5; decisiones 2, 3, 5, 7 y 9 del plan 3a; `AnnotationScene`, `AnnotationTiming`, `AnnotationGeometry`, `StepNumbering`, `AnnotationTypography`).

- **Dos espacios.** Una anotación pegada a la grabación (anclaje `content`) se mide en fracciones del contenido de la pantalla que se muestra en ese instante, como un bloque de privacidad: su espacio es donde se dibujaría el contenido entero (el Área en el modo Área, el cuadro grabado entero si no), llevado por el recorte que dibuja la capa de la pantalla hasta su rectángulo, en coordenadas del escenario (`AnnotationGeometry.contentSpace`, con `PrivacyGeometry.inLayerCrop`). Así queda sobre el mismo píxel del contenido con otro margen, formato, marco, reencuadre (Seguir el cursor), cambio de forma, tarjeta o zoom, que mueven el escenario entero. Su `rect` se lee acotado a −0,5…1,5 en cada eje, con un lado mínimo de 0,01: puede salir del contenido al margen. Sin una pantalla en el cuadro (la cámara sobre todo el cuadro, la pantalla escondida por su layout, una toma sin pantalla) no se dibuja, y en una placa o un clip de la secuencia tampoco, porque no hay contenido. Una de la salida (`output`) o de todo el video (`whole`) se mide en fracciones del cuadro de salida, con su centro acotado a 0…1 y el mismo lado mínimo. En los dos, la unidad (el tamaño de un texto, el ancho de un trazo, un radio) es el alto del espacio. `rotation` gira la caja en grados, en el sentido del reloj, alrededor de su centro; las flechas y los globos no la leen (sus puntos los ubican).
- **La caja de un texto y de un globo.** El ancho de `rect` es el de la caja, y el texto se envuelve por palabras en ese ancho menos su relleno a cada lado; cada salto de línea empieza un renglón (uno al final, un renglón vacío). Las palabras se cortan como si la unidad fuera 1 080 px, con el ancho escalado igual (`AnnotationTypography.referenceUnit`): el ancho de un renglón de CoreText no es del todo proporcional a su tamaño (el espaciado y el tamaño óptico de la fuente cambian con él), y así un texto se parte en los mismos renglones en todo tamaño al que se dibuja (la vista previa, un export en 4K, la tarjeta de la pantalla que crece). El alto es el del texto medido, sus renglones (ascenso, descenso e interlineado de CoreText) más el relleno de arriba y de abajo: ninguno en `plain` y `title`, 0,3 em arriba y abajo y 0,55 em a cada lado en `label`, 0,45 y 0,8 em en `lowerThird`, y el de `label` en un globo, con un em de `size` por la unidad; así `rect.height` no se usa para dibujar un texto ni un globo. La caja se acota donde su anclaje la deja estar (arriba) con el alto medido, no con el guardado: un texto de cuatro renglones en `y` 0,95 de la salida queda con su centro en el borde del cuadro. Una de la salida es tan ancha como el ancho de su `rect` por la proporción del cuadro que nombra el documento (su `aspect`; la de la grabación con `auto`, como la mide el export) por el alto del cuadro, no por su ancho en píxeles: cada tamaño de salida redondea sus lados a píxeles pares (1 108 × 720 y 3 326 × 2 160 difieren un 0,06 %), y con eso una palabra en el límite cambiaría de renglón entre la vista previa y un export en 4K. Un cuadro de otra proporción (a más de 1 % de esa) usa la suya. La proporción del contenido, en las pegadas, no se redondea. La fuente es la del sistema pedida para el idioma `en`, en su diseño (`system`, `rounded`, `serif` o `mono`: SF Pro, su redondeada, New York, SF Mono) y en su peso (`kCTFontWeightTrait` 0, 0,3, 0,4 y 0,56), con el tamaño óptico de su tamaño a esa unidad de referencia (`kCTFontOpticalSizeAttribute` de `size` × 1 080, revisión de A6): así sus formas y sus anchos son proporcionales en todo tamaño al que se dibuja, y un renglón centrado no se corre de un paso de √2 del zoom al siguiente. La flecha va de `from` a `to` y su caja es la que rodea sus extremos y su curva; la cola del globo, del borde de su caja más cercano a `target` hasta él (sin cola con el punto adentro).
- **Cuándo se ve.** Pegada a la grabación: en los instantes de su toma `[start, end)` que muestra la salida, nunca en un corte, en un clip de otra toma, en una placa ni en un clip importado; en un cuadro congelado, si su punto está en ese tramo, igual durante todo el congelado. Su rango de salida es el de su tramo con los cortes de adentro cerrados (`TimeMap.outputRange(ofSource:take:)`). De la salida, `[start, end)` en ns de salida; de todo el video, `[0, D)`. Un clip (`kind` `clip`) se ve en su anclaje recortado al largo de su tramo del archivo (`end − start`) desde donde empieza, y no se repite: ese es su rango de salida (`AnnotationTiming.outputRange`), el mismo que muestran la pista Anotaciones y que leen los comandos; el tiempo del archivo que muestra en el instante de salida `τ` es `start + (τ − c)`, con `c` el comienzo de ese rango. Un clip anclado a la toma no se dibuja nunca.
- **La entrada y la salida** duran `T = min(0,25 s, L / 2)`, con `L` el largo del rango de salida, y se miden con lo que va del rango hasta el instante (`e`) y lo que le falta: pegada a la grabación, por la salida de su tramo de la fuente hasta el punto que se muestra, así quedan quietas en un congelado y una anotación con el comienzo cortado ya entró. `fade`: opacidad `smoothstep(e / T)`; `pop`: opacidad `p = e / T` y escala `0,9 + 0,1 × s(p · 0,25 s) / s(0,25 s)` con `s(t) = 1 − (1 + ωt)·e^(−ωt)` y `ω = 2π / 0,30` (el resorte crítico de `Motion.panelSwap`, congelado), alrededor del centro de la caja: el resorte recorre siempre sus 0,25 s, también en una anotación corta, cuya entrada dura menos (`AnnotationTiming.pop`); `draw`, solo en flechas y formas (las demás lo leen como `fade`): la fracción dibujada del trazo es `smoothstep(e / T)`. La salida es `fade` (la opacidad por `smoothstep` de lo que falta sobre `T`) o `none`. Todo por `opacity`, acotada a 0…1.
- **El orden de las capas.** Dos grupos: las pegadas a la grabación, dentro del escenario y debajo de la cámara (paso 5 del orden de dibujo), y las de la salida y de todo el video, encima de la cámara y debajo de las teclas (paso 7). Dentro de cada grupo, por `layer` (más alto, más arriba) y, con el mismo `layer`, por el orden de `annotations.items`.
- **Los pasos** (`kind` `step`) se numeran 1, 2, 3… una sola vez para toda la salida, por dónde la salida muestra primero su rango; los empates, por `layer` y después por el orden de `annotations.items`. Uno cortado entero, vacío o después del fin de la salida no tiene número, no cuenta y no se dibuja.
- **El aspecto** (`AnnotationRaster`; decisiones 4, 5 y 6 del plan 3a). Cada texto, flecha, forma, globo y paso se dibuja con CoreText y CoreGraphics en un mapa de bits de los píxeles que toca (su caja, sus trazos, su cola, su sombra), en un `CGContext` sRGB fijo, sin suavizado de fuentes ni posición subpíxel y con antialias, así no depende de la pantalla ni de los ajustes y la vista previa da los mismos bytes que el export (la fuente del sistema sí cambia de un macOS a otro). Su opacidad, su escala de `pop` y su giro no están en el mapa: se aplican al dibujarlo.
  - **Un texto**: sus renglones (los que mide la escena) uno debajo del otro desde arriba de su caja menos su relleno, cada uno de `ascenso + descenso + interlineado` de CoreText y alineado según `align` dentro de la caja menos su relleno, con su comienzo y su línea de base en píxeles enteros. `plain` y `title`, con la sombra de los subtítulos (negro al 50 %, 0,04 em abajo, 0,12 em de desenfoque); con un `fill`, sobre una caja de esquinas de 0,12 em de ese color y sin la sombra. `label`, sobre una píldora de esquinas de 0,3 em en su `fill`. `lowerThird`, sobre una caja de esquinas de 0,12 em en su `fill`, con una barra de 0,12 em del color del texto a lo largo de su borde izquierdo, cortada por las esquinas. Las cajas van en píxeles enteros, para que sus bordes queden nítidos.
  - **Una flecha**: el cuerpo es la Bézier cuadrática desde `from`, con el punto de control de la curva (el medio de los extremos corrido `curve × 0,5 × largo` por la normal izquierda), hasta donde empieza la punta (sobre la recta del punto de control a `to`, así el cuerpo entra en la punta en su dirección), de `width` de ancho y con extremos redondos; la punta llena es un triángulo de 4,5 w de largo y 2,25 w de semiancho, la abierta dos trazos de 4,5 w a ±28° con extremos y unión redondos. Todo en su color como un grupo: donde se superponen, su alfa una sola vez.
  - **Una forma**: su borde por dentro del rect (el medio del trazo corrido `width / 2`), de `width` de ancho; las esquinas de afuera del rectángulo redondeado son 0,18 de su lado corto. Su relleno, si tiene, cubre la forma entera, debajo del borde.
  - **Un globo**: su caja (la de un texto con el relleno de `label`) con esquinas de 0,35 em y su cola, en el `fill` del texto como un grupo; encima, su texto como el de una etiqueta, sin sombra.
  - **Un paso**: un círculo tan ancho como el lado corto de su rect, centrado, blanco, y encima uno de su color 0,06 de su diámetro más chico de cada lado (un anillo blanco de 0,06 d); su número blanco, redondeado y en negrita, de 0,5 d, con sus glifos centrados en el círculo.
  - **Trazarse** (`enter` `draw`, mientras entra): la flecha se dibuja desde `from` esa fracción del largo del cuerpo más la punta (la llena aparece de su base a su punta; los trazos de la abierta, de la punta hacia afuera); el borde de la forma, desde su comienzo (en un rectángulo, la esquina de arriba a la izquierda, en el sentido del reloj) esa fracción de su perímetro, con extremos redondos, y su relleno a esa fracción de su alfa.
  - **El giro y la aparición**: `rotation` gira el dibujo alrededor del centro de su caja, y la escala de `pop` lo achica alrededor del mismo centro; las flechas y los globos no giran.
- **A qué escala.** Una de la salida se dibuja **un texel por píxel**: su mapa de bits es de píxeles enteros de la salida y, quieta (sin giro ni `pop`), se lee sin filtrar. Una pegada a la grabación, **a la escala del zoom en pasos de √2**: la profundidad con que se dibuja el contenido (el zoom del escenario, o el del contenido de la tarjeta, que puede ser menor que 1) redondeada hacia arriba a una potencia de √2, hacia arriba o hacia abajo de 1, así nunca se agranda ni se achica más de √2 (que el filtro bilineal hace sin escalones) y un zoom que entra la dibuja de nuevo solo en cada paso; quieta, sin zoom o con una profundidad de hasta 1,01 (el final de un zoom que se asienta), a escala 1, también un texel por píxel. Uno que a la escala del zoom pasaría de 4 096 × 4 096 píxeles o de 8 192 de lado baja de a un paso de √2 hasta caber (y entonces sí se agranda al dibujarlo); a escala 1, uno de más de 8 192 píxeles de lado no se dibuja; la escala más chica es √2⁻¹⁶.
- **Dibujados antes, y guardados.** Los mapas de bits se guardan por lo que dibujan (su contenido, su caja, su espacio y su fracción trazada) y por su escala: una anotación quieta se rasteriza una vez. Cada cuadro entrega los que van a dibujar los cuadros que siguen (`RenderFrame.annotationsAhead`): las que entran en el próximo medio segundo, como las muestra su primer cuadro; mientras una se traza, sus pasos de los tres cuadros siguientes (hasta entera); y mientras el zoom se mueve, las pegadas que se ven en cada paso de √2 que alcanza en ese medio segundo (leído cinco veces), con el contenido de la pantalla como está en el cuadro. Se dibujan en segundo plano, de a ocho a la vez, con la misma función, así los bytes son los mismos que dibujados en su cuadro; un cuadro que pide uno que se está dibujando lo espera, y uno que no se dibujó antes (un salto) se dibuja en su cuadro. Se guardan los últimos 32 usados y no más de 256 MB, los más viejos primero, pero **nunca uno que usó o entregó el cuadro que se dibuja o el anterior**, sean cuantos sean: un cuadro con 40 anotaciones, o con más de 256 MB de ellas (un export en 4K con formas grandes bajo un zoom), las conserva todas y el siguiente no dibuja ninguna de nuevo.
- **Cómo se dibuja.** Las pegadas a la grabación van dentro del escenario, a través del zoom del cuadro y, en una tarjeta (Pantalla dividida), a través de su contenido y cortadas a ella con la fuerza con que se corta el cursor; con el desenfoque de movimiento se dibujan una sola vez, nítidas, sobre el promedio. Una a opacidad 0, fuera del cuadro o sin nada que dibujar no hace ninguna llamada ni se rasteriza; una que CoreGraphics o Metal no pueden hacer (sin memoria) deja el cuadro sin ella.
- **Sin anotaciones no se mide nada**: los dos grupos están vacíos en todo cuadro, y un documento migrado se dibuja como antes (`make golden-3`).

### Las placas (`titleCard-1`)

Una placa (`sequence[].content` `card`, diseño de la fase 3, §5.2; decisión 10 del plan 3a) ocupa todo el cuadro de salida durante su `duration` en lugar de los pasos 1 a 6 del orden de dibujo, sin teclas ni subtítulos, y las anotaciones de la salida van encima. Lo dibujan `TitleCardScene` (qué hay debajo y cuánto se ve), `TitleCardTextures` (los textos) y `Compositor.drawTitleCard`; el aspecto es `titleCard-1`, congelado: otro aspecto es `titleCard-2`.

- **Los textos.** En una salida de `W × H` píxeles, con la fuente del sistema (SF Pro, pedida para el idioma `en`, como el título de una ventana, así un texto en chino, japonés o coreano se dibuja igual con cualquier idioma del sistema) en los pesos de `kCTFontWeightTrait` (regular 0, semibold 0,3, bold 0,4, heavy 0,56) y el interlineado de CoreText; las líneas se parten por palabras dentro de `0,8 W` y donde el texto tiene un salto (`\n`). Ninguna palabra se parte: un texto con una palabra más ancha que `0,8 W` (una palabra larga en Grande a 9:16) se dibuja más chico, lo justo para que entre. El subtítulo va debajo del título a `0,3` del tamaño del título, en el color del texto (`textColor`) al 70 % de su alfa; un texto vacío no se dibuja, y una placa sin textos no tiene textura.

  | Estilo | Título | Subtítulo | Líneas |
  |---|---|---|---|
  | `centered` | `0,085 H`, bold | `0,04 H`, regular | centradas |
  | `leading` | `0,085 H`, bold | `0,04 H`, regular | desde `0,1 W` |
  | `large` | `0,14 H`, heavy (0,56) | `0,04 H`, regular | centradas |
  | `minimal` | `0,05 H`, semibold | `0,03 H`, regular | centradas |

  El bloque (las líneas del título y las del subtítulo) va centrado de arriba abajo, cada línea en una línea de base de píxeles enteros. CoreText lo dibuja en un `CGContext` sRGB fijo, sin suavizado de fuentes ni posición subpíxel y con antialias, en una textura de los píxeles enteros del bloque con un margen de 0,3 del tamaño más grande y 2 píxeles (cortada al cuadro), que se dibuja un texel por píxel: la vista previa y el export dan los mismos bytes. Se guarda por textos, estilo, color y tamaño de salida (las dos últimas).
- **El fundido.** Con `D` lo que dura la placa en la salida (`ClipContent.outputDuration`) y `F = min(0,3 s, D / 2)`, la placa entra en sus primeros `F` contra el cuadro que la salida muestra en `O_k − 1` (el último instante del clip de antes), quieto todo el fundido, con `p = desplazamiento / F`; y sale en sus últimos `F` contra el cuadro de `O_k + D` (el primero del clip de después), con `p = (D − desplazamiento) / F`; en el resto, `p = 1`. Sin un clip de ese lado (la placa empieza o termina la salida), o con otra placa, ese lado corta (`p = 1`): dos placas no se piden cuadros entre sí y una placa nunca pide uno suyo. El cuadro del vecino es el de ese instante dibujado sin el desenfoque de movimiento, como un cuadro congelado, y sigue siendo de su toma: una placa de una toma junto a un clip de otra lee los videos y la máscara de ese clip como los lee él.
- **Los fondos** (`background`), con `p`:
  - `stage`: el cuadro del vecino con el grupo de la pantalla (las pantallas, el marco de ventana o de dispositivo, la sombra, el cursor y los efectos de clic, como lo funden los layouts de la cámara, `RenderFrame.screenOpacity`), lo que va sobre el escenario (el zoom tranquilo, las anotaciones pegadas a la grabación) y la cámara a `1 − p`; en `p = 1`, el fondo del proyecto solo.
  - `color`: el cuadro de `stage` debajo del color sobre todo el cuadro a `p` por su alfa: un color que deja ver muestra debajo el fondo solo una vez entrada la placa, nunca el cursor, la cámara ni los clics del vecino.
  - `blurredFrame`: el cuadro del vecino quieto sin cursor, cámara, efectos de clic, zoom tranquilo ni anotaciones pegadas a la grabación, con su pantalla debajo nítida (con su privacidad) y encima la misma con un desenfoque de privacidad en todo su recorte, a fuerza 1, a `p` de su opacidad, y un velo negro al 35 % × `p`. En la primera mitad de la placa es el cuadro del clip de antes y en la segunda el del clip de después (el de un lado si el otro no tiene). Sin pantalla en ese cuadro (la cámara a pantalla completa, un clip importado, sin vecino), como `stage`.

  En todos, ni teclas ni subtítulos, y los textos a `p` encima. Los cuadros del segundo antes de una placa pasan sus textos para dibujarlos antes (`RenderFrame.titleCardsAhead`, como los subtítulos): el primer cuadro de la placa encuentra su textura hecha. Una textura que no se pudo hacer (sin memoria) se recuerda como ninguna: la placa se dibuja sin sus textos sin volver a intentarlo cada cuadro.

## Los datos crudos nunca se borran

Los segmentos y `events.jsonl` de una toma son los datos crudos, y ningún componente los borra ni los reescribe sin que el usuario lo pida: ni la grabación, ni la recuperación, ni una actualización de la app. Un archivo que no se puede leer se marca como `unreadable` en el manifiesto y queda en el disco tal cual estaba. La única excepción es la línea cortada al final de `events.jsonl` (ver arriba): son los bytes de una escritura que no terminó, no un evento, y se truncan antes de seguir escribiendo. Lo único que se puede borrar sin perder nada es `cache/` y la carpeta de cachés del proyecto fuera del paquete, porque todo lo que contienen se vuelve a calcular, y el `.reserve` de una toma, que es espacio vacío.

## Cambios de la versión 4

La versión 4 llega con la fase 2, para las tomas que graban un iPhone o un iPad por cable o las teclas. Los paquetes nuevos se siguen creando con `formatVersion: 3` (`Manifest.currentFormatVersion`); la versión más nueva que escribe y lee esta versión es la 4 (`Manifest.newestFormatVersion`).

- Tipos de pista nuevos, al final de la lista:

  | `kind` | Qué graba | Segmentos | Campos de `source` |
  |---|---|---|---|
  | `device` | La pantalla de un iPhone o un iPad conectado por cable: es la pantalla de la toma, como `display` o `window`. | video | `name`, `deviceUniqueID`, `globalFrame`, `pixelScale` |
  | `deviceAudio` | El sonido de ese iPhone o iPad, en una pista aparte. | audio | `name`, `deviceUniqueID` |

  La recuperación y la verificación leen video en `device` y audio en `deviceAudio`.
- Evento nuevo, `keyPress`: una tecla que bajó, solo en las tomas en que el usuario eligió grabar las teclas y nunca con la entrada segura de macOS activa. `code` es el código virtual de la tecla (`kCGKeyboardEventKeycode`, de 0 a 65535), `chars` lo que escribe con solo ⇧ de sus modificadores (falta en una tecla que no escribe nada, como una flecha o una tecla de función), `mods` los modificadores (`CGEventFlags`, sus 32 bits bajos, de 0 a 4294967295), `repeat` si es la repetición automática de la tecla y `key` lo que escribe sin ningún modificador (falta donde falta `chars`, y en las líneas grabadas antes de que existiera). Convive con `keyActivity`, que sigue igual y es lo único que usa la actividad de tipeo:

  ```
  {"chars":"a","code":0,"mods":256,"repeat":false,"t":5,"type":"keyPress"}
  {"chars":"$","code":21,"key":"4","mods":131072,"repeat":false,"t":6,"type":"keyPress"}
  {"code":123,"mods":0,"repeat":true,"t":7,"type":"keyPress"}
  ```

Cuándo un paquete pasa a la versión 4:

- **Un paquete pasa a 4 solo cuando una toma los usa**: la grabación sube el manifiesto a 4 en la misma escritura que suma el registro de una toma con una pista `device` o `deviceAudio` (`ManifestStore.update(raisingTo:_:)`), o con una escritura propia (`ManifestStore.raiseFormatVersion(to: 4)`) antes de escribir la primera línea `keyPress`. Si no, sigue en 3 y lo abre la app de la fase 1. Un manifiesto de una versión anterior a 4 nunca se escribe con una pista `device` o `deviceAudio` (`ManifestStoreError.needsFormatVersion(4)`), y una subida que no se pudo escribir deja la versión como estaba.
- La versión solo sube, y solo desde 3: un paquete v1 o v2 pasa a 3 con su primera edición y no se graba en él (`Manifest.recordableFormatVersions`, `3...4`), así que nunca salta a 4.
- Una vez en 4, el paquete se queda en 4: nada lo baja, y las tomas siguientes y la recuperación lo escriben en 4 aunque no tengan pistas de dispositivo ni teclas. El documento de edición no cambia por la versión 4.

Compatibilidad:

- **El lector acepta 1…4** (`Manifest.supportedFormatVersions`, `1...4`) y rechaza cualquier otra antes de decodificar el manifiesto: un manifiesto de la versión 5 o más es de una Toma más nueva (*versión más nueva* en la biblioteca, *para reparar* en la recuperación, que no lo toca).
- La app de la fase 1 (lector de `1...3`) dice que un paquete v4 es de una versión más nueva, nunca que está dañado, y no lo toca. Un paquete de la fase 2 sin iPhone ni teclas sigue en 3 y lo abre igual.
- Un lector que no conoce `keyPress` salta esas líneas, como cualquier línea que no entiende; la versión 4 del manifiesto ya avisa antes.

Cómo graba las teclas esta versión (`KeyPressRecorder`, solo en las tomas con *Grabar las teclas para mostrarlas*):

- Las escucha un `CGEventTap` de solo escucha de `keyDown`, que no cambia ninguna tecla. Necesita el permiso de Monitoreo de entrada y una toma nunca lo pide: sin el permiso no se intenta el tap (hacerlo mostraría el pedido) y la toma graba igual, sin teclas.
- `t` es el `HostTime` del momento en que la tecla llega al tap (no la marca del evento, cuya unidad cambia según la Mac).
- `chars` es lo que escribe la tecla en la distribución de teclado en uso teniendo en cuenta **solo ⇧** de sus modificadores (`UCKeyTranslate` sin teclas muertas: una tecla muerta da su propio carácter): `"A"` con ⇧, `"c"` en ⌘C, `"ñ"` en una distribución en español. Falta en una tecla que no escribe nada o que da un carácter de control (↩, ⇥, ⌫, ⌦, esc, las flechas, las teclas de función). Una tecla del instante antes de que se lea la distribución, al empezar, puede quedar sin `chars`.
- `key` es lo que escribe la misma tecla **sin ningún modificador**, en la misma distribución y también sin teclas muertas: `"4"` en ⌘⇧4 (donde `chars` es `"$"`), `"7"` en el ⌘⇧7 de un teclado en español (donde `chars` es `"/"`), `"a"` en ⇧A. Es la etiqueta de la tecla en un atajo, sea cual sea el teclado. Falta donde falta `chars`. Es opcional: un lector la usa si está y, en una línea sin ella (de antes de que se escribiera), puede volver de `chars` a la tecla como en un teclado de EE. UU. (`keyOverlay-1` lo hace así). Con la entrada segura activa no hay línea, así que tampoco `key`.
- `mods` lleva solo cinco bits de `CGEventFlags` (`KeyPressRecorder.modifierMask`, 10354688 = `0x9E0000`): ⇧ 131072 (`0x20000`), ⌃ 262144 (`0x40000`), ⌥ 524288 (`0x80000`), ⌘ 1048576 (`0x100000`) y fn 8388608 (`0x800000`, que macOS pone también en las flechas y las teclas de función). No quedan Bloq Mayús, el bit del teclado numérico ni los del dispositivo. El lector acepta cualquier valor de 32 bits (como el `256` del ejemplo de arriba); la grabación solo escribe esos bits.
- **Con la entrada segura de macOS activa no hay línea** (`IsSecureEventInputEnabled()`, leída en cada tecla, al llegar al tap y otra vez justo antes de escribirla, después de la subida a 4): ni lo que se escribe en un campo de contraseña ni la ↩ que lo cierra. La protección cubre los campos en los que la app activa la entrada segura, como hacen los campos de contraseña; un campo de una app que no la activa se graba como cualquier otro. Tampoco hay líneas en pausa (el teclado no se escucha), de antes del comienzo o de la reanudación, ni después del final de la toma.
- **El paquete sube a 4 justo antes de la primera línea**: la grabación llama a `ManifestStore.raiseFormatVersion(to: 4)` una vez por toma, en la cola de las teclas, antes de escribir la primera `keyPress`. Si esa subida falla (por ejemplo, con el disco lleno), la toma no escribe ninguna tecla más, así que nunca queda una línea `keyPress` en un paquete 3. Una toma con la opción prendida en la que no se tocó ninguna tecla (o solo con la entrada segura activa) deja el paquete en 3. Una toma con una pista `device` o `deviceAudio` sube a 4 con la misma escritura que lleva su registro al manifiesto.

### Las pistas de un iPhone o un iPad

- El `source` de una pista `device`: `name`, el nombre del dispositivo; `deviceUniqueID`, su `AVCaptureDevice.uniqueID` (el mismo cada vez que se conecta ese dispositivo); `globalFrame`, `{"x": 0, "y": 0, "width": …, "height": …}` en **píxeles** del formato con el que empezó a grabar el dispositivo en la toma (el tamaño de su primer segmento), y `pixelScale` 1. No es un lugar en el escritorio de la Mac: con el origen en (0, 0) y la escala 1, la geometría coloca la pantalla del dispositivo tal como es. El registro de la toma llega al manifiesto antes de que el dispositivo grabe, con lo que dice entonces (un iPhone no dice su tamaño antes de grabar), y la pista se corrige con una escritura en cuanto empieza a grabar; girarlo después, o reconectarlo, no lo cambia. Si el dispositivo no dice su tamaño, faltan `globalFrame` y `pixelScale`.
- Al girar el dispositivo cambia el tamaño de sus cuadros: la pista sigue en un segmento nuevo (`formatChanged`) y `globalFrame` sigue siendo el del comienzo, el tamaño del primer segmento.
- **Un segmento de otro tamaño de una pista `device` se ve entero dentro del tamaño del primero**: al leerlo, cada cuadro se escala entero (sin recortar, con la mayor escala que lo deja entero y los lados redondeados al píxel) y se centra en un cuadro del tamaño de `globalFrame`, con negro alrededor (barras arriba y abajo para un iPhone vertical que se giró a horizontal). La colocación y la geometría de la pantalla son siempre las del primer segmento, y la vista previa, el avance por la línea de tiempo y el export leen los mismos cuadros. Sin `globalFrame` (un dispositivo que no dijo su tamaño), cada segmento se lee como se grabó. Nada de esto cambia los archivos de la toma.
- Una toma con una pista `device` empieza en el editor con el marco del dispositivo (`deviceFrame-1`, Oscuro: iPhone si el lado corto sobre el lado largo de `globalFrame` es 0,6 o menos, en cualquier orientación, iPad si no) y sin el cursor, que no graba; el zoom automático no planea nada sin clics y el zoom a mano funciona como en cualquier toma.
- `deviceAudio` es el sonido que llega por el mismo cable, del mismo dispositivo (su `source` lleva el mismo `name` y `deviceUniqueID`, sin `globalFrame`), en el formato propio del dispositivo y en una pista aparte de `mic` y `systemAudio`.
- Desconectar el cable termina el segmento abierto de las dos pistas (`streamError`); al volver a conectar **el mismo** dispositivo (el mismo `deviceUniqueID`, nunca otro que esté conectado), las dos siguen en segmentos nuevos, como cualquier pista que se reinicia.

## Cambios de la versión 5

La versión 5 llega con la fase 3, para los paquetes con dos tomas o más. Los paquetes nuevos se siguen creando con `formatVersion: 3` (`Manifest.currentFormatVersion`); la versión más nueva que escribe y lee esta versión es la 5 (`Manifest.newestFormatVersion`).

Cuándo un paquete pasa a la versión 5:

- **Un paquete pasa a 5 solo al tener dos tomas** (`Manifest.needsFormatVersion5`): la grabación sube el manifiesto a 5 en la misma escritura que suma el registro de una toma nueva a un paquete que ya tiene una (`ManifestStore.update(raisingTo:_:)`). Un paquete de una toma nunca sube por esto. El motivo: la app de la fase 2 abriría la última toma, con el documento de la primera (fondo y silencio) o, sin documento, la toma nueva en lugar de la editada; con la versión 5 dice que el proyecto es de una versión más nueva y no lo toca.
- Un manifiesto de una versión anterior a 5 nunca se escribe con una toma agregada a otra (`ManifestStoreError.needsFormatVersion(5)`). Un paquete que ya tiene dos tomas por debajo de 5 (ninguna app lo escribe: la fase 1 y la 2 graban una toma por paquete) se sigue cerrando y recuperando: lo que se rechaza es la toma agregada, nunca un cambio de las que están.
- La subida cambia solo `formatVersion`. **Una toma nueva nunca toca las de antes**: su registro en el manifiesto, su carpeta, `edit.json`, `edit-log.jsonl` y `assets/` quedan igual byte a byte, también si la toma nueva se corta (un corte de energía o un `kill -9` la dejan para recuperar, como a cualquier toma; lo comprueba `make crash-test`). Como la subida y el registro van en una sola escritura atómica, un corte deja el manifiesto de antes (en su versión, con las tomas de antes; a lo sumo queda la carpeta vacía de la toma nueva, que nadie lista) o el nuevo (en 5, con la toma nueva): nunca un paquete de una toma en 5, que la app de la fase 2 rechazaría.
- La versión solo sube, y solo desde 3 o 4 (`Manifest.recordableFormatVersions`, `3...5`): un paquete v1 o v2 pasa a 3 con su primera edición antes de grabar en él.

Las pistas de audio del sistema por app (diseño §7.1) **no suben la versión**: una toma que graba cada app en su propia pista sigue en la suya (3, o 4 con un iPhone o las teclas).

- El id de la pista es `system-audio-` y el bundle id de la app con todo carácter (escalar Unicode) que no es una letra o un dígito ASCII cambiado por `-` (`TrackRecord.systemAudioTrackID(bundleID:taken:)`), y `-2`, `-3`… si ya está tomado: `com.apple.Safari` es `system-audio-com-apple-Safari`. Es un id de pista válido (letras, dígitos y `-`).
- Campos nuevos de la pista, opcionales, al final: `appBundleID` (el bundle id de la app) y `appName` (su nombre); faltan en cualquier otra pista. La app también va en `source.name` y `source.includedBundleIDs`, como en una pista de *Solo estas apps*.

  ```json
  {
    "appBundleID" : "com.apple.Safari",
    "appName" : "Safari",
    "id" : "system-audio-com-apple-Safari",
    "kind" : "systemAudio",
    "segments" : [ … ],
    "source" : {
      "includedBundleIDs" : [
        "com.apple.Safari"
      ],
      "name" : "Safari"
    }
  }
  ```
- El lector de la fase 2 ignora los campos nuevos, acepta el id y mezcla cada pista `systemAudio` por su clave `<toma>/<pista>`, a 1 sin entrada en el documento, con los canales de la más ancha (comprobado contra `main` a78fbe1: `threeAppTracksMixAsTheirSum`, `appTrackDecodesInThePhase2Reader`). Si una recuperación de la fase 2 reescribe el manifiesto, se pierden solo `appBundleID` y `appName`.

Archivos nuevos del paquete, que tampoco suben la versión (los nombra el documento de edición):

| Qué | Dónde, y el nombre exacto | Límite | Formatos |
|---|---|---|---|
| Clip propio | `assets/<sha>.<ext>`, `[0-9a-f]{32}\.(mov\|mp4\|m4v)` | 16 GiB | H.264, HEVC o ProRes, con duración |
| Audio propio | `assets/<sha>.<ext>`, `[0-9a-f]{32}\.(m4a\|mp3\|wav\|aiff\|caf)` (un `.aif` se nombra `aiff`) | 2 GiB | una pista de audio con duración |
| Guion | `script.txt`, en la raíz del paquete | 1 MiB | texto UTF-8 |

- **Los clips y el audio** se copian a `assets/` como las imágenes (clon de APFS, nombre por los primeros 16 bytes del SHA-256, el mismo archivo una sola vez), después de comprobar que se reproducen: AVFoundation los abre (legibles y con duración) y tienen una pista de su tipo con duración, de H.264, HEVC o ProRes en un clip. Lo que no, no se copia. Desde el paquete, AVFoundation (que abre un archivo por su ruta y sigue enlaces) recibe la ruta solo después de `ProjectPackage.mediaAsset(_:as:)`: el nombre exacto, la carpeta `assets/`, ningún enlace en el camino (`openat` con `O_NOFOLLOW` desde la carpeta del paquete) y un archivo común dentro del límite, mirado con `fstatat` sin abrirlo (un FIFO nunca se abre). Lo que no cumple se trata como ausente.
- **`script.txt`** es el guion del teleprompter del proyecto (diseño §8.5). Se escribe entero y atómico (`ProjectPackage.writeScript`: `script.txt.tmp`, `F_FULLFSYNC` y `renameat` desde el descriptor de la carpeta del paquete; un enlace en su lugar se reemplaza, nunca se sigue) y se lee con `SafePackageFile` (`readScript`): un enlace, algo que no es un archivo común, uno de más de 1 MiB o bytes que no son UTF-8 son como si no hubiera guion.

Compatibilidad:

- **El lector acepta 1…5** (`Manifest.supportedFormatVersions`, `1...5`) y rechaza cualquier otra antes de decodificar el manifiesto: un manifiesto de la versión 6 o más es de una Toma más nueva (*versión más nueva* en la biblioteca, *para reparar* en la recuperación, que no lo toca).
- La app de la fase 2 (lector de `1...4`) dice que un paquete v5 es de una versión más nueva y no lo toca; la de la fase 1 (`1...3`), lo mismo. Un paquete de una toma sigue en 3 o 4 aunque tenga pistas por app, clips, audio o guion: su manifiesto lo leen igual (lo que pueden abrir lo decide además la versión del documento de edición).

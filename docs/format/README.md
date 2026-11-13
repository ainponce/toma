# Formato de proyecto de Toma

**Versión 1 (`formatVersion: 1`), inestable hasta la fase 4.** Los nombres y campos todavía pueden cambiar. A partir del primer release público, cada cambio de formato viene con su migración y sus pruebas de compatibilidad.

El formato es público para que cualquier herramienta pueda leer, verificar o recuperar una grabación sin la app. Las reglas de este documento son las que sigue el código de `Packages/RecorderKit/Sources/ProjectFormat`.

## El paquete

Un proyecto es una carpeta con extensión `.toma` que Finder muestra como un solo documento:

```
MiVideo.toma/
  manifest.json                versión de formato, app, fecha, tomas, pistas y segmentos
  edit.json                    decisiones del usuario (línea de tiempo, estilos); lo crea el editor
  takes/
    take-001/
      display-1/               una carpeta por pista, con el id de la pista
        seg-0001.mov           un archivo por segmento (QuickTime fragmentado)
        seg-0002.mov
      mic/
        seg-0001.mov
      events.jsonl             un evento por línea: cursor, clics, cortes de stream, pausas
      recording.lock           lock de la grabación en curso (ver más abajo)
  cache/                       regenerable: transcripciones, sugerencias, miniaturas
```

- Las tomas se llaman `take-001`, `take-002`, … Un número nunca se reutiliza: la toma nueva recibe el número siguiente al más alto del manifiesto y salta cualquier carpeta que ya exista en `takes/`.
- Los segmentos se numeran desde 1 con cuatro dígitos (`seg-0001.mov`). Cada pista abre un segmento nuevo cada vez que su captura se interrumpe (pausa, error del stream, cambio de formato), así un corte nunca daña lo grabado antes.
- Los segmentos son películas fragmentadas, con fragmentos de 1 s: si la app, el sistema o la batería se apagan de golpe, se puede leer todo hasta el último fragmento escrito.
- Las pistas de cámara, audio del sistema y iPhone/iPad, y las imágenes de cursor (`cursors/`), llegan en fases posteriores con sus propias carpetas dentro de la toma.

## `manifest.json`

Ejemplo completo de un proyecto con una toma terminada: la pantalla tuvo un corte del stream (error `-3821`) y siguió en un segundo segmento; el micrófono grabó sin cortes.

```json
{
  "app" : {
    "name" : "Toma",
    "version" : "0.1.0"
  },
  "createdAt" : "2026-11-13T16:00:00Z",
  "formatVersion" : 1,
  "takes" : [
    {
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
        }
      ]
    }
  ]
}
```

Reglas de escritura:

- JSON UTF-8 con claves en orden alfabético, indentado y sin escapar `/`.
- Los campos opcionales se omiten cuando no tienen valor (nunca se escribe `null`).
- El archivo se reemplaza entero en cada cambio: se escribe `manifest.json.tmp`, se fuerza a disco con `F_FULLFSYNC`, se renombra sobre `manifest.json` con `rename(2)` y se fuerza a disco también la carpeta del paquete con `F_FULLFSYNC`, para que el cambio de nombre sobreviva a un corte de energía. Si el volumen no admite `F_FULLFSYNC`, se usa `fsync`. Un lector ve siempre el manifiesto anterior o el nuevo, nunca uno a medias.
- Después de un corte de energía puede quedar un `manifest.json.tmp` más nuevo que `manifest.json` (completo en disco, pero sin el cambio de nombre). Los lectores lo ignoran y usan `manifest.json`; la recuperación puede revisarlo más adelante. La próxima escritura lo pisa.
- Un solo proceso escribe el manifiesto de un paquete por vez, porque todas las escrituras usan el mismo `manifest.json.tmp`.

### Campos

| Campo | Tipo | Significado |
|---|---|---|
| `formatVersion` | entero | Versión del formato. Hoy, `1`. |
| `app` | objeto | `name` y `version` de la app que creó el proyecto. |
| `createdAt` | fecha | Creación del proyecto. |
| `takes` | lista | Tomas en el orden en que se grabaron. |

**Toma** (`takes[]`)

| Campo | Tipo | Significado |
|---|---|---|
| `id` | texto | `take-001`, … Es también el nombre de su carpeta en `takes/`. |
| `status` | texto | `recording` (se está grabando, o la app murió sin cerrarla), `complete` (la cerró la app) o `recovered` (la cerró la recuperación tras un crash). |
| `startedAt` | fecha | Inicio de la toma. |
| `tracks` | lista | Pistas de la toma. |

**Pista** (`tracks[]`)

| Campo | Tipo | Significado |
|---|---|---|
| `id` | texto | Identificador único dentro de la toma y nombre de su carpeta (por ejemplo `display-1`, `mic`). |
| `kind` | texto | `display` o `microphone`. |
| `source` | objeto | Qué se grabó (ver abajo). |
| `segments` | lista | Segmentos en orden de `index`. |

**Fuente** (`source`): solo están los campos que corresponden al tipo de pista.

| Campo | Tipo | Significado |
|---|---|---|
| `name` | texto | Nombre visible de la pantalla o del dispositivo. |
| `displayID` | entero | `CGDirectDisplayID` de la pantalla. |
| `deviceUniqueID` | texto | `uniqueID` del dispositivo de audio. |
| `globalFrame` | objeto | `x`, `y`, `width`, `height` en puntos globales, con el origen arriba a la izquierda de la pantalla principal. |
| `pixelScale` | número | Píxeles por punto de la pantalla (2 en una pantalla Retina). |

**Segmento** (`segments[]`)

| Campo | Tipo | Significado |
|---|---|---|
| `index` | entero | Número del segmento dentro de la pista, desde 1. |
| `file` | texto | Ruta del archivo relativa a la raíz del paquete. |
| `startHostTime` | `HostTime` | Instante del primer cuadro o muestra del archivo. |
| `endHostTime` | `HostTime` | Instante en que se cerró. Falta mientras el segmento está abierto. |
| `endReason` | objeto | Por qué se cerró. Falta mientras el segmento está abierto. |
| `droppedFrames` | entero | Cuadros (o bloques de audio) que llegaron de la captura y se descartaron porque el escritor no daba abasto. |
| `heartbeatFrames` | entero | Cuadros repetidos para que el tiempo siga corriendo con la pantalla quieta. |

**Motivo de cierre** (`endReason`): un objeto plano con `type` y, según el tipo, otros campos al mismo nivel.

| `type` | Campos extra | Significado |
|---|---|---|
| `stopped` | | La grabación se detuvo de forma ordenada. |
| `paused` | | Pausa, bloqueo de pantalla o reposo. |
| `streamError` | `domain`, `code` | El stream de captura falló; la pista sigue en un segmento nuevo. |
| `writerError` | `domain`, `code` | El escritor del archivo falló. |
| `formatChanged` | | Cambió el formato de la fuente (por ejemplo, la resolución). |
| `diskFull` | | Se cerró la toma por falta de espacio. |
| `recoveredAfterCrash` | | Lo cerró la recuperación; `endHostTime` es el final de lo legible. |
| `empty` | | La recuperación encontró el archivo vacío o sin ninguna muestra; `endHostTime` es igual a `startHostTime`. |
| `unreadable` | `bytes` | La recuperación no pudo leer un archivo no vacío de `bytes` bytes. El archivo queda intacto. |

## Tiempos

- Todos los instantes son `HostTime`: nanosegundos de `CLOCK_UPTIME_RAW`, guardados como un entero JSON. Es el mismo reloj de `CMClockGetHostTimeClock()`, de los timestamps de ScreenCaptureKit y AVFoundation, y de `NSEvent.timestamp`, así que pistas y eventos quedan alineados sin estimar nada.
- El tiempo 0 de cada archivo de segmento es su `startHostTime`: una muestra en el segundo `t` del archivo ocurrió en `startHostTime + t × 1 000 000 000`.
- El reloj vuelve a cero en cada arranque de la Mac, así que los `HostTime` solo se comparan dentro de una misma toma.

## Fechas

Las fechas (`createdAt`, `startedAt`) son ISO 8601 en UTC y sin fracción de segundo, por ejemplo `"2026-11-13T16:00:12Z"`. Se redondean hacia abajo al segundo entero cuando se crean, así lo que se lee del disco es exactamente lo que se escribió.

## `recording.lock`

Mientras se graba una toma existe `takes/<toma>/recording.lock`, y el proceso que graba lo mantiene abierto con un lock `flock` exclusivo.

- **Lo que cuenta es el lock, no el archivo.** Una toma se está grabando si y solo si alguien tiene el lock. Para saberlo se abre el archivo con `open(ruta, O_RDONLY | O_EXLOCK | O_NONBLOCK)`: si falla con `EWOULDBLOCK`, está tomado; si abre (o el archivo no existe), está libre y hay que cerrarlo enseguida.
- El kernel suelta el lock cuando muere el proceso, aun con `kill -9` o un corte de energía. Un `recording.lock` que quedó en disco después de un crash no significa que se esté grabando.
- El lock pertenece al archivo abierto, no al proceso: un segundo `open` con `O_EXLOCK` dentro del mismo proceso también falla con `EWOULDBLOCK`.
- El que graba lo toma con `open(ruta, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0644)` antes de marcar la toma como `recording`. Al terminar borra el archivo y después lo cierra, en ese orden, para que nadie pueda quedarse con el lock de un archivo ya borrado.
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

## Los datos crudos nunca se borran

Los segmentos y `events.jsonl` de una toma son los datos crudos, y ningún componente los borra ni los reescribe sin que el usuario lo pida: ni la grabación, ni la recuperación, ni una actualización de la app. Un archivo que no se puede leer se marca como `unreadable` en el manifiesto y queda en el disco tal cual estaba. Lo único que se puede borrar sin perder nada es `cache/`, porque todo lo que contiene se vuelve a calcular.

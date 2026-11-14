# Formato de proyecto de Toma

**Versión 1 (`formatVersion: 1`), inestable hasta la fase 4.** Los nombres y campos todavía pueden cambiar. A partir del primer release público, cada cambio de formato viene con su migración y sus pruebas de compatibilidad.

El formato es público para que cualquier herramienta pueda leer, verificar o recuperar una grabación sin la app. Las reglas de este documento son las que sigue el código de `Packages/RecorderKit/Sources/ProjectFormat`.

## El paquete

Un proyecto es una carpeta con extensión `.toma` que Finder muestra como un solo documento:

```
MiVideo.toma/
  manifest.json                versión de formato, app, fecha, tomas, pistas y segmentos
  edit.json                    decisiones del usuario (línea de tiempo, estilos); lo escribe el editor desde
                               la fase 1 (en la fase 0 no existe)
  takes/
    take-001/
      display-1/               una carpeta por pista, con el id de la pista
        seg-0001.mov           un archivo por segmento (QuickTime fragmentado)
        seg-0002.mov
      mic/
        seg-0001.mov
      events.jsonl             un evento por línea: cursor, clics, cortes de stream, pausas
      recording.lock           lock de la grabación en curso (ver más abajo)
      .reserve                 espacio reservado mientras se graba (ver más abajo)
  cache/                       regenerable: transcripciones, sugerencias, miniaturas
```

- Las tomas se llaman `take-001`, `take-002`, … Un número nunca se reutiliza: la toma nueva recibe el número siguiente al más alto del manifiesto y salta cualquier carpeta que ya exista en `takes/`.
- **Rutas.** Un paquete puede venir de cualquier lado (una carpeta compartida, una descarga), así que ninguna herramienta sigue una ruta del manifiesto sin comprobarla. El `id` de una toma es `take-` y tres o más dígitos; el de una pista, solo letras ASCII, dígitos y `-`; el `file` de un segmento es exactamente `takes/<toma>/<pista>/seg-NNNN.mov` para su `index`. Dentro de una toma, `takes/`, la carpeta de la toma, las de sus pistas, `recording.lock`, `events.jsonl` y `.reserve` no pueden ser enlaces simbólicos ni de otro tipo (carpetas las carpetas, archivos comunes los archivos). Un paquete que no cumple algo de esto es *para reparar*: la recuperación no lo toca y el editor no lo abre. La ruta del paquete en sí sí puede pasar por enlaces (`/var` es uno, o una carpeta Movies enlazada): solo se comprueba lo que está dentro.
- Los segmentos se numeran desde 1 con cuatro dígitos (`seg-0001.mov`). Cada pista abre un segmento nuevo cada vez que su captura se interrumpe (pausa, error del stream, cambio de formato), así un corte nunca daña lo grabado antes.
- Los segmentos son películas fragmentadas, con fragmentos de 1 s: si la app, el sistema o la batería se apagan de golpe, se puede leer todo hasta el último fragmento escrito.
- Los segmentos de micrófono guardan todos los canales del dispositivo, en su orden: ALAC hasta 8 canales y LPCM Float32 con distribución discreta (`kAudioChannelLayoutTag_DiscreteInOrder`) desde 9. La distribución de canales que declara un archivo de 3 a 8 canales es la que ALAC exige para esa cantidad (por ejemplo `MPEG_5_1_D` para 6) y es solo una etiqueta: el canal *n* del archivo es la entrada *n* del dispositivo, no el altavoz que la etiqueta nombra.
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
- El archivo se reemplaza entero en cada cambio: se borra un `manifest.json.tmp` que haya quedado (aunque sea un enlace simbólico, que nunca se sigue), se crea uno nuevo con `O_CREAT | O_EXCL | O_NOFOLLOW`, se fuerza a disco con `F_FULLFSYNC`, se renombra sobre `manifest.json` con `rename(2)` y se fuerza a disco también la carpeta del paquete con `F_FULLFSYNC`, para que el cambio de nombre sobreviva a un corte de energía. Si el volumen no admite `F_FULLFSYNC`, se usa `fsync`. Un lector ve siempre el manifiesto anterior o el nuevo, nunca uno a medias.
- Después de un corte de energía puede quedar un `manifest.json.tmp` más nuevo que `manifest.json` (completo en disco, pero sin el cambio de nombre). Los lectores lo ignoran y usan `manifest.json`; la recuperación puede revisarlo más adelante. La próxima escritura lo borra y crea uno nuevo.
- Una toma entra al manifiesto, ya `recording`, antes de que se grabe nada: si esa primera escritura no llega al disco (después de un reintento con el espacio del `.reserve` si faltó espacio), la toma no empieza, y se sueltan el lock y el `.reserve`. Una carpeta de `takes/` que el manifiesto no lista pero que tiene un segmento o un `recording.lock` que nadie tiene hace que el paquete sea *para reparar*.
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
| `droppedFrames` | entero | Cuadros (o bloques de audio) que llegaron de la captura y no se escribieron: porque el escritor no daba abasto, o porque lo rechazó o no se pudo abrir (en ese caso se cuentan en el segmento siguiente, o en el último si no hay otro). En un segmento que cerró la recuperación, es el último `droppedSamples` de `events.jsonl` para ese segmento (0 si no hay), así que pueden faltar los de los últimos 2 s antes del crash. |
| `heartbeatFrames` | entero | Cuadros repetidos para que el tiempo siga corriendo con la pantalla quieta. La recuperación no los conoce y escribe 0. |

**Motivo de cierre** (`endReason`): un objeto plano con `type` y, según el tipo, otros campos al mismo nivel.

| `type` | Campos extra | Significado |
|---|---|---|
| `stopped` | | La grabación se detuvo de forma ordenada. |
| `paused` | | Pausa: reposo de la Mac, pantalla bloqueada o pantallas apagadas (ver el evento `paused`). |
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
{"t":81234600000000,"type":"cursor","x":640.5,"y":402}
{"t":81234608333333,"type":"cursor","x":642.25,"y":401}
{"button":"left","t":81234650000000,"type":"mouseDown","x":642.25,"y":401}
{"button":"left","t":81234720000000,"type":"mouseUp","x":642.25,"y":401}
{"code":-3821,"domain":"SCStreamErrorDomain","t":81276901234567,"track":"display-1","type":"streamInterrupted"}
{"index":2,"t":81277458000000,"track":"display-1","type":"segmentStarted"}
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

**Coordenadas.** `x`, `y` (cursor y clics) y `frame` (`displayGeometry`) están en puntos globales, el espacio de `CGEvent.location` y de `globalFrame` en el manifiesto: el origen está arriba a la izquierda de la pantalla principal, `y` crece hacia abajo, y una pantalla a la izquierda o arriba de la principal tiene coordenadas negativas. La posición dentro de la grabación de una pantalla es `(x − globalFrame.x, y − globalFrame.y)` en puntos, o eso por `pixelScale` en píxeles. macOS da el cursor con fracciones de punto, así que `x` e `y` no siempre son enteros.

### Tipos

| `type` | Campos además de `t` | Significado |
|---|---|---|
| `cursor` | `x`, `y` | Posición del puntero. La grabación la muestrea a 120 Hz y escribe una línea solo cuando cambia. |
| `mouseDown` | `button`, `x`, `y` | Se presionó un botón del mouse (`left`, `right` u `other` para cualquier otro) en esa posición. |
| `mouseUp` | `button`, `x`, `y` | Se soltó un botón del mouse en esa posición. |
| `displayGeometry` | `displayID`, `frame`, `scale` | Una pantalla grabada: su `CGDirectDisplayID`, su rectángulo en puntos globales (`x`, `y`, `width`, `height`) y sus píxeles por punto. Se escribe al empezar la toma para cada pantalla. En esta versión es informativo: la geometría que usa el render es `globalFrame` del manifiesto. |
| `segmentStarted` | `track`, `index` | La pista `track` (su `id` en el manifiesto) abrió el segmento `index`. `t` es el `startHostTime` del segmento; la recuperación lo usa si el archivo quedó en disco pero el segmento no llegó al manifiesto. |
| `streamInterrupted` | `track`, `domain`, `code` | El stream de captura de la pista falló con ese error (dominio y código del `NSError`). La pista sigue en un segmento nuevo, que tiene su propio `segmentStarted`. |
| `paused` | `reason` | La captura se detuvo en todas las pistas, que cierran su segmento como `paused`. `reason` es `willSleep` (la Mac va a entrar en reposo) o `screenLocked`, que cubre dos cosas: la pantalla se bloqueó, o las pantallas se apagaron (las dos se pliegan en un solo estado, que termina solo cuando la pantalla está desbloqueada y encendida, así encender las pantallas sobre la pantalla de bloqueo no reanuda nada). Mientras se graba, la app no deja que las pantallas se apaguen solas por inactividad, así que eso pasa solo si el usuario las apaga o bloquea la Mac. Con varios motivos a la vez hay un solo `paused` y un solo `resumed`. Un lector no falla ante un `reason` que no conoce. |
| `resumed` | | La captura volvió después de `paused`; cada pista abre un segmento nuevo. Entre un `paused` y su `resumed` no se graba nada: tampoco hay eventos `cursor`, `mouseDown` ni `mouseUp` (privacidad: ni la pantalla de bloqueo ni sus clics). |
| `deviceChanged` | `track`, `deviceUniqueID` | La pista siguió grabando desde otro dispositivo (el `uniqueID` del dispositivo de audio), por ejemplo porque se desconectó el micrófono. |
| `marker` | | Una marca que el usuario puso mientras grababa. |
| `droppedSamples` | `track`, `count` | Total de muestras (cuadros o bloques de audio) que la pista `track` perdió hasta ahora en su segmento actual, el que abrió su último `segmentStarted`. Se escribe cada 2 s mientras se graba, solo si cambió, y no toca el manifiesto: es lo que la recuperación usa como `droppedFrames` de un segmento que la app no llegó a cerrar. |
| `audioClock` | `track`, `frame` | La muestra número `frame` del archivo del segmento actual de la pista de audio `track` (contando desde 0, la muestra de `startHostTime`) se capturó en `t`. El archivo de audio solo cuenta muestras y el reloj del dispositivo no va exactamente al ritmo del host, así que la grabación escribe uno cada 5 s de audio de cada segmento, con el instante del bloque que empieza en esa muestra, y el export ubica el audio por host time interpolando entre ellos (ver [Tiempos](#tiempos)). `frame` cuenta solo las muestras escritas en el archivo, así que el audio que el escritor descarta en tiempo real (su cola llena) no corre las anclas: cada una nombra una muestra que está en el archivo. Un lector descarta un ancla que no avanza en `frame` y en `t` respecto de la última que usa, o que se aparta más de 5000 ppm de la frecuencia del archivo respecto de la anterior. |

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

## Cierre de una toma

La regla es la de los segmentos: el manifiesto dice que algo terminó solo cuando eso ya está en el disco. Al cerrar una toma, en este orden:

1. se detienen las fuentes y el registro de cursor y clics, y cada pista cierra su segmento (forzado a disco con `F_FULLFSYNC` antes de anotar su `endHostTime` y `endReason`);
2. se escriben las últimas líneas de `events.jsonl`, que se fuerza a disco con `F_FULLFSYNC` y se cierra;
3. la toma se marca `complete` en el manifiesto;
4. se suelta el lock (se borra `recording.lock` y se cierra).

La recuperación nunca toca una toma `complete`, así que si la app muere entre 2 y 3 la toma queda `recording` y se recupera con su `events.jsonl` entero; al revés, se perderían para siempre sus últimas líneas.
- Un `.reserve` que quedó en disco después de un crash no significa nada: la recuperación lo ignora y lo borra.

## Recuperación después de un crash

Una toma con `status` `recording` cuyo `recording.lock` no tiene nadie quedó abierta porque la app murió. La recuperación la cierra con lo que hay en el disco, sin borrar ni reescribir datos crudos:

- Antes de tocar nada comprueba las rutas (ver [Rutas](#el-paquete)): con un `id`, un `file` o un enlace simbólico que podrían sacarla del paquete, no cambia nada y no crea nada fuera de él. `events.jsonl` se abre con `O_NOFOLLOW` y tiene que ser un archivo común.
- Toma el lock de la toma mientras trabaja. No recupera nada mientras otra toma del mismo paquete se está grabando (su grabador es quien escribe `manifest.json`), y lo vuelve a comprobar, junto con que el manifiesto no haya cambiado, justo antes de escribirlo. Las tomas de un paquete se recuperan de a una y antes de grabar algo nuevo en él.
- No toca un manifiesto con un `formatVersion` mayor que el que conoce.
- Hace terminar `events.jsonl` en un límite de línea, como antes de agregarle líneas (ver arriba).
- Cierra cada segmento abierto (sin `endHostTime` o sin `endReason`) según lo que se puede leer de su archivo:
  - `recoveredAfterCrash`, con `endHostTime` igual a `startHostTime` más la duración legible, que llega hasta el último fragmento completo;
  - `empty` si el archivo tiene 0 bytes, no tiene ninguna muestra del tipo de su pista o ya no existe;
  - `unreadable` con `bytes` si el archivo no está vacío pero su contenido no se puede leer; el archivo queda intacto;
  - en `empty` y `unreadable`, `endHostTime` es igual a `startHostTime`;
  - `droppedFrames` es el último `droppedSamples` del segmento (0 si no hay) y `heartbeatFrames` es 0.
- Si un archivo de segmento existe pero no se puede examinar ni abrir (por ejemplo, por permisos), se detiene sin cambiar el manifiesto (puede haber borrado `.reserve` y cortado la cola de `events.jsonl`): la toma sigue `recording` y se puede recuperar cuando el archivo se pueda leer.
- Un archivo de una carpeta de pista que el manifiesto no lista se agrega como segmento solo si su nombre es exactamente el de un segmento (`seg-0002.mov`) y `events.jsonl` tiene su `segmentStarted`, cuyo `t` pasa a ser su `startHostTime`. Si no, nada dice cuándo empieza: queda fuera del manifiesto y sin tocar.
- Borra el `.reserve` de la toma.
- Marca la toma `recovered` y escribe el manifiesto una sola vez, con todo. Recuperar una toma que ya no está `recording` no cambia nada.

## Interfaz de render (congelada)

La vista previa del editor y el export MP4 dibujan con el mismo código, y desde la fase 0 su interfaz no cambia sin una migración: lo que un proyecto muestra hoy lo vuelve a mostrar igual una versión nueva.

- **Línea de tiempo** (`FrameEvaluator`). La pantalla es la primera pista `display` de la toma. El tiempo de salida 0 es el `startHostTime` de su primer segmento. La línea de tiempo termina en el final más tardío (el inicio, si el segmento sigue abierto) de un segmento de esa pantalla o de la primera pista `microphone`: el audio grabado después del último segmento de la pantalla (una pantalla que no volvió) se exporta sobre el último cuadro de la pantalla. Una toma sin segmentos de pantalla tiene una línea de tiempo de 0 s. Los tiempos de salida se recortan a `[0, duración]`. El cuadro de un tiempo es una función pura de la toma, sus eventos, el estilo y el tamaño de salida; la geometría es el `globalFrame` de la pantalla.
- **Cuadros de la pantalla** (`TrackFrameReader`). En un tiempo se muestra el último cuadro presentado en ese instante o antes. Un segmento `empty` o `unreadable`, un archivo que falta, uno que no se puede abrir o leer, y lo que no se pudo decodificar son huecos: se mantiene el cuadro anterior (o el fondo, antes del primer cuadro legible), y cada hueco se informa (`FrameRenderer.missingVideo`, `ExportSummary.missingVideo`). Si la lectura se corta con un error a mitad de un segmento, se vuelve a abrir justo después del último cuadro y, si se corta en el mismo lugar, cada vez `preroll` (1 s) más adelante, hasta decodificar o llegar al final del segmento.
- **Dibujo** (`FrameRenderer`, `Compositor`). Todo pasa por `FrameRenderer.encode(at:into:commandBuffer:)`, que dibuja con `Compositor.encode` en una textura `.bgra8Unorm` del tamaño de salida: `render(at:into:)` (un `CVPixelBuffer` 32BGRA, para el export) y `renderBytes(at:)` (bytes BGRA sin relleno) lo usan, igual que la vista previa. Mismo proyecto, mismo tiempo y mismo tamaño dan los mismos bytes en la vista previa y en el export.
- **Audio** (`MicrophoneTimeline`). El primer micrófono se ubica en la misma línea de tiempo por host time (ver [Tiempos](#tiempos)); lo que no se pudo usar queda en silencio y se informa (`ExportSummary.missingAudio`).

## Los datos crudos nunca se borran

Los segmentos y `events.jsonl` de una toma son los datos crudos, y ningún componente los borra ni los reescribe sin que el usuario lo pida: ni la grabación, ni la recuperación, ni una actualización de la app. Un archivo que no se puede leer se marca como `unreadable` en el manifiesto y queda en el disco tal cual estaba. La única excepción es la línea cortada al final de `events.jsonl` (ver arriba): son los bytes de una escritura que no terminó, no un evento, y se truncan antes de seguir escribiendo. Lo único que se puede borrar sin perder nada es `cache/`, porque todo lo que contiene se vuelve a calcular, y el `.reserve` de una toma, que es espacio vacío.

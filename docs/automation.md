# Automatizar Toma: la línea de comandos y el servidor MCP

Un proyecto de Toma se puede leer, editar y exportar sin abrir la app: desde Terminal con el comando `toma`, o desde un
agente (Claude Code, Claude Desktop o cualquier cliente MCP) con su servidor MCP, `toma mcp`. Los dos usan la misma API
que la app: los mismos comandos que los gestos del editor (cada uno un paso que se deshace con Edición ▸ Deshacer) y el
mismo export (voz limpia, sonoridad, máscaras de la cámara y música, preparados igual).

El formato del paquete, los comandos y los códigos de error están en [`docs/format/README.md`](format/README.md) («La API
y sus errores»); el esquema de los comandos, en
[`docs/format/schema/edit-command.schema.json`](format/schema/edit-command.schema.json).

## Instalar la línea de comandos

Toma lleva el comando adentro, en `Toma.app/Contents/Helpers/toma`. En Ajustes ▸ General, «Instalar la línea de
comandos» crea un enlace a él:

- en `/usr/local/bin/toma`, si esa carpeta existe y se puede escribir sin contraseña;
- si no, en `~/.local/bin/toma` (crea la carpeta). Esa carpeta tiene que estar en el `PATH`: por ejemplo, sumar
  `export PATH="$HOME/.local/bin:$PATH"` a `~/.zshrc`.

Nunca pide una contraseña ni pisa un `toma` ajeno. Si se mueve Toma.app, el enlace queda apuntando a la vieja: volver a
apretar el botón lo arregla. También se puede usar el binario directo, sin instalar nada:
`/Applications/Toma.app/Contents/Helpers/toma --version`.

```sh
toma --version        # 1.0
toma --help           # los subcomandos y los códigos de salida
```

## Los subcomandos

`<proyecto>` es la ruta de un paquete `.toma` (absoluta o desde la carpeta actual).

| Subcomando | Qué hace |
|---|---|
| `toma info <proyecto>` | Describe el proyecto: título, duración, tomas y pistas, la secuencia de clips, marcadores, capítulos, zoom, estilo, cámara, música y transcripción |
| `toma validate <proyecto>` | Comprueba que abre, las reglas de su documento, sus registros y los archivos que nombra; sale con 1 si no es válido |
| `toma transcript <proyecto>` | El texto que dice la salida; con `--json`, cada palabra con sus tiempos |
| `toma markers <proyecto>` | Los marcadores: su tiempo en la salida, su id y su nombre |
| `toma chapters <proyecto> [--youtube]` | Los capítulos que escribe el export (de los marcadores con nombre); con `--youtube`, como los lista una descripción de YouTube |
| `toma edit <proyecto> '<comando>'` | Aplica un comando JSON, por ejemplo `'{"command":"setAspect","aspect":"9:16"}'` |
| `toma edit <proyecto> --file <archivo>` | Aplica una lista de comandos en orden (`-` lee la entrada estándar); para en el primero que falla y lo hecho antes queda |
| `toma undo <proyecto>`, `toma redo <proyecto>` | Deshace o rehace el último paso, también uno hecho en la app |
| `toma export <proyecto> <salida>` | Exporta como la app (ver abajo) |
| `toma mcp` | El servidor MCP por la entrada y la salida estándar (ver abajo) |

Todos (menos `mcp`) aceptan `--json`: la salida estándar tiene entonces exactamente un documento JSON, el resultado o
`{"error": {"code": "…", "message": "…"}}`. Sin `--json`, un texto para leer; `edit` escribe una línea por comando a
medida que lo guarda.

**Códigos de salida:** 0 bien; 1 un error; 2 un error de uso (argumentos que no son los del subcomando, o un comando que
no es de la API: `invalidCommand`); 3 el proyecto lo está editando otro proceso (`locked`).

### Exportar

```sh
toma export Demo.toma ~/Desktop/demo                       # ~/Desktop/demo.mp4, H.264 1080p
toma export Demo.toma demo.mov --codec prores4444         # fondo transparente
toma export Demo.toma demo.gif --gif --size 640 --fps 15  # un GIF animado
```

- `--codec`: `h264` (por defecto) y `hevc` escriben un `.mp4`; `prores422`, `prores422hq`, `prores4444` y
  `hevc-alpha` un `.mov` (los dos últimos con el fondo transparente).
- `--size`: el lado corto de un video (720, 1080, 1440 o 2160; 1080 por defecto) o el lado largo de un GIF (480, 640,
  800, 1080, 1280 o 1920; 800 por defecto).
- `--fps`: el del proyecto por defecto (24, 25, 30, 50 o 60); para un GIF, 10, 15, 20, 25 o 30 (15 por defecto).
- `--quality`: `standard` o `high`.

Sin extensión se agrega la del formato; otra extensión es un error de uso. Un export nunca escribe dentro de un `.toma`;
un archivo que ya está en la salida se reemplaza cuando el nuevo está entero. El progreso sale por la salida de errores
como `progress: N %`, y ⌃C corta el export sin dejar archivo.

## El servidor MCP

`toma mcp` habla [MCP](https://modelcontextprotocol.io) (versión del protocolo `2025-06-18`) por la entrada y la salida
estándar: JSON-RPC 2.0, un mensaje por línea. La salida estándar lleva solo esos mensajes; cualquier otra cosa va a la
salida de errores. Termina cuando se cierra su entrada (o con SIGTERM), y antes cancela lo que está haciendo: un export a
medio hacer no deja archivo. No abre ningún puerto ni usa la red.

### Conectarlo a Claude Code

```sh
claude mcp add toma -- toma mcp
```

Con `--scope user` queda para todos los proyectos de Claude Code, no solo para la carpeta actual. Si `toma` no está en
el `PATH`, se le da la ruta entera: `claude mcp add toma -- /Applications/Toma.app/Contents/Helpers/toma mcp`. Dentro de
Claude Code, `/mcp` muestra si está conectado y sus herramientas.

### Conectarlo a Claude Desktop

En Claude Desktop, Ajustes ▸ Desarrollador ▸ Editar configuración abre
`~/Library/Application Support/Claude/claude_desktop_config.json`. Sumar el servidor:

```json
{
  "mcpServers": {
    "toma": {
      "command": "/usr/local/bin/toma",
      "args": ["mcp"]
    }
  }
}
```

y reiniciar Claude Desktop. Claude Desktop no lee el `PATH` de la terminal: `command` va con la ruta absoluta (con
`~/.local/bin`, `/Users/<usuario>/.local/bin/toma`; sin instalar, `/Applications/Toma.app/Contents/Helpers/toma`).
La carpeta de trabajo del servidor no es la de ningún proyecto: las rutas que se le pasan a las herramientas van
absolutas (o con `~`).

### Otros clientes

Cualquier cliente MCP por stdio: el comando es `toma` y el argumento `mcp`. El servidor responde `initialize` (siempre con
la versión `2025-06-18`), `ping`, `tools/list` y `tools/call`, y recibe las notificaciones `notifications/initialized` y
`notifications/cancelled`. Responde aunque no haya llegado `initialize`. Un arreglo de mensajes (un lote) es un error
`-32600`; una herramienta que no existe, `-32602`; un método que no existe, `-32601`; una línea que no es JSON, `-32700`
con `id: null`.

### Las herramientas

| Herramienta | Argumentos | Qué hace |
|---|---|---|
| `list_projects` | `folder`? | Los proyectos de la biblioteca (`~/Movies/Toma`) o de esa carpeta, hasta 4 niveles: ruta, nombre, duración, versión del documento, última modificación, o el problema que no lo deja abrir. Solo lee |
| `project_info` | `project` | Lo que dice `toma info --json`. Solo lee |
| `get_transcript` | `project` | La transcripción: idioma, texto y cada palabra con sus tiempos en la salida. Sin transcripción, `refused`. Solo lee |
| `get_markers` | `project` | Los marcadores, los capítulos y los capítulos como los lista YouTube. Solo lee |
| `apply_commands` | `project`, `commands` | Los comandos de la API, en orden, cada uno su paso; para en el primero que falla |
| `undo`, `redo` | `project` | Deshace o rehace el último paso del proyecto |
| `export_video` | `project`, `output`, `codec`?, `size`?, `fps`?, `quality`?, `gif`? | Exporta como `toma export` |

- **Resultados.** Cada resultado trae el JSON en `structuredContent` y el mismo JSON como texto en `content`. Las
  herramientas que solo leen llevan `readOnlyHint: true`.
- **Errores.** Lo que una herramienta rechaza vuelve como resultado con `isError: true` y
  `{"error": {"code": "…", "message": "…"}}`, con los códigos estables de la API (`notAProject`, `locked`,
  `invalidCommand`, `outOfRange`, `refused`…). Un argumento que la herramienta no toma, uno que falta o uno de otro tipo es
  `invalidCommand`. `apply_commands` con un comando que falla devuelve, con `isError: true`, los resultados de los que
  corrieron (`results`), el que falló (`failedIndex`, desde 0) y su `error`; un comando que no es de la API hace que no
  corra ninguno.
- **Tiempos.** En segundos de la salida tal como se reproduce cuando corre el comando: después de un `cut`, el resto se
  corre. Para encontrarlos sirven `project_info`, `get_transcript` (cada palabra con su `start` y `end`) y `get_markers`.
- **Progreso.** Un `export_video` puede tardar minutos. Si la llamada trae `_meta.progressToken`, el servidor manda
  `notifications/progress` con ese token, `progress` de 0 a 1 (sube con cada aviso) y `total: 1`, y ninguno después de la
  respuesta. `notifications/cancelled` con el `requestId` de la llamada la cancela: el export para, no queda archivo y no
  hay respuesta.
- **Rutas.** `project` es un paquete `.toma` con su `manifest.json`; ni el paquete ni el manifiesto pueden ser enlaces, y
  una ruta con `..` se rechaza (`notAProject`). `output` nunca puede caer dentro de un paquete (`refused`). Las rutas
  relativas son desde la carpeta de trabajo del servidor; `~` es la carpeta personal.
- **Un proyecto a la vez.** Las llamadas corren a la vez, pero las de un mismo paquete (aunque lleguen por rutas
  distintas) esperan su turno, en el orden en que llegaron. Ninguna deja el proyecto abierto entre llamadas: lo abre, hace
  lo suyo y lo cierra.
- **La app.** Si Toma tiene el proyecto abierto, tiene su `edit.lock`: `apply_commands`, `undo` y `redo` dan `locked`
  (cerrar el proyecto en Toma, o editarlo ahí). Leer y exportar funcionan igual, con lo que hay en disco.

### Sesión de ejemplo: Claude Code

Con el servidor agregado, en Claude Code:

> **Yo:** listá mis proyectos de Toma
>
> *Claude llama a `list_projects` sin argumentos:*
> `{"folder": "/Users/ana/Movies/Toma", "projects": [{"name": "Lanzamiento", "path": "/Users/ana/Movies/Toma/Lanzamiento.toma", "duration": 42.6, "documentVersion": 5, …}, …]}`
>
> **Claude:** Tenés 3 proyectos: «Lanzamiento» (42,6 s), …
>
> **Yo:** en Lanzamiento, cortá del segundo 2 al 4 y agregá un marcador «Demo» donde empieza el corte
>
> *Claude llama a `apply_commands`:*
> `{"project": "/Users/ana/Movies/Toma/Lanzamiento.toma", "commands": [{"command": "cut", "from": 2, "to": 4}, {"command": "addMarker", "at": 2, "name": "Demo"}]}`
> *y recibe los dos pasos:*
> `{"results": [{"command": "cut", "changed": true, "label": "delete", "duration": 40.6, …}, {"command": "addMarker", "changed": true, "created": "m-3f9a0c1e", "label": "marker.add", "duration": 40.6, …}]}`
>
> **Yo:** exportalo a MP4 en el Escritorio
>
> *Claude llama a `export_video` con `{"project": "…/Lanzamiento.toma", "output": "~/Desktop/Lanzamiento.mp4"}`; el
> resultado:*
> `{"path": "/Users/ana/Desktop/Lanzamiento.mp4", "format": "mp4", "codec": "h264", "width": 1920, "height": 1080, "duration": 40.6, "chapters": 2, …}`

Al abrir el proyecto en Toma se ven el corte y el marcador, y Edición ▸ Deshacer los deshace uno por uno. El video tiene
el capítulo «Demo», y antes uno de introducción («Introducción» si la transcripción está en español, «Intro» si no).

### Sesión de ejemplo: JSON-RPC a mano

Lo que pasa por la entrada (→) y la salida (←) de `toma mcp`, una línea por mensaje (acortadas con `…`):

```text
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}
← {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"Toma's screen recordings are .toma packages. …","protocolVersion":"2025-06-18","serverInfo":{"name":"toma","title":"Toma","version":"1.0"}}}
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"apply_commands","arguments":{"project":"/tmp/Demo.toma","commands":[{"command":"setTitle","title":"Prueba"},{"command":"cut","from":4,"to":3}]}}}
← {"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"{\"error\":{\"code\":\"outOfRange\",…},\"failedIndex\":1,\"results\":[…]}","type":"text"}],"isError":true,"structuredContent":{"error":{"code":"outOfRange","message":"cut: from has to be before to"},"failedIndex":1,"results":[{"changed":true,"command":"setTitle",…}]}}}
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"export_video","arguments":{"project":"/tmp/Demo.toma","output":"/tmp/demo.mp4","size":720},"_meta":{"progressToken":"e1"}}}
← {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0,"progressToken":"e1","total":1}}
← {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.01,"progressToken":"e1","total":1}}
← …
← {"id":3,"jsonrpc":"2.0","result":{"content":[…],"isError":false,"structuredContent":{"bytes":412977,"chapters":0,"codec":"h264","duration":10,"format":"mp4","framesPerSecond":30,"height":720,"path":"/tmp/demo.mp4","warnings":[],"width":1280}}}
```

Para probarlo a mano:
`printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | toma mcp` (al cerrarse la entrada, el servidor
termina).

## Variables de entorno

`toma` y `toma mcp` usan las mismas carpetas que la app: las cachés de análisis, la música, los estilos guardados, la
biblioteca y el socket de control. Para pruebas (o para usuarios avanzados), cada una se cambia con su variable:

| Variable | Por defecto |
|---|---|
| `TOMA_CACHES_ROOT` | Las cachés de análisis de los proyectos, `~/Library/Caches/dev.toma.Toma/Projects` |
| `TOMA_MUSIC_ROOT` | La caché de la biblioteca de música, `~/Library/Caches/dev.toma.Toma/Music` |
| `TOMA_STYLES` | Los estilos guardados en la app, `~/Library/Application Support/Toma/Styles` |
| `TOMA_PROJECTS_FOLDER` | La biblioteca, `~/Movies/Toma` (lo que lista `list_projects` sin carpeta) |
| `TOMA_CONTROL_SOCKET` | `~/Library/Application Support/dev.toma.Toma/control.sock` |

Con Claude Code: `claude mcp add toma -e TOMA_PROJECTS_FOLDER=/ruta/a/proyectos -- toma mcp`. En Claude Desktop, una clave
`"env": {"TOMA_PROJECTS_FOLDER": "/ruta/a/proyectos"}` junto a `command` y `args`.

## IA local: capítulos, título y resumen

`toma ai` y la herramienta `suggest_chapters` le piden al modelo del Mac (Apple Intelligence, macOS 26 o más; nada sale
del equipo) una propuesta a partir de la transcripción. **Solo proponen**: no tocan el proyecto. El resultado trae los
comandos listos (`addMarker`, `setTitle`, `setSummary`) para que quien los revisó los aplique con `toma edit --file` o
`apply_commands`.

| Subcomando | Qué propone |
|---|---|
| `toma ai chapters <proyecto> [--transcribe]` | Capítulos de 30 s en adelante, con título corto (hasta 40 caracteres) en el idioma de la transcripción, uno por línea con su tiempo |
| `toma ai title <proyecto> [--transcribe] [--variation N]` | Un título de hasta 70 caracteres; `--variation` 1, 2… da otros |
| `toma ai summary <proyecto> [--transcribe] [--variation N]` | Un resumen de 2 a 4 frases |

- **Transcripción.** Hace falta una. Sin ella, el error dice cómo hacerla; `--transcribe` la hace primero (edita el
  proyecto, en un paso que se deshace: con el proyecto abierto en Toma, sale con 3, `locked`).
- **Sin el modelo.** Sin Apple Intelligence, antes de macOS 26 o con un idioma que el modelo no escribe, sale con 1 y el
  código `notAvailable`, con el motivo («Apple Intelligence is not turned on», «the on-device model requires macOS 26»…).
  Lo mismo para un video de menos de un minuto (`too short for chapters`).
- **Tiempo.** Los capítulos de un video de 20 minutos tardan unos 30 segundos; el progreso va a la salida de errores
  (`progress: part 2 of 3`).

```
$ toma ai chapters ~/Movies/Toma/Tutorial.toma
00:00 Introducción
02:14 Instalar el paquete
05:40 Configurar el editor

$ toma ai chapters ~/Movies/Toma/Tutorial.toma --json > capitulos.json
$ python3 -c 'import json; print(json.dumps(json.load(open("capitulos.json"))["commands"]))' > comandos.json
$ toma edit ~/Movies/Toma/Tutorial.toma --file comandos.json
```

Con `--json`, `toma ai chapters` da `{"language", "chapters": [{"at", "time", "title"}], "skippedParts", "commands"}`
(`at` en segundos de la salida; `commands`, un `addMarker` por capítulo) y `title` y `summary` dan
`{"kind", "text", "command"}` con `setTitle` o `setSummary`.

**Desde un agente (MCP).** `suggest_chapters{project}` devuelve el mismo informe de capítulos (solo lee, y manda
`notifications/progress` por parte si la llamada trae `progressToken`). Un error vuelve con `isError: true` y su código,
`notAvailable` si falta el modelo o la transcripción. El agente muestra los capítulos y, con el visto bueno, manda los
`commands` a `apply_commands`:

```
→ tools/call suggest_chapters {"project": "~/Movies/Toma/Tutorial.toma"}
← {"chapters": [{"at": 0, "time": "0:00", "title": "Introducción"}, {"at": 134, "time": "2:14", "title": "Instalar el paquete"}],
   "commands": [{"command": "addMarker", "at": 0, "name": "Introducción"}, {"command": "addMarker", "at": 134, "name": "Instalar el paquete"}], …}
→ tools/call apply_commands {"project": "~/Movies/Toma/Tutorial.toma", "commands": [← los "commands" de arriba]}
```

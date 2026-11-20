# La biblioteca de música de Toma (`music-1`)

Toma trae seis temas propios para poner de fondo en un video (diseño de la fase 3, §7.6). No son archivos grabados: son
partituras escritas en código que la Mac sintetiza la primera vez que se usan, siempre con los mismos bytes. Duran dos
minutos cada uno, son estéreo a 48 kHz y se repiten sin costura.

## Los temas

| Id | Nombre | Estilo | Tempo | Compás | Compases |
|---|---|---|---|---|---|
| `calm` | Calma (Calm) | ambiental | 64 BPM | 4/4 | 32 |
| `focus` | Foco (Focus) | lo-fi | 80 BPM | 4/4 | 40 |
| `drive` | Impulso (Drive) | pop alegre | 112 BPM | 4/4 | 56 |
| `piano` | Piano (Piano) | piano mínimo | 72 BPM | 3/4 | 48 |
| `pulse` | Pulso (Pulse) | electrónica | 128 BPM | 4/4 | 64 |
| `breeze` | Brisa (Breeze) | cuerdas pulsadas | 96 BPM | 4/4 | 48 |

Cada uno dura exactamente 5 760 000 cuadros (120 s a 48 kHz) y cierra su frase en la vuelta. Un documento nombra un tema
como `library:music-1/<id>`; en la mezcla suena 14 dB por debajo de la voz (diseño §7.4).

Los seis están compuestos (tareas U2 y U3 del hito 3c): cada uno a −16 LUFS, con su costura de vuelta medida (±1 dB). Un
tema que todavía fuera un marcador (`MusicScore.isPlaceholder`) no se guarda nunca en la caché.

## Licencia

**La música está dedicada al dominio público con CC0 1.0 Universal**
(<https://creativecommons.org/publicdomain/zero/1.0/>): las composiciones de los seis temas y el audio que la app sintetiza
de ellas se pueden usar, cambiar y publicar, también con fines comerciales, sin pedir permiso ni nombrar a nadie. Un video
hecho con Toma que los usa no tiene ninguna restricción por la música.

El código que los sintetiza (el motor de `Packages/RecorderKit/Sources/Export/Music/`, las partituras de `Themes/` como
código) sigue con la licencia del proyecto, GPL-3.0-or-later.

## Cómo se hacen

El motor (`MusicSynth`) toma una partitura (`MusicScore`): partes, cada una un instrumento que toca notas, con una reverb y
un retardo para todo el tema.

- **Instrumentos propios:** un pad de sierras desafinadas con su filtro, un piano eléctrico de FM de dos operadores, un
  piano aditivo de parciales inarmónicos, una cuerda pulsada (Karplus-Strong), un bajo, una melodía, bombo, caja,
  platillos, palmas, shaker y el crujido de un disco. Efectos: una reverb de 8 líneas (FDN), un retardo estéreo a tempo y
  un chorus.
- **La versión del motor** (`MusicSynth.engineVersion`) sube con cualquier cambio del motor que cambie los bytes de una
  partitura; el digest fijado en `renderIsTheSameBytesEveryRun` suma una fila por versión.
- **Los mismos bytes en toda Mac:** todas las muestras salen de `+ − × ÷` y raíz cuadrada en `Double`, con polinomios
  propios para el seno, `exp2` y `tanh` (`SynthMath`) y la única aleatoriedad de SplitMix64 con semilla fija por tema y
  por nota. Nada de `sin`, `exp` o `pow` de libm ni de Accelerate, ningún reloj, y las voces que se calculan en varios
  hilos a la vez se suman siempre en el mismo orden. El build de depuración y el de release dan los mismos bytes.
- **Sin costura:** cada nota suena hasta su final real (una que empieza justo antes del final y sigue en la vuelta
  siguiente no se corta), se dibujan 8 s más después de la última, y todo lo que pasa del final (las notas ligadas, las que
  se apagan, la reverb, los ecos) se suma sobre el comienzo, donde la oiría la vuelta siguiente. Lo que se mueve a lo largo del tema (un filtro que se abre, un
  trémolo, el chorus) da un número entero de vueltas por vuelta del tema. Después solo hay pasos sin memoria: se quita la
  media de cada canal, se aplica la ganancia del tema y un recorte suave que deja todo pico bajo −1 dBFS.
- **Las medidas de un tema** (decisión 5 del plan 3c): −16 LUFS ± 1 integrados, pico ≤ −1 dBFS, ningún hueco de más de
  50 ms bajo −45 dBFS (Calma: −50), compatible en mono (correlación de 0,3 a 0,98), sin graves bajo 30 Hz ni agudos sobre
  16 kHz de más (≤ −25 dB y ≤ −35 dB del total).
- Sintetizar un tema lleva menos de medio segundo en un M5 Pro en release (de 180 a 340 veces el tiempo real; la meta es
  40). En un build de depuración, unas 6 veces el tiempo real.

## Dónde se guardan

En la caché de la app, `~/Library/Caches/dev.toma.Toma/Music/music-1/<id>-<huella>.caf` (`MusicLibrary`), enteros y
atómicos, fuera del hilo principal. La huella sale de la partitura y de la versión del motor: un tema que cambia (o un
motor nuevo) se vuelve a sintetizar y su versión vieja se borra. Un tema que todavía es un marcador no se guarda nunca. Si
macOS vacía la caché, se vuelven a sintetizar iguales y el export espera. El formato del archivo y sus reglas están en
`docs/format/README.md` ("La caché de la música").

## El id del algoritmo

`music-1` es el id del sonido de la biblioteca con su versión. Los bytes de cada tema se fijan en sus pruebas
(`samplesArePinned`) y pueden cambiar hasta que se publique la primera versión de Toma. Después, cualquier cambio que haga sonar
distinto un tema (una nota, un instrumento, el motor) es `music-2`: otra carpeta de la caché y otras fuentes
(`library:music-2/<id>`), y un documento que nombra `library:music-1/<id>` sigue sonando igual.

## Escucharlos

```
swift run -c release --package-path Packages/RecorderKit recorder-dev music --out /tmp/toma-music
afplay /tmp/toma-music/calm.caf
```

`recorder-dev music` escribe `<id>.caf` de los seis temas (o de uno, con `--theme <id>`) y por cada uno imprime cuánto
tardó, cuántas veces el tiempo real, su sonoridad, su pico, sus 50 ms más bajos, la correlación de sus lados, la energía
bajo 30 Hz y sobre 16 kHz, y la costura (el salto del último cuadro al primero junto al mayor salto de adentro, y el nivel
de sus primeros 50 ms sobre los últimos). En la app, la lista de la biblioteca toca cada tema antes de elegirlo.

## Escribir un tema

Cada tema es una función de `Themes/<Nombre>.swift` que devuelve su `MusicScore`. `MusicScore` (en `MusicScore.swift`)
explica las reglas: las notas empiezan dentro de la vuelta, todo se apaga dentro de los 8 s de cola, lo que se mueve va
en Hz y se redondea a vueltas enteras, la aleatoriedad sale de semillas. `ScoreBuilder` arma las notas: progresiones de
acordes (`Chord("Am7")`, con sus disposiciones), arpegios, baterías como texto (`"x---x---x---x---"`, con swing),
melodías como texto (`"C5 - E5 G5 | . A5 - -"`), y las corre, repite, transpone y humaniza. Los presets de cada
instrumento (`PadPreset.warm`, `PianoPreset.felt`, `PluckPreset.harp`, …) están en `SynthInstruments.swift`, con lo que hace
cada valor.

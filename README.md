# RAW Viewer

Native, non-destructive macOS photo viewer for camera RAW, JPEG, HEIC, PNG and TIFF files.

## Fotoindex und Vorschaubilder

Beim ersten Start fragt RAW Viewer nach einem Cache-Ordner. Dort werden ausschließlich
der SQLite-Fotoindex und erzeugte Vorschaubilder gespeichert; Originalfotos bleiben
unverändert. Ein Ordner auf einer lokalen SSD bietet die beste Leistung.

Bekannte Ordner werden sofort aus dem Index angezeigt und anschließend im Hintergrund
auf Änderungen geprüft. Unveränderte Dateien behalten ihre bereits gelesenen
Metadaten. Die Einstellungen erlauben einen anderen Cache-Speicherort, eine
Größenbegrenzung sowie das Löschen der Vorschaubilder oder den Neuaufbau des Index.

Nach dem Einlesen erzeugt die App zuerst die sichtbaren und anschließend alle übrigen
Vorschaubilder des ausgewählten Ordners im Hintergrund. Der Grid-Kopf zeigt Prüfung,
Fortschritt, Abschluss und gegebenenfalls fehlgeschlagene Vorschaubilder an.

## Lokale Fotoanalyse mit LM Studio

Unter **Einstellungen → KI-Analyse** lassen sich die Basisadresse eines lokalen oder
entfernten LM-Studio-Servers und die ID eines installierten Vision-Modells hinterlegen.
RAW Viewer prüft den Server beim Start. Eine lokale Instanz kann über die mit LM Studio
gelieferte `lms`-CLI im Hintergrund gestartet werden; ein entfernter Server muss bereits
als Dienst laufen.

Mit **Aktueller Ordner → fehlende Fotos analysieren** werden alle noch nicht bearbeiteten Fotos des aktuellen
Ordners nacheinander analysiert. Die Ordneraktion umfasst den ausgewählten Ordner und
alle seine Unterordner, nicht automatisch den gesamten Fotobestand. Vor dem Start zeigt
eine Bestätigung den genauen Ordner und die Anzahl der ausstehenden Fotos. Die Analyse
kann abgebrochen und später fortgesetzt werden. Die App lädt das gewählte Modell bei
Bedarf und entlädt es nach Abschluss wieder, sofern sie es selbst geladen hat. Schlagwörter,
Bildbeschreibung, Modell und Analysezeit werden im SQLite-Index des Cache-Ordners
gespeichert. Die Originalfotos bleiben unverändert.

Beim Laden verwendet RAW Viewer automatisch ein auf präzise Fotoanalyse abgestimmtes
Profil: 16.384 Kontext-Tokens, Temperature 0,1, Top P 0,8, Top K 20, Min P 0,
Repeat Penalty 1,0 und höchstens 2.048 Ausgabetokens. Samplingwerte werden bei jeder
Analyse an LM Studio übermittelt, da sie nicht Teil des Modell-Ladevorgangs sind.

Über **Aktueller Ordner → XMP-Sidecars aktualisieren** lassen sich die gespeicherten
Schlagwörter zusätzlich in portable `.xmp`-Dateien neben proprietären Kamera-RAWs wie
CR3, NEF, ARW oder RAF schreiben. Vorhandene XMP-Dateien werden eingelesen und nur um
fehlende Schlagwörter ergänzt; Lightroom-Einstellungen und manuelle Metadaten bleiben
erhalten. DNG sowie JPEG, HEIC, PNG und TIFF werden nicht über externe Sidecars geändert,
weil Lightroom Metadaten bei diesen Formaten üblicherweise in der Bilddatei erwartet.
Der Exportstatus liegt im SQLite-Index, sodass nach Abbruch oder Neustart nur noch
ausstehende beziehungsweise neu analysierte Fotos verarbeitet werden.

## Frühere Personendaten

Die experimentelle Gesichtserkennung und manuelle Personenzuordnung sind nicht mehr
Bestandteil von RAW Viewer. Falls ein älterer Katalog noch biometrische Einträge enthält,
können diese unter **Einstellungen → Cache → Alte Personendaten löschen** entfernt werden.

Die Schlagwörter erscheinen neben den Metadaten in der linken Informationsfläche. Das
Suchfeld findet Dateinamen, Dateitypen, Schlagwörter und Bildbeschreibungen. Für die
Netzwerknutzung sollte LM Studio 0.4 oder neuer auf dem Rack-Rechner als dauerhaft
laufender Dienst eingerichtet und nur in einem vertrauenswürdigen Netz freigegeben
werden.

## Build and run

```sh
./script/build_and_run.sh
```

Build, bundle and verify without launching:

```sh
./script/build_and_run.sh --build
```

Run the integrated test suite:

```sh
./script/build_and_run.sh --test
```

The build script requires a complete Xcode installation selected through
`xcode-select`. It uses Xcode's active Swift compiler and macOS SDK without a
project-specific SDK override. The current verified setup is Xcode 26.6,
Swift 6.3.3 and the macOS 26.5 SDK.

The generated app bundle is written to `dist/RAW Viewer.app`.

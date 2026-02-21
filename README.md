# TOSOT/GREE WiFi Reprovision Scripts

Diese Sammlung automatisiert das erneute Anlernen von TOSOT/GREE-Klimaanlagen, wenn das WiFi-Modul in den AP-Modus zurückfällt.

Die Skripte suchen regelmäßig nach bekannten Geräte-APs (z. B. `c6982a76`), verbinden sich damit und senden die WLAN-Konfiguration per UDP (`t=wlan`) an das Gerät.

## Enthaltene Skripte

- `tosot_wifi_reprovision.sh`
  - Für Linux-Systeme mit **NetworkManager** (`nmcli`)
- `tosot_wifi_reprovision_pi.sh`
  - Für **Raspberry Pi OS ohne nmcli**, mit `wpa_cli`/`iw`

## Unterstützte Geräte-APs

Aktuell vorkonfiguriert:

- `c699e72b` -> Buero
- `c6982a76` -> Hobbyzimmer
- `c699e6bf` -> Schlafzimmer

AP-Passwort ist pro SSID im Skript konfigurierbar (`GREE_AP_PSW`).

## Funktionsweise (kurz)

1. AP-SSIDs werden gescannt.
2. Bei Treffer wird Verbindung zum Klima-AP aufgebaut.
3. Payload wird mehrfach per UDP an Port `7000` gesendet.
4. Erfolg wird heuristisch geprüft: AP verschwindet anschließend (verlässt AP-Modus).

## Voraussetzungen

### 1) `tosot_wifi_reprovision.sh` (Desktop/Server Linux)

Benötigt:

- `bash` (v4+)
- `nmcli` (NetworkManager)
- `ip`
- `iw`
- `nc`
- `ping`

### 2) `tosot_wifi_reprovision_pi.sh` (Raspberry Pi)

Benötigt:

- `bash` (v4+)
- `wpa_cli` + laufender `wpa_supplicant`
- `iw`
- `ip`
- `nc`
- `ping`

Hinweis: Pi-Skript als root starten (`sudo`), da WLAN-Steuerung sonst oft scheitert.

## Konfiguration

Standard-Zielnetz (im Skript / per Env/CLI überschreibbar):

- `TARGET_SSID`
- `TARGET_PSW`

`.env` wird automatisch geladen (Standardpfad: `./.env`). Alternativ:

- `ENV_FILE=/pfad/zur/datei.env ./tosot_wifi_reprovision.sh`
- `ENV_FILE=/pfad/zur/datei.env sudo ./tosot_wifi_reprovision_pi.sh`

Wichtige Laufzeitparameter:

- `CHECK_INTERVAL` (Scan-Intervall, Default `60`)
- `SEND_RETRIES` (UDP-Versuche, Default `12`)
- `SEND_INTERVAL` (Abstand zwischen Sends)
- `INITIAL_SEND_WAIT` (Wartezeit nach AP-Connect)
- `VERIFY_TIMEOUT` / `VERIFY_SCAN_INTERVAL` (Erfolgsprüfung)
- `AP_IP_CANDIDATES` (Default `192.168.1.1 192.168.0.1`)

## Nutzung

### Hilfe

```bash
./tosot_wifi_reprovision.sh --help
./tosot_wifi_reprovision_pi.sh --help
```

### Nutzung mit `.env` (empfohlen)

```bash
cp .env.example .env
chmod 600 .env
```

Danach Werte in `.env` setzen und starten:

```bash
./tosot_wifi_reprovision.sh
sudo ./tosot_wifi_reprovision_pi.sh
```

### Desktop/Server Linux (mit nmcli)

```bash
./tosot_wifi_reprovision.sh \
  --target-ssid "MeinWLAN" \
  --target-psw "MeinPasswort" \
  --check-interval 60 \
  --send-retries 12
```

### Raspberry Pi

```bash
sudo ./tosot_wifi_reprovision_pi.sh \
  --target-ssid "MeinWLAN" \
  --target-psw "MeinPasswort" \
  --check-interval 60 \
  --send-retries 12
```

## Autostart auf Raspberry Pi (systemd)

Service-Datei:

`/etc/systemd/system/tosot-wifi-reprovision.service`

```ini
[Unit]
Description=Tosot WiFi Reprovision (Pi)
After=network-online.target wpa_supplicant.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/pi
ExecStart=/pfad/zu/tosot_wifi_reprovision_pi.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
```

Aktivieren:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tosot-wifi-reprovision.service
sudo systemctl status tosot-wifi-reprovision.service
sudo journalctl -u tosot-wifi-reprovision.service -f
```

## Typische Fehlerbilder

- **AP wird gesehen, aber keine Provisionierung wirkt**
  - `AP_IP_CANDIDATES` prüfen (`192.168.1.1` vs `192.168.0.1`)
  - `SEND_RETRIES` erhöhen (z. B. `15` bis `20`)

- **Verbindungscheck läuft hoch, obwohl verbunden**
  - War bereits gefixt: nur echtes WLAN-Interface wird ausgewertet, nicht `p2p-dev-*`.

- **Pi: keine Steuerung via `wpa_cli`**
  - `sudo systemctl status wpa_supplicant`
  - Interface prüfen: `iw dev`

## Sicherheitshinweise

- Passwörter stehen ggf. im Klartext (CLI, Env, Skript).
- Skriptzugriff auf vertrauenswürdige Benutzer beschränken.
- Optional eigene `.env`/Service-Umgebungsdatei mit restriktiven Rechten verwenden.

## Anpassungen

- Geräte-SSID + AP-Passwort: in `GREE_AP_PSW`
- Anzeigename pro Gerät: in `GREE_AP_LABEL`

## Lizenz

Private Nutzung / internes Projekt. Bei Bedarf ergänzen.

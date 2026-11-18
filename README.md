# MESIS menu API

Piccola API JSON che legge il menù mensile della ristorazione scolastica di Roma Capitale
(portale MESIS) usando un browser headless (Playwright/Chromium) e lo restituisce in JSON.

## Avvio

    docker compose up -d --build

## Endpoint

| Endpoint | Descrizione |
|---|---|
| `GET /menu?month=12&year=2026` | Menù dell'intero mese |
| `GET /menu/day?date=2026-12-01` | Menù di un singolo giorno (404 se festivo/senza menù) |
| `GET /health` | Healthcheck |

Parametri opzionali: `municipio`, `ciclo` (default 4 e 4, configurabili via env `MESIS_MUNICIPIO` / `MESIS_CICLO`),
`refresh=true` per saltare la cache (TTL default 6 ore, env `CACHE_TTL_SECONDS`).

Documentazione interattiva: `http://<host>:8000/docs`

## Esempio di risposta

    {
      "month": 11, "year": 2026, "municipio": 4, "ciclo_scolastico": 4,
      "school_year": "2026/2027",
      "title": "Menu mese di Novembre - MUNICIPIO ROMA III - INFANZIA",
      "days": [
        {"date": "2026-11-02", "weekday": "Lunedì", "meals": [
          {"name": "Spuntino", "items": ["Fette biscottate con cioccolata al latte/fondente"]},
          {"name": "Pranzo",   "items": ["Lasagna", "Fagiolini all'olio", "Pane", "Frutta"]},
          {"name": "Merenda",  "items": ["Frutta di stagione"]}
        ]}
      ]
    }

## Note

- Il parser (`app/parser.py`) dipende dalla struttura HTML attuale della pagina: se il Comune la cambia, va aggiornato.
- Se il sito risponde 403 al browser headless, prova a cambiare `BROWSER_USER_AGENT`.
- Su Proxmox: una VM o un LXC con Docker (con nesting attivo nel caso LXC), ~1 GB di RAM bastano.

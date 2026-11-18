import asyncio
import os
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from playwright.async_api import Error as PlaywrightError
from playwright.async_api import async_playwright

from .parser import parse_menu

BASE_URL = os.getenv(
    "MESIS_BASE_URL",
    "https://www.comune.roma.it/servizi/mesis-portal-reports-war/loadMenuMese.do",
)
DEFAULT_MUNICIPIO = int(os.getenv("MESIS_MUNICIPIO", "4"))
DEFAULT_CICLO = int(os.getenv("MESIS_CICLO", "4"))
CACHE_TTL = int(os.getenv("CACHE_TTL_SECONDS", str(6 * 3600)))
NAV_TIMEOUT_MS = int(os.getenv("NAV_TIMEOUT_MS", "45000"))
USER_AGENT = os.getenv(
    "BROWSER_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36",
)

state: dict = {}
cache: dict[tuple, tuple[float, dict]] = {}
sem = asyncio.Semaphore(2)  # al massimo 2 pagine contemporanee: la RAM del LXC/VM ringrazia


@asynccontextmanager
async def lifespan(app: FastAPI):
    pw = await async_playwright().start()
    state["pw"] = pw
    state["browser"] = await pw.chromium.launch(args=["--no-sandbox"])
    yield
    await state["browser"].close()
    await pw.stop()


app = FastAPI(title="MESIS menu API", version="1.0.0", lifespan=lifespan)


async def fetch_html(month: int, year: int, municipio: int, ciclo: int) -> str:
    url = f"{BASE_URL}?municipio={municipio}&cicloScolastico={ciclo}&dataSelezionata=01/{month:02d}/{year}"
    context = await state["browser"].new_context(user_agent=USER_AGENT, locale="it-IT")
    try:
        page = await context.new_page()
        await page.goto(url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT_MS)
        try:
            await page.wait_for_selector("#zonaMenuMese", timeout=NAV_TIMEOUT_MS)
        except PlaywrightError:
            # se il mese non ha menù la zona potrebbe mancare: restituisco comunque l'HTML
            pass
        return await page.content()
    finally:
        await context.close()


async def get_menu(month: int, year: int, municipio: int, ciclo: int, refresh: bool) -> dict:
    key = (month, year, municipio, ciclo)
    hit = cache.get(key)
    if hit and not refresh and time.time() - hit[0] < CACHE_TTL:
        return hit[1]

    async with sem:
        try:
            html = await fetch_html(month, year, municipio, ciclo)
        except PlaywrightError as e:
            raise HTTPException(502, f"Errore nel caricare la pagina MESIS: {e}") from e

    try:
        data = parse_menu(html)
    except ValueError as e:
        raise HTTPException(404, f"Nessun menù trovato per {month:02d}/{year}") from e

    result = {
        "month": month,
        "year": year,
        "municipio": municipio,
        "ciclo_scolastico": ciclo,
        "fetched_at": int(time.time()),
        **data,
    }
    cache[key] = (time.time(), result)
    return result


@app.get("/menu")
async def menu(
    month: int = Query(..., ge=1, le=12),
    year: int = Query(..., ge=2000, le=2100),
    municipio: int = Query(DEFAULT_MUNICIPIO, ge=1),
    ciclo: int = Query(DEFAULT_CICLO, ge=1),
    refresh: bool = False,
):
    """Menù dell'intero mese. Es: /menu?month=12&year=2026"""
    return await get_menu(month, year, municipio, ciclo, refresh)


@app.get("/menu/day")
async def menu_day(
    date: str = Query(..., pattern=r"^\d{4}-\d{2}-\d{2}$", description="YYYY-MM-DD"),
    municipio: int = Query(DEFAULT_MUNICIPIO, ge=1),
    ciclo: int = Query(DEFAULT_CICLO, ge=1),
):
    """Menù di un singolo giorno. Es: /menu/day?date=2026-11-18"""
    year, month = int(date[:4]), int(date[5:7])
    data = await get_menu(month, year, municipio, ciclo, False)
    for d in data["days"]:
        if d["date"] == date:
            return d
    raise HTTPException(404, f"Nessun menù per il {date} (festivo o giorno non scolastico)")


@app.get("/health")
async def health():
    return {"status": "ok"}

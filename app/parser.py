"""Parser della pagina MESIS (menù mensile) -> struttura JSON.

La pagina è composta da una lunga sequenza di tabelle a cella singola dentro
#zonaMenuMese. Ogni cella è di uno di tre tipi:
  - intestazione giorno : <td style="background-color:..."> con <strong> ("Lunedì 02/11/2026")
  - intestazione pasto  : <strong><span style="color: #8E001C"> ("Spuntino", "Pranzo", "Merenda")
  - piatto              : <span> semplice, senza <strong>
"""
import re
from datetime import datetime

from bs4 import BeautifulSoup

DAY_RE = re.compile(r"^(?P<weekday>\w+)\s+(?P<date>\d{2}/\d{2}/\d{4})$", re.UNICODE)


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def parse_menu(html: str) -> dict:
    soup = BeautifulSoup(html, "lxml")

    # Intestazioni informative (anno scolastico, "Menu mese di Novembre - MUNICIPIO ... - INFANZIA")
    headings = [_clean(h.get_text()) for h in soup.select("h4.u-text-h4")]
    school_year = next((h.replace("Anno scolastico", "").strip() for h in headings if h.startswith("Anno scolastico")), None)
    title = next((h for h in headings if h.startswith("Menu mese")), None)

    zone = soup.find(id="zonaMenuMese")
    if zone is None:
        raise ValueError("Elemento #zonaMenuMese non trovato: pagina diversa dal previsto")

    days: list[dict] = []
    day = None
    meal = None

    for table in zone.find_all("table"):
        td = table.find("td")
        if td is None:
            continue
        text = _clean(td.get_text(" "))
        if not text:
            continue
        is_bold = td.find("strong") is not None

        m = DAY_RE.match(text) if is_bold else None
        if m:
            date = datetime.strptime(m["date"], "%d/%m/%Y").date().isoformat()
            day = {"date": date, "weekday": m["weekday"], "meals": []}
            days.append(day)
            meal = None
        elif is_bold:
            if day is None:
                continue
            meal = {"name": text, "items": []}
            day["meals"].append(meal)
        else:
            if meal is None:
                # testo libero senza pasto (es. "Menu non previsto"): lo tengo come nota del giorno
                if day is not None:
                    day.setdefault("notes", []).append(text)
                continue
            meal["items"].append(text)

    return {
        "school_year": school_year,
        "title": title,
        "days": days,
    }

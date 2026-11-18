# L'immagine Playwright include già Chromium e le librerie di sistema.
# La versione deve combaciare con quella di playwright in requirements.txt.
FROM mcr.microsoft.com/playwright/python:v1.49.1-noble

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

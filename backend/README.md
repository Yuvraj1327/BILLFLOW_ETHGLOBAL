# BillFlow backend
See `../docs/BACKEND_API.md` for the full guide. Run: `cp .env.example .env` (fill it in) · `pip install -r requirements.txt` · `uvicorn app.main:app --reload` · Swagger at `/docs`.
Indexer: `python -m app.workers.blockchain_indexer`. Tests: `pip install -r requirements-dev.txt && pytest`.

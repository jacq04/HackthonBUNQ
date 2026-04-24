# kitty-backend

FastAPI orchestrator for Kitty (bunq Hackathon 7.0). See the [repo README](../README.md) and [CLAUDE.md](../CLAUDE.md) for the full picture.

```bash
../start.sh           # recommended — full dev boot
uvicorn app.main:app  # once deps are installed, if you only want the backend
pytest                # tests
ruff check .          # lint
```

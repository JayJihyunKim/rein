# `AGENTS.md` examples

> Per-directory `AGENTS.md` files give Claude Code language- and stack-specific
> rules that automatically load when work happens inside that directory tree.

Rein itself ships hooks, rules, and skills via the Claude Code plugin — those
live in the plugin cache and you don't author them. The `AGENTS.md` files
**in your own repo** are entirely yours; Rein reads them but never overwrites
them. Use them to encode your project's stack, commands, and forbidden
patterns.

---

## Required sections

Every per-directory `AGENTS.md` should have:

- **Tech stack** — language, framework, versions
- **Commands** — dev / build / test / lint
- **Directory layout**
- **Coding rules** — language- or framework-specific
- **Forbidden patterns**

Claude Code will load the *nearest* `AGENTS.md` walking upward from the file
being edited, so a `frontend/AGENTS.md` only applies inside `frontend/`.

---

## Example A — Next.js / TypeScript frontend

```markdown
# frontend/AGENTS.md — Next.js / TypeScript rules

## Tech stack
- Framework: Next.js 15 (App Router)
- Language: TypeScript 5.x
- Styling: Tailwind CSS + shadcn/ui
- State: Zustand (client) / React Query (server)
- Testing: Vitest + Testing Library
- Lint: ESLint + Prettier

## Commands
npm run dev / build / test / lint / type-check

## Layout
app/           — App Router pages
components/    — reusable UI (ui/ for shadcn primitives, [feature]/ for app code)
hooks/         — custom React hooks
lib/           — utilities
store/         — Zustand stores
types/         — shared TypeScript types

## TypeScript rules
- No `any` — use `unknown` or a concrete type
- Component props must be `interface`s
- Centralise API response types in `types/`
- `as` assertions need a comment explaining why

## Component rules
- Server vs client components must be explicit
- Client components start with `'use client'`
- File name = PascalCase, one default export per file

## Forbidden
- `pages/` directory (App Router only)
- Data fetching in `useEffect` (use React Query)
- Inline `style={{}}` (use Tailwind)
- `console.log` in production code
```

---

## Example B — Python / FastAPI backend

```markdown
# api/AGENTS.md — Python API rules

## Tech stack
- Language: Python 3.12+
- Framework: FastAPI
- ORM: SQLAlchemy 2.x (async)
- Validation: Pydantic v2
- Testing: pytest + httpx
- Lint: Ruff + mypy

## Commands
uvicorn main:app --reload     # dev server
pytest                        # tests
ruff check . --fix            # lint + autofix
ruff format .                 # format
mypy .                        # type-check

## Layout
app/
  routers/        — FastAPI routers (one file per resource)
  models/         — SQLAlchemy models
  schemas/        — Pydantic request/response schemas
  services/       — business logic
  repositories/   — DB access layer
  core/           — settings, dependencies, middleware
tests/
  unit/ integration/
alembic/          — DB migrations

## Python rules
- Type hints required on every function signature
- Use `async`/`await` consistently — no mixing with sync
- Validate every external input via Pydantic
- Inject dependencies via FastAPI `Depends()`
- DB queries only inside the repository layer

## Forbidden
- String-concatenated SQL — use SQLAlchemy or parameterised queries
- Business logic in routers — push it to `services/`
- Module-level mutable state
- `print()` for debugging — use `logging`
```

---

## Example C — ML pipeline

```markdown
# ml/AGENTS.md — ML pipeline rules

## Tech stack
- Language: Python 3.12+
- ML framework: PyTorch / scikit-learn
- Experiment tracking: MLflow or Weights & Biases
- Data versioning: DVC
- Testing: pytest

## Commands
python train.py --config configs/default.yaml   # train
python evaluate.py --model <checkpoint>          # evaluate
dvc repro                                        # rerun pipeline
pytest tests/                                    # tests

## Layout
configs/          — YAML experiment configs
data/             — DVC-tracked datasets (raw/, processed/)
models/           — model definitions
pipelines/        — train / eval pipelines
notebooks/        — exploratory only
tests/

## ML rules
- All experiments parameterised via YAML configs — no hard-coded hyperparameters
- Every training run logs to MLflow / W&B
- Reproducibility: fix the random seed and store it in the config
- Manage data with DVC — never commit raw datasets to Git

## Forbidden
- Production code in Jupyter notebooks (notebooks are exploratory)
- Committing training data to Git
- Versioning experiments by filename (`model_v3_final.pt`)
- Training runs without a fixed random seed
```

---

## Tips

- Start with one root `AGENTS.md` covering project-wide rules. Split into
  per-directory files only when you have language- or framework-specific rules
  worth isolating.
- Keep each file under ~150 lines. If it grows beyond that, the rules are
  probably mixing concerns — split or push detail into `trail/decisions/`.
- When a rule fires twice in incidents, promote it from `trail/incidents/` to
  the relevant `AGENTS.md` so Claude picks it up automatically next time.

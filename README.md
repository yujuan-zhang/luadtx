# LUADtx — LUAD Precision Platform

An end-to-end targeted-therapy matching / neoantigen vaccine design pipeline for lung adenocarcinoma
(LUAD). Upload a somatic VCF, a tumor expression matrix, and HLA typing — one request (~2–5 minutes)
returns ranked drug matches, ranked neoantigen candidates, a designed vaccine peptide, and KEGG pathway
visualizations.

**Live app: https://luadtx.stoichioomics.com/** (real domain, real HTTPS — the same code described below)

## Table of Contents

- [Architecture](#architecture)
- [Current Status](#current-status)
- [Pipeline Details](#pipeline-details)
- [Pipeline Funnel](#pipeline-funnel)
- [Pathway Visualization](#pathway-visualization)
- [Data Persistence (Postgres)](#data-persistence-postgres)
- [Quickstart — Local, Bare Python](#quickstart--local-bare-python)
- [Quickstart — Local, Docker](#quickstart--local-docker)
- [Deployment](#deployment)
- [Precomputed Demo Results](#precomputed-demo-results)
- [Project Structure](#project-structure)
- [Known Limitations](#known-limitations)

## Architecture

```
                     ┌─────────────────────────────────────┐
   Browser   ──HTTPS──▶│  nginx (80/443, Let's Encrypt TLS)   │
                     └───────────────┬───────────────────┬─┘
                          /  (UI)    │        /api/ (direct API)
                                     ▼                    ▼
                     ┌──────────────────────┐   ┌──────────────────────┐
                     │ frontend (Streamlit) │──▶│ backend (FastAPI)    │
                     │  upload / results /  │   │  the real pipeline:  │
                     │  Patient-Case card    │   │  VEP/UniProt/CIViC/  │
                     └──────────────────────┘   │  mhcflurry/pvactools │
                                                 └──────────┬───────────┘
                                                             ▼
                                                 ┌──────────────────────┐
                                                 │ postgres              │
                                                 │  every result → JSONB │
                                                 └──────────────────────┘
```

Five Docker containers (`docker-compose.yml`): `nginx`, `certbot` (automatic Let's Encrypt renewal),
`frontend`, `backend`, `postgres`. `frontend` / `backend` / `postgres` publish no host ports — everything
talks over Docker's internal network. **nginx is the only public entry point.**

## Current Status

Phase 4 — full real pipeline, running persistently in the cloud.

The built-in demo case is **TCGA-38-4627** (real results from an earlier `luad_workflow` run). A second
real test case, **TCGA-05-4244**, is also bundled (`data/uploads/TCGA-05-4244/`) — real MAF-derived
variants, real RNA-seq TPM, and real GDC clinical data, downloaded and converted from GDC's Open Access
tier the same way as the demo case.

- `data/demo/variants.vcf.gz` — 25 real protein-altering somatic variants, unannotated raw VCF with real
  DNA VAF in `INFO` (matches the intended design: users upload a VCF, the VEP API does the annotation)
- `data/demo/expression.tsv.gz` — real genome-wide tumor expression (TPM + GTEx-lung z-score/percentile)
- `data/demo/hla.tsv` — **synthetic HLA** (no real HLA typing exists for this case; labeled as synthetic
  by design)
- `data/demo/case_metadata.json` — real GDC clinical data (age, sex, stage, vital status, smoking
  history); missing fields are shown as "Not available", never guessed

## Pipeline Details

`vep.py` calls the real Ensembl VEP REST API (`rest.ensembl.org/vep/human/region`, free, no token,
GRCh38). `canonical=1` pins annotation to each gene's canonical transcript; `gene` / `consequence` /
`functional_impact` (VEP's native HIGH/MODERATE/LOW/MODIFIER tiering) come straight from the response.
`protein_change` is built from the returned `amino_acids` + `protein_start` rather than requesting HGVS
strings (the `hgvs=1` option 500s on this endpoint). DNA VAF isn't a VEP concept at all — it's read
directly from the input VCF's own `INFO/VAF` field, the same way a real variant caller would produce it.
`hotspot` isn't derived from the API response either — COSMIC co-location (`colocated_variants[].somatic`)
flags almost any observed somatic variant, not just recurrent drivers, so it's checked against a small,
curated, conservative LUAD driver hotspot table (`_KNOWN_LUAD_HOTSPOTS`) — the same pattern as
`civic.DRUG_KB`. A failed API call raises rather than silently degrading into fake annotations.

`civic.py` is a real implementation: a curated drug knowledge base plus live CIViC (civicdb.org) GraphQL
queries — no OncoKB token required. Every protein-altering variant needs its own CIViC lookup, and a real
case can easily have 100+ of them — **this step is concurrent** (`ThreadPoolExecutor`, 10 workers), not
sequential; it was the single largest measured bottleneck in the whole pipeline before this change.

`pvactools.py` is also a real implementation:
- **Mutant peptide** — fetched from UniProt REST (real protein sequence, free, no token) for the gene's
  canonical sequence, substituted at the mutated residue, sliced into a real flanking peptide. Missense
  variants only (stop_gained/frameshift/splice produce an entirely new downstream sequence that would
  need real CDS-level modeling to get right; those are skipped rather than faked).
- **MHC binding** — real `pvactools` (7.1.2) is installed, using its `mhcflurry` dependency's real trained
  model to compute IC50. Not via the full `pvacseq run` pipeline (that path needs real VEP annotation plus
  the Wildtype/Frameshift plugins, which this project doesn't have) but by batch-calling
  `mhcflurry-predict` directly — the same model pVACtools' own wrapper class calls internally. Verified
  against classic strong-binding CMV/influenza epitopes.
- mhcflurry install pitfall: its model uses the old TF1 Keras API, which Keras 3 removed. Fixed with the
  `tf-keras` compatibility layer + `TF_USE_LEGACY_KERAS=1` (already handled in `pvactools.py`).
- Model weights (135MB+, not committed to git — over GitHub's 100MB file limit, and it's a third-party
  release artifact, not something this project produces) are baked into the image at **Docker build time**
  (see `Dockerfile`) — containers are ready to go with no extra download. Running bare-metal locally needs
  one manual fetch:
  ```bash
  mhcflurry-downloads fetch models_class1_presentation
  ```
- **Vaccine construct** (`design_vaccine_construct()`) — chains the top 5 neoantigen candidates into one
  vaccine peptide. The core problem: the join between two peptides can accidentally create a new,
  unintended strong-binding epitope (a "junctional epitope") — this is what pVACtools' own `pvacvector`
  tool solves, but its CLI is not called directly: measured, it reloads the MHCflurry model in a fresh
  process for every (HLA allele × epitope length × spacer) combination, taking 1.5+ hours for this case's
  candidate set (5 candidates × 6 HLA alleles) — the same per-call model-reload cost that made pVACtools'
  own wrapper class slow elsewhere in this project (10+ minutes vs. tens of seconds batched), just far
  more severe here. Same fix: every candidate junction (peptide pair × spacer) is batched into one
  `_run_mhcflurry` call, then all 120 orderings of the 5 candidates (5! — brute force, no simulated
  annealing needed at this scale) are evaluated to pick the ordering + spacer combination that maximizes
  the weakest junction's binding score. Real MHCflurry model, real "avoid a strong accidental binder"
  objective — just not a reimplementation of pVACvector's own simulated-annealing search or its
  multi-algorithm median scoring (irrelevant when only one algorithm, MHCflurry, is in use).

## Pipeline Funnel

`main.py` reports how many variants are filtered out at each stage, not just the final three tables
(numbers are real, not fixed), with per-stage timing (`[timing]` log lines) so real bottlenecks are
visible rather than guessed at:

```
Protein-altering variants    25
Actionable variants           1   -> routed to drug_matches
Neoantigen candidates        24   -> routed to pvactools
Expressed variants           17   (TPM >= 1)
Real peptide generated        12  (missense only, real sequence fetched + position matched)
HLA-presented                 69  (IC50 <= 500nM, real mhcflurry prediction)
```

## Pathway Visualization

`pathway.py` (same design as `luad_workflow/modules/06_pathway/kegg_viewer.py`) overlays colored blocks on
locally cached KEGG official PNGs using Pillow — no call to pathview or Cytoscape. Pathway membership comes
from gseapy's `KEGG_2021_Human` gene set (cached locally, offline); the base images and gene-box
coordinates are real, downloaded via the KEGG REST API/KGML and cached in
`pipelines/downstream/kegg_cache/pathways/`.

Coverage: five of KEGG's own official BRITE categories directly relevant to cancer (Signal transduction /
Cancer: overview / Cancer: specific types / Cell growth and death / Immune system) — **79 pathways** total
(including KEGG's own Non-small cell lung cancer / Small cell lung cancer diagrams), not a hand-picked
subset — this is KEGG's own classification. Build script: `scripts/build_kegg_cache.py` (re-runnable;
network access happens only here — the build output, 79 × (PNG + coordinate JSON) ≈ 9.4MB, is committed
to the repo, and `pathway.py` reads it entirely offline at runtime). Only pathways that actually contain a
hit mutated gene are rendered. Color coding:

- Green = mutated gene
- Yellow = expressed (TPM ≥ 1)
- Red = highly expressed (TPM ≥ 5)
- A gene box matching multiple states is split into vertical color bands

`build_kegg_url()` also generates a link to KEGG's own colored pathway viewer as a fallback/cross-check.

## Data Persistence (Postgres)

`backend/db.py` handles the Postgres connection. Two tables: `cases` (case metadata, JSONB clinical
fields) and `analysis_results` (the complete output of every `/analyze` call, stored as one JSONB row with
`case_id` + `created_at`). Today this is a result archive, not a normalized data warehouse — there's no
split into per-entity tables (variants, drug_matches, …) and no cross-case aggregation.

`scripts/seed_postgres.py` creates the tables and seeds the demo case's metadata and precomputed result —
run once when setting up a fresh environment:

```bash
python -m scripts.seed_postgres
```

The connection string is read from the `DATABASE_URL` environment variable, falling back to the dev
default in `docker-compose.yml` when unset.

## Quickstart — Local, Bare Python

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mhcflurry-downloads fetch models_class1_presentation   # first time only, 135MB+

# 1. Smoke-test the downstream pipeline from the CLI (no server needed)
python -m pipelines.downstream.main

# 2. Bring up a local Postgres (or: docker compose up -d postgres) and seed it
python -m scripts.seed_postgres

# 3. Start the backend API (new terminal)
uvicorn backend.main:app --reload --port 8000

# 4. Start the frontend (another new terminal)
streamlit run frontend/streamlit_app.py
```

Open the URL Streamlit prints (default http://localhost:8501). It loads showing the TCGA-38-4627 demo
result instantly (read from a precomputed cache — see below). Upload your own VCF/expression/HLA (plus an
optional `case_metadata.json` for real clinical info) in the sidebar and click "Run analysis" to trigger a
real run against the backend (~2–5 minutes: real MHC binding prediction + vaccine construct design).

## Quickstart — Local, Docker

```bash
docker compose up -d --build
```

Brings up `postgres`, `backend`, and `frontend` together; `backend` creates its own tables on startup
(`db.init_db()`). There's no nginx/TLS layer locally by default — just expose whichever container's port
you need by adding a `ports:` mapping to it in `docker-compose.yml`.

## Deployment

### Production: AWS EC2 + CloudFormation (what luadtx.stoichioomics.com actually runs)

`infra/cloudformation.yaml` is the complete Infrastructure-as-Code definition — one command provisions
everything:

```bash
aws cloudformation deploy \
  --template-file infra/cloudformation.yaml \
  --stack-name luadtx --capabilities CAPABILITY_IAM \
  --parameter-overrides GitHubRepoUrl=https://github.com/yujuan-zhang/luadtx.git
```

What it creates: an EC2 instance (t3.medium / 20GB; UserData installs Docker, `git clone`s this repo, runs
`docker compose up --build`), an S3 backup bucket, a Secrets Manager secret (Postgres password,
auto-generated — never hardcoded or committed), an IAM role scoped to exactly that bucket, that secret,
that CloudWatch log group, and SSM (nothing more), a security group open only on 80/443 (**no SSH** —
remote shell access is via AWS Systems Manager Session Manager instead), CloudWatch Logs, an Elastic IP, a
Route 53 DNS record, and a Let's Encrypt certificate (`certbot`, webroot mode, with a containerized
renewal loop — no host cron dependency).

Tear-down is equally a single command, with nothing orphaned behind:

```bash
aws cloudformation delete-stack --stack-name luadtx
```

RDS and ECR are deliberately not used — Postgres runs as a container directly on the EC2 instance, and the
image is built on-instance rather than pulled from a registry. At this single-instance scale, both would
be unnecessary added cost and complexity.

### Demo: Streamlit Community Cloud (read-only, no server required)

`frontend/streamlit_app.py` itself only depends on `streamlit` / `pandas` / `requests` (it never imports
any pipeline code), so this deployment only needs the lightweight `frontend/requirements.txt` — no
`pvactools` / `tensorflow` / `mhcflurry`. This mode can only show the precomputed
`precomputed_result.json`; live analysis of an uploaded file needs a real backend, and `API_URL` (an
environment variable, unset here) falls back to `localhost:8000` — unreachable in this environment, so the
frontend degrades gracefully with a message instead of crashing.

To deploy: push the repo to GitHub, then in share.streamlit.io select this repo with **Main file path set
to `frontend/streamlit_app.py`** (Cloud auto-detects `requirements.txt` in the same directory).

## Precomputed Demo Results

The demo case's answer never changes, so there's no reason to re-run the real ~2-minute pipeline on every
page load. `scripts/precompute_demo.py` saves `run_pipeline()`'s output to
`data/demo/precomputed_result.json` (~550KB, committed to the repo); the frontend reads this file directly
by default for an instant load. Regenerate it after changing the demo data or pipeline logic:

```bash
python -m scripts.precompute_demo
```

## Project Structure

```
data/demo/                         Default case TCGA-38-4627: real VCF + real expression + synthetic HLA + real clinical + precomputed result
data/uploads/TCGA-05-4244/         Second real test case, for exercising the custom-upload path
scripts/seed_postgres.py           Create tables + seed demo data into Postgres
scripts/precompute_demo.py         Regenerate data/demo/precomputed_result.json
scripts/build_kegg_cache.py        Regenerate the KEGG pathway cache
pipelines/downstream/               Core analysis logic: vep.py / civic.py / pvactools.py / pathway.py / main.py (orchestrates all of them, with per-stage timing)
pipelines/downstream/kegg_cache/    KEGG pathway base images + gene-box coordinates (offline)
backend/main.py                    FastAPI; the /analyze endpoint; writes every result to Postgres
backend/db.py                      Postgres connection + schema + read/write
frontend/streamlit_app.py          Streamlit UI; API_URL is configurable (works unmodified across local / Streamlit Cloud / EC2)
frontend/requirements.txt          Lightweight deps for the cloud demo deployment (no pvactools/tensorflow)
Dockerfile                         Backend image (mhcflurry weights baked in at build time)
frontend/Dockerfile                Frontend image (lightweight, no tensorflow)
docker-compose.yml                 Orchestrates postgres + backend + frontend + nginx + certbot
nginx/conf.d/                      Reverse proxy config: / -> frontend, /api/ -> backend, HTTP->HTTPS redirect
infra/cloudformation.yaml          Complete AWS deployment IaC template (EC2/S3/Secrets Manager/IAM/security group/DNS/TLS)
```

## Known Limitations

- HLA typing in both bundled demo cases is **synthetic** — neither TCGA case has real HLA typing on file;
  this is clearly labeled in the UI, never presented as real.
- Neoantigen filtering uses a single IC50 threshold (≤500nM) — no percentile-rank filter, no wild-type
  vs. mutant binding-delta comparison, both of which a production `pvacseq` run would apply.
- `analysis_results` is an append-only JSONB archive, not a queryable, normalized schema — cross-case
  cohort analytics aren't supported yet.
- Drug-evidence sources are the curated KB and CIViC only; no OncoKB integration (it requires a licensed
  token this project doesn't have).
- No LICENSE file is currently present in this repository.

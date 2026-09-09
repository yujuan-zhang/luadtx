# LUADtx — LUAD Precision Platform

肺腺癌（LUAD）靶向治疗匹配 / neoantigen 疫苗设计一体化 pipeline。上传体细胞 VCF + 肿瘤表达矩阵 + HLA typing，
一次请求（~2-5 分钟）拿到：靶向药物匹配、neoantigen 候选排名、疫苗肽链设计、KEGG 通路可视化。

**在线体验：https://luadtx.stoichioomics.com/**（真实域名 + HTTPS，跟本 README 描述的是同一套代码）

## 整体架构

```
                     ┌─────────────────────────────────────┐
 用户浏览器  ──HTTPS──▶│  nginx (80/443, Let's Encrypt TLS)   │
                     └───────────────┬───────────────────┬─┘
                          /  (页面)  │           /api/ (直连API)
                                     ▼                    ▼
                     ┌──────────────────────┐   ┌──────────────────────┐
                     │ frontend (Streamlit) │──▶│ backend (FastAPI)    │
                     │  上传/结果展示/       │   │  真实 pipeline：      │
                     │  Patient-Case 卡片    │   │  VEP/UniProt/CIViC/  │
                     └──────────────────────┘   │  mhcflurry/pvactools │
                                                 └──────────┬───────────┘
                                                             ▼
                                                 ┌──────────────────────┐
                                                 │ postgres              │
                                                 │  每次分析结果存 JSONB │
                                                 └──────────────────────┘
```

五个 Docker 容器（`docker-compose.yml`）：`nginx`、`certbot`（Let's Encrypt 自动续期）、`frontend`、
`backend`、`postgres`。`frontend`/`backend`/`postgres` 不对外暴露端口，全部通过 Docker 内部网络通信，
**nginx 是唯一的公网入口**。

## 当前阶段：Phase 4 — 全链路真实 + 云上常驻

默认 demo 病例是 **TCGA-38-4627**（来自 `luad_workflow` 项目已经跑过的真实结果），另外还内置了
**TCGA-05-4244** 作为第二个真实测试病例（`data/uploads/TCGA-05-4244/`，同样是从 GDC Open Access
下载 + 转换出来的真实 MAF 变异 + 真实 RNA-seq TPM + 真实 GDC 临床数据）：

- `data/demo/variants.vcf.gz`：真实的 25 个 protein-altering somatic variants，未注释的原始 VCF，INFO 里带真实
  DNA VAF —— 符合项目设计（用户上传 VCF，VEP API 负责注释）
- `data/demo/expression.tsv.gz`：真实的全基因组 tumor expression（TPM + GTEx-lung z-score/percentile）
- `data/demo/hla.tsv`：**synthetic HLA**（这个病例没有真实 HLA typing，按项目计划明确标注为 synthetic）
- `data/demo/case_metadata.json`：真实 GDC 临床数据（年龄/分期/生死/吸烟史），缺失字段标注 "Not available"，不猜测

`vep.py` 真的调 Ensembl VEP REST API（`rest.ensembl.org/vep/human/region`，免费不需要 token，GRCh38）
做注释，`canonical=1` 锁定 canonical transcript，`gene`/`consequence`/`functional_impact`（VEP 原生的
HIGH/MODERATE/LOW/MODIFIER 分级）都是接口直接返回的；`protein_change` 是从返回的 `amino_acids` +
`protein_start` 自己拼的（没用 `hgvs=1` 参数——这个参数在这个接口上会 500）。DNA VAF 不是 VEP 的概念，
是从输入 VCF 自己的 `INFO/VAF` 字段读出来的（跟真实变异检测流程一样，caller 出 VAF，VEP 只管注释）。
`hotspot` 也不是接口直接给的——COSMIC 共定位（`colocated_variants[].somatic`）几乎所有体细胞变异都命中，
不能当热点信号，所以换成一个小的、保守的 curated 真实 LUAD driver hotspot 表（`_KNOWN_LUAD_HOTSPOTS`），
跟 `civic.DRUG_KB` 是同一个套路。API 调用失败会直接抛错，不会静默退化成假注释。

`civic.py` 是真实实现：curated 药物知识库 + CIViC（civicdb.org）GraphQL API 实时查询，不需要 OncoKB token。
每个 protein-altering 变异都要单独查一次 CIViC，真实病例常有 100+ 个变异——**这部分是并发的**
（`ThreadPoolExecutor`，10 并发），不是串行逐个查，这是实测出来的整条 pipeline 最大耗时瓶颈优化点。

`pvactools.py` 现在也是真实实现了：
- **mutant peptide**：从 UniProt REST（真实蛋白序列，免费不需要 token）取该基因的 canonical 序列，在突变位置替换氨基酸，切出真实的 flanking peptide。只对 missense 变异做（stop_gained/frameshift/splice 会产生全新的下游序列，需要真正的 CDS 层建模才能算对，这里没做，会被跳过而不是编一个假的出来）。
- **MHC binding**：真的装了 `pvactools`（7.1.2），并用它依赖的 `mhcflurry` 真实预测模型算 IC50 —— 不是通过完整 `pvacseq run`（那条路需要真 VEP 标注 + Wildtype/Frameshift plugin，我们没有），而是直接批量调 `mhcflurry-predict`（跟 pVACtools 内部包装类调的是同一个模型）。用 CMV/流感的经典强结合表位验证过预测结果是对的。
- 装 mhcflurry 踩了个坑：它内部用的是老版 TF1 Keras API，新版 Keras 3 删掉了，需要装 `tf-keras` 兼容层 + 设 `TF_USE_LEGACY_KERAS=1`（`pvactools.py` 里已经处理了）。
- 模型权重（135MB+，不提交进 git——GitHub 单文件 100MB 限制 + 这是第三方发布物不是本项目产物）在 **Docker build 阶段**就烤进镜像了（见 `Dockerfile`），容器启动即用，不需要额外手动下载；本地裸机跑才需要手动跑一次：
  ```bash
  mhcflurry-downloads fetch models_class1_presentation
  ```
- **vaccine construct（`design_vaccine_construct()`）**：把 top 5 个 neoantigen 拼成一条疫苗肽链，核心问题是
  两个肽拼接处可能意外产生一个新的、没设计过的强结合表位（junctional epitope）——这是 pVACtools 自带的
  `pvacvector` 工具要解决的事，但**没有直接调用它的 CLI**：实测它对每一个（HLA型别 × 表位长度 × spacer）
  组合都单独起一次进程重新加载 MHCflurry 模型，这个case（5个候选×6个HLA型别）跑一轮要 1.5 小时以上，是
  跟当初 pVACtools 自带 wrapper 类同一个性能问题（10+分钟 vs 批量调用几十秒），只是这次严重得多。用的是同一个
  解法：把所有候选拼接点（每对肽 × 每种spacer）产生的候选表位一次性批量丢给 `_run_mhcflurry`，再对5个候选的
  全排列（120种，直接暴力枚举，不用模拟退火）挑出"最弱那个拼接点的结合力最强"这个目标下最优的排列+spacer组合。
  真实MHCflurry模型、真实的"避免拼接处产生强结合表位"这个科学目标，只是没有照搬pVACvector自己的代码
  （它的模拟退火寻路 + 多算法取中位数的打分方式在只用一个算法（MHCflurry）时也用不上）。

## Pipeline Funnel

`main.py` 会输出每一步筛掉多少变异，而不只是最终三张表（数字是真实跑出来的，非固定），并且每个阶段
自带耗时统计（`[timing]` 日志，方便定位真实瓶颈在哪一步，而不是猜）：

```
Protein-altering variants    25
Actionable variants           1   -> 进 drug_matches 分支
Neoantigen candidates        24   -> 进 pvactools 分支
Expressed variants           17   (TPM >= 1)
Real peptide generated        12  (missense only, 真实蛋白序列取到 + 位点对得上)
HLA-presented                 69  (IC50 <= 500nM，真实 mhcflurry 预测)
```

## Pathway 可视化

`pathway.py`（同一套设计思路来自 `luad_workflow/modules/06_pathway/kegg_viewer.py`）：自己在
本地缓存的 KEGG 官方 PNG 上用 Pillow 叠色块，不调 pathview/cytoscape。通路成员基因用 gseapy 的
KEGG_2021_Human gene set（本地缓存，不联网）；底图 + 基因框坐标是真的用 KEGG REST API/KGML 下载好
缓存在 `pipelines/downstream/kegg_cache/pathways/` 的。

覆盖范围：KEGG 自己的 BRITE 分类体系里 5 个跟肿瘤直接相关的官方类别（Signal transduction / Cancer:
overview / Cancer: specific types / Cell growth and death / Immune system），一共 **79 条通路**
（含 KEGG 自己的 Non-small cell lung cancer / Small cell lung cancer 通路图），不是随手挑的，是
KEGG 官方的分类。构建脚本是 `scripts/build_kegg_cache.py`（可重新跑，联网只发生在这一步，构建产物
79×(PNG + 坐标json) ≈ 9.4MB 全部提交进仓库，`pathway.py` 运行时只读本地文件，不联网）。只渲染实际
命中突变基因的通路。颜色：

- 绿色 = 突变基因
- 黄色 = 有表达（TPM ≥ 1）
- 红色 = 较高表达（TPM ≥ 5）
- 一个基因框同时符合多种状态时，切成竖条分别染色

`build_kegg_url()` 保留了生成 KEGG 官网彩色链接的功能，作为备用/对照。

## 数据持久化（Postgres）

`backend/db.py` 负责连接 Postgres，两张表：`cases`（病例元信息，JSONB 存临床字段）、`analysis_results`
（每次 `/analyze` 调用的完整输出，整个存成一行 JSONB，带 `case_id` + `created_at`）。目前是"结果存档"，
不是规范化的数据仓库——没有拆分成独立的 variants/drug_matches 表，也没有跨病例聚合分析。

`scripts/seed_postgres.py` 建表 + 把 demo 病例的元信息和预计算结果灌进去，首次搭建环境时跑一次：

```bash
python -m scripts.seed_postgres
```

连接串默认读环境变量 `DATABASE_URL`，没设的话用 `docker-compose.yml` 里的开发默认值兜底。

## 快速开始 —— 本地裸机跑（不用 Docker）

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mhcflurry-downloads fetch models_class1_presentation   # 首次需要，135MB+

# 1. 命令行测试 downstream pipeline（不需要开服务）
python -m pipelines.downstream.main

# 2. 起一个本地 Postgres（或用 docker compose up -d postgres）
python -m scripts.seed_postgres

# 3. 启动后端 API（新开一个终端）
uvicorn backend.main:app --reload --port 8000

# 4. 启动前端网页（再开一个终端）
streamlit run frontend/streamlit_app.py
```

浏览器打开 Streamlit 给出的地址（默认 http://localhost:8501），默认打开就直接看到 TCGA-38-4627 的结果
（读的是预先算好的缓存，见下）。侧栏可以上传自己的 VCF/expression/HLA（+ 可选的 `case_metadata.json`
显示真实临床信息），点「Run analysis」才会真的调后端跑一遍（约 2-5 分钟，真实 MHC binding 预测 + vaccine
construct 设计）。

## 快速开始 —— 本地 Docker（跟生产环境同一套）

```bash
docker compose up -d --build
```

三个容器（`postgres`/`backend`/`frontend`）会一起起来，`backend` 启动时自动建表（`db.init_db()`）。
本地默认没有 nginx/证书那两层，直接开 `frontend` 容器映射出来的端口即可（`docker-compose.yml` 里按需
加回 `ports:` 映射）。

## 部署

### 生产环境：AWS EC2 + CloudFormation（当前 luadtx.stoichioomics.com 用的就是这套）

`infra/cloudformation.yaml` 是完整的 Infrastructure-as-Code，一条命令建出全部资源：

```bash
aws cloudformation deploy \
  --template-file infra/cloudformation.yaml \
  --stack-name luadtx --capabilities CAPABILITY_IAM \
  --parameter-overrides GitHubRepoUrl=https://github.com/yujuan-zhang/luadtx.git
```

建的东西：EC2（t3.medium / 20GB，UserData 里装 Docker、`git clone` 本仓库、`docker compose up --build`）、
S3（备份桶）、Secrets Manager（自动生成 Postgres 密码，从不写死/提交进 git）、IAM Role（权限精确限定在
这个 S3 桶 + 这个 secret + 这个 CloudWatch log group + SSM，不多给）、Security Group（只开 80/443，
**不开 SSH**——用 AWS Systems Manager Session Manager 远程登录）、CloudWatch Logs、Elastic IP、
Route 53 DNS 记录、Let's Encrypt 证书（`certbot`，webroot 模式，容器化的 renewal loop 自动续期，
不依赖宿主机 cron）。

删除同样一条命令，不留孤儿资源：

```bash
aws cloudformation delete-stack --stack-name luadtx
```

设计上刻意跳过了 RDS 和 ECR（Postgres 直接跑在 EC2 上的容器里，镜像在实例上现场 build，不经 registry）——
对单实例这种规模，两者都是不必要的额外成本/复杂度，详见项目对话记录里的取舍讨论。

### 演示环境：Streamlit Community Cloud（只读 demo，无需服务器）

`frontend/streamlit_app.py` 本身只依赖 `streamlit`/`pandas`/`requests`（不 import 任何 pipeline 代码），
所以云端只需要 `frontend/requirements.txt` 这份轻量依赖，不需要装 `pvactools`/`tensorflow`/`mhcflurry`
这些重依赖 —— 这个部署方式下只能展示预先算好的 `precomputed_result.json`；上传自定义文件走真实分析，
`API_URL` 环境变量没设时默认指向 `localhost:8000`，连不上时前端会优雅降级显示提示，不会崩溃。

部署方式：仓库推到 GitHub 后，在 share.streamlit.io 里选这个仓库，**Main file path 填
`frontend/streamlit_app.py`**（Cloud 会自动找同目录下的 `requirements.txt`）。

## Demo 结果预计算（避免每次都重新跑 ~2 分钟的真实预测）

默认病例的结果不会变，没必要每次打开网页都重新跑一遍真实 pipeline。`scripts/precompute_demo.py` 把
`run_pipeline()` 的结果存成 `data/demo/precomputed_result.json`（~550KB，已提交进仓库），前端默认直接读
这个文件，秒开。改了 demo 数据或 pipeline 逻辑之后要记得重新生成：

```bash
python -m scripts.precompute_demo
```

## 目录结构

```
data/demo/                         默认病例 TCGA-38-4627：真实 VCF + 真实 expression + synthetic HLA + 真实临床 + 预计算结果
data/uploads/TCGA-05-4244/         第二个真实测试病例，用于验证自定义上传流程
scripts/seed_postgres.py           建表 + 灌 demo 种子数据进 Postgres
scripts/precompute_demo.py         重新生成 data/demo/precomputed_result.json
scripts/build_kegg_cache.py        重新生成 KEGG 通路缓存
pipelines/downstream/               核心分析逻辑：vep.py / civic.py / pvactools.py / pathway.py / main.py（串联，带各阶段计时）
pipelines/downstream/kegg_cache/    KEGG 通路底图 PNG + 基因框坐标缓存（不联网）
backend/main.py                    FastAPI，/analyze 接口，结果写入 Postgres
backend/db.py                      Postgres 连接 + 建表 + 读写
frontend/streamlit_app.py          Streamlit 网页；API_URL 可配置（本地/云端/EC2 三种场景通用）
frontend/requirements.txt          云端部署用的轻量依赖（不含 pvactools/tensorflow）
Dockerfile                         backend 镜像（含 mhcflurry 权重，build 时烤进去）
frontend/Dockerfile                frontend 镜像（轻量，无 tensorflow）
docker-compose.yml                 postgres + backend + frontend + nginx + certbot 五容器编排
nginx/conf.d/                      反向代理配置：/ -> frontend，/api/ -> backend，HTTP->HTTPS 重定向
infra/cloudformation.yaml          AWS 部署的完整 IaC 模板（EC2/S3/Secrets Manager/IAM/安全组/DNS/证书）
```

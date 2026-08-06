# Zev — ML-Native Version Control

Zev is a version control system built for machine learning. Every commit is a content-addressed **IPLD** node hashed with **Blake3**, optionally signed with **Ed25519**, exportable as a **CAR** file, and semantically diffable — showing which hyperparameters changed, which Python functions were added, and whether metrics improved or regressed. The entire history is a traversable DAG, fully compatible with **IPFS** and the broader IPLD ecosystem.

**Core tech:** Zig · IPLD dag-cbor · Blake3 · Ed25519 · CAR files · IPFS · libp2p

> **IPFS note:** Any command that reads from or writes to IPFS requires the IPFS daemon running first: `ipfs daemon`

---

## Install

```bash
# Requires Zig 0.17.0-dev
git clone https://codeberg.org/arvand/zev
cd zev
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/zev /usr/local/bin/zev

zev version
# Zev version 0.0.0 (with IPFS integration)
```

---

## Table of Contents

1. [Init & Clone](#1-init--clone)
2. [Configuration](#2-configuration)
3. [File Operations](#3-file-operations)
4. [Branches & Merge](#4-branches--merge)
5. [Remotes, Push & Pull](#5-remotes-push--pull)
6. [History & Inspection](#6-history--inspection)
7. [Advanced Git-style Commands](#7-advanced-git-style-commands)
8. [IPFS Operations](#8-ipfs-operations)
9. [ML Metrics](#9-ml-metrics)
10. [Experiments](#10-experiments)
11. [Snapshots](#11-snapshots)
12. [Drift Detection](#12-drift-detection)
13. [Semantic Diff](#13-semantic-diff)
14. [Regression Detection & CI Gate](#14-regression-detection--ci-gate)
15. [IPLD DAG](#15-ipld-dag)
16. [IPLD Commits](#16-ipld-commits)
17. [Graft — Cross-Repo Links](#17-graft--cross-repo-links)
18. [Federated Merge](#18-federated-merge)
19. [Cryptographic Signing](#19-cryptographic-signing)
20. [Notarization](#20-notarization)
21. [Peer & Fork](#21-peer--fork)
22. [Dataset Tracking](#22-dataset-tracking)
23. [Lineage](#23-lineage)
24. [Context — AI Authorship](#24-context--ai-authorship)
25. [Publish](#25-publish)
26. [Search](#26-search)
27. [Compare](#27-compare)
28. [Audit & Provenance](#28-audit--provenance)
29. [Reproduce](#29-reproduce)
30. [Export & Import Archive](#30-export--import-archive)
31. [Repository Structure](#31-repository-structure)
32. [How It Works](#32-how-it-works)

---

## 1. Init & Clone

**`zev init`** — Create a new Zev repository. Creates `.zev/` with HEAD, config, index, objects/, refs/, and the IPLD block store.

```bash
zev init                        # init in current directory
zev init my-project             # init in ./my-project/
zev init --ipfs                 # init with hybrid IPFS storage enabled
```

**`zev clone`** — Clone a repository from any supported protocol.

```bash
zev clone file:///path/to/repo              # local filesystem
zev clone file:///path/to/repo my-dir       # clone into named directory
zev clone http://example.com/repo           # HTTP
zev clone https://example.com/repo         # HTTPS
zev clone ssh://user@host:/path/repo        # SSH
zev clone user@host:path/repo              # SSH (Git style)
zev clone ipfs://<CID>                     # full repo from IPFS (requires daemon)
zev clone ipfs://<CID> my-project          # clone IPFS repo into named dir
```

---

## 2. Configuration

**`zev config`** — Manage repository config stored in `.zev/config`.

```bash
zev config list                              # list all config values
zev config get user.name                     # get one value
zev config set user.name "Arvand"            # set user name
zev config set user.email "a@example.com"   # set email (validated: must contain @)
zev config set storage.backend local         # storage: local | ipfs | hybrid
zev config set storage.backend ipfs
zev config set storage.backend hybrid
zev config set ipfs.url http://127.0.0.1:5001  # IPFS API URL (must start with http://)
zev config set ipfs.auto_pin true            # auto-pin IPFS objects: true | false
zev config set core.default_branch main      # default branch name (no spaces/special chars)
```

**`zev version`** — Print Zev version string.

```bash
zev version
```

**`zev hash`** — Compute the Blake3 content ID for any data string.

```bash
zev hash "hello world"
zev hash "$(cat model.py)"
```

---

## 3. File Operations

**`zev add`** — Stage files for the next commit. Hashes content with Blake3, stores in object store.

```bash
zev add model.py                  # stage one file
zev add train.py config.yaml      # stage multiple files
zev add .                         # stage all changed files in current directory
```

**`zev commit`** — Commit staged files. Writes a text commit object AND an IPLD CommitNode (Blake3 CID shown after commit hash).

```bash
zev commit "Initial baseline"
zev commit "Add data augmentation and tune lr"
```

**`zev status`** — Show staged, modified, and untracked files.

```bash
zev status
```

**`zev diff`** — Show line-level changes. For semantic ML diff use `zev sdiff`.

```bash
zev diff                          # diff of unstaged changes
zev diff --staged                 # diff of staged changes
zev diff train.py                 # diff a specific file
```

**`zev cat`** — Print raw content of any object by CID.

```bash
zev cat <cid>
```

---

## 4. Branches & Merge

**`zev branch`** — List, create, or delete branches.

```bash
zev branch                        # list all branches (* marks current)
zev branch feature-aug            # create branch at HEAD
zev branch -d feature-aug         # delete branch
```

**`zev checkout`** — Switch to a branch.

```bash
zev checkout main
zev checkout feature-aug
```

**`zev merge`** — Merge a branch into the current branch. Attempts fast-forward, falls back to three-way merge.

```bash
zev merge feature-aug
# Output: Fast-forward | Three-way success | Conflict detected
```

**`zev cherry-pick`** — Apply a single commit from another branch onto the current branch.

```bash
zev cherry-pick <commit-hash>
```

**`zev rebase`** — Rebase the current branch onto another.

```bash
zev rebase main
```

---

## 5. Remotes, Push & Pull

**`zev remote`** — Manage remote repositories.

```bash
zev remote                              # list all remotes
zev remote add origin file:///path      # add a remote
zev remote add ipfs-origin ipfs://placeholder
zev remote remove origin                # remove a remote
zev remote show origin                  # show remote URL and details
```

**`zev push`** — Push to a remote. For IPFS remotes, uploads ALL objects and prints the repo CID.

```bash
zev push origin main                    # push main to origin
zev push ipfs-origin main               # push to IPFS (requires daemon)
# Output: Repository CID: Qm...
```

**`zev pull`** — Pull from a remote.

```bash
zev pull origin main
zev pull ipfs-origin main               # pull from IPFS (requires daemon)
```

---

## 6. History & Inspection

**`zev log`** — Show commit history with author, timestamp, and message.

```bash
zev log                           # last 10 commits
zev log 20                        # last 20 commits
zev log 1                         # just HEAD
```

**`zev blame`** — Show which commit last modified each line of a file.

```bash
zev blame train.py
```

**`zev tag`** — Create, list, or delete tags.

```bash
zev tag                           # list all tags
zev tag v1.0                      # tag HEAD as v1.0
zev tag v1.0 <hash>               # tag a specific commit
zev tag -d v1.0                   # delete tag
```

**`zev stash`** — Temporarily save uncommitted changes without committing.

```bash
zev stash                         # stash current changes
zev stash list                    # list all stashes
zev stash pop                     # apply and remove latest stash
zev stash apply                   # apply latest stash (keep it)
zev stash drop                    # discard latest stash
```

---

## 7. Advanced Git-style Commands

**`zev bisect`** — Binary search through commit history to find where a regression was introduced.

```bash
zev bisect start                  # start bisect session
zev bisect good <hash>            # mark commit as known-good
zev bisect bad <hash>             # mark commit as known-bad
zev bisect reset                  # end bisect session, return to HEAD
```

**`zev hook`** — Manage lifecycle hooks (pre-commit, post-commit, pre-push, post-merge, commit-msg).

```bash
zev hook list                               # list all configured hooks
zev hook add pre-commit ./check.sh          # add a hook script
zev hook add post-commit ./notify.sh
zev hook remove pre-commit                  # remove a hook
zev hook run pre-commit                     # run a hook manually
```

**`zev gc`** — Garbage collect unreachable objects from the object store to reclaim disk space.

```bash
zev gc                            # remove unreachable objects
zev gc --dry-run                  # preview what would be removed
```

**`zev archive-info`** — Show metadata about a repository archive file.

```bash
zev archive-info my-repo.zev.tar.gz
```

---

## 8. IPFS Operations

All commands below require `ipfs daemon` running.

**`zev ipfs status`** — Check if the IPFS daemon is reachable at the configured URL.

```bash
zev ipfs status
```

**`zev ipfs id`** — Show IPFS node identity (peer ID, addresses).

```bash
zev ipfs id
```

**`zev ipfs add`** — Add a file to IPFS and get its CID.

```bash
zev ipfs add model.py             # print CID
zev ipfs add weights.bin          # works with any file type
```

**`zev ipfs cat`** — Retrieve and print content from IPFS by CID.

```bash
zev ipfs cat <CID>
```

**`zev ipfs block-put`** — Store raw bytes as a low-level IPFS block.

```bash
zev ipfs block-put <file>
```

**`zev ipfs block-get`** — Retrieve a raw IPFS block by CID.

```bash
zev ipfs block-get <CID>
```

**`zev ipfs block-stat`** — Show size and CID info for an IPFS block.

```bash
zev ipfs block-stat <CID>
```

**`zev ipfs pin`** — Pin content to local IPFS storage (prevents garbage collection).

```bash
zev ipfs pin <CID>
```

**`zev ipfs unpin`** — Unpin content (allows garbage collection).

```bash
zev ipfs unpin <CID>
```

---

## 9. ML Metrics

Metrics are stored as **MetricsNode** IPLD objects, Blake3-hashed, linked to their commit by CID. Every record is tamper-proof, queryable via `zev dag query`, and tracked historically by `zev check`.

**`zev metrics set`** — Record a numeric metric for the current HEAD commit.

```bash
zev metrics set accuracy 0.913
zev metrics set loss 0.271
zev metrics set f1_score 0.908
zev metrics set precision 0.921
zev metrics set recall 0.896
zev metrics set perplexity 24.3
zev metrics set latency_ms 42.1
```

**`zev metrics show`** — Show metrics for a commit.

```bash
zev metrics show                  # metrics for HEAD
zev metrics show <hash>           # metrics for a specific commit (first 8 chars ok)
```

**`zev metrics list`** — List all metric records across all commits.

```bash
zev metrics list
```

**`zev metrics compare`** — Compare metrics between two commits side-by-side.

```bash
zev metrics compare <hash-a> <hash-b>
```

---

## 10. Experiments

Track named ML experiments with start/complete/abandon lifecycle.

**`zev experiment start`** — Begin a named experiment. Records the current commit as the starting point.

```bash
zev experiment start "ResNet50-augmentation"
zev experiment start "BERT-finetuning" --desc "Fine-tune on domain corpus"
```

**`zev experiment list`** — List all experiments with status (running/complete/abandoned).

```bash
zev experiment list
```

**`zev experiment show`** — Show full details of one experiment.

```bash
zev experiment show "ResNet50-augmentation"
zev experiment show <id>
```

**`zev experiment complete`** — Mark an experiment as successfully completed.

```bash
zev experiment complete "ResNet50-augmentation"
zev experiment complete <id>
```

**`zev experiment abandon`** — Mark an experiment as abandoned (keeps history).

```bash
zev experiment abandon "ResNet50-augmentation"
```

**`zev experiment compare`** — Compare two experiments side-by-side (metrics, commits, duration).

```bash
zev experiment compare <id-a> <id-b>
```

---

## 11. Snapshots

Save named checkpoints of the current state (commit + metrics + configuration). Restore any time.

**`zev snapshot create`** — Save the current state as a named snapshot.

```bash
zev snapshot create "before-pruning"
zev snapshot create "best-checkpoint" --desc "Accuracy 0.931, before LR decay"
zev snapshot create "v1-release" --tags release,stable
```

**`zev snapshot list`** — List all snapshots.

```bash
zev snapshot list
```

**`zev snapshot show`** — Show full details of a snapshot.

```bash
zev snapshot show "before-pruning"
zev snapshot show <id>
```

**`zev snapshot restore`** — Restore to a snapshot (checks out the commit, restores config).

```bash
zev snapshot restore "before-pruning"
zev snapshot restore <id>
```

**`zev snapshot diff`** — Compare two snapshots.

```bash
zev snapshot diff "before-pruning" "best-checkpoint"
```

---

## 12. Drift Detection

Monitor metrics for drift from a baseline. Alert when a metric moves in the wrong direction beyond a configured threshold.

**`zev drift baseline`** — Set the current metrics as the drift baseline.

```bash
zev drift baseline                # use HEAD commit
zev drift baseline <hash>         # use a specific commit as baseline
```

**`zev drift config`** — Configure drift sensitivity per metric.

```bash
zev drift config --metric accuracy --delta 0.05 --direction hib    # hib = higher-is-better
zev drift config --metric loss --delta 0.1 --direction lib         # lib = lower-is-better
zev drift config --metric f1_score --delta 0.03 --direction hib
zev drift config --metric latency_ms --delta 10.0 --direction lib
zev drift config --metric perplexity --delta 2.0 --direction lib
# --direction: hib | lib | any
```

**`zev drift check`** — Check current metrics against the baseline for drift.

```bash
zev drift check                   # check HEAD
zev drift check <hash>            # check a specific commit
```

**`zev drift show`** — Show current drift configuration and baseline values.

```bash
zev drift show
```

**`zev drift history`** — Show drift events over time.

```bash
zev drift history
zev drift history --metric accuracy
```

**`zev drift watch`** — Watch for drift continuously, polling on an interval.

```bash
zev drift watch                   # default interval
zev drift watch --interval 60     # check every 60 seconds
# Ctrl+C to stop
```

---

## 13. Semantic Diff

Unlike `git diff` which shows meaningless bytes for binary files, `zev sdiff` understands the content:

- **Python** — which functions/classes added/removed, which imports changed, which numeric assignments (hyperparameters) shifted
- **JSON/YAML/TOML** — which config keys changed, added, or removed with exact before/after values
- **Text** — line-level added/removed count
- **Binary** — size delta and hash change only
- **Metrics** — direction (improved/degraded), absolute delta, % change, significance (large/moderate/small/negligible)

Loss and error metrics are handled correctly — a decrease in loss is flagged as **improved**, not degraded.

```bash
zev sdiff HEAD~1 HEAD                     # diff last two commits
zev sdiff HEAD~2 HEAD                     # diff 2 commits back vs now
zev sdiff <cid-a> <cid-b>                # diff any two IPLD commit CIDs
zev sdiff HEAD~1 HEAD --metric accuracy   # show only one metric
zev sdiff HEAD~1 HEAD --metric loss
zev sdiff HEAD~1 HEAD --format json       # machine-readable JSON output
zev sdiff HEAD~1 HEAD --format text       # default human-readable
```

Example output:
```
🔬 Semantic Diff: 9863146f → 0087c8df

   ✅ Overall: IMPROVED

📊 Metrics:
   ✅ accuracy:  0.8470 → 0.9130  (+0.066  +7.8%)   [moderate change]
   ✅ loss:      0.4120 → 0.2710  (-0.141  -34.2%)  [large change]
   Improved: 2  Degraded: 0  Unchanged: 0

🌲 Files:
   ✏️  🐍 train.py  (+124 bytes)
         ＋ fn def augment  added
         ＋ import import albumentations as A  added
         ≈  config batch_size  32.000000 → 64.000000
         ≈  config learning_rate  0.001000 → 0.000100
   ✏️  📋 config.json
         ≈  config optimizer  "adam" → "adamw"
         ≈  config weight_decay  "0.0001" → "0.01"

📂 Dataset: not tracked in either commit
```

> Requires `zev ipld migrate` so commits exist as IPLD nodes.

---

## 14. Regression Detection & CI Gate

Automatically detect metric regressions against configured thresholds and the historical best. Designed for CI pipelines — exits with code 1 on critical regression.

**`zev threshold set`** — Configure regression thresholds for a metric. All flags are optional and combinable.

```bash
# Hard floor — CRITICAL if accuracy drops below 0.90
zev threshold set accuracy --min 0.90

# Hard ceiling — CRITICAL if loss exceeds 0.5
zev threshold set loss --max 0.5

# Warn if metric drops by absolute amount
zev threshold set accuracy --warn-delta 0.02

# Warn if metric drops by percentage
zev threshold set accuracy --warn-pct 5

# All combined
zev threshold set accuracy --min 0.85 --warn-delta 0.03 --warn-pct 5
zev threshold set loss --max 0.5 --warn-pct 20
zev threshold set f1_score --min 0.80 --warn-delta 0.05
```

Severity levels automatically assigned:
- `CRITICAL` — crossed a hard `min`/`max` boundary, or dropped >10% vs best-ever
- `WARNING` — exceeded `warn-delta` or `warn-pct`, or dropped 5–10% vs best-ever
- `INFO` — dropped vs best-ever but within acceptable range

**`zev threshold list`** — Show all configured thresholds in a table.

```bash
zev threshold list
```

**`zev check`** — Compare HEAD (or a given ref) against its parent. Records metrics to history. Exits 1 on CRITICAL regression, 0 on pass or warnings only.

```bash
zev check                         # check HEAD vs HEAD~1
zev check HEAD                    # same
zev check HEAD~1                  # check HEAD~1 vs HEAD~2
zev check <cid>                   # check a specific IPLD commit CID
echo $?                           # 0 = passed, 1 = critical regression, 2 = error
```

GitHub Actions example:
```yaml
- name: Record metrics
  run: |
    ACC=$(python -c "import json; print(json.load(open('results.json'))['accuracy'])")
    LOSS=$(python -c "import json; print(json.load(open('results.json'))['loss'])")
    zev metrics set accuracy $ACC
    zev metrics set loss $LOSS
    zev add results.json && zev commit "Run ${{ github.run_number }}"
    zev ipld migrate

- name: Regression gate
  run: zev check HEAD
  # Exits 1 automatically if accuracy drops below min or any threshold is crossed
```

**`zev history`** — Show metric trend over time with a Unicode sparkline. Records are populated each time `zev check` runs.

```bash
zev history accuracy
zev history loss
zev history f1_score
```

Example output:
```
📈 Metric history: accuracy

   ▅██▁

   commit     value      trend
   ──────────────────────────────────
   e61a4a73   0.8470      (first)
   7fd3dd61   0.9310      ↑
   25c73a01   0.7120      ↓ ⚠️

   Best:  0.9310  Worst: 0.7120
```

---

## 15. IPLD DAG

Every Zev object is an **IPLD node** with a **Blake3 CID**. The DAG is content-addressed, tamper-proof, and fully compatible with IPFS tools (`ipfs dag import`, Filecoin, w3up).

Node types in the store: `commit` · `metrics` · `merge` · `graft` · `snapshot` · `dataset_shard` · `context`

**`zev dag show`** — Inspect any IPLD node by CID. Prints all fields, links shown as arrows.

```bash
zev dag show <cid>
zev dag show 9cfcac1a             # short prefix (8+ chars) works
```

**`zev dag walk`** — Walk the DAG recursively from a root, following all CID links.

```bash
zev dag walk <cid>                # default depth 3
zev dag walk <cid> --depth 2
zev dag walk <cid> --depth 5
```

**`zev dag put`** — Store any file as an IPLD block. JSON is encoded as dag-cbor; other files stored as raw blocks. Returns the CID.

```bash
zev dag put metadata.json         # stored as dag-cbor IPLD node
zev dag put weights.bin           # stored as raw block
zev dag put config.yaml
```

**`zev dag stat`** — Show block store stats: total blocks, total size, and breakdown by node type.

```bash
zev dag stat
# Blocks:  12  Size: 2 KB
# commit: 3  metrics: 6  merge: 1  graft: 2
```

**`zev dag export`** — Export blocks to a CAR (Content Addressable aRchive) file — the standard IPLD portable format.

```bash
zev dag export all --output history.car           # all blocks
zev dag export HEAD --output head.car             # from HEAD commit
zev dag export <cid> --output subtree.car         # specific subtree
zev dag export all --output h.car --depth 10      # limit traversal depth
zev dag export all --output h.car --to-ipfs       # export + import to IPFS daemon
```

The resulting `.car` file is compatible with:
```bash
ipfs dag import history.car       # import into IPFS
```

**`zev dag import`** — Import blocks from a CAR file into the local block store. Content-addressed — safe to run multiple times, duplicates are skipped.

```bash
zev dag import history.car
zev dag import researcher_a.car
```

**`zev dag query`** — Query the block store using IPLD selectors. The most powerful inspection command in Zev.

```bash
# Query all nodes of a type
zev dag query all:commit
zev dag query all:metrics
zev dag query all:graft
zev dag query all:merge
zev dag query all:snapshot

# Filter with conditions (operators: > < >= <= =)
zev dag query all:metrics where accuracy>0.9
zev dag query all:metrics where loss<0.3
zev dag query all:metrics where f1_score>=0.85
zev dag query all:metrics where accuracy=0.913

# Path traversal — get a specific field from a node
zev dag query <cid>/author
zev dag query <cid>/message
zev dag query <cid>/metrics/accuracy

# HEAD-relative path queries (requires zev ipld migrate)
zev dag query HEAD/metrics
zev dag query HEAD~3/metrics

# Output formats
zev dag query all:commit                          # default: human-readable text
zev dag query all:commit --format json            # JSON array
zev dag query all:commit --format cids            # one CID per line (for scripting)

# Scripting example: process each commit
for cid in $(zev dag query all:commit --format cids); do
    zev dag show $cid
done
```

---

## 16. IPLD Commits

Convert text-format commits into IPLD nodes so history is queryable, signable, and exportable as a DAG.

**`zev ipld migrate`** — Convert all commits to IPLD CommitNodes. Idempotent — already-migrated commits are detected and skipped via `.zev/ipld_commits/` mappings.

```bash
zev ipld migrate
# 🔄 Migrating 3 commit(s) to IPLD
#   ● a1b2c3d4 → IPLD:9fa15e64...
#   ● e5f6g7h8 → IPLD:2bec1a74...
# ✅ IPLD HEAD: 2bec1a74...
```

After migration, every commit has:
- A `CommitNode` with author, message, branch, parent CID link, tree CID link
- Linked `MetricsNode` for each recorded metric
- All exportable as a single CAR file

**`zev ipld log`** — Show commit history by walking the IPLD DAG via parent links. Works in imported repos (after `zev dag import`) without needing local text commits.

```bash
zev ipld log                      # default 20 entries
zev ipld log 5                    # last 5 entries
```

---

## 17. Graft — Cross-Repo Links

Reference any content from any repo, IPFS node, or Filecoin archive by CID — without copying the data. Only the CID reference is stored as a `GraftNode`.

**`zev graft <cid>`** — Create a named alias for an external CID.

```bash
zev graft <cid> --as dataset/imagenet-v2
zev graft <cid> --as dataset/imagenet-v2 --desc "ImageNet v2 on IPFS"
zev graft <cid> --as model/resnet50-pretrained --desc "ImageNet-pretrained weights"
zev graft <cid> --as dataset/imagenet-v2 --fetch   # also try to retrieve from local IPFS
```

**`zev graft list`** — Show all grafted external links.

```bash
zev graft list
# Alias                       Target CID           Description
# dataset/imagenet-v2         9cfcac1af0847ee6     ImageNet v2 on IPFS
```

**`zev graft resolve`** — Resolve an alias to its CID.

```bash
zev graft resolve dataset/imagenet-v2
# Target:  9cfcac1af0847ee6
# Inspect: zev dag show 9cfcac1af0847ee6
```

---

## 18. Federated Merge

Merge two independent repos by exchanging a CAR file. No GitHub, no server, no shared infrastructure. Both commit chains are preserved. Metrics are merged by strategy. Ed25519 signatures prove authorship of each chain.

```bash
# Researcher A: export their work
zev dag export all --output my_run.car

# Researcher B: import and merge
zev fedmerge --from my_run.car                               # default: metrics-max
zev fedmerge --from my_run.car --strategy metrics-max        # higher value wins per metric
zev fedmerge --from my_run.car --strategy metrics-min        # lower value wins (good for loss)
zev fedmerge --from my_run.car --strategy metrics-avg        # average the two values
zev fedmerge --from my_run.car --strategy commit-union       # merge histories, no metric resolution
zev fedmerge --from my_run.car --dry-run                     # preview without writing anything
zev fedmerge --from my_run.car --strategy metrics-max --sign # sign the resulting merge node
```

The resulting `MergeNode` contains:
- `parent_a` — CID of local HEAD
- `parent_b` — CID of imported HEAD
- `strategy` — resolution strategy used
- `resolved` — list of metric conflicts and winners
- `merged_by` — Ed25519 public key of who merged
- `merged_at` — timestamp

---

## 19. Cryptographic Signing

Blake3 is used for all CID computation (20x faster than SHA-256, streaming-verifiable). Ed25519 provides 64-byte commit signatures. The public key is embedded in the signed node — verification works offline with no key server.

**`zev identity`** — Show your Ed25519 signing identity. Auto-generates one on first use and stores the seed in `.zev/identity` (mode 0600).

```bash
zev identity
# 🔑 Zev Identity
#    Public Key: l84nCdsmxflud2BS_B3saBIlad95K1PPTYA4R08Xo9Y
#    Stored at:  .zev/identity
#    Algorithm:  Ed25519
#
#    Share your public key so others can verify your commits.
```

**`zev sign`** — Sign an IPLD node. Creates a new node with `sig` (86-char base64url) and `sig_pk` (43-char base64url) fields. Returns the new signed CID.

```bash
zev sign <cid>
# ✍️  Signed IPLD node
#    Original: 26a734ce85be05d7
#    Signed:   c29664dd38cf884a
#    Key:      l84nCdsmxflud2BS...
#    Verify:   zev verify c29664dd38cf884a
```

**`zev verify`** — Verify the Ed25519 signature on any IPLD node. Works in any repo that has the block — no access to signer's machine needed.

```bash
zev verify <cid>
# ✅ Signature VALID
#    Signer: l84nCdsmxflud2BS_B3saBIlad95K1PPTYA4R08Xo9Y

zev verify <unsigned-cid>
# ⚠️  Node is unsigned — Sign it: zev sign <cid>
```

---

## 20. Notarization

Record a cryptographic proof of a commit on a blockchain or Arweave for long-term tamper-evidence.

**`zev notarize commit`** — Notarize a commit on-chain.

```bash
zev notarize commit                      # notarize HEAD
zev notarize commit <hash>               # notarize specific commit
zev notarize commit --chain ethereum     # Ethereum (requires configured RPC)
zev notarize commit --chain arweave      # Arweave (requires key file)
zev notarize commit --chain local        # local hash proof only (no blockchain)
```

**`zev notarize snapshot`** — Notarize a named snapshot.

```bash
zev notarize snapshot "best-checkpoint"
zev notarize snapshot <id> --chain ethereum
```

**`zev notarize verify`** — Verify a notarization proof.

```bash
zev notarize verify <commit-hash>
```

**`zev notarize list`** — List all notarization records.

```bash
zev notarize list
```

**`zev notarize config`** — Configure blockchain connection.

```bash
zev notarize config --chain ethereum --rpc http://localhost:8545
zev notarize config --chain arweave --key ./arweave-key.json
```

---

## 21. Peer & Fork

Peer-to-peer repository sync using libp2p — no central server required.

**`zev peer status`** — Show connection status and known peers.

```bash
zev peer status
```

**`zev peer announce`** — Announce this repository to the peer network.

```bash
zev peer announce
zev peer announce --topic ml-experiments     # announce on a named topic channel
```

**`zev peer listen`** — Start listening for incoming peer connections.

```bash
zev peer listen                              # listen on default port
zev peer listen --port 7777                  # listen on specific port
```

**`zev peer connect`** — Connect to a specific peer by multiaddr.

```bash
zev peer connect /ip4/1.2.3.4/tcp/7777/p2p/<peer-id>
```

**`zev peer sync`** — Sync with a connected peer (exchange missing objects).

```bash
zev peer sync <peer-id>
```

**`zev fork`** — Fork a repository to a new path (copy with shared object history).

```bash
zev fork <source-path> <dest-path>
```

---

## 22. Dataset Tracking

Track which dataset shards were used for training. Detect data poisoning by tracing shard lineage.

**`zev dataset register`** — Register a CSV file as a tracked dataset.

```bash
zev dataset register data.csv --name imagenet-v2
zev dataset register train.csv --name my-dataset --desc "Training set, cleaned v3"
```

**`zev dataset split`** — Split a registered dataset into numbered shards.

```bash
zev dataset split --shards 8 --strategy sequential    # split in order
zev dataset split --shards 8 --strategy random        # shuffle then split
zev dataset split --shards 8 --strategy stratified    # stratified by class label
```

**`zev dataset assign`** — Assign the current dataset shards to a specific commit.

```bash
zev dataset assign <commit-hash>
```

**`zev dataset lineage`** — Show which commits used a specific shard (forward lineage).

```bash
zev dataset lineage <shard-cid>
```

**`zev dataset impact`** — Show which commits and models are affected if a shard is corrupted (impact analysis).

```bash
zev dataset impact <shard-cid>
# Use case: "shard 3 had mislabeled data — which training runs are tainted?"
```

**`zev dataset list`** — List all registered datasets and their shards.

```bash
zev dataset list
```

---

## 23. Lineage

Track data and model lineage — where data came from, what transformed it, which models used it.

**`zev lineage add`** — Add a lineage record for an artifact.

```bash
zev lineage add train.csv --source "s3://bucket/raw.csv" --transform "normalize.py"
zev lineage add model.pt --source "train.py" --inputs "train.csv,val.csv"
```

**`zev lineage link`** — Explicitly link two artifacts in the lineage graph.

```bash
zev lineage link <source-cid> <derived-cid>
```

**`zev lineage show`** — Show lineage for a specific artifact.

```bash
zev lineage show <cid>
zev lineage show train.csv
```

**`zev lineage list`** — List all lineage records.

```bash
zev lineage list
```

**`zev lineage graph`** — Print the full lineage graph as text.

```bash
zev lineage graph
```

**`zev lineage provenance`** — Show the full upstream provenance chain for an artifact.

```bash
zev lineage provenance <cid>
```

---

## 24. Context — AI Authorship

Track which AI model generated which file, with optional prompt provenance. No other VCS tracks AI authorship at the commit level.

**`zev context add`** — Record AI authorship metadata for a file.

```bash
zev context add model.py --model gpt-4 --kind generated
zev context add train.py --model claude-3 --kind generated --prompt "Write a ResNet training loop with augmentation"
zev context add config.yaml --model gpt-4 --kind assisted    # human edited AI output
zev context add loss.py --model none --kind human             # fully human-written
# --kind options: generated | assisted | human | reviewed
```

**`zev context show`** — Show AI authorship for files in the current commit.

```bash
zev context show
```

**`zev context blame`** — Show which model generated which file.

```bash
zev context blame train.py
```

**`zev context stats`** — Show statistics: percentage of codebase that is AI-generated vs human.

```bash
zev context stats
```

**`zev context list`** — List all context records across all commits.

```bash
zev context list
```

**`zev context export`** — Export context records to a JSON file.

```bash
zev context export --output context.json
```

**`zev context import`** — Import context records from a JSON file.

```bash
zev context import context.json
```

**`zev context query`** — Query context records by model or kind.

```bash
zev context query --model gpt-4                      # files generated by GPT-4
zev context query --kind generated                   # all AI-generated files
zev context query --kind assisted                    # all AI-assisted files
zev context query --model claude-3 --kind generated  # combined filter
```

---

## 25. Publish

Publish commits, experiments, or snapshots to a configured registry or IPFS.

**`zev publish config`** — Configure publishing settings.

```bash
zev publish config --endpoint https://registry.example.com
zev publish config --ipfs                                    # publish via IPFS
```

**`zev publish commit`** — Publish a commit to the registry.

```bash
zev publish commit                   # publish HEAD
zev publish commit <hash>            # publish specific commit
zev publish commit --public          # make publicly discoverable
```

**`zev publish experiment`** — Publish an experiment.

```bash
zev publish experiment "ResNet50-augmentation"
zev publish experiment <id>
```

**`zev publish snapshot`** — Publish a snapshot.

```bash
zev publish snapshot "best-checkpoint"
zev publish snapshot <id>
```

---

## 26. Search

Full-text and structured search across the repository history.

```bash
zev search commits "augmentation"               # search commit messages
zev search commits "fix learning rate"
zev search experiments "ResNet"                 # search experiment names/descriptions
zev search metrics "accuracy>0.9"               # find commits where accuracy > 0.9
zev search metrics "loss<0.3"
zev search lineage "imagenet"                   # search lineage records
zev search snapshots "before-pruning"           # search snapshot names
zev search all "augmentation"                   # search across everything at once
```

---

## 27. Compare

Side-by-side comparison of commits, experiments, snapshots, or branches.

```bash
zev compare commits <hash-a> <hash-b>           # compare two commits
zev compare experiments <id-a> <id-b>           # compare two experiments
zev compare snapshots <name-a> <name-b>         # compare two snapshots
zev compare branches main feature-aug           # compare two branches
```

---

## 28. Audit & Provenance

**`zev audit`** — Generate a full provenance timeline covering commits, metrics, experiments, snapshots, notarizations, drift events, reproductions, and context records.

```bash
zev audit                           # print to terminal (color table)
zev audit --format markdown         # write zev-audit.md
zev audit --format json             # machine-readable JSON
zev audit --since <hash>            # audit from a specific commit forward
zev audit --commit <hash>           # audit one specific commit only
```

---

## 29. Reproduce

Reproduce the exact environment of any commit: code, data shards, dependencies, hardware config.

**`zev reproduce status`** — Show whether HEAD (or a given commit) is reproducible.

```bash
zev reproduce status
zev reproduce status <hash>
```

**`zev reproduce capture`** — Capture the current environment as a reproduction record (dependencies, hardware, seeds).

```bash
zev reproduce capture               # capture HEAD environment
zev reproduce capture --full        # include hardware info
```

**`zev reproduce HEAD`** / **`zev reproduce <hash>`** — Reproduce a specific commit's environment.

```bash
zev reproduce HEAD
zev reproduce <64-char-hash>
```

---

## 30. Export & Import Archive

Export the full Zev repository (objects, history, metadata) to a portable archive. Different from `zev dag export` which exports IPLD blocks only.

**`zev export`** — Export the complete repository to an archive file.

```bash
zev export --output my-repo.zev.tar.gz
zev export --output archive.zip --format zip
zev export --include-ipld                       # include IPLD block store
```

**`zev import`** — Import a repository from an archive.

```bash
zev import my-repo.zev.tar.gz
zev import archive.zip
```

---

## 31. Repository Structure

```
.zev/
├── HEAD                    current branch ("ref: refs/heads/main")
├── config                  user + storage + IPFS config
├── index                   staging area (binary)
├── identity                Ed25519 seed (base64url, mode 0600, auto-generated)
├── regression_config       threshold config ("metric min=X max=X warn_delta=X")
├── metric_history          append-only log ("commit metric value timestamp\n")
│
├── objects/                text-format objects
│   ├── <64-char-hash>      commit: "tree <hash>\nauthor...\ntimestamp\n\nmessage"
│   ├── <64-char-hash>      tree:   "filename hash size perms\n..."
│   └── <64-char-hash>      blob:   raw file content
│
├── refs/heads/
│   └── main                branch pointer (64-char hash)
│
├── ipld/                   IPLD block store (dag-cbor, Blake3 CIDs)
│   └── <2-char-shard>/     sharded by first 2 hex chars of CID
│       └── <16-char-cid>   dag-cbor encoded IPLD node
│
├── ipld_commits/           text-hash prefix → IPLD CID mappings
│   └── <16-char-prefix>    contains IPLD CID string
├── ipld_head               current IPLD HEAD CID
│
├── grafts/                 alias → CID mappings
├── metrics/                per-commit metric files
├── experiments/            experiment lifecycle records
├── snapshots/              named checkpoint records
├── contexts/               AI authorship records
├── lineage/                lineage graph records
├── notarizations/          blockchain proof records
├── reproduce/              environment capture records
└── remotes/                remote URL files
```

---

## 32. How It Works

```
Every zev commit:
  1. Writes text object → .zev/objects/<hash>
  2. Writes CommitNode → .zev/ipld/<shard>/<blake3-cid>  (IPLD dag-cbor)

CommitNode links:
  parent   → previous CommitNode CID (forms the chain)
  tree     → Blake3 CID of the file tree object
  metrics  → MetricsNode CID (after zev metrics set)

zev sdiff:
  collectMetricsForCommit(A)  → scan block store, match by text hash
  collectMetricsForCommit(B)  → same
  MetricDelta per key         → direction, %, significance
  diffTrees(tree_A, tree_B)   → per-file semantic diff:
    .py   → functions, imports, numeric assignments
    .json/.yaml/.toml → config key/value changes
    .txt  → line counts
    other → size + hash change

zev check:
  computeSemanticDiff(parent_cid, head_cid)
  detectRegressions(configured thresholds + historical best)
  appendMetricHistory(both commits)
  exit 1 if any CRITICAL regression

zev fedmerge:
  import CAR → local block store (safe: content-addressed)
  findHeadInCar() → HEAD-B
  collectMetrics(HEAD-A) + collectMetrics(HEAD-B)
  resolve conflicts by strategy (max/min/avg/union)
  write MergeNode { parent_a, parent_b, strategy, resolved, merged_by }
  optionally Ed25519-sign the merge node

zev dag export → CAR file:
  [varint(header_len)] [dag-cbor {version:1, roots:[CID...]}]
  [varint(block_len)] [CID bytes] [block data] × N
  Compatible with: ipfs dag import, Filecoin, w3up, any IPLD tool
```

**Hashing:** Blake3 — 20x faster than SHA-256, native tree hashing, streaming verification, IPLD multicodec `0x1e`.

**Encoding:** dag-cbor — canonical CBOR with IPLD link support (CBOR tag 42). Map keys sorted by length then lexicographic. Varint-encoded CID components.

**Signatures:** Ed25519 — 64-byte signatures, 32-byte public keys, base64url (no padding) encoded. Public key embedded in signed node. Self-verifying offline.

---

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| Zig | 0.14+ | Build from source |
| OS | Linux / macOS | Windows via WSL |
| IPFS daemon | any | Optional — required for `zev ipfs *`, `zev push ipfs://`, `zev clone ipfs://`, `--to-ipfs` flag |
| Ethereum node | any | Optional — required for `zev notarize --chain ethereum` |
| Arweave key | — | Optional — required for `zev notarize --chain arweave` |

---

## License

MIT — part of the [Mazaryn](https://mazaryn.io) distributed social network project.

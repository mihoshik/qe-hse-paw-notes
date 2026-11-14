# CPU PAW batching patches / CPU版PAW一括演算パッチ

[Index / 一覧](../../README.md) · [日本語の測定記録](../../CPU_ACCELERATION.ja.md) · [English measurements](../../CPU_ACCELERATION.en.md)

Implementation and measurements recorded on 2026-11-12 JST. Source patches published on 2026-11-14 JST.

## 日本語

QE 7.6の一般k点・collinear・逆空間US/PAW交換補正を、複数バンドの複素行列演算へ一括化するソースを公開する。射影子対の三角形表現、BLASの`ZGEMM`、原子位相と作業配列の再利用を使用する。基準のPAW一中心補正は、既公開の各EXXグループrootで計算する修正版を使用する。

| ファイル | 内容 |
| --- | --- |
| [cpu-paw-batch.patch](cpu-paw-batch.patch) | 新しい`exx_paw_cpu_batch`モジュール、`vexx_bp_k`の呼び出し、Makeビルドのオブジェクトと依存関係 |
| [exx-block20.patch](exx-block20.patch) | `Modules/mp_exx.f90`の一括幅`jblock`を7から20へ変更 |
| [source-manifest.json](source-manifest.json) | 変更前後のソースと配布ファイルのSHA-256、測定済み実行ファイルの識別子 |
| [validation-summary.json](validation-summary.json) | 保存済みの数値照合、速度試験、公開時の適用確認 |
| [License](License) | QE 7.6のGNU GPLライセンス本文 |

`jblock`は一度の演算で処理するバンド数を表す。電子状態のバンド数は入力の`nbnd`で設定する。元の高速化試験は幅7で、現在のCPU本番計算では追加の幅20変更も使用している。

### 適用とビルド

別の書き込み可能なディレクトリにQE 7.6のCPU用Makeビルドを構成し、そのルートで次を実行する。配布パッチは保存済みソースに加え、公式`qe-7.6`タグの`exx_bp.f90`と`mp_exx.f90`にも照合した。コンパイラ、MPI、BLASは構成済みビルドと同じものを使用する。コンパイルと数値計算はSlurmで確保した計算ノード上で実行する。

```bash
NOTES=/absolute/path/to/qe-hse-paw-notes

git apply --check "$NOTES/reproduction/cpu-paw-pool/paw-exx-pool.patch"
git apply "$NOTES/reproduction/cpu-paw-pool/paw-exx-pool.patch"

git apply --check "$NOTES/reproduction/cpu-paw-batch/cpu-paw-batch.patch"
git apply "$NOTES/reproduction/cpu-paw-batch/cpu-paw-batch.patch"

# Add the width20 change to reproduce the current CPU configuration.
git apply --check "$NOTES/reproduction/cpu-paw-batch/exx-block20.patch"
git apply "$NOTES/reproduction/cpu-paw-batch/exx-block20.patch"

make -j1 pw
```

既にPAW一中心補正の修正を適用済みなら、一括演算パッチから進める。幅7を比較対象として残す場合は、幅20パッチを適用する前に別のビルドを保存する。`cpu-paw-batch.patch`には新規モジュールのソース全体を含めた。

公開時にはパッチの適用、逆適用確認、生成ソースのSHA-256一致を確認した。`exx_bp.f90`と新規モジュールは測定済みソースと同一である。Makefileへの通常ビルド用の統合は今回追加した。保存済みの実測では独立したオブジェクトの再リンクを使用しており、公開準備中の再コンパイル・SCF再実行は未実施である。

### 数値照合と速度試験

[既存の追試入力とPBE seed作成手順](../cpu-paw-pool/README.md)を使用できる。各比較では同じseedの独立コピーを用い、`OMP_NUM_THREADS=1`、`MKL_NUM_THREADS=1`を設定する。

| 設定 | 動作 |
| --- | --- |
| `QE_PAW_CPU_BATCH=0` | PAW一中心修正を含む既存の逐次バンド演算を使用 |
| `QE_PAW_CPU_BATCH=1` | 一括演算を使用。高速化版の既定値 |
| `QE_PAW_CPU_VALIDATE=1` | 各呼び出しの全対象バッチ・q点で元のUS補正配列と照合 |
| `QE_PAW_CPU_VALIDATE=0` | 速度測定用の実行 |

SnOの4原子セル、HSE、PBE生成PAW、40電子、`nbnd=20`、80/400 Ry、k2×1×1/q1×1×1を使用した。幅7の32MPI・2pool、および幅20の4MPI・2poolで、検算付きHSE SCFが収束し、いずれも全エネルギー`-808.90861004 Ry`と`JOB DONE`を確認した。一致精度は表示された小数点以下8桁である。

| 試験 | 条件 | 初回ACE WALL中央値 | 比率 |
| --- | --- | --- | --- |
| PAW修正のみ → 一括演算・幅7 | 32MPI、2pool、検算無効、交互に3組 | 5.42 → 1.36 s | 約3.99倍 |
| 一括演算・幅7 → 幅20 | 4MPI、2pool、検算無効、交互に3組 | 9.34 → 6.01 s | 約1.55倍 |

表の測定範囲は小メッシュの初回EXX/ACE構築である。幅20の履歴試験は既存Ruby02割当内で本番計算とCPU資源を共有していた。各行の条件と測定範囲を保って解釈する。元の三組の値と検算出力は`validation-summary.json`に収録した。

実装と検証の対象はcollinear・一般k点・逆空間補正で、対応する経路で有効になる。HSEの力・応力による構造緩和は引き続き別途実装・検証を要する。

## English

These patches publish the measured QE 7.6 CPU implementation for batching collinear, general-k reciprocal-space US/PAW exchange augmentation. It uses triangular projector pairs, complex BLAS `ZGEMM`, and reused atomic phases and work arrays. The PAW one-center terms use the existing EXX-group-root correctness repair.

`cpu-paw-batch.patch` contains the complete new Fortran module, its `vexx_bp_k` call sites, and Make object/dependency integration. `exx-block20.patch` additionally changes `mp_exx:jblock` from 7 to 20. `jblock` controls the width of a band batch. The input `nbnd` controls the number of electronic bands. The first acceleration measurements used width 7, and the current CPU production configuration also uses the width 20 change.

### Apply and build

Prepare a separate writable, configured QE 7.6 CPU Make build. Run the shell commands above from its root, with `NOTES` pointing to this repository. Use the compiler, MPI and BLAS stack matching that build. Compile and run numerical tests on a Slurm-allocated compute node. If the PAW group-root repair is already applied, start with the batching patch. Preserve a separate width 7 build before applying the width 20 patch when comparing both widths.

Publication checks applied the existing correctness repair followed by both new patches, checked reverse application, and compared the resulting sources by SHA-256. The fetched official `qe-7.6` versions of `exx_bp.f90` and `mp_exx.f90` matched the saved original sources exactly. The new module and patched `exx_bp.f90` match the measured sources. The ordinary Makefile integration was added for this publication. Historical numerical tests used private object relinking. Compilation and SCF execution during publication remain untested.

### Numerical checks and timing

Use independent copies of the same PBE seed for each comparison and single-threaded OpenMP/MKL. Set `QE_PAW_CPU_VALIDATE=1` to compare every active batch/q against the original US augmentation routines. Set it to 0 for timing. `QE_PAW_CPU_BATCH=0` selects the original band-at-a-time augmentation with the PAW one-center repair retained, and 1 enables batching. [Existing reproduction inputs and PBE seed instructions](../cpu-paw-pool/README.md)

For the four-atom SnO cell with HSE, PBE-generated PAW, 40 electrons, 20 bands, 80/400 Ry, k2×1×1/q1×1×1, the width 7 full SCF at 32 MPI ranks and 2 pools and width 20 full SCF at 4 MPI ranks and 2 pools both reached EXX convergence and `JOB DONE`, with energy `-808.90861004 Ry` at the printed eight decimal places.

Three alternating timing pairs with validation disabled gave median first-ACE WALL times of 5.42→1.36 s for correctness-only versus batch 7 at 32 MPI ranks and 2 pools, and 9.34→6.01 s for batch 7 versus batch 20 at 4 MPI ranks and 2 pools. The latter historical experiment shared CPU resources with production inside the existing Ruby02 allocation. Each ratio applies to its stated small-mesh first-construction scope. Samples and validation output are in `validation-summary.json`.

The accelerated and tested scope is collinear, general-k reciprocal-space augmentation. Structural relaxation through HSE forces/stress requires further implementation and validation.

The code follows the GNU GPL terms used by QE 7.6. The accompanying `License` contains the upstream license text. Source modifications and measurements date to 2026-11-12, and this publication dates to 2026-11-14.

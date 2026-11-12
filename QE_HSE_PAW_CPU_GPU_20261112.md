# Quantum ESPRESSO 7.6: HSE + PAW CPU/GPU optimization and a pool-dependent PAW exchange omission
# Quantum ESPRESSO 7.6：HSE＋PAW計算のCPU/GPU高速化とpool並列によるPAW交換補正欠落

**Date / 記録日:** 2026-11-12, Japan Standard Time

[日本語 / Japanese](#japanese) · [English](#english) · [References / 参考資料](#references)

This is an experimental technical record, with completed small-mesh tests distinguished from production-mesh validation. It is not an announcement of an upstream QE fix or a claim of first discovery.

本稿は実験的な改造と検証の技術記録であり、小規模試験で確認した事項と、本番メッシュで照合中の事項を区別する。QE上流での修正完了や、世界初の発見を主張するものではない。

<a id="japanese"></a>
## 日本語

### 1. 要点と、混同してはいけない三つの変更

SnOのHSE＋PAW計算について、次の三つを分けて実装・検証した。

| 項目 | 変更の目的 | この記録で確認できたこと |
| --- | --- | --- |
| GPU版の交換補正の高速化 | GPU実行中もCPUに残っていた大きなUS/PAW補正計算を、GPU上の一括行列演算へ移す | 小規模HSE試験で標準版との全エネルギー一致。GPU試験機2台で実行時間短縮 |
| CPU版のPAW一中心交換補正の修正 | 複数poolで補正が欠落する並列実行条件を修正する | 標準版でpool数依存のエネルギー差を再現し、修正版で解消 |
| CPU版の交換補正の高速化 | 修正版を基準に、US/PAW補正を複数バンドまとめたBLAS演算へ置き換える | 小規模試験で数値一致。32MPIで初回EXX構築が約4倍高速化 |

**PAW補正の欠落を直す変更と、`addusxx/newdxx`を高速化する変更は独立している。** 「正しさの修正」と「性能改善」を別々に比較するため、CPUには修正のみの版と、修正＋高速化版の両方を用意した。

### 2. 計算の目的・物理モデル・共通条件

目的は、HSE全エネルギーを用いたSnOの構造・ひずみ応答の評価に向け、計算の正しさと実行速度を確認すること。本稿では弾性テンソルや内部緩和込みポアソン比の最終値を提示しない。

「HSE＋PBE」という表現は、ここでは**PBEで生成されたPAW擬ポテンシャルを使用し、交換相関汎関数にはHSEを指定する**という意味である。独立したHSEエネルギーとPBEエネルギーを後から足した計算ではない。

| 項目 | 設定 |
| --- | --- |
| コード | インストール済みQuantum ESPRESSO 7.6を基にした独立した改造版 |
| 構造 | 正方晶SnO、4原子セル（Sn 2原子、O 2原子） |
| 基準格子・内部座標 | `A=3.801 Å`, `C=4.984 Å`, `u=0.231` |
| 価電子数 | 40電子／4原子セル。Snは14価電子、Oは6価電子 |
| バンド数・スピン | `nbnd=20`, `nspin=1`, `occupations='fixed'` |
| 汎関数 | `input_dft='HSE'`, `exx_fraction=0.25`, `screening_parameter=0.106` |
| カットオフ | `ecutwfc=80 Ry`, `ecutrho=400 Ry` |
| EXX | `ace=.true.`, `exxdiv_treatment='gygi-baldereschi'`, `x_gamma_extrapolation=.true.` |
| 電子収束 | `conv_thr=1e-9`, `electron_maxstep=400`, `exx_maxstep=100` |
| SCF制御 | `adaptive_thr=.true.`, `conv_thr_init=1e-3`, `conv_thr_multi=0.1`, `mixing_beta=0.03`, Davidson対角化 |
| SnのPAW | `Sn.pbe-dn-kjpaw_psl.1.0.0.UPF`、MD5 `67f11dec737d427557dc41ea34975807` |
| OのPAW | `O.pbe-n-kjpaw_psl.1.0.0.UPF`、MD5 `e99d9cef9b487d1ca56f5b95ecd0fd7a` |

20バンドは40電子をスピン縮退した20個の占有状態で扱う設定であり、「20電子で計算した」という意味ではない。空バンド数の収束、励起状態、金属や異なる占有条件での適切なバンド数は、本稿の検証対象外である。

比較するメッシュは次のように区別した。

| 用途 | kメッシュ | EXXのqメッシュ | 備考 |
| --- | --- | --- | --- |
| GPU版の小規模数値・速度試験 | 1×1×1 | 1×1×1 | 一般k点経路を使う入力。`K_POINTS gamma`専用経路の検証とは区別 |
| CPU版のpool依存性・高速化試験 | 2×1×1 | 1×1×1 | 1poolと2poolを同じ入力で比較 |
| 本番条件の参照構造 | 6×6×6 | 6×6×6 | この参照構造では対称性適用後40k点。最終照合は継続中 |

計測条件は、CPUの実計算比較では単一ノード上の32MPI、各rankのOpenMP/MKLは1スレッド。GPU試験ではGPU1枚、MPI1rank、CPU側1スレッドとした。GPUの結果はRTX 3090（24GB）およびRTX 2080 Ti（11GB級）で得たもので、異なるGPUや多GPUへの一般化はしていない。CPU側はIntel oneAPI/Intel MPI/MKL系、GPU改造版はCUDA Fortran/cuBLASを使用した。

### 3. GPU版で重かった処理と変更内容

HSEでは、交換演算子EXXを構築・更新し、ACE演算子として利用する。今回の小規模プロファイルでは、EXX構築の中にある大きなG空間のUS/PAW補正処理が主要な負荷だった。

| 標準GPU版のプロファイル項目 | WALL時間 |
| --- | ---: |
| `aceinit` | 415.46 s |
| `addusxx` | 204.33 s |
| `newdxx` | 201.17 s |
| 別の一中心項 `PAW_newdxx` | 1.60 s |

`addusxx + newdxx`は、この試験の`aceinit`時間の約97.6%に相当する。これらのCPU時間もWALL時間に近く、CPU側での計算が大きいことが観測できた。転送時間だけを原因と決めたものではない。

標準GPU版では、FFTなどのGPU処理と、CPUに残る交換補正処理が混在していた。今回の変更は、`exx_bp::vexx_bp_k_gpu`に独立した`exx_paw_gpu`モジュールを組み込み、主に次を行うものだった。

- 複数バンドの射影係数と補正をまとめ、cuBLASの`ZGEMM`で処理する。
- 対称な射影子の組を三角形の組として扱う。
- q点に対応する位相や作業配列を再利用する。
- 対応するPAW一中心項も、密度行列の収縮と`ZGEMV`などを用いてGPU側で評価する。
- 大きな補正配列をGPU上に保持し、補正のためのCPU/GPU往復を減らす。

浮動小数点精度は複素倍精度のままで、汎関数、擬ポテンシャル、カットオフ、占有数、物理係数や収束しきい値を高速化のために変更していない。完全に転送がなくなったという意味でもない。

対象はcollinear・一般k点・逆空間補正の経路である。非collinear、`tqr`による実空間補正、Gamma専用経路、複数MPI rankのGPU実行などを同じ範囲で検証したものではない。GPU試作版は1MPI/1poolを検証条件とする。

### 4. GPU小規模試験の数値と速度

以下は同じk1/q1条件で、標準GPU版と改造GPU版を収束まで計算した結果である。改造版の時間には配列照合の検算を含む。初期PBE seedの作成は別に扱った。

| GPU | 標準GPU版のHSE計算時間 | 改造GPU版・検算あり | 比率 |
| --- | ---: | ---: | ---: |
| RTX 3090 | 436.81 s | 41.50 s | 約10.5倍 |
| RTX 2080 Ti | 344.75 s | 39.76 s | 約8.7倍 |

この条件では、CPU参照、標準GPU版、改造GPU版の収束エネルギーがいずれも**−808.59971427 Ry／4原子セル**で、出力された小数桁まで一致した。

単独の初回EXX構築を計る検算なしの試験では、RTX 3090で`aceinit`が46.52→1.12 s、RTX 2080 Tiで41.32→2.04 sだった。これは初回構築の測定であり、収束計算全体の倍率とは別である。

GPU試作版の配列検算は、各プロセスの最初の12回の対象呼び出しを標準CPUルーチンと比較する実装だった。報告最大差はRTX 3090で約1.34×10⁻¹⁵、RTX 2080 Tiで約1.18×10⁻¹⁵。ただし、その後に同じ累積最大値が表示されても、全q点・全周回を毎回検算した証明にはならない。

**これらの速度と数値一致は小規模メッシュの結果であり、そのままk6/q6の最終一致や同じ倍率を保証しない。**

### 5. CPU/GPUの差から見つかったPAW補正欠落

本番条件でCPUとGPUのエネルギー差を調べると、比較していたCPU版は2pool、GPU版は1poolだった。

`PW/src/paw_exx.f90`の二つのルーチンには、PAW一中心交換補正を`IF(ionode)`で実行する条件があった。

- `PAW_newdxx`：Hamiltonianへ入るPAW一中心交換項。
- `PAW_xx_energy`：対応する交換エネルギー項。

`ionode`はimage全体のI/Oルートを表す。各k点poolのルートではない。そのため、後続poolではこの項が計算されず、欠落した項が後の和で復元されない。エネルギーの表示だけでなくHamiltonianにも関係するため、SCFが収束していてもpool数で別の値になり得る。

修正は、この二つのルーチンを**各pool内の各EXX計算グループで一度ずつ**実行することだった。

```fortran
! Before
IF (ionode) THEN

! Experimental repair
IF (me_egrp == root_egrp) THEN
```

呼び出し側のコミュニケータ内の和は維持する。検証したソースでは`PAW_init_fock_kernel`は全rankでkernelを初期化しており、この経路の修正に追加のkernel broadcastは不要だった。単にpool0の値を他のpoolへ配ればよいという問題ではない。各poolで扱う波動関数が異なるためである。

### 6. 不具合の再現と修正の数値照合

まず、完了済みの同じSnO保存波動関数を用い、global k点1/20/21/40の第1バンドのPAW項を評価した。

- 標準1poolでは4点とも非ゼロ。
- 標準2poolでは、pool1のk点21/40で項が正確にゼロ。
- 修正版2poolは標準1poolと、複素射影ベクトルの最大差約8.10×10⁻¹⁸以内で一致。
- 修正版1poolは標準1poolと一致。

小さな人工配列を使う別の実MPI試験でも、1/4rank、1/2pool、1/2/4EXXグループの有効な六つの構成で、同じ補正値になることを確認した。この試験は重複加算と欠落を確認するためのもので、完全なSCF計算の代わりではない。

続いて、**同一の入力・擬ポテンシャル・コピーしたPBE初期状態**から、32MPI、k2×1×1/q1のHSE計算をそれぞれ収束させた。標準版には実際にインストールされている未改造のCPU実行ファイルを使った。

| CPU版 | pool数 | EXX収束後の全エネルギー（Ry／4原子セル） |
| --- | ---: | ---: |
| 標準版 | 1 | −808.90861004 |
| 標準版 | 2 | −808.87291502 |
| PAW修正版 | 1 | −808.90861004 |
| PAW修正版 | 2 | −808.90861004 |
| PAW修正＋CPU高速化版 | 2 | −808.90861004 |

全五計算でEXX収束と`JOB DONE`を確認した。標準2poolだけが**＋0.03569502 Ry**ずれ、修正版でこのpool依存性が解消した。表の一致は出力精度（小数点以下8桁）での一致であり、内部の全ビットが同一という意味ではない。

本番条件の対応する途中段階では、GPU1pool−CPU2poolの差が約−0.04219332 Ryだった。保存密度による別の収縮計算は、欠落するpoolのPAW交換エネルギーを約−0.04181626 Ryと評価した。符号・大きさは主要因という解釈を支持するが、これは新しい完全自己無撞着SCFの最終結果ではない。

この収縮の生のFock traceは約−0.08363252 Ryであり、QEの`exxen = 0.5 * fock2`という規約により、交換エネルギーへの寄与はその半分となる。この係数を無視して比較してはいけない。

### 7. CPU高速化版の内容と、約4倍の意味

PAW修正のみの`pw_fixed.x`を基準に、`pw_batch.x`ではcollinear・一般k点の`vexx_bp_k`内のUS/PAW逆空間補正を一括化した。既存のバンドブロック、三角形の射影子対、Intel MKLの`ZGEMM`、q点位相と作業配列の再利用を使う。PAW一中心項は両実行ファイルで同じ修正版を使う。

CPU版の検算モードは、対象となる呼び出し・q点の全バッチを標準US補正ルーチンと比較し、初期化ごとに検算カウンタをリセットする。速度計測ではこの検算を無効にする。

32MPI、2pool、k2/q1、同一PBE seed、検算なしで、実行順を交互にした三組の初回`aceinit`測定は次の通りだった。

| 回 | PAW修正のみ | PAW修正＋CPU高速化 |
| --- | ---: | ---: |
| 1 | 5.42 s | 1.37 s |
| 2 | 5.42 s | 1.36 s |
| 3 | 5.44 s | 1.35 s |
| 中央値 | **5.42 s** | **1.36 s** |

中央値の比は**約3.99倍**。これは`addusxx/newdxx`を含む**EXX構築全体**の倍率で、二つの補正だけの倍率でも、SCF全体の倍率でもない。

別条件の単一CPUコア上の人工配列試験（47109Gベクトル、六つのq条件、三反復）では、`add+new`合計の中央値は次の結果だった。

| 一括バンド数 | 標準ルーチン | 一括CPU版 | 比率 |
| --- | ---: | ---: | ---: |
| 1 | 0.10042 s | 0.04729 s | 2.12倍 |
| 7 | 0.71125 s | 0.07717 s | 9.22倍 |
| 20 | 1.98375 s | 0.12407 s | 15.99倍 |

現在のバンドブロックは7。人工配列試験の約9.2倍と、32MPI試験の約4倍は測定範囲・条件が異なる。人工配列試験では非ゼロ初期配列、複素数、q条件の変化、端数のバンド数も確認し、最大配列差はaddで約7.02×10⁻¹⁶、newで約1.41×10⁻¹²だった。

### 8. 測定値・収束・未検証範囲の読み方

- **初期PBE、途中の内側SCF、最終HSEを区別する。** 最終値の判定にはEXX収束と`JOB DONE`を使った。初回構築だけで止める`exx_maxstep=1`の時間測定ログに残るエネルギーはPBE seedの値で、HSE数値一致の証拠には使わない。
- 配列検算を含む時間を、検算なし版の速度として扱わない。
- 「GPUならCPUより必ず速い」という一般的な結論ではない。今回の実装・バッチ化・データ配置・問題サイズ・GPU・MPI条件を含めた結果である。
- CPUのpool依存性を解消した小規模試験の結果を、あらゆるQE版・擬ポテンシャル・スピン条件に一般化しない。
- **本番k6/q6での最終CPU/GPU一致は、この記録では未確定。** GPU側の小規模試験合格だけで本番コードを全面的に検証済みとはしない。
- 今回の変更はSCFの実装・性能を扱うもので、HSE＋PAWの力・応力や直接`relax`/`vc-relax`を新たに実装したものではない。
- 欠落項は構造・電子状態に依存し得る。既存の全構造のエネルギーへ同じ定数を加減して弾性・内部緩和・ポアソン比を補正したことにはならない。

### 9. 関連する既報と、今回の発見の位置付け

調査時点の公式ミラー`develop/PW/src/paw_exx.f90`にも、上記の二つの`ionode`条件が残っていた。[1]

| 公開記録 | 内容と今回との関係 |
| --- | --- |
| 2016年、Lorenzo PaulattoのPAW＋EXX修正 [2] | `RETURN`で無効化されていたPAW Hamiltonian寄与などの修正。PAW項の欠落に関する前例だが、今回の後続poolの欠落と同じ報告とは扱わない |
| 2018年、giannozzのIssue #9 [3] | PAW＋EXXの不審なエネルギー変化や`tqr`の問題。調査時open。今回と同じ原因かは本文から同定できない |
| 2018年、Ye LuoのIssue #42 [4] | EXXのバンド並列でのクラッシュやNaNなど。closed。今回の`ionode`原因を特定した記載は確認できなかった |
| 2026年、Ron LeizrowiceのIssue #875 [5] | macOS/arm64＋gfortran15で`us_exx`が誤コンパイルされるという報告。今回のIntel/x86のpool依存性とは分ける |

関連する問題を発見・報告した人は以前からいる。一方、**今回と同じ`ionode`による後続poolの一中心交換項欠落を特定した公開報告は、今回の検索範囲では確認できなかった。世界初・未報告とは断定しない。**

検索対象は公式GitLabの公開issue/MRのタイトル・本文、公式ミラーのファイル履歴・コミット、公開メーリングリスト。issue検索はPAW、EXX、HSE、pool、ionode、二つの関数名で重複除去94件。個別issue・コメント取得APIが401を返したため、コメント欄は網羅していない。私的な修正や未索引の議論も除外できない。

### 10. 再現のために記録した情報

物理条件、同一初期状態、MPI/pool数、EXX収束、実行ファイル・入力のハッシュをそろえて比較した。インストール済み標準ソースや実行ファイルを上書きせず、独立したビルドで評価した。

| 識別対象 | SHA-256 |
| --- | --- |
| 検証した標準`paw_exx.f90` | `ee8bcaac2b18b5e8503ba6107dd8ad7f57b3c9833063811891a5125e2b167177` |
| 未改造CPU実行ファイル | `4c192f67731597c9a13e95a5d3c174115244525300ca3d5749a041075294c28b` |
| PAW修正のみCPU版 | `372f5729aed56294c06b5440a5878967370e275e7c7a5ef259646c17ddf6f677` |
| PAW修正＋一括CPU版 | `6454fb141032deea948867e2234745e3ab65441d0eba97eac6a76da6e323d7eb` |
| 元のCPU k2/q1比較入力 | `941e55bd1b737734a5318c9ef3319eb2dd63f9b5d973abb34e7eb63a4fb7e79c` |

再現手順の要点は、共通のPBE seedを一度作り、独立した作業ディレクトリへコピーし、同一HSE入力について標準1pool、標準2pool、修正版1pool、修正版2pool、高速化版2poolを実行すること。初期化していないEXXコミュニケータを使う人工的な比較ではなく、実際のQE並列初期化を行う必要がある。

本番計算の再実行では、両poolの親監視プロセスがQEタイマーを10秒ごとに読み、各poolの完了k点数とEXX周回を記録するようにした。同じ周回の値だけを合計し、古い試行のログを新しい計算の進捗として使わない。

<a id="english"></a>
## English

### 1. Summary: three separate changes

Three changes were implemented and evaluated for HSE calculations of SnO using PAW datasets.

| Change | Purpose | Evidence available in this record |
| --- | --- | --- |
| GPU exchange-augmentation optimization | Move large US/PAW correction operations that remained on the CPU into batched GPU linear algebra | Small-mesh HSE energies agree with the stock implementation; shorter runtimes on two GPUs |
| CPU PAW one-center exchange repair | Correct a parallel execution condition that omits terms in additional k-point pools | Pool-dependent converged-energy drift reproduced with the installed stock executable and removed by the repair |
| CPU exchange-augmentation optimization | Batch US/PAW correction work using BLAS, using the repaired implementation as the reference | Small-mesh numerical agreement; approximately fourfold faster initial EXX construction with 32 MPI ranks |

**The missing-PAW-term repair and the optimization of `addusxx/newdxx` are independent changes.** Separate repair-only and repair-plus-batching CPU executables were retained to distinguish correctness from performance.

### 2. Scientific assumptions and computational settings

The broader objective is to obtain reliable HSE total energies for evaluating the structural and strain response of SnO. This report does not provide a final elastic tensor or an internally relaxed Poisson ratio.

Here, “HSE + PBE” means **HSE as the exchange-correlation functional, with PAW datasets generated using PBE**. It does not mean adding two independently calculated HSE and PBE total energies.

| Item | Setting |
| --- | --- |
| Code | Independent experimental builds based on the installed Quantum ESPRESSO 7.6 |
| Structure | Tetragonal SnO, four-atom cell: two Sn and two O atoms |
| Reference lattice/internal coordinate | `A=3.801 Å`, `C=4.984 Å`, `u=0.231` |
| Valence electrons | 40 per four-atom cell: 14 per Sn and 6 per O |
| Bands and spin | `nbnd=20`, `nspin=1`, `occupations='fixed'` |
| Functional | `input_dft='HSE'`, `exx_fraction=0.25`, `screening_parameter=0.106` |
| Cutoffs | `ecutwfc=80 Ry`, `ecutrho=400 Ry` |
| EXX | `ace=.true.`, `exxdiv_treatment='gygi-baldereschi'`, `x_gamma_extrapolation=.true.` |
| Electronic convergence | `conv_thr=1e-9`, `electron_maxstep=400`, `exx_maxstep=100` |
| SCF control | `adaptive_thr=.true.`, `conv_thr_init=1e-3`, `conv_thr_multi=0.1`, `mixing_beta=0.03`, Davidson diagonalization |
| Sn PAW dataset | `Sn.pbe-dn-kjpaw_psl.1.0.0.UPF`, MD5 `67f11dec737d427557dc41ea34975807` |
| O PAW dataset | `O.pbe-n-kjpaw_psl.1.0.0.UPF`, MD5 `e99d9cef9b487d1ca56f5b95ecd0fd7a` |

Twenty bands accommodate 40 electrons in 20 spin-degenerate occupied states. They do not mean that only 20 electrons were included. Empty-band convergence, excited-state applications, metals, and different occupation settings are outside the demonstrated scope.

| Test | k mesh | EXX q mesh | Interpretation |
| --- | --- | --- | --- |
| Small GPU numerical/performance test | 1×1×1 | 1×1×1 | General-k path; does not certify the specialized `K_POINTS gamma` path |
| CPU pool-dependence and optimization test | 2×1×1 | 1×1×1 | The same input can be compared using one and two pools |
| Production reference | 6×6×6 | 6×6×6 | 40 symmetry-reduced k points for this reference structure; final comparison remains in progress |

The CPU SCF comparisons used 32 MPI ranks on one node and one OpenMP/MKL thread per rank. GPU tests used one GPU, one MPI rank, and one CPU-side thread. GPU results were obtained with an RTX 3090 (24GB) and an RTX 2080 Ti (approximately 11GB), without establishing portability of the same speedup to other hardware or multiple GPUs. The CPU stack used Intel oneAPI/Intel MPI/MKL; the GPU prototype used CUDA Fortran and cuBLAS.

### 3. GPU bottleneck and implementation

HSE repeatedly constructs or updates the EXX operator and uses its ACE representation during the inner SCF cycle. In the small-mesh stock-GPU profile, large reciprocal-space US/PAW augmentation operations dominated EXX construction.

| Stock-GPU profile entry | WALL time |
| --- | ---: |
| `aceinit` | 415.46 s |
| `addusxx` | 204.33 s |
| `newdxx` | 201.17 s |
| Separate one-center `PAW_newdxx` | 1.60 s |

`addusxx + newdxx` account for approximately 97.6% of `aceinit` in this test. Their CPU times were also close to their wall times, providing direct evidence of substantial CPU computation. Transfer overhead alone was not established as the bottleneck.

The stock GPU execution mixed GPU work, such as FFT-related operations, with exchange-correction work that remained on the CPU. An independent `exx_paw_gpu` module was integrated into `exx_bp::vexx_bp_k_gpu` to:

- Batch projector coefficients and corrections over bands using cuBLAS `ZGEMM`.
- Use triangular symmetric projector-pair indexing.
- Reuse q-dependent phases and workspaces.
- Evaluate the corresponding PAW one-center term through density-matrix contractions and operations including `ZGEMV` on the GPU.
- Keep large correction arrays on the GPU and reduce correction-related round trips.

Complex double precision, the physical coefficients, functional, datasets, cutoffs, occupations, and convergence thresholds were retained. Host/device transfers were reduced, not eliminated.

The optimized scope is the collinear, general-k, reciprocal-space augmentation path. Noncollinear calculations, real-space `tqr`, the specialized Gamma-only path, and multi-rank GPU calculations were not certified by these tests. The GPU prototype was tested with one MPI rank and one pool.

### 4. Small-mesh GPU results

These k1/q1 HSE calculations were run to convergence with stock and modified GPU implementations. Modified-run times include array validation; creation of the initial PBE seed was separate.

| GPU | Stock-GPU HSE run | Modified GPU with validation | Ratio |
| --- | ---: | ---: | ---: |
| RTX 3090 | 436.81 s | 41.50 s | approximately 10.5× |
| RTX 2080 Ti | 344.75 s | 39.76 s | approximately 8.7× |

For this test, the CPU reference, stock GPU, and modified GPU all produced **−808.59971427 Ry per four-atom cell** to the printed precision.

Separate validation-disabled first-construction tests reported `aceinit` times of 46.52→1.12 s on the RTX 3090 and 41.32→2.04 s on the RTX 2080 Ti. These are first-EXX-construction measurements, not converged-SCF speedup factors.

The GPU prototype's array validator compared only the first 12 relevant calls per process against the stock CPU routines. Reported maximum differences were approximately 1.34×10⁻¹⁵ on the RTX 3090 and 1.18×10⁻¹⁵ on the RTX 2080 Ti. Reprinting those cumulative maxima later does not certify every subsequent q point or EXX cycle.

**These are small-mesh results. They do not establish final agreement or identical speedups for the production k6/q6 calculation.**

### 5. A separate CPU PAW omission exposed by CPU/GPU comparison

The production-mesh discrepancy was initially observed between a two-pool CPU calculation and a one-pool GPU calculation.

In `PW/src/paw_exx.f90`, the following routines evaluated the PAW one-center exchange correction only under `IF(ionode)`:

- `PAW_newdxx`: the one-center exchange contribution to the Hamiltonian.
- `PAW_xx_energy`: the corresponding exchange-energy contribution.

`ionode` denotes the image-wide I/O root, not a root in each k-point pool. Consequently, additional pools can omit their PAW term, and the subsequent reduction does not reconstruct the missing contribution. Because the Hamiltonian is affected as well as the energy evaluation, an SCF calculation can converge to a pool-dependent result.

The repair evaluates these terms **once per EXX group within every pool**:

```fortran
! Before
IF (ionode) THEN

! Experimental repair
IF (me_egrp == root_egrp) THEN
```

Existing caller reductions were retained. `PAW_init_fock_kernel` initializes the kernel on all ranks in the examined implementation, so no additional kernel broadcast was needed for the tested paths. Broadcasting one pool's correction to all pools would not generally be a valid substitute, because the wavefunctions processed by the pools differ.

### 6. Reproduction and numerical repair checks

Using the same saved, completed SnO wavefunctions, first-band PAW contractions were evaluated at global k-point indices 1/20/21/40:

- Stock one-pool evaluation gave nonzero terms at all four points.
- Stock two-pool evaluation gave exactly zero for points 21/40 in the second pool.
- Repaired two-pool complex projector vectors agreed with stock one-pool vectors within approximately 8.10×10⁻¹⁸.
- Repaired one-pool results matched stock one-pool results.

A separate small synthetic fixture using actual MPI communicators covered six valid combinations of 1/4 ranks, 1/2 pools, and 1/2/4 EXX groups. The repaired contributions agreed in those layouts. This checks omissions and duplicate accumulation; it is not a replacement for a complete SCF comparison.

Full small-mesh HSE SCF runs then used **identical input, datasets, and copied PBE seed state**, 32 MPI ranks, and k2×1×1/q1. The stock controls used the actual installed, unmodified CPU executable.

| CPU implementation | Pools | EXX-converged total energy, Ry per four-atom cell |
| --- | ---: | ---: |
| Installed stock | 1 | −808.90861004 |
| Installed stock | 2 | −808.87291502 |
| PAW repair only | 1 | −808.90861004 |
| PAW repair only | 2 | −808.90861004 |
| PAW repair + CPU batching | 2 | −808.90861004 |

All five runs reached EXX self-consistency and `JOB DONE`. The stock two-pool result alone shifted by **+0.03569502 Ry**. The repair removed this pool dependence in the demonstrated case. Agreement in the table means agreement to the printed eight decimal places, not bitwise identity of every internal quantity.

At corresponding intermediate stages of the production-mesh runs, the one-pool GPU minus two-pool CPU difference was approximately −0.04219332 Ry. An independent frozen-density contraction estimated the omitted pool's PAW exchange-energy contribution as approximately −0.04181626 Ry. Their sign and magnitude support this omission as the main explanation, but this estimate is not a new fully self-consistent final energy.

The raw Fock trace from that contraction was approximately −0.08363252 Ry. QE's convention `exxen = 0.5 * fock2` supplies the additional factor of one half. The raw trace must not be mistaken for the total-energy contribution.

### 7. CPU batching and the meaning of the fourfold speedup

The repair-only `pw_fixed.x` served as the baseline. The `pw_batch.x` variant additionally batches reciprocal-space US/PAW augmentation inside collinear general-k `vexx_bp_k`, using the existing band block, triangular projector pairs, Intel MKL `ZGEMM`, and reusable q phases/workspaces. Both binaries use the same repaired PAW one-center implementation.

CPU validation compares every active batch/q against the stock US augmentation routines and resets its counters at each initialization. It is disabled for performance measurements.

Three alternating-order first-`aceinit` comparisons used 32 MPI ranks, two pools, k2/q1, identical copied PBE seeds, and validation disabled:

| Repetition | PAW repair only | PAW repair + CPU batching |
| --- | ---: | ---: |
| 1 | 5.42 s | 1.37 s |
| 2 | 5.42 s | 1.36 s |
| 3 | 5.44 s | 1.35 s |
| Median | **5.42 s** | **1.36 s** |

The median ratio is **approximately 3.99× for EXX construction as a whole**, including the augmentation. It is neither the isolated `addusxx/newdxx` speedup nor the total-SCF speedup.

A separate synthetic component benchmark on one CPU core used 47109 G vectors, six q scenarios, and three repetitions:

| Batched bands | Stock add + new | Batched CPU add + new | Ratio |
| --- | ---: | ---: | ---: |
| 1 | 0.10042 s | 0.04729 s | 2.12× |
| 7 | 0.71125 s | 0.07717 s | 9.22× |
| 20 | 1.98375 s | 0.12407 s | 15.99× |

The current band block is seven. The approximately 9.2× component result and approximately 4× 32-rank result have different scopes and conditions. The synthetic fixture included nonzero initial arrays, complex data, changing q values, and partial band blocks. Maximum add/new array differences were approximately 7.02×10⁻¹⁶ and 1.41×10⁻¹², respectively.

### 8. Interpretation and remaining validation

- **Distinguish initial PBE, intermediate inner-SCF energies, and final HSE energies.** Final-energy validation requires EXX self-consistency and `JOB DONE`. Timing-only runs with `exx_maxstep=1` retain a pre-EXX seed energy in the output; that value is not evidence of converged HSE agreement.
- Validation-enabled runtimes include redundant reference computation and must not be represented as validation-disabled performance.
- This does not show that GPUs are intrinsically faster for all HSE calculations. Implementation, batching, data layout, system size, hardware, and MPI configuration all matter.
- The repaired small-mesh result does not certify every QE version, PAW dataset, spin condition, or parallel layout.
- **Final CPU/GPU agreement at k6/q6 is not established in this record.** Small-mesh success is insufficient for production certification.
- These changes concern SCF implementation and performance. They do not add HSE+PAW forces, stress, or direct `relax`/`vc-relax` support.
- The omitted term can depend on structure and electronic state. Adding a single constant to all previous energies does not validate elastic constants, internal relaxation, or a Poisson ratio.

### 9. Related prior reports

The official mirror's `develop/PW/src/paw_exx.f90` retained both `ionode` conditions at the time of inspection. [1]

| Public record | Relation to this investigation |
| --- | --- |
| Lorenzo Paulatto's 2016 PAW+EXX repair [2] | Re-enabled a PAW Hamiltonian contribution disabled by a `RETURN` and fixed related issues. A precedent for missing PAW contributions, but not identified as the same pool-specific omission |
| giannozz's 2018 Issue #9 [3] | Reports suspicious PAW+EXX energy changes and `tqr` issues; open at inspection. The public description does not identify the same cause |
| Ye Luo's 2018 Issue #42 [4] | Reports EXX band-group crashes/NaNs and related fixes; closed. The inspected description did not identify this `ionode` omission |
| Ron Leizrowice's 2026 Issue #875 [5] | Reports `us_exx` miscompilation with gfortran15 on macOS/arm64. Distinct from the demonstrated Intel/x86 pool dependence |

Other researchers have reported related PAW+EXX and parallelization issues. **No public report identifying this exact `ionode`-based omission in additional pools was confirmed in the bounded search. This is not a claim of first discovery or proof that no earlier report exists.**

The search covered public GitLab issue/MR titles and descriptions, official-mirror file history/commits, and public mailing lists. Searches for PAW, EXX, HSE, pool, ionode, and the two routine names yielded 94 unique issues. Individual issue/comment API endpoints returned 401, so comment threads were not exhaustively inspected. Private fixes and unindexed discussions cannot be excluded.

### 10. Reproducibility record

Comparisons controlled the physical settings, initial state, MPI/pool layout, convergence status, and executable/input identities. Standard installed sources and binaries were preserved; independent builds were used.

| Identity | SHA-256 |
| --- | --- |
| Examined stock `paw_exx.f90` | `ee8bcaac2b18b5e8503ba6107dd8ad7f57b3c9833063811891a5125e2b167177` |
| Installed unmodified CPU executable | `4c192f67731597c9a13e95a5d3c174115244525300ca3d5749a041075294c28b` |
| PAW-repair-only CPU executable | `372f5729aed56294c06b5440a5878967370e275e7c7a5ef259646c17ddf6f677` |
| PAW-repair-plus-batching CPU executable | `6454fb141032deea948867e2234745e3ab65441d0eba97eac6a76da6e323d7eb` |
| Original CPU k2/q1 comparison input | `941e55bd1b737734a5318c9ef3319eb2dd63f9b5d973abb34e7eb63a4fb7e79c` |

The key reproduction protocol is to create one common PBE seed, copy it into isolated working directories, and run the same HSE input with stock one-pool, stock two-pool, repaired one-pool, repaired two-pool, and batched two-pool implementations. Component probes must initialize the actual QE EXX communicators; uninitialized default group identifiers can invalidate such a comparison.

The restarted production calculation records each pool's completed k points and EXX cycle every ten seconds through a parent monitoring process. Pool counts are summed only when they refer to the same EXX cycle, and old-attempt logs are not used as current progress.

<a id="references"></a>
## References / 参考資料

1. [QE official mirror: `PW/src/paw_exx.f90`](https://github.com/QEF/q-e/blob/develop/PW/src/paw_exx.f90). The `develop` URL is mutable; the examined stock-source SHA-256 is recorded above.
2. [PAW+EXX changes, commit `fc0a3713`, 2016-11-04](https://github.com/QEF/q-e/commit/fc0a3713d7d166dfa89c83d289e31f70b5457e15).
3. [QE Issue #9: EXX with USPP and PAW](https://gitlab.com/QEF/q-e/-/issues/9).
4. [QE Issue #42: Bugs in EXX when nbgrp>1](https://gitlab.com/QEF/q-e/-/issues/42).
5. [QE Issue #875: `us_exx.f90` miscompiled by gfortran15 on macOS/arm64](https://gitlab.com/QEF/q-e/-/issues/875).
6. [QE parallelization documentation](https://www.quantum-espresso.org/Doc/user_guide/node20.html).

The benchmark numbers in this document are measurements from this investigation. The external references provide implementation context and related reports; they are not independent verification of these measurements.

本稿の性能・エネルギーの数値は本調査で得た測定値である。外部資料は実装の背景と関連報告を示すもので、これらの測定値を第三者が独立に検証したことを意味しない。

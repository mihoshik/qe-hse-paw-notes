# CPU版HSE＋PAW：pool数による交換補正欠落と修正

[一覧 / Index](README.md) · [English](CPU_PAW_POOL_BUG.en.md)

**記録日：2026-11-12（日本時間）**

同じ入力でもk点pool数により収束エネルギーが変わる現象、その原因と修正の数値照合を記録する。

## 1. 前提と比較条件

PBEで生成したPAW擬ポテンシャルを使用し、交換相関汎関数にはHSEを指定した。

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

収束エネルギーの比較は **k2×1×1/q1×1×1**。同一CPUノード上の32MPI、各rankのOpenMP/MKLは1スレッドで、Intel oneAPI/Intel MPI/MKL系のビルドを使用した。共通のPBE seedを作り、独立した作業ディレクトリにコピーして、同じHSE入力を実行した。

## 2. 標準版での再現と修正後の結果

同じ入力でpool数を1から2へ変えた場合の、EXX収束後の全エネルギーは次の通りだった。標準版には、実際にインストールされている未改造のCPU実行ファイルを使った。

| CPU版 | pool数 | 全エネルギー（Ry／4原子セル） |
| --- | ---: | ---: |
| 標準版 | 1 | −808.90861004 |
| 標準版 | 2 | −808.87291502 |
| PAW修正版 | 1 | −808.90861004 |
| PAW修正版 | 2 | −808.90861004 |

4計算ともEXX収束と`JOB DONE`を確認した。標準2poolだけが **＋0.03569502 Ry** ずれ、修正版ではpool依存性が解消した。一致は出力された小数点以下8桁での一致であり、内部の全ビットが同一という意味ではない。

## 3. 原因と修正箇所

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

## 4. 保存波動関数・MPI成分試験による確認

まず、完了済みの同じSnO保存波動関数を用い、global k点1/20/21/40の第1バンドのPAW項を評価した。

- 標準1poolでは4点とも非ゼロ。
- 標準2poolでは、pool1のk点21/40で項が正確にゼロ。
- 修正版2poolは標準1poolと、複素射影ベクトルの最大差約8.10×10⁻¹⁸以内で一致。
- 修正版1poolは標準1poolと一致。

小さな人工配列を使う別の実MPI試験でも、1/4rank、1/2pool、1/2/4EXXグループの有効な六つの構成で、同じ補正値になることを確認した。この試験は重複加算と欠落を確認するためのもので、完全なSCF計算の代わりではない。

## 5. 結果への影響と検証範囲

この結果は、記載したQE 7.6のソース・SnOのPAW・メッシュ・並列条件で確認したもの。あらゆるQE版、擬ポテンシャル、スピン条件を検証したものではない。

Hamiltonianにも入る項が欠落するため、単にエネルギー表示に定数を加減すれば済む問題ではない。欠落量は構造・電子状態に依存し得るので、既存の全構造へ同じ補正を加えて弾性・内部緩和・ポアソン比を求め直す方法は検証にならない。

2026-11-12の記録時点では、本番k6/q6の修正版による最終照合は未完了。

## 6. 実行ファイルの識別と実装参照

| 識別対象 | SHA-256 |
| --- | --- |
| 検証した標準`paw_exx.f90` | `ee8bcaac2b18b5e8503ba6107dd8ad7f57b3c9833063811891a5125e2b167177` |
| 未改造CPU実行ファイル | `4c192f67731597c9a13e95a5d3c174115244525300ca3d5749a041075294c28b` |
| PAW修正のみCPU版 | `372f5729aed56294c06b5440a5878967370e275e7c7a5ef259646c17ddf6f677` |
| CPU k2/q1比較入力 | `941e55bd1b737734a5318c9ef3319eb2dd63f9b5d973abb34e7eb63a4fb7e79c` |

標準インストールを上書きせず、独立したビルドを比較した。成分検証では実際のQE EXXコミュニケータを初期化した。

実装参照：[QE公式ミラーの`paw_exx.f90`](https://github.com/QEF/q-e/blob/develop/PW/src/paw_exx.f90)、[QEの並列化の説明](https://www.quantum-espresso.org/Doc/user_guide/node20.html)。`develop`のリンクは変化するため、検証したソースのハッシュを上記に記録した。ここに示す数値は本調査の測定値である。

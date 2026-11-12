# CPU batching and acceleration of HSE+PAW exchange augmentation

[Index / 一覧](README.md) · [日本語](CPU_ACCELERATION.ja.md)

**Recorded: 2026-11-12, Japan Standard Time**

Using the PAW-repaired implementation as the baseline, this document records batched CPU linear algebra for exchange augmentation and its numerical/performance evaluation.

## 1. Assumptions and test conditions

HSE was the exchange-correlation functional; the PAW datasets were generated using PBE.

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

Converged-energy tests used **k2×1×1/q1×1×1**, 32 MPI ranks on the same CPU node, and one OpenMP/MKL thread per rank, with an Intel oneAPI/Intel MPI/MKL build. One common PBE seed was copied into isolated working directories before running the same HSE input.

## 2. Batched implementation

The repair-only `pw_fixed.x` served as the baseline. The `pw_batch.x` variant additionally batches reciprocal-space US/PAW augmentation inside collinear general-k `vexx_bp_k`, using the existing band block, triangular projector pairs, Intel MKL `ZGEMM`, and reusable q phases/workspaces. Both binaries use the same repaired PAW one-center implementation.

CPU validation compares every active batch/q against the stock US augmentation routines and resets its counters at each initialization. It is disabled for performance measurements.

## 3. Controlled same-input timing

Three alternating-order first-`aceinit` comparisons used 32 MPI ranks, two pools, k2/q1, identical copied PBE seeds, and validation disabled:

| Repetition | PAW repair only | PAW repair + CPU batching |
| --- | ---: | ---: |
| 1 | 5.42 s | 1.37 s |
| 2 | 5.42 s | 1.36 s |
| 3 | 5.44 s | 1.35 s |
| Median | **5.42 s** | **1.36 s** |

The median speedup is **approximately 3.99× for QE's `aceinit` wall time in the first EXX cycle**. The timer covers exchange-operator application and ACE construction for each k point. Initialization in `exxinit`, wavefunction reads and projector preparation, and the inter-pool reduction after the k-point loop fall outside this measurement.

A separate synthetic component benchmark on one CPU core used 47109 G vectors, six q scenarios, and three repetitions:

| Batched bands | Stock add + new | Batched CPU add + new | Ratio |
| --- | ---: | ---: | ---: |
| 1 | 0.10042 s | 0.04729 s | 2.12× |
| 7 | 0.71125 s | 0.07717 s | 9.22× |
| 20 | 1.98375 s | 0.12407 s | 15.99× |

The 32-rank timing used a band block of seven. The synthetic benchmark measured each implementation three times per q scenario. Batch sizes 1, 7, and 20 used two, three, and one q scenarios, respectively. Each speedup compares the two implementations' median times over the same scenarios within that row. The approximately 9.2× component result and approximately 4× 32-rank result have different scopes and conditions. The synthetic fixture included nonzero initial arrays, complex data, changing q values, and partial band blocks. Maximum add/new array differences were approximately 7.02×10⁻¹⁶ and 1.41×10⁻¹², respectively.

## 4. Converged-energy checks

The following HSE runs used identical k2/q1 input and copied PBE seeds, with 32 MPI ranks and two pools in both cases.

| Implementation | EXX-converged total energy, Ry per four-atom cell |
| --- | ---: |
| PAW repair only | −808.90861004 |
| PAW repair + CPU batching, all-batch validation enabled | −808.90861004 |

Both runs reached EXX self-consistency and `JOB DONE`, agreeing to the printed eight decimal places. Array validation covered every active batch/q.

The last total energy printed in the `exx_maxstep=1` timing runs comes from the semilocal SCF before EXX construction. In these tests it matched the common PBE initialization energy to the printed precision. HSE numerical agreement is established by the separate converged runs above. Validation deliberately executes the stock reference work as well, so validation-enabled full-SCF times are not used as performance speedup factors.

## 5. Per-k time in production-size logs

Production-size logs on the same CPU node were also examined. Time per k point is the completed QE `vexx` WALL time divided by the number of completed calls, within the first EXX construction. The two pools run concurrently.

| Pool | Previous stock run: strained structure | Current batched run: reference structure | Previous/current time ratio |
| --- | ---: | ---: | ---: |
| 0 | approximately 19 min 24 s/k | approximately 4 min 51 s/k | approximately 3.99× |
| 1 | approximately 18 min 32 s/k | approximately 4 min 51 s/k | approximately 3.82× |

Both runs used 32 MPI ranks, two pools, k6/q6, 20 bands, and 80/400 Ry cutoffs. The previous case had −1% normal strain along the crystal [100] direction and 64 k points in total (32/pool); the current reference has 40 (20/pool). EXX G-vector counts also differ: 46521 versus 47005.

The previous averages cover 32 completed points per pool, while the current averages cover the first six. The observed per-k reduction is approximately 3.8–4.0×, but this is **an observational comparison of different structures**, separate from the controlled same-input benchmark. It must not be treated as a measured speedup for every EXX cycle or the complete converged SCF.

## 6. Runtime settings and implementation scope

| Setting | Behavior |
| --- | --- |
| `QE_PAW_CPU_BATCH=0` | Disable batching while retaining the PAW repair |
| `QE_PAW_CPU_VALIDATE=1` | Compare every active batch/q against the stock US augmentation routines |

Validation was disabled for performance measurements. The optimized scope is collinear, general-k, reciprocal-space augmentation. These changes do not certify or accelerate noncollinear, specialized Gamma-only, or real-space `tqr` paths, and do not add HSE+PAW forces, stress, or direct `relax`/`vc-relax` support.

| Identity | SHA-256 |
| --- | --- |
| Baseline PAW-repair-only CPU executable | `372f5729aed56294c06b5440a5878967370e275e7c7a5ef259646c17ddf6f677` |
| PAW-repair-plus-batching CPU executable | `6454fb141032deea948867e2234745e3ab65441d0eba97eac6a76da6e323d7eb` |
| k2/q1 converged comparison input | `941e55bd1b737734a5318c9ef3319eb2dd63f9b5d973abb34e7eb63a4fb7e79c` |

# GPU acceleration of HSE+PAW exchange operations

[Index / 一覧](README.md) · [日本語](GPU_ACCELERATION.ja.md)

**Recorded: 2026-11-12, Japan Standard Time**

This document records moving expensive exchange-augmentation work from the CPU to batched GPU linear algebra, together with numerical and performance checks.

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

The numerical/performance comparison in this document used **k1×1×1/q1×1×1** and 20 occupied bands through the general-k path, rather than the specialized `K_POINTS gamma` path. Runs used one GPU, one MPI rank, and one CPU-side thread, with an RTX 3090 (24GB) or RTX 2080 Ti (11GB). The prototype used CUDA Fortran/cuBLAS. Converged-run times are single measurements for each GPU/implementation, without a repeated-trial statistical performance evaluation.

## 2. Bottleneck and implementation

HSE repeatedly constructs or updates the EXX operator and uses its ACE representation during the inner SCF cycle. In the RTX 3090 small-mesh stock-GPU profile, large reciprocal-space US/PAW augmentation operations dominated EXX construction.

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
- Reuse q-independent phase factors and work arrays. At each q, upload the augmentation array and prepare the phase, then reuse them across band blocks at that q.
- Evaluate the corresponding PAW one-center term through density-matrix contractions and operations including `ZGEMV` on the GPU.
- Keep large correction arrays on the GPU and reduce correction-related round trips.

Complex double precision, the physical coefficients, functional, datasets, cutoffs, occupations, and convergence thresholds were retained. Host/device transfers were reduced, not eliminated.

The optimized scope is the collinear, general-k, reciprocal-space augmentation path. Noncollinear calculations, real-space `tqr`, the specialized Gamma-only path, and multi-rank GPU calculations were not certified by these tests. The GPU prototype was tested with one MPI rank and one pool.

## 3. Numerical agreement and runtime

These k1/q1 HSE calculations were run to convergence with stock and modified GPU implementations. Modified-run times include array validation; creation of the initial PBE seed was separate.

| GPU | Stock-GPU HSE run | Modified GPU with validation | Ratio |
| --- | ---: | ---: | ---: |
| RTX 3090 | 436.81 s | 41.50 s | approximately 10.5× |
| RTX 2080 Ti | 344.75 s | 39.76 s | approximately 8.7× |

For this test, the CPU reference, stock GPU, and modified GPU all produced **−808.59971427 Ry per four-atom cell** to the printed precision.

Separate validation-disabled first-construction tests reported `aceinit` times of 46.52→1.12 s on the RTX 3090 and 41.32→2.04 s on the RTX 2080 Ti. These are first-EXX-construction measurements, not converged-SCF speedup factors.

The GPU prototype's array validator compared only the first 12 relevant calls per process against the stock CPU routines. Reported maximum differences were approximately 1.34×10⁻¹⁵ on the RTX 3090 and 1.18×10⁻¹⁵ on the RTX 2080 Ti. Reprinting those cumulative maxima later does not certify every subsequent q point or EXX cycle.

**The reported speedups and numerical agreement apply to the small mesh. Final agreement at production k6/q6 is outside the validation scope of this note.** A synthetic nonzero-q fixture checks the US projector path. The real-SnO check including the PAW one-center term used k1/q1 with one MPI rank and one pool.

## 4. Reproducibility and implementation scope

A common PBE seed was copied into isolated working directories. Stock and modified GPU executables then used the same HSE input. Checks covered converged energies and correction-array differences against the stock routines. Validation-enabled converged runs were distinguished from validation-disabled first-construction timings.

| Identity | SHA-256 |
| --- | --- |
| Small-mesh GPU comparison input | `e737df030b15a4dd37693087bb4a33f58953eb00edc441ff6376ed6b981372d8` |

The change targets exchange operations in SCF. It does not add HSE+PAW forces, stress, or direct `relax`/`vc-relax` support.

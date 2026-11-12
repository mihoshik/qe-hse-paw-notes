# CPU HSE+PAW: pool-dependent missing exchange terms and repair

[Index / 一覧](README.md) · [日本語](CPU_PAW_POOL_BUG.ja.md)

**Recorded: 2026-11-12, Japan Standard Time**

This document records pool-dependent converged energies for the same input, the execution condition causing the omission, and numerical checks of the repair.

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

## 2. Stock reproduction and repaired results

EXX-converged total energies for the same input, changing only the pool layout and implementation, were as follows. The stock controls used the actual installed, unmodified CPU executable.

| CPU implementation | Pools | Total energy, Ry per four-atom cell |
| --- | ---: | ---: |
| Installed stock | 1 | −808.90861004 |
| Installed stock | 2 | −808.87291502 |
| PAW repair only | 1 | −808.90861004 |
| PAW repair only | 2 | −808.90861004 |

All four runs reached EXX self-consistency and `JOB DONE`. The stock two-pool result alone shifted by **+0.03569502 Ry**. The repair removed this pool dependence in the demonstrated case. Agreement is to the printed eight decimal places, not bitwise identity of every internal quantity.

## 3. Cause and implementation repair

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

## 4. Frozen-orbital and MPI component checks

Using the same saved, completed SnO wavefunctions, first-band PAW contractions were evaluated at global k-point indices 1/20/21/40:

- Stock one-pool evaluation gave nonzero terms at all four points.
- Stock two-pool evaluation gave exactly zero for points 21/40 in the second pool.
- Repaired two-pool complex projector vectors agreed with stock one-pool vectors within approximately 8.10×10⁻¹⁸.
- Repaired one-pool results matched stock one-pool results.

A separate small synthetic fixture using actual MPI communicators covered six valid combinations of 1/4 ranks, 1/2 pools, and 1/2/4 EXX groups. The repaired contributions agreed in those layouts. This checks omissions and duplicate accumulation; it is not a replacement for a complete SCF comparison.

## 5. Impact and validation scope

The demonstrated scope is the examined QE 7.6 source, these SnO PAW datasets, and the stated mesh/parallel settings. It does not certify all QE versions, datasets, or spin configurations.

The missing term affects the Hamiltonian as well as energy evaluation. Its magnitude can depend on structure and electronic state, so adding one constant to all earlier energies would not validate elastic constants, internal relaxation, or a Poisson ratio.

At the time of this 2026-11-12 record, the repaired production k6/q6 final comparison had not completed.

## 6. Executable identities and implementation references

| Identity | SHA-256 |
| --- | --- |
| Examined stock `paw_exx.f90` | `ee8bcaac2b18b5e8503ba6107dd8ad7f57b3c9833063811891a5125e2b167177` |
| Installed unmodified CPU executable | `4c192f67731597c9a13e95a5d3c174115244525300ca3d5749a041075294c28b` |
| PAW-repair-only CPU executable | `372f5729aed56294c06b5440a5878967370e275e7c7a5ef259646c17ddf6f677` |
| CPU k2/q1 comparison input | `941e55bd1b737734a5318c9ef3319eb2dd63f9b5d973abb34e7eb63a4fb7e79c` |

Independent builds were compared without replacing the installed software. Component probes initialized the actual QE EXX communicators.

Implementation references: [QE official mirror, `paw_exx.f90`](https://github.com/QEF/q-e/blob/develop/PW/src/paw_exx.f90), and [QE parallelization documentation](https://www.quantum-espresso.org/Doc/user_guide/node20.html). The `develop` URL is mutable; the examined source hash is recorded above. Numerical results here are measurements from this investigation.

# Reproduce the CPU HSE+PAW pool comparison

[日本語の解説](../../CPU_PAW_POOL_BUG.ja.md) · [English technical note](../../CPU_PAW_POOL_BUG.en.md)

This is the four-run SnO check using CPU Quantum ESPRESSO 7.6, 32 MPI ranks on one node, one thread per rank, a 2×1×1 k mesh and a 1×1×1 EXX q mesh. The two executables differ only in the guards for the PAW one-center exchange terms.

## Build the two CPU executables

Use separate copies of the same QE source with identical compiler, MPI, BLAS/LAPACK and configure options. The recorded build used the Intel oneAPI 2025.3.0 module with Intel MPI and MKL. The [patch](paw-exx-pool.patch) is against `PW/src/paw_exx.f90` from the tested build. Before applying it, check the stock file's SHA-256:

```text
ee8bcaac2b18b5e8503ba6107dd8ad7f57b3c9833063811891a5125e2b167177
```

From the **fixed** QE source root, with `REPRO` set to the absolute path to this directory:

```bash
sha256sum PW/src/paw_exx.f90
git apply --check "$REPRO/paw-exx-pool.patch"
git apply "$REPRO/paw-exx-pool.patch"
sha256sum PW/src/paw_exx.f90
```

The patched file's SHA-256 is `3b1fe9c8e3ea68d32e83c379ea887095cfe4897b4cb23e6f58554f8ba8dabf9b`. In each source tree, run `./configure` with the same site-specific options, then `make -j 4 pw`. Use the two CPU `bin/pw.x` executables. The original repaired executable was linked by replacing only `paw_exx.o` in a private build.

## Run the seed and four HSE calculations

Put these two PAW files in the same directory. Verify the MD5s with `md5sum` before running.

| UPF file | MD5 |
| --- | --- |
| `Sn.pbe-dn-kjpaw_psl.1.0.0.UPF` | `67f11dec737d427557dc41ea34975807` |
| `O.pbe-n-kjpaw_psl.1.0.0.UPF` | `e99d9cef9b487d1ca56f5b95ecd0fd7a` |

From a writable directory on a single CPU node with 32 MPI slots, load the MPI runtime matching the executables and run:

```bash
bash "$REPRO/run.sh" /path/to/stock/bin/pw.x /path/to/fixed/bin/pw.x /path/to/pseudo
```

For the Intel MPI/PMI2 configuration used in the recorded Slurm allocation, use the same command prefixed with `QE_USE_SLURM=1` inside an allocation for 32 tasks on one node. The driver uses `srun --mpi=pmi2 --cpu-bind=cores -n 32` there and `mpiexec -n 32` otherwise. Each PWSCF command uses `-npool 1` or `-npool 2`, followed by `-pd .true. -in scf.in`.

The driver converges the [PBE seed](inputs/seed.in) with the fixed executable and 2 pools. Each HSE run receives its own copy of the complete seed scratch directory and the same [HSE input](inputs/scf.in). The portable inputs differ from the recorded inputs only in `pseudo_dir='../pseudo'`. The driver creates a new run directory, retains stdout and stderr, and prints the last HSE energy after checking `EXX self-consistency reached` and `JOB DONE.`.

## Recorded results

These are the four original PWSCF stdout logs. Only the absolute pseudopotential directory was replaced with `[original-pseudo-dir]`. Energies, convergence messages, and timings are from the recorded runs.

| Executable | Pools | Final energy (Ry per 4-atom cell) | Log |
| --- | ---: | ---: | --- |
| Stock | 1 | −808.90861004 | [stock-1pool.out](logs/stock-1pool.out) |
| Stock | 2 | −808.87291502 | [stock-2pool.out](logs/stock-2pool.out) |
| Fixed | 1 | −808.90861004 | [fixed-1pool.out](logs/fixed-1pool.out) |
| Fixed | 2 | −808.90861004 | [fixed-2pool.out](logs/fixed-2pool.out) |

Check the reported MPI rank and pool counts in your logs. On a different build or MPI stack, check the stock pool-dependent shift and agreement after the repair, allowing for floating-point differences. The eight-decimal agreement above is the precision printed by PWSCF for this test.

The patch modifies Quantum ESPRESSO code, copyright © 2012 Quantum ESPRESSO group, originally written by Lorenzo Paulatto. It is distributed under the same GNU GPL terms as [the upstream source](https://github.com/QEF/q-e/blob/develop/PW/src/paw_exx.f90).

#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: bash %s STOCK_PW FIXED_PW PSEUDO_DIR\n' "$0" >&2
    exit 2
fi

here=$(cd -- "$(dirname -- "$0")" && pwd)
stock=$(realpath -- "$1")
fixed=$(realpath -- "$2")
pseudo=$(realpath -- "$3")
export OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
export QE_PAW_CPU_BATCH=0 QE_PAW_CPU_VALIDATE=0

if [[ ${QE_USE_SLURM:-0} == 1 ]]; then
    export I_MPI_PIN=0 I_MPI_FABRICS=shm I_MPI_SHM_CMA=0
    launch=(srun --mpi=pmi2 --cpu-bind=cores -n 32)
else
    launch=(mpiexec -n 32)
fi

results=$(mktemp -d "$PWD/paw-pool-repro.XXXXXX")
printf 'Run directory: %s\n' "$results"
ln -s -- "$pseudo" "$results/pseudo"

run_pw() (
    cd -- "$1"
    "${launch[@]}" "$2" -npool "$3" -pd .true. -in scf.in >scf.out 2>scf.err
)

mkdir -- "$results/seed"
cp -- "$here/inputs/seed.in" "$results/seed/scf.in"
run_pw "$results/seed" "$fixed" 2
grep -Fq 'convergence has been achieved' "$results/seed/scf.out"
grep -Fq 'JOB DONE.' "$results/seed/scf.out"

for variant in stock fixed; do
    case "$variant" in
        stock) exe=$stock ;;
        fixed) exe=$fixed ;;
    esac
    for pools in 1 2; do
        label="$variant-${pools}pool"
        case_dir="$results/$label"
        mkdir -- "$case_dir"
        cp -- "$here/inputs/scf.in" "$case_dir/scf.in"
        cp -a -- "$results/seed/scratch" "$case_dir/scratch"
        run_pw "$case_dir" "$exe" "$pools"
        printf '%s: ' "$label"
        awk '
            /^[[:space:]]*!![[:space:]]+total energy[[:space:]]*=/ {energy=$0; exx=0; done=0}
            /EXX self-consistency reached/ {exx=1}
            /JOB DONE\./ && exx {done=1}
            END {
                if (!energy || !done) {
                    print "Missing final HSE energy or completion marker" > "/dev/stderr"
                    exit 1
                }
                print energy
            }
        ' "$case_dir/scf.out"
    done
done

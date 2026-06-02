#!/usr/bin/env bash
#SBATCH --job-name=mass-ratio-reps
##SBATCH --partition=day
#SBATCH --time=04:00:00
#SBATCH --mem=128G
#SBATCH --cpus-per-task=21
#SBATCH --output=/gpfs/radev/project/yildirim/aa2842/GalileoMSC/logs/mass_ratio_reps_%j.out

set -euo pipefail

SCRIPT_DIR="/gpfs/radev/project/yildirim/aa2842/GalileoMSC/scripts"
PROJECT_ROOT="/gpfs/radev/project/yildirim/aa2842/GalileoMSC"

RUNS="${RUNS:-20}"

if [[ -z "${WORKERS:-}" ]]; then
  if [[ "${SLURM_CPUS_PER_TASK}" -gt 1 ]]; then
    WORKERS="$((SLURM_CPUS_PER_TASK - 1))"
  else
    WORKERS="1"
  fi
fi

OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/results/mass_ratio_replicates_${SLURM_JOB_ID}}"

cd "${PROJECT_ROOT}"

echo "Job ID: ${SLURM_JOB_ID}"
echo "Node list: ${SLURM_JOB_NODELIST:-unknown}"
echo "CPUs per task: ${SLURM_CPUS_PER_TASK}"
echo "Julia workers: ${WORKERS}"
echo "Runs per model: ${RUNS}"
echo "Output directory: ${OUT_DIR}"

julia --project="${PROJECT_ROOT}" \
  "${PROJECT_ROOT}/scripts/run_mass_ratio_replicates.jl" \
  --runs "${RUNS}" \
  --workers "${WORKERS}" \
  --out-dir "${OUT_DIR}" \
  "$@"

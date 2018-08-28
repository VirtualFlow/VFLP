#!/bin/bash
# ---------------------------------------------------------------------------
#
# Usage: . sync-jobfile.sh VF_JOBLINE_NO
#
# Description: Synchronizes the jobfile with the settings in the VF_CONTROLFILE
# (the global or local VF_CONTROLFILE if existent).
#
# Revision history:
# 2015-12-05  Created (version 1.2)
# 2015-12-12  Various improvements (version 1.10)
# 2015-12-16  Adaption to version 2.1
# 2016-07-16  Various improvements
# 2017-03-18  Including the parition in the config file
#
# ---------------------------------------------------------------------------
# Displaying help if first argument is -h
if [ "${1}" = "-h" ]; then
usage="Usage: . sync-jobfile.sh VF_JOBLINE_NO"
    echo -e "\n${usage}\n\n"
    return
fi
if [[ "$#" -ne "1" && "$#" -ne "2" ]]; then
   echo -e "\nWrong number of arguments. Exiting."
   echo -e "\n${usage}\n\n"
   return 1
fi

# Standard error response
error_response_nonstd() {
    echo "Error was trapped which is a nonstandard error."
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})"
    echo "Error on line $1"
    exit 1
}
trap 'error_response_nonstd $LINENO' ERR

# Variables
VF_JOBLINE_NO=${1}

# Determining the controlfile to use for this jobline
VF_CONTROLFILE=""
for file in $(ls ../../workflow/control/*-* 2>/dev/null || true); do
    file_basename=$(basename $file)
    jobline_range=${file_basename/.*}
    VF_JOBLINE_NO_START=${jobline_range/-*}
    VF_JOBLINE_NO_END=${jobline_range/*-}
    if [[ "${VF_JOBLINE_NO_START}" -le "${VF_JOBLINE_NO}" && "${VF_JOBLINE_NO}" -le "${VF_JOBLINE_NO_END}" ]]; then
        export VF_CONTROLFILE="${file}"
        break
    fi
done
if [ -z "${VF_CONTROLFILE}" ]; then
    export VF_CONTROLFILE="../workflow/control/all.ctrl"
fi

# Getting the batchsystem type
batchsystem="$(grep -m 1 "^batchsystem=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"


# Printing some information
echo -e "Syncing the jobfile of jobline ${VF_JOBLINE_NO} with the controlfile file ${VF_CONTROLFILE}."

# Syncing the number of nodes
nodes_per_job_new="$(grep -m 1 "^nodes_per_job=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${batchsystem}" = "SLURM" ]; then
    job_line=$(grep -m 1 "nodes=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)
    VF_NODES_PER_JOB_old=${job_line/"#SBATCH --nodes="}
    sed -i "s/nodes=${VF_NODES_PER_JOB_old}/nodes=${nodes_per_job_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    job_line=$(grep -m 1 " -l nodes=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)
    VF_NODES_PER_JOB_old=${job_line/"#PBS -l nodes="}
    VF_NODES_PER_JOB_old=${VF_NODES_PER_JOB_old/:*}
    sed -i "s/nodes=${VF_NODES_PER_JOB_old}:/nodes=${nodes_per_job_new}:/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
fi

# Syncing the number of cpus per step
cpus_per_step_new="$(grep -m 1 "^cpus_per_step=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${batchsystem}" = "SLURM" ]; then
    job_line="$(grep -m 1 "cpus-per-task=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)"
    cpus_per_step_old=${job_line/"#SBATCH --cpus-per-task="}
    sed -i "s/cpus-per-task=${cpus_per_step_old}/cpus-per-task=${cpus_per_step_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    job_line="$(grep -m 1 " -l nodes=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)"
    cpus_per_step_old=${job_line/\#PBS -l nodes=*:ppn=}
    sed -i "s/ppn=${cpus_per_step_old}/ppn=${cpus_per_step_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "LSF" ]; then
    job_line="$(grep -m 1 "\-n" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)"
    cpus_per_step_old=${job_line/\#BSUB -n }
    sed -i "s/-n ${cpus_per_step_old}/-n ${cpus_per_step_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
    sed -i "s/ptile=${cpus_per_step_old}/ptile=${cpus_per_step_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
fi

# Syncing the timelimit
line=$(cat ../${VF_CONTROLFILE} | grep -m 1 "^timelimit=")
timelimit_new="$(grep -m 1 "^timelimit=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${batchsystem}" == "SLURM" ]; then
    job_line=$(grep -m 1 "^#SBATCH \-\-time=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)
    timelimit_old=${job_line/"#SBATCH --time="}
    sed -i "s/${timelimit_old}/${timelimit_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    job_line=$(grep -m 1 "^#PBS \-l walltime=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)
    timelimit_old=${job_line/"#PBS -l walltime="}
    sed -i "s/${timelimit_old}/${timelimit_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" == "SGE" ]; then
    job_line=$(grep -m 1 "^#\$ \-l h_rt=" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)
    timelimit_old=${job_line/"#\$ -l h_rt="}
    sed -i "s/${timelimit_old}/${timelimit_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" == "LSF" ]; then
    job_line=$(grep -m 1 "^#BSUB \-W " ../../workflow/job-files/main/${VF_JOBLINE_NO}.job)
    timelimit_old=${job_line/"#BSUB -W "}
    sed -i "s/${timelimit_old}/${timelimit_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
fi

# Syncing the partition
line=$(cat ../${VF_CONTROLFILE} | grep -m 1 "^partition=")
partition_new="$(grep -m 1 "^partition=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${batchsystem}" = "SLURM" ]; then
    sed -i "s/--partition=.*/--partition=${partition_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    sed -i "s/^#PBS -q .*/#PBS -q ${partition_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "SGE" ]; then
    sed -i "s/^#\\$ -q .*/#\$ -q ${partition_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "LSF" ]; then
    sed -i "s/^#BSUB -q .*/#BSUB -q ${partition_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
fi

# Syncing the job letter
line=$(cat ../${VF_CONTROLFILE} | grep -m 1 "^job_letter=")
job_letter_new="$(grep -m 1 "^job_letter=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${batchsystem}" = "SLURM" ]; then
    sed -i "s/^#SBATCH --job-name=[a-zA-Z]/#SBATCH --job-name=${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    sed -i "s/^#PBS -N [a-zA-Z]/#PBS -N ${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "SGE" ]; then
    sed -i "s/^#\\$ -N [a-zA-Z]/#\$ -N ${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "LSF" ]; then
    sed -i "s/^#BSUB -J [a-zA-Z]/#BSUB -J ${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
fi


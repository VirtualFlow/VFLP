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

# Getting the batchsystem type
line=$(grep -m 1 "^batchsystem" ../../workflow/control/all.ctrl)
batchsystem="${line/batchsystem=}"


# Printing some information
echo -e "Syncing the jobfile of jobline ${VF_JOBLINE_NO} with the VF_CONTROLFILE file ${VF_CONTROLFILE}."

# Syncing the number of nodes
line=$(cat ../${VF_CONTROLFILE} | grep -m 1 "^VF_NODES_PER_JOB=")
nodes_per_job_new=${line/"VF_NODES_PER_JOB="}
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
line=$(cat ../${VF_CONTROLFILE} | grep -m 1 "cpus_per_step=")
cpus_per_step_new=${line/"cpus_per_step="}
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
line=$(cat ../${VF_CONTROLFILE} | grep -m 1  "^timelimit=")
timelimit_new=${line/"timelimit="}
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
partition_new=${line/"partition="}
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
job_letter_new=${line/"job_letter="}
if [ "${batchsystem}" = "SLURM" ]; then
    sed -i "s/^#SBATCH --job-name=[a-zA-Z]/#SBATCH --job-name=${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    sed -i "s/^#PBS -N [a-zA-Z]/#PBS -N ${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "SGE" ]; then
    sed -i "s/^#\\$ -N [a-zA-Z]/#\$ -N ${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
elif [ "${batchsystem}" = "LSF" ]; then
    sed -i "s/^#BSUB -J [a-zA-Z]/#BSUB -J ${job_letter_new}/g" ../../workflow/job-files/main/${VF_JOBLINE_NO}.job
fi


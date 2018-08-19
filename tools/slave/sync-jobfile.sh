#!/bin/bash
# ---------------------------------------------------------------------------
#
# Usage: . sync-jobfile.sh jobline_no
#
# Description: Synchronizes the jobfile with the settings in the controlfile
# (the global or local controlfile if existent).
#
# Revision history:
# 2015-12-05  Created (version 1.2)
# 2015-12-12  Various improvements (version 1.10)
# 2015-12-16  Adaption to version 2.1
# 2016-07-16  Various improvements
#
# ---------------------------------------------------------------------------

# Displaying help if first argument is -h
if [ "${1}" = "-h" ]; then
usage="Usage: . sync-jobfile.sh jobline_no"
    echo "${usage}"
    return
fi

# Variables
jobline_no=${1}

# Getting the batchsystem type
line=$(grep -m 1 batchsystem ../../workflow/control/all.ctrl)
batchsystem="${line/batchsystem=}"

# Determining the batchsystem controlfile to use for this jobline
if [ -f ../../workflow/control/${jobline_no}.ctrl ]; then
    controlfile="../../workflow/control/${jobline_no}.ctrl"
else
    controlfile="../../workflow/control/all.ctrl"
fi

# Setting the number of nodes
line=$(cat ${controlfile} | grep "nodes_per_job=")
nodes_per_job_new=${line/"nodes_per_job="}
if [ "${batchsystem}" = "SLURM" ]; then
    job_line=$(grep -m 1 "nodes=" ../../workflow/job-files/main/${jobline_no}.job)
    nodes_per_job_old=${job_line/"#SBATCH --nodes="}
    sed -i "s/nodes=${nodes_per_job_old}/nodes=${nodes_per_job_new}/g" ../../workflow/job-files/main/${jobline_no}.job
elif [ "${batchsystem}" = "MT" ]; then
    job_line=$(grep -m 1 " -l nodes=" ../../workflow/job-files/main/${jobline_no}.job)
    sed -i "s/nodes=${nodes_per_job_old}:/nodes=${nodes_per_job_new}:/g" ../../workflow/job-files/main/${jobline_no}.job
fi

# Setting the number of cpus per step
line=$(cat ${controlfile} | grep "cpus_per_step=")
cpus_per_step_new=${line/"cpus_per_step="}
if [ "${batchsystem}" = "SLURM" ]; then
    job_line="$(grep -m 1 "cpus-per-task=" ../../workflow/job-files/main/${jobline_no}.job)"
    cpus_per_step_old=${job_line/"#SBATCH --cpus-per-task="}
    sed -i "s/cpus-per-task=${cpus_per_step_old}/cpus-per-task=${cpus_per_step_new}/g" ../../workflow/job-files/main/${jobline_no}.job
elif [ "${batchsystem}" = "MT" ]; then
    job_line="$(grep -m 1 " -l nodes=" ../../workflow/job-files/main/${jobline_no}.job)"
    cpus_per_step_old=${job_line/\#PBS -l nodes=*:ppn=}
    sed -i "s/ppn=${cpus_per_step_old}/ppn=${cpus_per_step_new}/g" ../../workflow/job-files/main/${jobline_no}.job
fi

# Setting the timelimit
line=$(cat ${controlfile} | grep "timelimit=")
timelimit_new=${line/"timelimit="}
if [ "batchsystem" = "SLURM" ]; then
    job_line=$(grep -m 1 "time=" ../../workflow/job-files/main/${jobline_no}.job)
    timelimit_old=${job_line/"#SBATCH --time="}
    sed -i "s/${timelimit_old}/${timelimit_new}/g" ../../workflow/job-files/main/${jobline_no}.job
elif [ "${batchsystem}" = "MT" ]; then
    job_line=$(grep -m 1 "walltime=" ../../workflow/job-files/main/${jobline_no}.job)
    timelimit_old=${job_line/\#PBS -l walltime=}
    sed -i "s/${timelimit_old}/${timelimit_new}/g" ../../workflow/job-files/main/${jobline_no}.job
fi

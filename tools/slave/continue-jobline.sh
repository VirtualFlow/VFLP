#!/bin/bash
# ---------------------------------------------------------------------------
#
# Usage: . continue-jobline.sh jobline_no partition/queue sync_mode
#
# Description: Continues a jobline by adjusting the latest job script and submitting
# it to the batchsystem.
#
# Option: sync_mode
#    Possible values: 
#        sync: The sync-control-jobfile script is called
#        anything else: no synchronization
#
# Revision history:
# 2015-12-05  Created (version 1.2)
# 2015-12-12  Various improvements (version 1.10)
# 2015-12-16  Adaption to version 2.1
# 2016-07-16  Various improvements
#
# ---------------------------------------------------------------------------

# Displaying help if the first argument is -h
usage="Usage: . continue-jobline.sh jobline_no batch_partition sync_mode"
if [ "${1}" = "-h" ]; then
    echo "${usage}"
    return
fi

# Variables
partition=${2}

# Getting the batchsystem type
line=$(grep -m 1 "^batchsystem=" ../../workflow/control/all.ctrl)
batchsystem="${line/batchsystem=}"

# Getting the jobline number and the old job number
jobline_no=${1}
if [ "${batchsystem}" = "SLURM" ]; then
    line=$(cat ../../workflow/job-files/main/${jobline_no}.job | grep -m 1 "job-name")
    old_job_no=${line/"#SBATCH --job-name=j-"}
elif [ "${batchsystem}" = "MT" ]; then
    line=$(cat ../../workflow/job-files/main/${jobline_no}.job | grep -m 1 "\-N")
    old_job_no=${line/\#PBS -N j-}
fi
old_job_no_2=${old_job_no/*.}


# Computing the new job number
new_job_no_2=$((${old_job_no_2} + 1))
new_job_no="${jobline_no}.${new_job_no_2}"


# Syncing the workflow settings if specified
if [ "${3}" = "sync" ]; then
    . sync-jobfile.sh ${jobline_no}
fi

# Changing the partition
if [ "${batchsystem}" = "SLURM" ]; then
    line=$(cat ../../workflow/job-files/main/${jobline_no}.job | grep -m 1 "partition=")
    sed -i "s/${line}/#SBATCH --partition=${partition}/g" ../../workflow/job-files/main/${jobline_no}.job
elif [ "${batchsystem}" = "MT" ]; then
    line=$(cat ../../workflow/job-files/main/${jobline_no}.job | grep -m 1 " -q ")
    sed -i "s/${line}/\#PBS -q ${partition}/g" ../../workflow/job-files/main/${jobline_no}.job
fi

# Updating the job name (increase by one)
sed -i "s/j-${old_job_no}/j-${new_job_no}/g" ../../workflow/job-files/main/${jobline_no}.job

# Updating the output filenames (increase by one)
sed -i "s/${old_job_no}_/${new_job_no}_/g" ../../workflow/job-files/main/${jobline_no}.job

# Submitting new job
. submit.sh ../workflow/job-files/main/${jobline_no}.job ${partition}


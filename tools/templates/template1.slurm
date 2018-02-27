#!/bin/bash
# ---------------------------------------------------------------------------
#
# Description: Slurm job file. 
#
# Revision history:
# 2015-12-05  Created (version 1.2)
# 2015-12-07  Various improvemnts (version 1.3)
# 2015-12-16  Adaption to version 2.1
# 2016-07-16  Various improvements
#
# ---------------------------------------------------------------------------


# Slurm Settings
###############################################################################

#SBATCH --job-name=j-1.1
#SBATCH --mail-user=silmaril@zedat.fu-berlin.de
#SBATCH --mail-type=fail
#SBATCH --time=00-01:00:00
#SBATCH --mem-per-cpu=500
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=test
#SBATCH --output=../workflow/output-files/jobs/job-1.1_%j.out           # File to which standard out will be written
#SBATCH --error=../workflow/output-files/jobs/job-1.1_%j.out            # File to which standard err will be written


# Job Information
##################################################################################

echo
echo "                    *** Job Information ***                    "
echo "==============================================================="
echo 
echo "Environment variables"
echo "------------------------"
env
echo
echo
echo "Job infos by scontrol"
echo "------------------------"
scontrol show job $SLURM_JOB_ID

# Running the Job - Screening of the Ligands
######################################################################
echo
echo "                    *** Job Output ***                    "
echo "==========================================================="
echo

# Functions
# Standard error response 
error_response_std() {
    echo "Error was trapped" 1>&2
    echo "Error in bash script $0" 1>&2
    echo "Error on line $1" 1>&2
    echo "Environment variables" 1>&2 
    echo "----------------------------------" 1>&2
    env 1>&2
    print_job_infos_end
    exit 1
}
trap 'error_response_std $LINENO' ERR

# Printing final job information
print_job_infos_end() {
    # Job information
    echo
    echo "                     *** Final Job Information ***                    "
    echo "======================================================================"
    echo
    echo "Starting time:" $STARTINGTIME
    echo "Ending time:  " $(date)
    echo
}

# Checking if the queue should be stopped
check_queue_end1() {
    if [ -f ../workflow/control/${jobline_no}.ctrl ]; then
        export controlfile="../workflow/control/${jobline_no}.ctrl"
    else
        export controlfile="../workflow/control/all.ctrl"
    fi

    # Checking if the queue should be stopped
    line="$(cat ${controlfile} | grep "stop_after_ligand=")"
    stop_after_ligand=${line/"stop_after_ligand="}
    if [ "${stop_after_ligand}" = "yes" ]; then
        echo
        echo "This job line was stopped by the stop_after_ligand flag in the controlfile ${controlfile}."
        echo
        print_job_infos_end
        exit 0
    fi

    # Checking if there are still ligand collections todo
    no_collections_processing="0"
    no_collections_incomplete="$(cat ../workflow/ligand-collections/todo/todo.all ../workflow/ligand-collections/todo/${jobline_no}* ../workflow/ligand-collections/current/${jobline_no}* 2>/dev/null | grep -c "[^[:blank:]]" || true)"
    if [[ "${no_collections_incomplete}" = "0" ]]; then
        echo
        echo "This job line was stopped because there are no ligand collections left."
        echo
        print_job_infos_end
        exit 0
    fi
}

check_queue_end2() {
    check_queue_end1
    line=$(cat ${controlfile} | grep "stop_after_job=")
    stop_after_job=${line/"stop_after_job="}
    if [ "${stop_after_job}" = "yes" ]; then
        echo
        echo "This job line was stopped by the stop_after_job flag in the controlfile ${controlfile}."
        echo
        print_job_infos_end
        exit 0
    fi
}

# Creating the /tmp/${USER} folder if not present
if [ ! -d "/tmp/${USER}" ]; then
    mkdir /tmp/${USER}
fi

# Setting important variables
export nodes_per_job=${SLURM_JOB_NUM_NODES}
export old_job_no=${SLURM_JOB_NAME/j-}
export old_job_no_2=${old_job_no/*.}
export queue_no_1=${old_job_no/.*}
export jobline_no=${queue_no_1}
export batch_system="SLURM"
export sleep_time_1="1"
STARTINGTIME=`date`
export start_time_seconds="$(date +%s)"

# Determining the workflow controlfile to use for this jobline
if [ -f ../workflow/control/${jobline_no}.ctrl ]; then
    export controlfile="../workflow/control/${jobline_no}.ctrl"
else
    export controlfile="../workflow/control/all.ctrl"
fi

# Checking if queue should be stopped
check_queue_end1

# Getting the available wallclock time
job_line=$(grep -m 1 "time=" ../workflow/job-files/main/${jobline_no}.job)
timelimit=${job_line/"#SBATCH --time="}
timelimit=${timelimit//-/:}
export timelimit_seconds="$(echo -n "${timelimit}" | awk -F ':' '{print $4 + $3 * 60 + $2 * 3600 + $1 * 3600 * 24}')"

# Getting the number of queues per step
line=$(cat ${controlfile} | grep "queues_per_step=")
export queues_per_step=${line/"queues_per_step="}

# Preparing the todo lists for the queues
cd slave
bash prepare-todolists ${jobline_no} ${nodes_per_job} ${queues_per_step}
cd ..

# Starting the individual steps on different nodes
for step_no in $(seq 1 ${nodes_per_job} ); do
    export step_no
    echo "Starting job step $step_no on host $(hostname)."
    srun --relative=$((step_no - 1)) -n 1 -N 1 ../workflow/job-files/sub/one-step.sh &
    sleep "${sleep_time_1}"
done

# Waiting for all steps to finish
wait


# Creating the next job
#####################################################################################
echo
echo
echo "                  *** Preparing the next batch system job ***                     "
echo "=================================================================================="
echo

# Checking if the queue should be stopped
check_queue_end2

# Syncing the new jobfile with the settings in the controlfile
cd slave
. sync-jobfile ${jobline_no}
cd ..

# Changing the job name
new_job_no_2=$((old_job_no_2 + 1))
new_job_no="${jobline_no}.${new_job_no_2}"
sed -i "s/j-${old_job_no}/j-${new_job_no}/g" ../workflow/job-files/main/${jobline_no}.job

# Changing the output filenames
sed -i "s/${old_job_no}_/${new_job_no}_/g" ../workflow/job-files/main/${jobline_no}.job

# Submitting a new new job
cd slave 
. submit ../workflow/job-files/main/${jobline_no}.job
cd ..


# Finalizing the job
#####################################################################################
print_job_infos_end

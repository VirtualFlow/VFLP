#!/bin/bash
# ---------------------------------------------------------------------------
#
# Description: Subjobfile which runs on one node and belongs to one batch system step. 
#
# Revision history:
# 2015-12-05  Created (version 1.2)
# 2015-12-07  Various improvemnts (version 1.3)
# 2015-12-16  Adaption to version 2.1
# 2016-07-16  Various improvements
#
# ---------------------------------------------------------------------------

# Functions
# Standard error response 
error_response_std() {
    echo "Error was trapped" 1>&2
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})" 1>&2
    echo "Error on line $1" 1>&2
    echo "Environment variables" 1>&2 
    echo "----------------------------------" 1>&2
    env 1>&2
    exit 0
}
trap 'error_response_std $LINENO' ERR

time_near_limit() {
    echo "The script one-step.sh caught a time limit signal."
    echo "Sending this signal to all the queues started by this step."
    kill -s 10 ${pids[*]} || true
    wait
}
trap 'time_near_limit' 10

another_signal() {
    echo "The script one-step.sh caught a terminating signal."
    echo "Sending terminating signal to all the queues started by this step."
    kill -s 1 ${pids[*]} || true
    wait
}
trap 'time_near_limit' 1 2 3 9 15


# Sourcing bashrc
source ~/.bashrc

prepare_queue_files_tmp() {
    # Creating the required folders    
    if [ -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO}/" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO}/
    fi
    mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO}/workflow/output-files/queues
    
    # Copying the requires files
    if ls -1 ../workflow/output-files/queues/queue-${VF_QUEUE_NO}.* > /dev/null 2>&1; then
        cp ../workflow/output-files/queues/queue-${VF_QUEUE_NO}.* ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO}/workflow/output-files/queues/
    fi    
}

# Verbosity
if [ "${VF_VERBOSITY_LOGFILES}" = "debug" ]; then
    set -x
fi

# Setting and exporting variables
export VF_QUEUE_NO_2=${VF_STEP_NO}
export VF_QUEUE_NO_12="${VF_QUEUE_NO_1}-${VF_QUEUE_NO_2}"
export VF_LITTLE_TIME="false";
export VF_START_TIME_SECONDS
export VF_TIMELIMIT_SECONDS
pids=""
chemaxon_license_file="$(grep -m 1 "^chemaxon_license_file=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Copying the ChemAxon license file if needed
if [[ ! "${chemaxon_license_file}" == "none" ]] && [[ -n "${chemaxon_license_file}" ]]; then

    # Creating the required folders
    if [ -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/ChemAxon/" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/ChemAxon/*
    else
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/ChemAxon/
    fi
    cp $(eval echo ${chemaxon_license_file}) ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/ChemAxon/

    # Adjusting the CHEMAXON environment variable
    export CHEMAXON_LICENSE_URL=$(eval echo ${chemaxon_license_file})
fi

# Starting the individual queues
for i in $(seq 1 ${VF_QUEUES_PER_STEP}); do
    export VF_QUEUE_NO_3="${i}"
    export VF_QUEUE_NO="${VF_QUEUE_NO_12}-${VF_QUEUE_NO_3}"
    prepare_queue_files_tmp
    echo "Job step ${VF_STEP_NO} is starting queue ${VF_QUEUE_NO} on host $(hostname)."
    . ../workflow/job-files/sub/one-queue.sh >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out 2>&1 &
    pids[$(( i - 1 ))]=$!
done

# Checking if all queues exited without error ("wait" waits for all of them, but always returns 0)
exit_code=0
for pid in ${pids[@]}; do
    wait $pid || let "exit_code=1"
done
if [ "$exit_code" == "1" ]; then
    error_response_std
fi

# Cleaning up
exit 0

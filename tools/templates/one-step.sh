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
    if [ -d "/tmp/${USER}/${queue_no}/" ]; then
        rm -r /tmp/${USER}/${queue_no}/
    fi
    mkdir -p /tmp/${USER}/${queue_no}/workflow/output-files/queues
    
    # Copying the requires files
    if ls -1 ../workflow/output-files/queues/queue-${queue_no}.* > /dev/null 2>&1; then
        cp ../workflow/output-files/queues/queue-${queue_no}.* /tmp/${USER}/${queue_no}/workflow/output-files/queues/
    fi    
}

# Setting important variables
export queue_no_2=${step_no}
export queue_no_12="${queue_no_1}-${queue_no_2}"
export little_time="false";
export start_time_seconds
export timelimit_seconds
export CHEMAXON_LICENSE_URL=/tmp/${USER}/ChemAxon/license.cxl
pids=""

# Copying the license file
# Creating the required folders    
if [ -d "/tmp/${USER}/ChemAxon/" ]; then
    rm -r /tmp/${USER}/ChemAxon/*
else 
    mkdir -p /tmp/${USER}/ChemAxon/
fi
cp ${HOME}/downloads/ChemAxon/license.cxl /tmp/${USER}/ChemAxon/

# Starting the individual queues
for i in $(seq 1 ${queues_per_step}); do
    export queue_no_3="${i}"
    export queue_no="${queue_no_12}-${queue_no_3}"
    prepare_queue_files_tmp
    echo "Job step ${step_no} is starting queue ${queue_no} on host $(hostname)."
    . ../workflow/job-files/sub/one-queue.sh >> /tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out 2>&1 &
    pids[$(( i - 1 ))]=$!
done

wait || true

# Cleaning up


exit 0

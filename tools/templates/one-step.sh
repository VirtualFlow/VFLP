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

    # Printint some information
    echo "Error was trapped" 1>&2
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})" 1>&2
    echo "Error on line $1" 1>&2
    echo "Environment variables" 1>&2
    echo "----------------------------------" 1>&2
    env 1>&2

    # Checking error response
    if [[ "${VF_ERROR_RESPONSE}" == "ignore" ]]; then

        # Printing some information
        echo -e "\n * Ignoring error. Trying to continue..."
    elif [[ "${VF_ERROR_RESPONSE}" == "next_job" ]]; then

        # Printing some information
        echo -e "\n * Trying to stop this queue without causing the jobline to fail..."

        # Exiting
        exit 0

    elif [[ "${VF_ERROR_RESPONSE}" == "fail" ]]; then

        # Printing some information
        echo -e "\n * Trying to stop this queue and causing the jobline to fail..."

        # Exiting
        exit 1
    fi
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


clean_up() {

    # Removing the used temp folder folder
    rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages || true
}
trap 'clean_up' EXIT

# Sourcing bashrc
source ~/.bashrc

prepare_queue_files_tmp() {
    # Creating the required folders    
    if [ -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/
    fi
    mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues
    
    # Copying the requires files
    if ls -1 ../workflow/output-files/queues/queue-${VF_QUEUE_NO}.* > /dev/null 2>&1; then
        cp ../workflow/output-files/queues/queue-${VF_QUEUE_NO}.* ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/
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
protonation_state_generation="$(grep -m 1 "^protonation_state_generation=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
protonation_program_1="$(grep -m 1 "^protonation_program_1=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
protonation_program_2="$(grep -m 1 "^protonation_program_2=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
conformation_generation="$(grep -m 1 "^conformation_generation=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
conformation_program_1="$(grep -m 1 "^conformation_program_1=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
conformation_program_2="$(grep -m 1 "^conformation_program_2=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
store_queue_log_files="$(grep -m 1 "^store_queue_log_files=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Preparing the JChem and associated packages if JChem is used
if [[ ( "${protonation_state_generation}" == "true" && ( "${protonation_program_1}" == "cxcalc" || "${protonation_program_2}" == "cxcalc" )) || ( "${conformation_generation}" == "true" && ( "${conformation_program_1}" == "molconvert" || "${conformation_program_2}" == "molconvert" )) ]]; then

    # Preparing the JChem Package
    chemaxon_license_filename="$(grep -m 1 "^chemaxon_license_filename=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    jchem_package_filename="$(grep -m 1 "^jchem_package_filename=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/
    tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/ -xvzf packages/${jchem_package_filename}
    #chmod u+x ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/jchemsuite/bin/*
    #export PATH="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/jchemsuite/bin:$PATH"

    # Copying the ChemAxon license file if needed
    if [[ "${chemaxon_license_filename}" == "none" ]] || [[ -z "${chemaxon_license_filename}" ]]; then

        # Error
        echo " Error: The ChemAxon license file was not specified, but is required..."

        # Causing an error
        error_response_std $LINENO

    elif [[ ! -f "packages/${chemaxon_license_filename}" ]]; then

        # Error
        echo " Error: The specified ChemAxon license file was not found..."

        # Causing an error
        error_response_std $LINENO

    else
        # Copying the ChemAxon licence file
        cp packages/${chemaxon_license_filename} ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/license.cxl

        # Adjusting the CHEMAXON_LICENSE_URL environment variable
        export CHEMAXON_LICENSE_URL="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/license.cxl"
    fi

    # Preparing the JVM
    java_package_filename="$(grep -m 1 "^java_package_filename=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

    if [[ ${java_package_filename} != "none" ]]; then
        if [[ -f packages/${java_package_filename} ]]; then
            tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/ -xvzf packages/${java_package_filename}

            # Checking the folder structure
            if [ ! -d ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/java/ ]; then

                # Error
                echo " Error: The root folder of the java package does not seem to have the name \'java\', which is required..."

                # Causing an error
                error_response_std $LINENO
            fi

            export JAVA_HOME="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/java"
            chmod u+x ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/java/bin/*
            export PATH="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/java/bin:$PATH"
        else

            # Error
            echo " Error: The Java package file (java_package_filename=${java_package_filename}) which was specified in the relevant controlfile (${VF_CONTROLFILE}) was was not found..."

            # Causing an error
            error_response_std $LINENO
        fi
    fi

    # Preparing ng
    java_max_heap_size="$(grep -m 1 "^java_max_heap_size=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    ng_package_filename="$(grep -m 1 "^ng_package_filename=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/ -xvzf packages/${ng_package_filename}
    export CLASSPATH="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/nailgun/nailgun-server/target/classes:${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/chemaxon/jchemsuite/lib/*"
    chmod u+x ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/nailgun/nailgun-client/target/ng
    export PATH="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/packages/nailgun/nailgun-client/target/:$PATH"
    # Getting the first free port (Source: https://unix.stackexchange.com/questions/55913/whats-the-easiest-way-to-find-an-unused-local-port )
    read lowerport upperport < /proc/sys/net/ipv4/ip_local_port_range
    while :
    do
        test_port="$(shuf -i $lowerport-$upperport -n 1)"
        bin/ss -lpn | grep -q ":${test_port} " || break
    done
    export NG_PORT=${test_port}
    # Starting the ng server
    # Java 10/11 debugging options: -XX:+HeapDumpOnOutOfMemoryError -XX:OnOutOfMemoryError="echo %p" -XX:OnError="echo %p" -Xlog:gc*:file=${PWD}/java.gc.${VF_QUEUE_NO_12}.log -Xlog:all=warning:file=${PWD}/java.warning.${VF_QUEUE_NO_12}.log
    # Java 8 debugging options: -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${PWD}/java.gc.${VF_QUEUE_NO_12}.log -XX:-PrintConcurrentLocks -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:${PWD}/java.gc.${VF_QUEUE_NO_12}.log
    java -Xmx${java_max_heap_size}G com.martiansoftware.nailgun.NGServer localhost:${NG_PORT} &
    sleep 10 # Loading the ng server takes a few seconds
fi

# Starting the individual queues
for i in $(seq 1 ${VF_QUEUES_PER_STEP}); do
    export VF_QUEUE_NO_3="${i}"
    export VF_QUEUE_NO="${VF_QUEUE_NO_12}-${VF_QUEUE_NO_3}"
    prepare_queue_files_tmp
    echo "Job step ${VF_STEP_NO} is starting queue ${VF_QUEUE_NO} on host $(hostname)."
    if [ ${store_queue_log_files} == "all_uncompressed" ]; then
        source ../workflow/job-files/sub/one-queue.sh &>> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.all &
    elif [ ${store_queue_log_files} == "all_compressed" ]; then
        source ../workflow/job-files/sub/one-queue.sh 2>&1 | gzip >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.all.gz &
    elif [ ${store_queue_log_files} == "only_error_uncompressed" ]; then
        source ../workflow/job-files/sub/one-queue.sh 2> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.err &
    elif [ ${store_queue_log_files} == "only_error_compressed" ]; then
        source ../workflow/job-files/sub/one-queue.sh 2> >(gzip >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.err.gz) &
    elif [ ${store_queue_log_files} == "std_compressed_error_uncompressed" ]; then
        source ../workflow/job-files/sub/one-queue.sh 1> >(gzip >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.std.gz) 2>> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.err &
    elif [ ${store_queue_log_files} == "all_compressed_error_uncompressed" ]; then
        source ../workflow/job-files/sub/one-queue.sh 1> >(gzip >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.all.gz) 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out.err) &
    elif [ ${store_queue_log_files} == "none" ]; then
        source ../workflow/job-files/sub/one-queue.sh 2>&1 >/dev/null &
    else
        echo "Error: The variable store_log_file in the control file ${VF_CONTROLFILE} has an unsupported value (${store_queue_log_files})."
        false
    fi
    pids[$(( i - 1 ))]=$!
done

# Checking if all queues exited without error ("wait" waits for all of them, but always returns 0)
exit_code=0
for pid in ${pids[@]}; do
    wait $pid || let "exit_code=1"
done
if [ "$exit_code" == "1" ]; then
    error_response_std $LINENO
fi

# Cleaning up
exit 0

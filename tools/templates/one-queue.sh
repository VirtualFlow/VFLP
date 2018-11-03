#!/bin/bash
# ---------------------------------------------------------------------------
#
# Description: Bash script for virtual screening of ligands with AutoDock Vina.
#
# ---------------------------------------------------------------------------

# Setting the verbosity level
if [[ "${VF_VERBOSITY_LOGFILES}" == "debug" ]]; then
    set -x
fi

# Setting the error sensitivity
if [[ "${VF_ERROR_SENSITIVITY}" == "high" ]]; then
    set -uo pipefail
    trap '' PIPE        # SIGPIPE = exit code 141, means broken pipe. Happens often, e.g. if head is listening and got all the lines it needs.
fi
# TODO: different input file format
# TODO: Test with storing logfile
# TODO: Change ligand-lists/todo /current ... to subfolders
# TODO: add ligand info into each completed collection -> creating correct sums and faster
# TODO: Refill during runtime

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

        # Cleaning up
        clean_queue_files_tmp

        # Printing some information
        echo -e "\n * Trying to stop this queue and causing the jobline to fail..."

        # Exiting
        exit 0

    elif [[ "${VF_ERROR_RESPONSE}" == "fail" ]]; then

        # Cleaning up
        clean_queue_files_tmp

        # Printing some information
        echo -e "\n * Trying to stop this queue and causing the jobline to fail..."

        # Exiting
        exit 1
    fi
}
trap 'error_response_std $LINENO' ERR

# Time limit close
time_near_limit() {
    VF_LITTLE_TIME="true";
    end_queue 0
}
trap 'time_near_limit' 1 2 3 9 10 12 15

# Cleaning the queue folders
clean_queue_files_tmp() {
    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.* ../workflow/output-files/queues/
    sleep 1
    rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/
}
trap 'clean_queue_files_tmp' EXIT RETURN

# Writing the ID of the next ligand to the current ligand list
update_ligand_list_start() {

    # Variables
    ligand_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    ligand_list_entry=""

    # Updating the ligand-list file
    echo "${next_ligand} processing" >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status
}

update_ligand_list_end() {

    # Variables
    success="${1}" # true or false
    ligand_total_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${ligand_start_time_ms}))"

    # Updating the ligand-list file
    perl -pi -e "s/${next_ligand/_T*}.* processing.*/${next_ligand} ${ligand_list_entry} total-time:${ligand_total_time_ms}/g" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status

    # Printing some information
    echo
    if [ "${success}" == "true" ]; then
        echo "Ligand ${next_ligand} completed ($2) on $(date)."
    else
        echo "Ligand ${next_ligand} failed ($2) on on $(date)."
    fi
    echo "Total time for this ligand (${next_ligand}) in ms: ${ligand_total_time_ms}"
    echo

    # Variables
    ligand_list_entry=""
}

# Obtaining the next ligand collection.
next_ligand_collection() {
    trap 'error_response_std $LINENO' ERR
    needs_cleaning=false

    # Checking if this jobline should be stopped now
    line=$(cat ${VF_CONTROLFILE} | grep "^stop_after_collection=")
    stop_after_collection=${line/"stop_after_collection="}
    if [ "${stop_after_collection}" = "true" ]; then
        echo
        echo "This job line was stopped by the stop_after_collection flag in the VF_CONTROLFILE ${VF_CONTROLFILE}."
        echo
        end_queue 0
    fi
    echo
    echo "A new collection has to be used if there is one."

    # Checking if there exists a todo file for this queue
    if [ ! -f ../workflow/ligand-collections/todo/${VF_QUEUE_NO} ]; then
        echo
        echo "This queue is stopped because there exists no todo file for this queue."
        echo
        end_queue 0
    fi

    # Loop for iterating through the remaining collections until we find one which is not already finished
    new_collection="false"
    while [ "${new_collection}" = "false" ]; do

       # Checking if there is one more ligand collection to be done
        no_collections_remaining="$(grep -cv '^\s*$' ../workflow/ligand-collections/todo/${VF_QUEUE_NO} || true)"
        if [[ "${no_collections_remaining}" = "0" ]]; then
            # Renaming the todo file to its original name
            no_more_ligand_collection
        fi

        # Setting some variables
        next_ligand_collection=$(head -n 1 ../workflow/ligand-collections/todo/${VF_QUEUE_NO} | awk '{print $1}')
        next_ligand_collection_length=$(head -n 1 ../workflow/ligand-collections/todo/${VF_QUEUE_NO} | awk '{print $2}')
        next_ligand_collection_tranch="${next_ligand_collection/_*}"
        next_ligand_collection_metatranch="${next_ligand_collection_tranch:0:2}"
        next_ligand_collection_ID="${next_ligand_collection/*_}"
        if grep -w "${next_ligand_collection}" ../workflow/ligand-collections/done/* &>/dev/null; then
            echo "This ligand collection was already finished. Skipping this ligand collection."
        elif grep -w "${next_ligand_collection}" ../workflow/ligand-collections/current/* &>/dev/null; then
            echo "On this ligand collection already another queue is working. Skipping this ligand collection."
        elif grep -w ${next_ligand_collection} $(ls ../workflow/ligand-collections/todo/* | grep -v "${VF_QUEUE_NO}" &>/dev/null); then
            echo "This ligand collection is in one of the other todo-lists. Skipping this ligand collection."
        else
            new_collection="true"
        fi
        # Removing the new collection from the ligand-collections-todo file
        perl -ni -e "print unless /${next_ligand_collection}\b/" ../workflow/ligand-collections/todo/${VF_QUEUE_NO}
    done

    # Updating the ligand-collection files
    echo "${next_ligand_collection} ${next_ligand_collection_length}" > ../workflow/ligand-collections/current/${VF_QUEUE_NO}

    if [ "${VF_VERBOSITY_LOGFILES}" == "debug" ]; then
        echo -e "\n***************** INFO **********************"
        echo ${VF_QUEUE_NO}
        ls -lh ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
        cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
        cat ../workflow/ligand-collections/todo/${VF_QUEUE_NO} 2>/dev/null || true
        echo -e "***************** INFO END ******************\n"
    fi

    # Creating the subfolder in the ligand-lists folder
    mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists

    # Printing some information
    echo "The new ligand collection is ${next_ligand_collection}."
}

# Preparing the folders and files in ${VF_TMPDIR}
prepare_collection_files_tmp() {

    # Creating the required folders
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    for targetformat in ${targetformats//:/ }; do
        if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
        elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/")" ]; then
            rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
        fi
    done
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/*
    fi


    # Copying the required files
    tar -xf ${collection_folder}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/ ${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar.gz
    gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar.gz


    # Checking if the collection could be extracted
    if [ ! -f ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar ]; then

        # Raising an error
        echo " * Error: The ligand collection ${next_ligand_collection_tranch}_${next_ligand_collection_ID} could not be prepared."
        false
    fi

    # Extracting all the SMILES at the same time (faster than individual for each ligand separately)
    tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}

    # Copying the required old output files if continuing old collection
    if [ "${new_collection}" == "false" ]; then

        # Loop for each target format
        for targetformat in ${targetformats//:/ }; do
            tar -xvzf ../output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/
        done

        if [[ -f  ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status ]]; then
            cp ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/
        fi
    fi

    # Cleaning up
    tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar
}

# Stopping this queue because there is no more ligand collection to be screened
no_more_ligand_collection() {

    # Printing some information
    echo
    echo "This queue is stopped because there is no more ligand collection."
    echo

    # Ending the queue
    end_queue 0
}

# Tidying up collection folders and files in ${VF_TMPDIR}
clean_collection_files_tmp() {

    # Checking if cleaning is needed at all
    if [ "${needs_cleaning}" = "true" ]; then
        local_ligand_collection=${1}
        local_ligand_collection_tranch="${local_ligand_collection/_*}"
        local_ligand_collection_metatranch="${local_ligand_collection_tranch:0:2}"
        local_ligand_collection_ID="${local_ligand_collection/*_}"

        # Checking if all the folders required are there
        if [ "${collection_complete}" = "true" ]; then

            # Loop for each target format
            for targetformat in ${targetformats//:/ }; do

                # Compressing the collection and saving in the complete folder
                mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/
                tar -cvzf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/ ${local_ligand_collection_ID}
                local_ligand_collection_length="$(ls ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID} | wc -l)"
                echo "${local_ligand_collection}" "${local_ligand_collection_length}" >> ../output-files/complete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}.length

                # Adding the completed collection archive to the tranch archive
                mkdir  -p ../output-files/complete/${targetformat}/${local_ligand_collection_metatranch}
                tar -rf ../output-files/complete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranch} ${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz || true

                # Cleaning up
                rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz 2>&1 > /dev/null || true

            done

            # Checking if we should keep the ligand log summary files
            if [ "${keep_ligand_summary_logs}" = "true" ]; then

                # Directory preparation
                mkdir  -p ../output-files/complete/logfiles/${local_ligand_collection_metatranch}
                tar -rf ../output-files/complete/logfiles/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranch}/ ${local_ligand_collection_tranch}/${local_ligand_collection_ID}.status || true
            fi

            # Updating the ligand collection files
            echo -n "" > ../workflow/ligand-collections/current/${VF_QUEUE_NO}
            ligands_succeeded_tautomerization="$(grep succeeded ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.status | grep -c tautomerization)"
            ligands_succeeded_conversion="$(grep succeeded ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.status | grep -vc tautomerization)"
            ligands_failed="$(grep -c failed ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.status)"
            ligands_started=$((ligands_succeeded_conversion+ligands_failed))
            echo "${local_ligand_collection} was completed by queue ${VF_QUEUE_NO} on $(date). Ligands started:${ligands_started} succeeded(tautomerization):${ligands_succeeded_tautomerization} succeeded(conversion):${ligands_succeeded_conversion} failed:${ligands_failed}" >> ../workflow/ligand-collections/done/${VF_QUEUE_NO}

        else
            # Loop for each target format
            for targetformat in ${targetformats//:/ }; do
                # Compressing the collecion
                tar -cvzf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/ ${local_ligand_collection_ID}

                # Copying the files which should be kept in the permanent storage location
                mkdir -p ../output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz ../output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/
            done

            mkdir -p ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/
            cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/ || true

        fi

        # Cleaning up
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} 2>&1 > /dev/null || true
        rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.status 2>&1 > /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} 2>&1 > /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} 2>&1 > /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} 2>&1 > /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} 2>&1 > /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} 2>&1 > /dev/null || true

        # Cleaning up
        for targetformat in ${targetformats//:/ }; do
            rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranch}/${local_ligand_collection_tranch}/${local_ligand_collection_ID} 2>&1 > /dev/null || true
        done

    fi
    needs_cleaning="false"
}

# Function for end of the queue
end_queue() {

    # Variables
    exitcode=${1}

    # Checking if cleaning up is needed
    if [[ "${ligand_index}" -gt "1" && "${new_collection}" == "false" ]] ; then
        clean_collection_files_tmp ${next_ligand_collection}
    fi

    # Cleaning up the queue files
    clean_queue_files_tmp

    #  Exiting
    exit ${exitcode}
}

# Checking the pdb file for 3D coordinates
check_pdb_coordinates() {

    # Checking the coordinates
    no_nonzero_coord="$(grep -E "ATOM|HETATM" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb | awk -F ' ' '{print $6,$7,$8}' | tr -d '0.\n\+\- ' | wc -m)"
    if [ "${no_nonzero_coord}" -eq "0" ]; then
        echo "The pdb(qt) file only contains zero coordinates."
        return 1
    else
        return 0
    fi
}

# Desalting
desalt() {


    # Number of fragments in SMILES
    number_of_smiles_fragments="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | wc -l)"

    # Checking the number of fragments
    if [[ "${number_of_smiles_fragments}" -ge "2" ]]; then

        # Carrying out the desalting
        trap '' ERR
        desalted_smiles_largest_fragment="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | perl -e 'print sort { length($a) <=> length($b) } <>' | tail -n 1)"
        desalted_smiles_smallest_fragment="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | perl -e 'print sort { length($a) <=> length($b) } <>' | head -n 1)"
        last_exit_code=$?
        trap 'error_response_std $LINENO' ERR

        # Checking if the desalting was successful
        if [ "${last_exit_code}" -ne "0" ]; then
            echo "    * Warning: Desalting has failed. Desalting procedure resulted in a non-zero exit code..."
        elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found|non-zero'; then
            echo "    * Warning: Desalting has failed. An error flag was detected in the log files..."
        elif [[ -z ${desalted_smiles_largest_fragment} ]]; then
            echo "    * Warning: Desalting has failed. No valid SMILES were generated..."
        else

            # Printing some information
            echo "    * Ligand successfully desalted."

            # Variables
            desalting_success="true"
            desalting_type="genuine"
            pdb_desalting_remark="REMARK    The ligand was desalted by extracting the largest organic fragment (out of ${number_of_smiles_fragments}) from the original structure."

            # Storing the SMILES of the largest fragment
            echo ${desalted_smiles_largest_fragment} > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
        fi
    elif [[ "${number_of_smiles_fragments}" -eq "1" ]]; then

        # Printing some information
        echo "    * Ligand was not a salt, leaving it untouched."

        # Variables
        desalting_success="true"
        desalting_type="untouched"
        pdb_desalting_remark="REMARK    The ligand was originally not a salt, therefore no desalting was carried out."

        # Nothing to extract, just copying the structure
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
    else

        # Printing some information
        echo "    * Warning: Could not determine the number of fragments. Desalting failed..."
    fi
}

standardizer_neutralize() {

    # Checking if the charged counterion
    charged_counterion=false
    if echo ${desalted_smiles_smallest_fragment} | grep -c -E "\-\]|\+\]" &>/dev/null; then
        charged_counterion="true"
    fi

    # Checking type of neutralization mode
    neutralization_flag="false"
    if [[ "${neutralization_mode}" == "always" ]]; then
        neutralization_flag="true"
    elif [[ "${neutralization_mode}" == "if_genuine_desalting" && "${number_of_smiles_fragments}" -ge "2" ]]; then
        neutralization_flag="true"
    elif [[ "${neutralization_mode}" == "if_genuine_desalting_and_charged" && "${number_of_smiles_fragments}" -ge "2" && "${charged_counterion}" == "true" ]]; then
        neutralization_flag="true"
    fi

    # Checking if conversion successful
    if [ ${neutralization_flag} == "true" ]; then

        # Carrying out the neutralization
        trap '' ERR
        timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of standardizer (user real system): %U %e %S"  ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.standardizer.StandardizerCLI ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -c "neutralize" | tail -n 1 > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
        last_exit_code=$?
        trap 'error_response_std $LINENO' ERR

        if [ "${last_exit_code}" -ne "0" ]; then
            echo "    * Warning: Neutralization with Standardizer failed. Standardizer was interrupted by the timeout command..."
        elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 4 | grep "refused"; then
            echo "    * Error: The Nailgun server seems to have terminated..."
            error_response_std $LINENO
        elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found'; then
            echo "    * Warning: Neutralization with Standardizer failed. An error flag was detected in the log files..."
        elif [[ ! -s  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ]]; then
            echo "    * Warning: Neutralization with Standardizer failed. No valid SMILES file was generated..."
        else
            echo "    * Ligand successfully neutralized by Standardizer."
            neutralization_success="true"
            pdb_neutralization_remark="REMARK    The compound was neutralized by Standardizer version ${standardizer_version} of ChemAxons JChem Suite."
            neutralization_type="genuine"
        fi
    else
        # Printing some information
        echo "    * This ligand does not need to be neutralized, leaving it untouched."

        # Variables
        neutralization_success="true"
        neutralization_type="untouched"
    fi
}

# Protonation with cxcalc
cxcalc_tautomerize() {

    # Carrying out the tautomerization
    trap '' ERR
    tautomer_smiles=$(timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of cxcalc (user real system): %U %e %S"  ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator tautomers ${cxcalc_tautomerization_options} ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk -F ' ' '{print $2}' | tr "." " ")
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if the tautomerization was successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Tautomeriization with cxcalc failed. cxcalc was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 4 | grep "refused"; then
        echo "    * Error: The Nailgun server seems to have terminated..."
        error_response_std $LINENO
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found|non-zero'; then
        echo "    * Warning: Tautomeriization with cxcalc failed. An error flag was detected in the log files..."
    elif [[ -z ${tautomer_smiles} ]]; then
        echo "    * Warning: Tautomerization with cxcalc failed. No valid SMILES were generated..."
    else
        echo "    * Ligand successfully tautomerized by cxcalc."
        tautomerization_success="true"
        pdb_tautomerization_remark="REMARK    The tautomeric state was generated by cxcalc version ${cxcalc_version} of ChemAxons JChem Suite."
        tautomerization_program="cxcalc"

        # Storing each tautomer SMILES in a file and storing the new ligand names
        tautomer_index=0
        next_ligand_tautomers=""
        for tautomer_smile in ${tautomer_smiles}; do
            tautomer_index=$((tautomer_index + 1))
            echo ${tautomer_smile} > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}_T${tautomer_index}.smi
            next_ligand_tautomers="${next_ligand_tautomers} ${next_ligand}_T${tautomer_index}"
        done
    fi
}

# Protonation with cxcalc
cxcalc_protonate() {

    # Carrying out the protonation
    trap '' ERR
    timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of cxcalc (user real system): %U %e %S"  ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator majorms -H ${protonation_pH_value} ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk -F ' ' '{print $2}' > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Protonation with cxcalc failed. cxcalc was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 4 | grep "refused"; then
        echo "    * Error: The Nailgun server seems to have terminated..."
        error_response_std $LINENO
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found'; then
        echo "    * Warning: Protonation with cxcalc failed. An error flag was detected in the log files..."
    elif [[ ! -s  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ]]; then
        echo "    * Warning: Protonation with cxcalc failed. No valid SMILES file was generated..."
    else
        echo "    * Ligand successfully protonated by cxcalc."
        protonation_success="true"
        pdb_protonation_remark="REMARK    Protonation state was generated at pH ${protonation_pH_value} by cxcalc version ${cxcalc_version} of ChemAxons JChem Suite."
        protonation_program="cxcalc"
    fi
}

# Protonation with obabel
obabel_protonate() {

    # Carrying out the protonation
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of obabel (user real system): %U %e %S" obabel -p ${protonation_pH_value} -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -osmi -O ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi)
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Protonation with obabel failed. obabel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found'; then
        echo "    * Warning: Protonation with obabel failed. An error flag was detected in the log files..."
    elif [[ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ]]; then
        echo "    * Warning: Protonation with cxcalc failed. No valid SMILES file was generated (empty or nonexistent)..."
    else
        echo "    * Ligand successfully protonated by obabel."
        protonation_success="true"
        pdb_protonation_remark="REMARK    The protonation state was generated at pH ${protonation_pH_value} by Open Babel version ${obabel_version}"
        protonation_program="obabel"
    fi
}

# Conformation generation with molconvert
molconvert_generate_conformation() {

    # Converting SMILES to 3D PDB
    # Trying conversion with molconvert
    trap '' ERR
    timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of molconvert (user real system): %U %e %S" ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.formats.MolConverter pdb:+H -3 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -o ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb 2>&1
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Conformation generation with molconvert failed. Molconvert was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 4 | grep "refused"; then
        echo "    * Error: The Nailgun server seems to have terminated..."
        error_response_std $LINENO
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E'failed|timelimit|error|no such file|not found' &>/dev/null; then
        echo "    * Warning: Conformation generation with molconvert failed. An error flag was detected in the log files..."
    elif [ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb ]; then
        echo "    * Warning: Conformation generation with molconvert failed. No valid PDB file was generated (empty or nonexistent)..."
    elif ! check_pdb_coordinates; then
        echo "    * Warning: The output PDB file exists but does not contain valid coordinates."
    else
        # Printing some information
        echo "    * 3D conformation successfully generated with molconvert."

        # Variables
        conformation_success="true"
        pdb_conformation_remark="REMARK    Generation of the 3D conformation was carried out by molconvert version ${molconvert_version} of ChemAxons JChem Suite."
        conformation_program="molconvert"
        molconvert_3D_options="$(grep -m 1 "^molconvert_3D_options=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

        # Modifying the header of the pdb file and correction of the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/TITLE\|SOURCE\|KEYWDS\|EXPDTA/d' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb | sed "s/PROTEIN.*/Small molecule (ligand)/g" | sed "s/AUTHOR.*/${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_conformation_remark}/g" | sed "/REVDAT.*/d" | sed "s/NONE//g" | sed "s/ UN[LK] / LIG /g" | sed "s/COMPND.*/COMPND    Compound: ${next_ligand}/g" | sed 's/+0//' | sed 's/\([+-]\)\([0-9]\)$/\2\1/g' | sed '/^\s*$/d' > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp
        mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb
    fi
}

# Conformation generation with obabel
obabel_generate_conformation(){

    # Converting SMILES to 3D PDB
    # Trying conversion with obabel
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of obabel (user real system): %U %e %S" obabel --gen3d -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -opdb -O ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb 2>&1 | sed "s/1 molecule converted/The ligand was successfully converted from smi to pdb by obabel.\n/" >  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp)
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion c
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Conformation generation with obabel failed. Open Babel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found' &>/dev/null; then
        echo "    * Warning: Conformation generation with obabel failed. An error flag was detected in the log files..."
    elif [ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb ]; then
        echo "    * Warning: Conformation generation with obabel failed. No valid PDB file was generated (empty or nonexistent)..."
    elif ! check_pdb_coordinates; then
        echo "    * Warning: The output PDB file exists but does not contain valid coordinates."
    else
        # Printing some information
        echo "    * 3D conformation successfully generated with obabel."

        # Variables
        conformation_success="true"
        pdb_conformation_remark="REMARK    Generation of the 3D conformation was carried out by Open Babel version ${obabel_version}"
        conformation_program="obabel"

        # Modifying the header of the pdb file and correction the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/COMPND/d' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}//${next_ligand}.pdb | sed "s/AUTHOR.*/HEADER    Small molecule (ligand)\nCOMPND    Compound: ${next_ligand}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_conformation_remark}/g" | sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp
        mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb
    fi
}

# PDB generation with obabel
obabel_generate_pdb() {

    # Converting SMILES to PDB
    # Trying conversion with obabel
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "    * Timings of obabel (user real system): %U %e %S" obabel -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -opdb -O ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}//${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb 2>&1 | sed "s/1 molecule converted/The ligand was successfully converted from smi to pdb by obabel.\n/" >  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp)
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: PDB generation with obabel failed. Open Babel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found' &>/dev/null; then
        echo "    * Warning:  PDB generation with obabel failed. An error flag was detected in the log files..."
    elif [ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb ]; then
        echo "    * Warning: PDB generation with obabel failed. No valid PDB file was generated (empty or nonexistent)..."
    elif ! check_pdb_coordinates; then
        echo "    * Warning: The output PDB file exists but does not contain valid coordinates."
    else
        # Printing some information
        echo "    * PDB file successfully generated with obabel."

        # Variables
        pdb_generation_success="true"
        pdb_generation_remark="REMARK    Generation of the the PDB file (without conformation generation) was carried out by Open Babel version ${obabel_version}"

        # Modifying the header of the pdb file and correction the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/COMPND/d' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}//${next_ligand}.pdb | sed "s/AUTHOR.*/HEADER    Small molecule (ligand)\nCOMPND    Compound: ${next_ligand}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}/g" |  sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp
        mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb
    fi
}

# Target format generation with obabel
obabel_generate_targetformat() {

    # Converting pdb to target the format
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; timeout 300 bin/time_bin -a -o "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "\n    * Timings of obabel (user real system): %U %e %S" obabel -ipdb ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb -o${targetformat} -O ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat} 2>&1 | uniq | sed "s/1 molecule converted/    * The ligand was successfully converted from the PDB format to the targetformat by obabel./")
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Target format generation with obabel failed. Open Babel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|not found'; then
        echo "    * Warning:  Target format generation with obabel failed. An error flag was detected in the log files..."
    elif [ ! -f ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat} ]; then
        echo "    * Warning: target format generation with obabel failed. No valid target format file was generated (empty or nonexistent)..."
    elif [[ "${targetformat}" == "pdb" ||"${targetformat}" == "pdbqt" ]] && ! check_pdb_coordinates ; then
        echo "    * Warning: The output PDB(QT) file exists but does not contain valid coordinates."
    else
        # Printing some information
        #echo "    * targetformat (${targetformat}) file successfully generated with obabel."
        # not needed, we convert the std output of obabel itself

        # Variables
        targetformat_generation_success="true"

        if [[ "${targetformat}" == "pdb" || "${targetformat}" = "pdbqt" ]]; then

            # Variables
            pdb_targetformat_remark="REMARK    Generation of the the target format file (${targetformat}) was carried out by Open Babel version ${obabel_version}."

            # Modifying the header of the targetformat file
            sed "s/REMARK  Name.*/REMARK    Small molecule (ligand)\nREMARK    Compound: ${next_ligand}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_conformation_remark}\n${pdb_targetformat_remark}\nREMARK    Created on $(date)/g" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat} | sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat}.tmp
            mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat}.tmp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat}
        fi
    fi
}

# Verbosity
if [ "${VF_VERBOSITY_LOGFILES}" = "debug" ]; then
    set -x
fi

# Variables
targetformats="$(grep -m 1 "^targetformats=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
minimum_time_remaining="$(grep -m 1 "^minimum_time_remaining=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
obabel_version="$(obabel -V | awk '{print $3}')"
keep_ligand_summary_logs="$(grep -m 1 "^keep_ligand_summary_logs=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
ligand_check_interval="$(grep -m 1 "^ligand_check_interval=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
obabel_memory_limit="$(grep -m 1 "^obabel_memory_limit=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"


# Desalting
desalting="$(grep -m 1 "^desalting=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${desalting}" == "true" ]; then

    # Variables
    desalting_obligatory="$(grep -m 1 "^desalting_obligatory=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
fi

# Neutralization
neutralization="$(grep -m 1 "^neutralization=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${neutralization}" == "true" ]; then

    # Variables
    neutralization_mode="$(grep -m 1 "^neutralization_mode=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    neutralization_obligatory="$(grep -m 1 "^neutralization_obligatory=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    standardizer_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.standardizer.StandardizerCLI -h | head -n 1 | awk -F '[ ,]' '{print $2}')"

    # Checking variable values
    if [[ ( "${neutralization_mode}" == "if_genuine_desalting" || "${neutralization_mode}" == "if_genuine_desalting_and_charged" ) && ! "${desalting}" == "true" ]]; then

        # Printing some information
        echo -e " Error: The value (${neutralization_mode}) of the variable neutralization_mode requires desalting to be enabled, but it is disabled."
        error_response_std $LINENO
    fi
fi

# Tautomerization settings
tautomerization="$(grep -m 1 "^tautomerization=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${tautomerization}" == "true" ]; then

    # Variables
    tautomerization_obligatory="$(grep -m 1 "^tautomerization_obligatory=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    cxcalc_tautomerization_options="$(grep -m 1 "^cxcalc_tautomerization_options=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    cxcalc_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
fi

# Protonation settings
protonation_state_generation="$(grep -m 1 "^protonation_state_generation=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${protonation_state_generation}" == "true" ]; then

    # Variables
    protonation_program_1="$(grep -m 1 "^protonation_program_1=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    protonation_program_2="$(grep -m 1 "^protonation_program_2=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    protonation_obligatory="$(grep -m 1 "^protonation_obligatory=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    protonation_pH_value="$(grep -m 1 "^protonation_pH_value=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

    # Interdependent variables
    if [[ "${protonation_program_1}" ==  "cxcalc" ]] || [[ "${protonation_program_2}" ==  "cxcalc" ]]; then
        cxcalc_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
    fi

    # Checking some variables
    if [[ "${protonation_program_1}" !=  "cxcalc" ]] && [[ "${protonation_program_1}" !=  "obabel" ]]; then
        echo -e " Error: The value (${protonation_program_1}) for protonation_program_1 which was specified in the controlfile is invalid..."
        error_response_std $LINENO
    elif [[ "${protonation_program_2}" !=  "cxcalc" ]] && [[ "${protonation_program_2}" !=  "obabel" ]] && [[ "${protonation_program_2}" ==  "none" ]]; then
        echo -e " Error: The value (${protonation_program_2}) for protonation_program_2 which was specified in the controlfile is invalid..."
        error_response_std $LINENO
    fi
fi

# Conformation settings
conformation_generation="$(grep -m 1 "^conformation_generation=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${conformation_generation}" == "true" ]; then

    # Variables
    conformation_program_1="$(grep -m 1 "^conformation_program_1=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    conformation_program_2="$(grep -m 1 "^conformation_program_2=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    conformation_obligatory="$(grep -m 1 "^conformation_obligatory=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

    # Interdependent variables
    if [[ "${conformation_program_1}" ==  "molconvert" ]] || [[ "${conformation_program_2}" ==  "molconvert" ]]; then
        molconvert_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.formats.MolConverter | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
    fi

    # Checking some variables
    if [[ "${conformation_program_1}" !=  "molconvert" ]] && [[ "${conformation_program_1}" !=  "obabel" ]]; then
        echo -e " Error: The value (${conformation_program_1}) for conformation_program_1 which was specified in the controlfile is invalid..."
        error_response_std $LINENO
    elif [[ "${conformation_program_2}" !=  "molconvert" ]] && [[ "${conformation_program_2}" !=  "obabel" ]] && [[ "${protonation_program_2}" ==  "none" ]]; then
        echo -e " Error: The value (${conformation_program_2}) for conformation_program_2 which was specified in the controlfile is invalid..."
        error_response_std $LINENO
    fi
fi

# Saving some information about the VF_CONTROLFILEs
echo
echo
echo "*****************************************************************************************"
echo "              Beginning of a new job (job ${VF_OLD_JOB_NO}) in queue ${VF_QUEUE_NO}"
echo "*****************************************************************************************"
echo
echo "Control files in use"
echo "-------------------------"
echo "Controlfile = ${VF_CONTROLFILE}"
echo
echo "Contents of the VF_CONTROLFILE ${VF_CONTROLFILE}"
echo "-----------------------------------------------"
cat ${VF_CONTROLFILE}
echo
echo

# Getting the folder where the colections are
collection_folder="$(grep -m 1 "^collection_folder=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Loop for each ligand
ligand_index=0
while true; do

    # Variables
    new_collection="false"
    collection_complete="false"
    ligand_index=$((ligand_index+1))

    # Preparing the next ligand
    # Checking if this is the first ligand at all (beginning of first ligand collection)
    if [[ ! -f  "../workflow/ligand-collections/current/${VF_QUEUE_NO}" ]]; then
        queue_collection_file_exists="false"
    else
        queue_collection_file_exists="true"
        perl -ni -e "print unless /^$/" ../workflow/ligand-collections/current/${VF_QUEUE_NO}
    fi
    # Checking the conditions for using a new collection
    if [[ "${queue_collection_file_exists}" = "false" ]] || [[ "${queue_collection_file_exists}" = "true" && ! "$(cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} | tr -d '[:space:]')" ]]; then

#        if [ "${VF_VERBOSITY_LOGFILES}" == "debug" ]; then
#            echo -e "\n***************** INFO **********************"
#            echo ${VF_QUEUE_NO}
#            ls -lh ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
#            cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
#            cat ../workflow/ligand-collections/todo/${VF_QUEUE_NO} 2>/dev/null || true
#            echo -e "***************** INFO END ******************\n"
#        fi

        next_ligand_collection
        prepare_collection_files_tmp

        # Getting the name of the first ligand of the first collection
        next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')

    # Using the old collection
    else
        # Getting the name of the current ligand collection
        last_ligand_collection=$(awk '{print $1}' ../workflow/ligand-collections/current/${VF_QUEUE_NO})
        last_ligand_collection_tranch="${last_ligand_collection/_*}"
        last_ligand_collection_metatranch="${last_ligand_collection_tranch:0:2}"
        last_ligand_collection_ID="${last_ligand_collection/*_}"

        # Checking if this is the first ligand of this queue
        if [ "${ligand_index}" = "1" ]; then
            # Extracting the last ligand collection
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}
            tar -xf ${collection_folder}/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/ ${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar.gz
            gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar.gz
            # Extracting all the SMILES at the same time (faster)
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}
            tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/

            if [[ -f  ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status ]]; then
                cp ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/
            fi

            # Variables
            last_ligand=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status | awk -F '[: ,/]' '{print $1}' 2>/dev/null || true)
            last_ligand_status=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status | awk -F '[: ,/]' '{print $2}' 2>/dev/null || true)

            # Checking if the last ligand was in the status processing. In this case we will try to process the ligand again since the last process might have not have the chance to complete its tasks.
            if [ "${last_ligand_status}" == "processing" ]; then
                perl -ni -e "/${last_ligand}:processing/d" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status # Might not work for VFVS due to multiple replicas
                next_ligand="${last_ligand}"
            else
                next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar | grep -w -A 1 "${last_ligand/_T*}" | grep -v ${last_ligand/_T*} | awk -F '[/.]' '{print $2}')
            fi

        # Not first ligand of this queue
        else
            last_ligand=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status 2>/dev/null | awk -F '[:. ]' '{print $1}' || true)
            last_ligand_status=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status 2>/dev/null | awk -F '[:. ]' '{print $2}' || true)

            # Checking if the last ligand was in the status processing. In this case we will try to process the ligand again since the last process might have not have the chance to complete its tasks.
            if [ "${last_ligand_status}" == "processing" ]; then
                perl -ni -e "/${last_ligand}:processing/d" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status # Might not work for VFVS due to multiple replicas
                next_ligand="${last_ligand}"
            else
                next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_metatranch}/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar | grep -w -A 1 "${last_ligand/_T*}" | grep -v ${last_ligand/_T*} | awk -F '[/.]' '{print $2}')
            fi
        fi

        # Check if we can use the old collection
        if [ -n "${next_ligand}" ]; then

            # We can continue to use the old ligand collection
            next_ligand_collection=${last_ligand_collection}
            next_ligand_collection_ID="${next_ligand_collection/*_}"
            next_ligand_collection_tranch="${next_ligand_collection/_*}"
            
            # Preparing the collection folders only if ligand_index=1
            if [ "${ligand_index}" = "1" ]; then
                prepare_collection_files_tmp
            fi
        # Otherwise we have to use a new ligand collection
        else
            collection_complete="true"
            # Cleaning up the files and folders of the old collection
            if [ ! "${ligand_index}" = "1" ]; then
               clean_collection_files_tmp ${last_ligand_collection}
            fi
            # Getting the next collection if there is one more
            next_ligand_collection
            prepare_collection_files_tmp
            # Getting the first ligand of the new collection
            next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
        fi
    fi

    # Displaying the heading for the new ligand
    echo ""
    echo "      Ligand ${ligand_index} of job ${VF_OLD_JOB_NO} belonging to collection ${next_ligand_collection}: ${next_ligand}"
    echo "*****************************************************************************************"
    echo ""

    # Setting up variables
    # Checking if the current ligand index divides by ligand_check_interval
    if [ "$((ligand_index % ligand_check_interval))" == "0" ]; then
        # Determining the VF_CONTROLFILE to use for this jobline
        VF_CONTROLFILE=""
        for file in $(ls ../workflow/control/*-* 2>/dev/null|| true); do
            file_basename=$(basename $file)
            jobline_range=${file_basename/.*}
            jobline_no_start=${jobline_range/-*}
            jobline_no_end=${jobline_range/*-}
            if [[ "${jobline_no_start}" -le "${VF_JOBLINE_NO}" && "${VF_JOBLINE_NO}" -le "${jobline_no_end}" ]]; then
                export VF_CONTROLFILE="${file}"
                break
            fi
        done
        if [ -z "${VF_CONTROLFILE}" ]; then
            VF_CONTROLFILE="../workflow/control/all.ctrl"
        fi

        # Checking if this queue line should be stopped immediately
        line=$(cat ${VF_CONTROLFILE} | grep "^stop_after_next_check_interval=")
        stop_after_next_check_interval=${line/"stop_after_next_check_interval="}
        if [ "${stop_after_next_check_interval}" = "true" ]; then
            echo
            echo " * This queue will be stopped due to the stop_after_next_check_interval flag in the VF_CONTROLFILE ${VF_CONTROLFILE}."
            echo
            end_queue 0
        fi
    fi

    # Checking if there is enough time left for a new ligand
    if [[ "${VF_LITTLE_TIME}" = "true" ]]; then
        echo
        echo " * This queue will be ended because a signal was caught indicating this queue should stop now."
        echo
        end_queue 0
    fi

    if [[ "$((VF_TIMELIMIT_SECONDS - $(date +%s ) + VF_START_TIME_SECONDS )) " -lt "${minimum_time_remaining}" ]]; then
        echo
        echo " * This queue will be ended because there is less than the minimum time remaining (${minimum_time_remaining} s) for the job (by internal calculation)."
        echo
        end_queue 0
    fi


    # Updating the ligand-list files
    update_ligand_list_start

    # Desalting
    pdb_desalting_remark=""
    if [ "${desalting}" == "true" ]; then

        # Variables
        desalting_success="false"

        # Printing information
        echo -e "\n * Starting the desalting procedure"

        # Carrying out the desalting step
        desalt

        # Checking if the desalting has failed
        if [ "${desalting_success}" == "false" ]; then

            # Printing information
            echo "    * Warning: The desalting procedure has failed..."

            # Updating the ligand-list entry
            ligand_list_entry="${ligand_list_entry} desalting:failed"

            # Checking if desalting is mandatory
            if [ "${desalting_obligatory}" == "true" ]; then

                # Printing some information
                echo "    * Warning: Ligand will be skipped since a successful desalting is required according to the controlfile."

                # Updating the ligand list
                update_ligand_list_end false "during desalting"

                # Skipping the ligand
                continue

            else
                # Printing some information
                echo "    * Warning: Ligand will be further processed without desalting"

                # Copying the original ligand
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
            fi
        else

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} desalting:success(${desalting_type})"
        fi
    else

        # Copying the original ligand
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi

    fi


    # Neutralization
    pdb_neutralization_remark=""
    if [ "${neutralization}" == "true" ]; then

        # Variables
        neutralization_success="false"

        # Printing information
        echo -e "\n * Starting the neutralization step"

        # Carrying out the neutralization step
        standardizer_neutralize

        # Checking if the neutralization has failed
        if [ "${neutralization_success}" == "false" ]; then

            # Printing information
            echo "    * Warning: The neutralization has failed."

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} neutralization:failed"

            # Checking if neutralization is mandatory
            if [ "${neutralization_obligatory}" == "true" ]; then

                # Printing some information
                echo "    * Warning: Ligand will be skipped since a successful neutralization is required according to the controlfile."

                # Updating the ligand list
                update_ligand_list_end false "during neutralization"

                # Skipping the ligand
                continue
            else

                # Printing some information
                echo "    * Warning: Ligand will be further processed without neutralization"

                # Copying the original ligand
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
            fi
        else

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} neutralization:success(${neutralization_type})"
        fi
    else

        # Copying the original ligand
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi

    fi

    # Tautomer generation
    pdb_tautomerization_remark=""
    if [ "${tautomerization}" == "true" ]; then

        # Variables
        tautomerization_success="false"

        # Printing information
        echo -e "\n * Starting the tautomerization with cxcalc"

        # Carrying out the tautomerization
        cxcalc_tautomerize

        # Checking if the tautomerization has failed
        if [ "${tautomerization_success}" == "false" ]; then

            # Printing information
            echo "    * Warning: The tautomerization has failed."

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} tautomerization:failed"

            # Checking if tautomerization is mandatory
            if [ "${tautomerization_obligatory}" == "true" ]; then

                # Printing some information
                echo "    * Warning: Ligand will be skipped since a successful tautomerization is required according to the controlfile."

                # Updating the ligand list
                update_ligand_list_end false "during tautomerization"

                # Skipping the ligand
                continue
            else

                # Printing some information
                echo "    * Warning: Ligand will be further processed without tautomerization"

                # Variables
                next_ligand_tautomers=${next_ligand}

                # Copying the original ligand
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
            fi
        else

            # Adjusting the ligand-list file
            next_ligand_tautomers_count=$(echo ${next_ligand_tautomers} | wc -w)
            ligand_list_entry="${ligand_list_entry} tautomerization(${next_ligand_tautomers_count}):success"
        fi
    else

        # Copying the original ligand
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi

        # Variables
        next_ligand_tautomers=${next_ligand}

    fi

    # Checking if we have more than one tautomer
    next_ligand_tautomers_count=$(echo ${next_ligand_tautomers} | wc -w)
    if [ "${next_ligand_tautomers_count}" -gt "1" ]; then
        update_ligand_list_end true "up to tautomerization"
    fi

    # Loop for each tautomer
    next_ligand_tautomer_index=0
    for next_ligand in ${next_ligand_tautomers}; do

        # Variables
        next_ligand_tautomer_index=$((next_ligand_tautomer_index+1))

        # Starting a new entry for each tautomer in the ligand-list log files if we have more than one tautomer
        if [ "${next_ligand_tautomers_count}" -gt "1" ]; then
            update_ligand_list_start
        fi

        # Printing some information
        echo -e "\n\n *** Starting the processing of tautomor ${next_ligand_tautomer_index}/${next_ligand_tautomers_count} (${next_ligand}) ***\n"

        # Protonation
        if [ "${protonation_state_generation}" == "true" ]; then

            # Variables
            pdb_protonation_remark=""
            protonation_program=""
            protonation_success="false"

            # Printing information
            echo -e "\n * Starting the protonation procedure"
            echo "    * Starting first protonation attempt with ${protonation_program_1} (protonation_program_1)"

            # Determining protonation_program_1
            case "${protonation_program_1}" in
                cxcalc)
                    # Attempting the protonation with cxcalc
                    cxcalc_protonate
                    ;;
                obabel)
                    # Attempting the protonation with obabel
                    obabel_protonate
                    ;;
            esac

            # Checking if first protonation has failed
            if [ "${protonation_success}" == "false" ]; then

                # Printing information
                echo "    * Starting second protonation attempt with ${protonation_program_2} (protonation_program_2)"

                # Determining protonation_program_2
                case "${protonation_program_2}" in
                    cxcalc)
                        # Attempting the protonation with cxcalc
                        cxcalc_protonate
                        ;;
                    obabel)
                        # Attempting the protonation with obabel
                        obabel_protonate
                        ;;
                esac
            fi

            # Checking if both of the protonation attempts have failed
            if [ "${protonation_success}" == "false" ]; then

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} protonation:failed"

                # Printing information
                echo "    * Warning: Both protonation attempts have failed."

                # Checking if protonation is mandatory
                if [ "${protonation_obligatory}" == "true" ]; then

                    # Printing some information
                    echo "    * Warning: Ligand will be skipped since a successful protonation is required according to the controlfile."

                    # Updating the ligand-list status file
                    update_ligand_list_end false "during protonation"

                    # Skipping the ligand
                    continue
                else

                    # Printing some information
                    echo "    * Warning: Ligand will be further processed without protonation, which might result in unphysiological protonation states."

                    # Variables
                    pdb_protonation_remark="REMARK    WARNING: Molecule was not protonated at physiological pH (protonation with both obabel and cxcalc has failed)"

                    # Copying the unprotonated ligand
                    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/protomers/${next_ligand_collection_metatranch}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
                fi
            else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} protonation:success(${protonation_program})"
            fi
        fi


         # 3D conformation generation
        if [ "${conformation_generation}" == "true" ]; then

            # Variables
            pdb_conformation_remark=""
            conformation_program=""
            conformation_success="false"

            # Printing information
            echo -e "\n * Starting the 3D conformation generation procedure"
            echo "    * Starting first 3D conformation generation attempt with ${conformation_program_1} (conformation_program_1)"

            # Determining conformation_program_1
            case "${conformation_program_1}" in
                molconvert)
                    # Attempting the conformation generation with molconvert
                    molconvert_generate_conformation
                    ;;
                obabel)
                    # Attempting the conformation generation with obabel
                    obabel_generate_conformation
                    ;;
            esac

            # Checking if first conformation generation attempt has failed
            if [ "${conformation_success}" == "false" ]; then

                # Printing information
                echo "    * Starting second 3D conformation generation attempt with ${conformation_program_2} (conformation_program_2)"

                # Determining conformation_program_2
                case "${conformation_program_2}" in
                    molconvert)
                        # Attempting the conformation generation with molconvert
                        molconvert_generate_conformation
                        ;;
                    obabel)
                        # Attempting the conformation generation with obabel
                        obabel_generate_conformation
                        ;;
                esac
            fi

            # Checking if both of the 3D conformation generation attempts have failed
            if [ "${conformation_success}" == "false" ]; then

                # Printing information
                echo "    * Warning: Both of the 3D conformation generation attempts have failed."

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} conformation:failed"

                # Checking if conformation generation is mandatory
                if [ "${conformation_obligatory}" == "true" ]; then

                    # Printing some information
                    echo "    * Warning: Ligand will be skipped since a successful 3D conformation generation is required according to the controlfile."

                    # Updating the ligand list
                    update_ligand_list_end false "during conformation generation"

                    # Skipping the ligand
                    continue
                else

                    # Printing some information
                    echo "    * Warning: Ligand will be further processed without 3D conformation generation."

                    # Variables
                    pdb_conformation_remark="REMARK    WARNING: 3D conformation could not be generated (both obabel and molconvert failed)"
                fi

            else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} conformation:success(${conformation_program})"
            fi
        fi


        # PDB generation
        # If conformation generation failed, and we reached this point, then conformation_obligatory=false, so we do not need to check this
        pdb_generation_remark=""
        if [[ "${conformation_generation}" == "false" ]] || [[ "${conformation_success}" == "false" ]]; then


            # Variables
            pdb_generation_success="false"

            # Printing information
            echo -e "\n * Starting conversion of the ligand into PDB format with obabel (without 3D conformation generation)"

            # Attempting the PDB generation with obabel
            obabel_generate_pdb

            # Checking if PDB generation attempt has failed
            if [ "${pdb_generation_success}" == "false" ]; then

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} pdb-generation:failed"

                # Printing some information
                echo "    * Warning: Ligand will be skipped since a successful PDB generation is mandatory."

                # Updating the ligand list
                update_ligand_list_end false "during PDB generation"

                # Skipping the ligand
                continue
            else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} pdb-generation:success"

            fi
        fi


        # Generating the target formats
        # Printing information
        echo -e "\n * Starting the target format generation with obabel"
        # Loop for each target format
        for targetformat in ${targetformats//:/ }; do

            # Variables
            targetformat_generation_success="false"

            # Printing information
            echo -e "    * Starting the conversion into the target format (${targetformat}) with obabel"

            # Attempting the target format generation with obabel
            obabel_generate_targetformat

            # Checking if the target format generation has failed
            if [ "${targetformat_generation_success}" == "false" ]; then

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} targetformat-generation(${targetformat}):failed"

           else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} targetformat-generation(${targetformat}):success"
            fi
        done

        # Updating the ligand list
        if [ "${next_ligand_tautomers_count}" -eq "1" ]; then
            update_ligand_list_end true "complete pipeline"
        elif [ "${next_ligand_tautomers_count}" -gt "1" ]; then
            update_ligand_list_end true "after tautomerization"
        fi

        # Variables
        needs_cleaning="true"
    done

done
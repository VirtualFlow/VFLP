#!/usr/bin/env bash

# Copyright (C) 2019 Christoph Gorgulla
#
# This file is part of VirtualFlow.
#
# VirtualFlow is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VirtualFlow is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VirtualFlow.  If not, see <https://www.gnu.org/licenses/>.

# Setting the verbosity level
if [[ "${VF_VERBOSITY_LOGFILES}" == "debug" ]]; then
    set -x
fi

# Setting the error sensitivity
if [[ "${VF_ERROR_SENSITIVITY}" == "high" ]]; then
    set -uo pipefail
    trap '' PIPE        # SIGPIPE = exit code 141, means broken pipe. Happens often, e.g. if head is listening and got all the lines it needs.
fi


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

    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/output-files/queues/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/queue-${VF_QUEUE_NO}.* ../workflow/output-files/queues/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/ || true

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
    echo "${next_ligand} processing" >> ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status
}

update_ligand_list_end() {

    # Variables
    success="${1}" # true or false
    pipeline_part="${2}"
    ligand_total_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${ligand_start_time_ms}))"

    # Updating the ligand-list file
    perl -pi -e "s/${next_ligand/_T*}.* processing.*/${next_ligand} ${ligand_list_entry} total-time:${ligand_total_time_ms} timings:${component_timings}/g" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status

    # Printing some information
    echo
    if [ "${success}" == "true" ]; then
        echo "Ligand ${next_ligand} completed ($pipeline_part) on $(date)."
    else
        echo "Ligand ${next_ligand} failed ($pipeline_part) on $(date)."
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

    # Determining the controlfile
    determine_controlfile

    # Checking if this jobline should be stopped now
    stop_after_collection="$(grep -m 1 "^stop_after_collection=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    if [ "${stop_after_collection}" = "true" ]; then
        echo
        echo "This job line was stopped by the stop_after_collection flag in the VF_CONTROLFILE ${VF_CONTROLFILE_TEMP}."
        echo
        end_queue 0
    fi
    echo
    echo "A new collection has to be used if there is one."

    # Checking if there exists a todo file for this queue
    if [ ! -f ../workflow/ligand-collections/todo/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO}   ]; then
        echo
        echo "This queue is stopped because there exists no todo file for this queue."
        echo
        end_queue 0
    fi

    # Loop for iterating through the remaining collections until we find one which is not already finished
    new_collection="false"
    while [ "${new_collection}" = "false" ]; do

       # Checking if there is one more ligand collection to be done
        no_collections_remaining="$(grep -cv '^\s*$' ../workflow/ligand-collections/todo/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO} || true)"

        if [[ "${no_collections_remaining}" = "0" ]]; then
            # Renaming the todo file to its original name
            no_more_ligand_collection
        fi

        # Setting some variables
        next_ligand_collection=$(head -n 1 ../workflow/ligand-collections/todo/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO} | awk '{print $1}')
        next_ligand_collection_ID="${next_ligand_collection/*_}"
        next_ligand_collection_tranche="${next_ligand_collection/_*}"
        next_ligand_collection_metatranche="${next_ligand_collection_tranche:0:2}"
        next_ligand_collection_length=$(head -n 1 ../workflow/ligand-collections/todo/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO} | awk '{print $2}')

#        for folder1 in $(find ../workflow/ligand-collections/done/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
#            for folder2 in $(find ../workflow/ligand-collections/done/${folder1}/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
#                if grep -w "${next_ligand_collection}" ../workflow/ligand-collections/done/$folder1/$folder2/* &>/dev/null; then
#                    echo "This ligand collection was already finished. Skipping this ligand collection."
#                    continue 3
#                fi
#            done
#        done
#
#        for folder1 in $(find ../workflow/ligand-collections/current/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
#            for folder2 in $(find ../workflow/ligand-collections/current/${folder1} -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
#                if grep -w "${next_ligand_collection}" ../workflow/ligand-collections/current/$folder1/$folder2/* &>/dev/null; then
#                    echo "On this ligand collection already another queue is working. Skipping this ligand collection."
#                    continue 3
#                fi
#            done
#        done
#
#        for folder1 in $(find ../workflow/ligand-collections/todo/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
#            for folder2 in $(find ../workflow/ligand-collections/todo/${folder1} -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
#                if grep -w ${next_ligand_collection} $(ls ../workflow/ligand-collections/todo/$folder1/$folder2/* &>/dev/null | grep -v "${VF_QUEUE_NO}" &>/dev/null); then
#                    echo "This ligand collection is in one of the other todo-lists. Skipping this ligand collection."
#                    continue 3
#                fi
#            done
#        done

        # Variables
        new_collection="true"
        # Removing the new collection from the ligand-collections-todo file        perl -ni -e "print unless /${next_ligand_collection}\b/" ../workflow/ligand-collections/todo/${VF_QUEUE_NO}
        perl -ni -e "print unless /${next_ligand_collection}\b/" ../workflow/ligand-collections/todo/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO}

    done

    # Updating the ligand-collection files
    echo "${next_ligand_collection} ${next_ligand_collection_length}" > ../workflow/ligand-collections/current/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO}


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
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
    for targetformat in ${targetformats//:/ }; do
        if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
        elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/")" ]; then
            rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
        fi
    done
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/*
    fi

    # Copying the required files
    if [ ! -f ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar ]; then
        if [ -f ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ]; then
            tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/ ${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
            gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
        elif [ -f ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ]; then
            rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/* 2>/dev/null || true
            cp ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar
            tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/ ${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
            gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
        else
            # Raising an error
            echo " * Error: The tranche archive file ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar does not exist..."
            error_response_std $LINENO
        fi
    fi

    # Checking if the collection could be extracted
    if [ ! -f ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar ]; then

        # Raising an error
        echo " * Error: The ligand collection ${next_ligand_collection_tranche}_${next_ligand_collection_ID} could not be prepared."
        error_response_std $LINENO
    fi

    # Extracting all the SMILES at the same time (faster than individual for each ligand separately)
    tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}

    # Copying the required old output files if continuing old collection
    if [ "${new_collection}" == "false" ]; then

        # Loop for each target format
        for targetformat in ${targetformats//:/ }; do
            tar -xzf ../output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/ || true
        done

        # Copying the status file
        if [[ -f  ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status ]]; then
            cp ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
        fi
    fi

    # Cleaning up
    #rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar
    # If we remove it here, then we need to make the next_ligand determination dependend on the extracted archive rather than the archive. Are we using the extracted archive? I think so, for using the SMILES
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
        local_ligand_collection_tranche="${local_ligand_collection/_*}"
        local_ligand_collection_metatranche="${local_ligand_collection_tranche:0:2}"
        local_ligand_collection_ID="${local_ligand_collection/*_}"

        # Checking if all the folders required are there
        if [ "${collection_complete}" = "true" ]; then

            # Printing some information
            echo -e "\n * The collection ${local_ligand_collection} has been completed."
            echo "    * Storing and cleaning corresponding files..."

            # Loop for each target format
            for targetformat in ${targetformats//:/ }; do

                # Compressing the collection and saving in the complete folder
                mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
                tar -czf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/ ${local_ligand_collection_ID} || true
                local_ligand_collection_length="$(ls ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} | wc -l)"

                # Adding the completed collection archive to the tranche archive
                if [ "${outputfiles_level}" == "tranche" ]; then
                    mkdir -p ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}
                    if [ -f ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar ]; then
                        cp ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar
                    fi
                    tar -rf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche} ${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar.gz || true
                    mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar
                elif [ "${outputfiles_level}" == "collection" ]; then
                    mkdir -p ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
                    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar.gz ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
                else
                    echo " * Error: The variable 'outputfiles_level' in the controlfile ${VF_CONTROLFILE_TEMP} has an invalid value (${outputfiles_level})"
                    exit 1
                fi

                # Adding the length entry
                echo "${local_ligand_collection}" "${local_ligand_collection_length}" >> ../output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.length

                # Cleaning up
                rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar.gz &> /dev/null || true
                rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true

            done

            # Updating the ligand collection files
            echo -n "" > ../workflow/ligand-collections/current/${VF_QUEUE_NO}
            ligands_succeeded_tautomerization="$(grep "tautomerization([0-9]\+):success" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status | grep -c tautomerization)"
            ligands_succeeded_targetformat="$(grep -c "targetformat-generation([A-Za-z]\+):success" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status)"
            ligands_failed="$(grep -c "failed total" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status)"
            ligands_started="$(grep -c "initial" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status)"
            echo "${local_ligand_collection} was completed by queue ${VF_QUEUE_NO} on $(date). Ligands started:${ligands_started} succeeded(tautomerization):${ligands_succeeded_tautomerization} succeeded(target-format):${ligands_succeeded_targetformat} failed:${ligands_failed}" >> ../workflow/ligand-collections/done/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO}


            # Checking if we should keep the ligand log summary files
            if [ "${keep_ligand_summary_logs}" = "true" ]; then


                # Compressing and archiving the status file
                gzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status

                # TODO Checking output file level
                if [ "${outputfiles_level}" == "tranche" ]; then

                    # Directory preparation
                    mkdir  -p ../output-files/complete/${docking_scenario_name}//ligand-lists/${local_ligand_collection_metatranche}

                    if [ -f ../output-files/complete/${docking_scenario_name}//ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar ]; then
                        cp ../output-files/complete/${docking_scenario_name}//ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar
                    fi
                    tar -rf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/ ${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status.gz || true
                    mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar ../output-files/complete/${docking_scenario_name}//ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}.tar
                elif [ "${outputfiles_level}" == "collection" ]; then
                    mkdir -p ../output-files/complete/${docking_scenario_name}/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
                    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status.gz ../output-files/complete/${docking_scenario_name}/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
                else
                    echo " * Error: The variable 'outputfiles_level' in the controlfile ${VF_CONTROLFILE_TEMP} has an invalid value (${outputfiles_level})"
                    exit 1
                fi
            fi

            # Removing possible old status files
            rm ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status &> /dev/null || true

        else
            # Loop for each target format
            for targetformat in ${targetformats//:/ }; do
                # Compressing the collection
                tar -czf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/ ${local_ligand_collection_ID} || true

                # Copying the files which should be kept in the permanent storage location
                mkdir -p ../output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar.gz ../output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/
            done

            mkdir -p ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
            cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/ || true

        fi

        # Cleaning up
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true
        rm  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.tar &> /dev/null || true
        rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID}.status* &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true

        # Cleaning up
        for targetformat in ${targetformats//:/ }; do
            rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_metatranche}/${local_ligand_collection_tranche}/${local_ligand_collection_ID} &> /dev/null || true
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
    no_nonzero_coord="$(grep -E "ATOM|HETATM" ${pdb_intermediate_output_file} | awk -F ' ' '{print $6,$7,$8}' | tr -d '0.\n\+\- ' | wc -m)"
    if [ "${no_nonzero_coord}" -eq "0" ]; then
        echo "The pdb(qt) file only contains zero coordinates."
        return 1
    else
        return 0
    fi
}

# Desalting
desalt() {


    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Number of fragments in SMILES
    number_of_smiles_fragments="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | wc -l)"

    # Checking the number of fragments
    if [[ "${number_of_smiles_fragments}" -ge "2" ]]; then

        # Carrying out the desalting
        trap '' ERR
        desalted_smiles_largest_fragment="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | perl -e 'print sort { length($a) <=> length($b) } <>' | tail -n 1 )" 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp)
        desalted_smiles_smallest_fragment="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | perl -e 'print sort { length($a) <=> length($b) } <>' | head -n 1 )" 2>> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp)
        last_exit_code=$?
        trap 'error_response_std $LINENO' ERR

        # Checking if the desalting was successful
        if [ "${last_exit_code}" -ne "0" ]; then
            echo "    * Warning: Desalting has failed. Desalting procedure resulted in a non-zero exit code..."
        elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found|non-zero'; then
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
            echo ${desalted_smiles_largest_fragment} > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
        fi
    elif [[ "${number_of_smiles_fragments}" -eq "1" ]]; then

        # Printing some information
        echo "    * Ligand was not a salt, leaving it untouched."

        # Variables
        desalting_success="true"
        desalting_type="untouched"
        pdb_desalting_remark="REMARK    The ligand was originally not a salt, therefore no desalting was carried out."

        # Nothing to extract, just copying the structure
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
    else

        # Printing some information
        echo "    * Warning: Could not determine the number of fragments. Desalting failed..."
    fi

    # Timings
    component_timings="${component_timings}:desalt=${temp_end_time_ms}"
}

standardizer_neutralize() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Checking the NG Server
    ng_server_check

    # Checking if the charged counterion
    charged_counterion=false
    if echo ${desalted_smiles_smallest_fragment} | grep -c -E "\-\]|\+\]" &>/dev/null; then
        charged_counterion="true"
    fi

    # Checking type of neutralization mode
    neutralization_flag="false"
    if [[ "${neutralization_mode}" == "always" ]]; then
        neutralization_flag="true"
    elif [[ "${neutralization_mode}" == "only_genuine_desalting" && "${number_of_smiles_fragments}" -ge "2" ]]; then
        neutralization_flag="true"
    elif [[ "${neutralization_mode}" == "only_genuine_desalting_and_if_charged" && "${number_of_smiles_fragments}" -ge "2" && "${charged_counterion}" == "true" ]]; then
        neutralization_flag="true"
    fi

    # Checking if conversion successful
    if [ ${neutralization_flag} == "true" ]; then

        # Carrying out the neutralization
        trap '' ERR
        { timeout 300 time_bin -f "    * Timings of standardizer (user real system): %U %e %S"  ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.standardizer.StandardizerCLI ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -c "neutralize" 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp 1>&2 ) | tail -n 1 > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ; } 2>&1
        last_exit_code=$?
        trap 'error_response_std $LINENO' ERR

        if [ "${last_exit_code}" -ne "0" ]; then
            echo "    * Warning: Neutralization with Standardizer failed. Standardizer was interrupted by the timeout command..."
        elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 4 | grep "refused"; then
            echo "    * Error: The Nailgun server seems to have terminated..."
            error_response_std $LINENO
        elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found'; then
            echo "    * Warning: Neutralization with Standardizer failed. An error flag was detected in the log files..."
        elif [[ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ]]; then
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

        # Copying the ligand from the desalting step
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
    fi
    
    # Timings
    component_timings="${component_timings}:standardizer_neutralize=${temp_end_time_ms}"
}

# Protonation with cxcalc
cxcalc_tautomerize() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Checking the NG Server
    ng_server_check

    # Carrying out the tautomerization
    trap '' ERR
    { timeout 300 time_bin -f "    * Timings of cxcalc (user real system): %U %e %S"  ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator -o ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp tautomers ${cxcalc_tautomerization_options}  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp 1>&2 ) ; } 2>&1
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if the tautomerization was successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Tautomerization with cxcalc failed. cxcalc was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 4 | grep "refused"; then
        echo "    * Error: The Nailgun server seems to have terminated..."
        error_response_std $LINENO
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found|non-zero'; then
        echo "    * Warning: Tautomerization with cxcalc failed. An error flag was detected in the log files..."
    elif [[ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp ]]; then
        echo "    * Warning: Tautomerization with cxcalc failed. No valid SMILES were generated..."
    else
        echo "    * Ligand successfully tautomerized by cxcalc."
        tautomer_smiles=$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp | tail -n 1 | awk -F ' ' '{print $2}' | tr "." " ")
        tautomerization_success="true"
        pdb_tautomerization_remark="REMARK    The tautomeric state was generated by cxcalc version ${cxcalc_version} of ChemAxons JChem Suite."
        tautomerization_program="cxcalc"

        # Storing each tautomer SMILES in a file and storing the new ligand names
        tautomer_index=0
        next_ligand_tautomers=""
        for tautomer_smile in ${tautomer_smiles}; do
            tautomer_index=$((tautomer_index + 1))
            echo ${tautomer_smile} > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}_T${tautomer_index}.smi
            next_ligand_tautomers="${next_ligand_tautomers} ${next_ligand}_T${tautomer_index}"
        done
    fi
    
    # Timings
    component_timings="${component_timings}:cxcalc_tautomerize=${temp_end_time_ms}"
}

# Protonation with cxcalc
cxcalc_protonate() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Checking the NG Server
    ng_server_check

    # Carrying out the protonation
    trap '' ERR
    { timeout 300 time_bin -f "    * Timings of cxcalc (user real system): %U %e %S"  ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator -o ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp majorms -H ${protonation_pH_value} ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp 1>&2) ; } 2>&1
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Protonation with cxcalc failed. cxcalc was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 4 | grep "refused"; then
        echo "    * Error: The Nailgun server seems to have terminated..."
        error_response_std $LINENO
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found'; then
        echo "    * Warning: Protonation with cxcalc failed. An error flag was detected in the log files..."
    elif [[ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp ]]; then
        echo "    * Warning: Protonation with cxcalc failed. No valid SMILES file was generated..."
    else
        echo "    * Ligand successfully protonated by cxcalc."
        protonation_success="true"
        pdb_protonation_remark="REMARK    Protonation state was generated at pH ${protonation_pH_value} by cxcalc version ${cxcalc_version} of ChemAxons JChem Suite."
        protonation_program="cxcalc"

        # Curating the output file
        tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp | awk -F ' ' '{print $2}' > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
        rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp
    fi
    
    # Timings
    component_timings="${component_timings}:cxcalc_protonate=${temp_end_time_ms}"
}

# Protonation with obabel
obabel_protonate() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Carrying out the protonation
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; { timeout ${obabel_time_limit} time_bin -f "    * Timings of obabel (user real system): %U %e %S" obabel -p ${protonation_pH_value} -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -osmi -O ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | sed "/1 molecule converted/d" 1>&2) ; } 2>&1 )
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Protonation with obabel failed. obabel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found'; then
        echo "    * Warning: Protonation with obabel failed. An error flag was detected in the log files..."
    elif [[ ! -s ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ]]; then
        echo "    * Warning: Protonation with cxcalc failed. No valid SMILES file was generated (empty or nonexistent)..."
    else
        echo "    * Ligand successfully protonated by obabel."
        protonation_success="true"
        pdb_protonation_remark="REMARK    The protonation state was generated at pH ${protonation_pH_value} by Open Babel version ${obabel_version}"
        protonation_program="obabel"
    fi
    
    # Timings
    component_timings="${component_timings}:obabel_protonate=${temp_end_time_ms}"
}

# Conformation generation with molconvert
molconvert_generate_conformation() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Checking the NG Server
    ng_server_check

    # Variables
    if [ "${tranche_assignments}" = "false" ]; then
        pdb_intermediate_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.pdb
    elif [ "${tranche_assignments}" = "true" ]; then
        pdb_intermediate_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${assigned_tranche}_${next_ligand}.pdb
    fi
    
    # Converting SMILES to 3D PDB
    # Trying conversion with molconvert
    trap '' ERR
    { timeout 300 time_bin -f "    * Timings of molconvert (user real system): %U %e %S" ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.formats.MolConverter pdb:+H -3 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -o ${pdb_intermediate_output_file} 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp 1>&2) ; } 2>&1
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Conformation generation with molconvert failed. Molconvert was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 4 | grep "refused"; then
        echo "    * Error: The Nailgun server seems to have terminated..."
        error_response_std $LINENO
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E'failed|timelimit|error|no such file|not found' &>/dev/null; then
        echo "    * Warning: Conformation generation with molconvert failed. An error flag was detected in the log files..."
    elif [ ! -s ${output_file} ]; then
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
        smiles=$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi)

        # Modifying the header of the pdb file and correction of the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/TITLE\|SOURCE\|KEYWDS\|EXPDTA/d' ${pdb_intermediate_output_file} | sed "s|PROTEIN.*|Small molecule (ligand)|g" | sed "s|AUTHOR.*|REMARK    SMILES: ${smiles}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_conformation_remark}\n${pdb_trancheassignment_remark}|g" | sed "/REVDAT.*/d" | sed "s/NONE//g" | sed "s/ UN[LK] / LIG /g" | sed "s/COMPND.*/COMPND    Compound: ${next_ligand}/g" | sed 's/+0//' | sed 's/\([+-]\)\([0-9]\)$/\2\1/g' | sed '/^\s*$/d' > ${pdb_intermediate_output_file}.tmp
        mv ${pdb_intermediate_output_file}.tmp ${pdb_intermediate_output_file}
    fi
    
    # Timings
    component_timings="${component_timings}:molconvert_generate_conformation=${temp_end_time_ms}"
}

# Conformation generation with obabel
obabel_generate_conformation(){

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Variables
    if [ "${tranche_assignments}" = "false" ]; then
        pdb_intermediate_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.pdb
    elif [ "${tranche_assignments}" = "true" ]; then
        pdb_intermediate_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${assigned_tranche}_${next_ligand}.pdb
    fi

    # Converting SMILES to 3D PDB
    # Trying conversion with obabel
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; { timeout ${obabel_time_limit} time_bin -f "    * Timings of obabel (user real system): %U %e %S" obabel --gen3d -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -opdb -O ${pdb_intermediate_output_file} 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | sed "/1 molecule converted/d" 1>&2) ; } 2>&1 )
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Conformation generation with obabel failed. Open Babel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found' &>/dev/null; then
        echo "    * Warning: Conformation generation with obabel failed. An error flag was detected in the log files..."
    elif [ ! -s ${pdb_intermediate_output_file} ]; then
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
        smiles=$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi)

        # Modifying the header of the pdb file and correction the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/COMPND/d' ${pdb_intermediate_output_file} | sed "s|AUTHOR.*|HEADER    Small molecule (ligand)\nCOMPND    Compound: ${next_ligand}\nREMARK    SMILES: ${smiles}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_conformation_remark}\n${pdb_trancheassignment_remark}|g" | sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${pdb_intermediate_output_file}.tmp
        mv ${pdb_intermediate_output_file}.tmp ${pdb_intermediate_output_file}
    fi
    
    # Timings
    component_timings="${component_timings}:obabel_generate_conformation=${temp_end_time_ms}"
}

# PDB generation with obabel
obabel_generate_pdb() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Variables
    if [ "${tranche_assignments}" = "false" ]; then
        pdb_intermediate_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.pdb
    elif [ "${tranche_assignments}" = "true" ]; then
        pdb_intermediate_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${assigned_tranche}_${next_ligand}.pdb
    fi

    # Converting SMILES to PDB
    # Trying conversion with obabel
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; { timeout ${obabel_time_limit} time_bin -f "    * Timings of obabel (user real system): %U %e %S" obabel -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -opdb -O ${pdb_intermediate_output_file} 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | sed "/1 molecule converted/d" 1>&2) ; } 2>&1 )
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: PDB generation with obabel failed. Open Babel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|no such file|not found' &>/dev/null; then
        echo "    * Warning:  PDB generation with obabel failed. An error flag was detected in the log files..."
    elif [ ! -s ${pdb_intermediate_output_file} ]; then
        echo "    * Warning: PDB generation with obabel failed. No valid PDB file was generated (empty or nonexistent)..."
    elif ! check_pdb_coordinates; then
        echo "    * Warning: The output PDB file exists but does not contain valid coordinates."
    else
        # Printing some information
        echo "    * PDB file successfully generated with obabel."

        # Variables
        pdb_generation_success="true"
        pdb_generation_remark="REMARK    Generation of the the PDB file (without conformation generation) was carried out by Open Babel version ${obabel_version}"
        smiles=$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi)

        # Modifying the header of the pdb file and correction the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/COMPND/d' ${pdb_intermediate_output_file} | sed "s|AUTHOR.*|HEADER    Small molecule (ligand)\nCOMPND    Compound: ${next_ligand}\nREMARK    SMILES: ${smiles}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_trancheassignment_remark}|g" |  sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${pdb_intermediate_output_file}.tmp
        mv ${pdb_intermediate_output_file}.tmp /${pdb_intermediate_output_file}
    fi
    
    # Timings
    component_timings="${component_timings}:obabel_generate_pdb=${temp_end_time_ms}"
}

# Target format generation with obabel
obabel_generate_targetformat() {

    # Variables
    if [ "${tranche_assignments}" = "false" ]; then
        input_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.pdb
        targetformat_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.${targetformat}
    elif [ "${tranche_assignments}" = "true" ]; then
        input_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${assigned_tranche}_${next_ligand}.pdb
        targetformat_output_file=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${assigned_tranche}_${next_ligand}.${targetformat}
    fi

    # Converting pdb to target the format
    trap '' ERR
    (ulimit -v ${obabel_memory_limit}; { timeout ${obabel_time_limit} time_bin -f "    * Timings of obabel (user real system): %U %e %S" obabel -ipdb ${input_file} ${additional_obabel_options} -O ${targetformat_output_file} 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | sed "/1 molecule converted/d" 1>&2) ; } 2>&1 )
    last_exit_code=$?
    trap 'error_response_std $LINENO' ERR

    # Checking if conversion successful
    if [ "${last_exit_code}" -ne "0" ]; then
        echo "    * Warning: Target format generation with obabel failed. Open Babel was interrupted by the timeout command..."
    elif tail -n 30 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp | grep -v "^+" | tail -n 3 | grep -i -E 'failed|timelimit|error|not found'; then
        echo "    * Warning:  Target format generation with obabel failed. An error flag was detected in the log files..."
    elif [ ! -s ${targetformat_output_file} ]; then
        echo "    * Warning: target format generation with obabel failed. No valid target format file was generated (empty or nonexistent)..."
    elif [[ "${targetformat}" == "pdb" ||"${targetformat}" == "pdbqt" ]] && ! check_pdb_coordinates ; then
        echo "    * Warning: The output PDB(QT) file exists but does not contain valid coordinates."
    else
        # Printing some information
        echo "    * Targetformat (${targetformat}) file successfully generated with obabel."

        # Variables
        targetformat_generation_success="true"

        if [[ "${targetformat}" == "pdb" || "${targetformat}" = "pdbqt" ]]; then

            # Variables
            pdb_targetformat_remark="REMARK    Generation of the the target format file (${targetformat}) was carried out by Open Babel version ${obabel_version}."

            # Modifying the header of the targetformat file
            sed "s|REMARK  Name.*|REMARK    Small molecule (ligand)\nREMARK    Compound: ${next_ligand}\nREMARK    SMILES: ${smiles}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_conformation_remark}\n${pdb_targetformat_remark}\n${pdb_trancheassignment_remark}\nREMARK    Created on $(date)|g" ${targetformat_output_file} | sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${targetformat_output_file}.tmp
            mv ${targetformat_output_file}.tmp ${targetformat_output_file}
        elif [[ "${targetformat}" == "mol2" ]]; then
            # Variables
            mol2_targetformat_remark="# Generation of the the target format file (${targetformat}) was carried out by Open Babel version ${obabel_version}."

            # Modifying the header of the targetformat file
            sed "1i# Small molecule (ligand)\n# Compound: ${next_ligand}\n# SMILES: ${smiles}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_conformation_remark}\n${pdb_targetformat_remark}\n${pdb_trancheassignment_remark}\n# Created on $(date)" ${targetformat_output_file} | sed "s/REMARK    /# /"  > ${targetformat_output_file}.tmp
            mv ${targetformat_output_file}.tmp ${targetformat_output_file}
        fi

        # Removing any local file path information which obabel often adds
        sed -i "s# /.*# ${next_ligand}#" ${targetformat_output_file}

    fi
}

# Determining the potential energy
obabel_check_energy() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

    # Computing the energy
    ligand_energy=""
    ligand_energy="$(obenergy ${pdb_intermediate_output_file} | tail -n 1 | awk '{print $4}')"

    # Checking if the energy is below threshold
    if (( $(echo "$ligand_energy <= ${energy_max}" | bc -l) )); then
        energy_check_success="true"
    fi
    
    # Timings
    component_timings="${component_timings}:obabel_energy=${temp_end_time_ms}"
}

# Determining and assigning the tranche
assign_tranches_to_ligand() {

    # Determining the tranche
    assigned_tranche=""
    tranche_letters=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z a b c d e f g h i j k l m n o p q r s t u v w x y z)
    pdb_trancheassignment_remark="REMARK    Ligand properties"

    # Timings
    tranche_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

    # Loop
    for tranche_type in "${tranche_types[@]}"; do

        case ${tranche_type} in

            mw)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_mw="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^mol_weight " | awk '{print $2}')"
                separator_count=$(echo "${tranche_mw_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_mw has a valid value
                if ! [[ "$ligand_mw" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The MW (${ligand_mw}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(mw)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (MW)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_mw <= ${tranche_mw_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_mw_partition[((interval_index-2))]} < $ligand_mw && $ligand_mw <= ${tranche_mw_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq "${interval_count}" ]]; then
                        if (( $(echo "$ligand_mw > ${tranche_mw_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The MW (${ligand_mw}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(mw)"
                    
                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (MW)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * MW: ${ligand_mw}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:mw=${temp_end_time_ms}"

                ;;

            logp_obabel)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_logp_obabel="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^logP " | awk '{print $2}')"
                separator_count=$(echo "${tranche_logp_obabel_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_logp_obabel has a valid value
                if ! [[ "$ligand_logp_obabel" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The logP by Open Babel (${ligand_logp_obabel}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logp_obabel)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (logP Open Babel)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_logp_obabel <= ${tranche_logp_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_logp_obabel_partition[((interval_index-2))]} < $ligand_logp_obabel && $ligand_logp_obabel <= ${tranche_logp_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq "${interval_count}" ]]; then
                        if (( $(echo "$ligand_logp_obabel > ${tranche_logp_obabel_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The logP by Open Babel (${ligand_logp_obabel}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logp_obabel)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (LogP Open Babel)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * logP (Open Babel): ${ligand_logp_obabel}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:logp_obabel=${temp_end_time_ms}"

                ;;

            logp_jchem)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_logp_jchem="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator logp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_logp_jchem_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_logp_jchem has a valid value
                if ! [[ "$ligand_logp_jchem" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The logP values by JChem (${ligand_logp_jchem}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logp_jchem)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (logP JChem)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_logp_jchem <= ${tranche_logp_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_logp_jchem_partition[((interval_index-2))]} < $ligand_logp_jchem && $ligand_logp_jchem <= ${tranche_logp_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_logp_jchem > ${tranche_logp_jchem_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The logP value by JChem (${ligand_logp_jchem}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logp_jchem)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (logP JChem)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * logP (JChem): ${ligand_logp_jchem}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:logp_jchem=${temp_end_time_ms}"

                ;;

            hba_jchem)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_hba_jchem="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator acceptorcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_hba_jchem_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_hba_jchem has a valid value
                if ! [[ "$ligand_hba_jchem" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The HBA count by JChem $(${ligand_hba_jchem}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hba_jchem)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (HBA JChem)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_hba_jchem <= ${tranche_hba_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_hba_jchem_partition[((interval_index-2))]} < $ligand_hba_jchem && $ligand_hba_jchem <= ${tranche_hba_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_hba_jchem > ${tranche_hba_jchem_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The HBA count by JChem (${ligand_hba_jchem}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hba_jchem)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (HBA JChem)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Hydrogen bond acceptor count (JChem): ${ligand_hba_jchem}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:hba_jchem=${temp_end_time_ms}"

                ;;

            hba_obabel)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_hba_obabel="$(obabel -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -osmi --append HBA1 | head -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_hba_obabel_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_hba_obabel has a valid value
                if ! [[ "$ligand_hba_obabel" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The HBA count by Open Babel (${ligand_hba_obabel}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hba_obabel)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (HBA count Open Babel)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_hba_obabel <= ${tranche_hba_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_hba_obabel_partition[((interval_index-2))]} < $ligand_hba_obabel && $ligand_hba_obabel <= ${tranche_hba_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_hba_obabel > ${tranche_hba_obabel_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The HBA count by Open Babel (${ligand_hba_obabel}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hba_obabel)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (HBA count Open Babel)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Hydrogen bond acceptor count (Open Babel): ${ligand_hba_obabel}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:hba_obabel=${temp_end_time_ms}"

                ;;

            hbd_jchem)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_hbd_jchem="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator donorcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_hbd_jchem_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_hbd_jchem has a valid value
                if ! [[ "$ligand_hbd_jchem" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The HBD count by JChem (${ligand_hbd_jchem}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hbd_jchem)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (HBD JChem)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_hbd_jchem <= ${tranche_hbd_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_hbd_jchem_partition[((interval_index-2))]} < $ligand_hbd_jchem && $ligand_hbd_jchem <= ${tranche_hbd_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_hbd_jchem > ${tranche_hbd_jchem_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The HBD count by JChem (${ligand_hbd_jchem}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hbd_jchem)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (JChem)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Hydrogen bond donor count (JChem): ${ligand_hbd_jchem}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:hbd_jchem=${temp_end_time_ms}"

                ;;

            hbd_obabel)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_hbd_obabel="$(obabel -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -osmi --append HBD |  head -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_hbd_obabel_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_hbd_obabel has a valid value
                if ! [[ "$ligand_hbd_obabel" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The HBD count by Open Babel (${ligand_hbd_obabel}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hbd_obabel)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (HBD count Open Babel)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_hbd_obabel <= ${tranche_hbd_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_hbd_obabel_partition[((interval_index-2))]} < $ligand_hbd_obabel && $ligand_hbd_obabel <= ${tranche_hbd_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_hbd_obabel > ${tranche_hbd_obabel_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The HBD count by Open Babel (${ligand_hbd_obabel}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(hbd_obabel)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (HBD count Open Babel)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Hydrogen bond donor count (Open Babel): ${ligand_hbd_obabel}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:hbd_obabel=${temp_end_time_ms}"

                ;;

            rotb)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_rotb="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator rotatablebondcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_rotb_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_rotb has a valid value
                if ! [[ "$ligand_rotb" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The RotB count (${ligand_rotb}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(rotb)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (RotB)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_rotb <= ${tranche_rotb_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_rotb_partition[((interval_index-2))]} < $ligand_rotb && $ligand_rotb <= ${tranche_rotb_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_rotb > ${tranche_rotb_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The RotB count (${ligand_rotb}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(rotb)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (RotB)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Rotatable bonds: ${ligand_rotb}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:rotb=${temp_end_time_ms}"

                ;;

            tpsa_jchem)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_tpsa_jchem="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator polarsurfacearea ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_tpsa_jchem_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_tpsa_jchem has a valid value
                if ! [[ "$ligand_tpsa_jchem" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The TPSA by JChem (${ligand_tpsa_jchem}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(tpsa_jchem)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (TPSA JChem)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_tpsa_jchem <= ${tranche_tpsa_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_tpsa_jchem_partition[((interval_index-2))]} < $ligand_tpsa_jchem && $ligand_tpsa_jchem <= ${tranche_tpsa_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_tpsa_jchem > ${tranche_tpsa_jchem_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The TPSA by JChem (${ligand_tpsa_jchem}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(tpsa_jchem)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (TPSA JChem)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * TPSA (JChem): ${ligand_tpsa_jchem}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:tpsa_jchem=${temp_end_time_ms}"

                ;;

            tpsa_obabel)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_tpsa_obabel="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^PSA " | awk '{print $2}')"
                separator_count=$(echo "${tranche_tpsa_obabel_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_tpsa_obabel has a valid value
                if ! [[ "$ligand_tpsa_obabel" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The TPSA by Open Babel (${ligand_tpsa_obabel}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(tpsa_obabel)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (TPSA Open Babel)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_tpsa_obabel <= ${tranche_tpsa_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_tpsa_obabel_partition[((interval_index-2))]} < $ligand_tpsa_obabel && $ligand_tpsa_obabel <= ${tranche_tpsa_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_tpsa_obabel > ${tranche_tpsa_obabel_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The TPSA by Open Babel (${ligand_tpsa_obabel}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(tpsa_obabel)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (TPSA Open Babel)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * TPSA (Open Babel): ${ligand_tpsa_obabel}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:tpsa_obabel=${temp_end_time_ms}"

                ;;

            logd)
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                # Variables
                ligand_logd="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator logd ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_logd_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_logd has a valid value
                if ! [[ "$ligand_logd" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The logD value (${ligand_logd}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logd)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (logD)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_logd <= ${tranche_logd_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_logd_partition[((interval_index-2))]} < $ligand_logd && $ligand_logd <= ${tranche_logd_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_logd > ${tranche_logd_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The logD value (${ligand_logd}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logd)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (logD)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * logD (JChem): ${ligand_logd}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:logd=${temp_end_time_ms}"

                ;;

            logs)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_logs="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator logs ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_logs_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_logs has a valid value
                if ! [[ "$ligand_logs" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The logS (${ligand_logs}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logs)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (logS)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_logs <= ${tranche_logs_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_logs_partition[((interval_index-2))]} < $ligand_logs && $ligand_logs <= ${tranche_logs_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_logs > ${tranche_logs_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The logS (${ligand_logs}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(logs)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (logS)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * logS (JChem): ${ligand_logs}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:logs=${temp_end_time_ms}"

                ;;

            atomcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_atomcount="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^num_atoms " | awk '{print $2}')"
                separator_count=$(echo "${tranche_atomcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_atomcount has a valid value
                if ! [[ "$ligand_atomcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The atom count (${ligand_atomcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(atomcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (atom count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_atomcount <= ${tranche_atomcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_atomcount_partition[((interval_index-2))]} < $ligand_atomcount && $ligand_atomcount <= ${tranche_atomcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_atomcount > ${tranche_atomcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The atom count (${ligand_atomcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(atomcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (atom count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Atom count: ${ligand_atomcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:atomcount=${temp_end_time_ms}"

                ;;

            bondcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_bondcount="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^num_bonds " | awk '{print $2}')"
                separator_count=$(echo "${tranche_bondcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_bondcount has a valid value
                if ! [[ "$ligand_bondcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The bond count (${ligand_bondcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(bondcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (bond count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_bondcount <= ${tranche_bondcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_bondcount_partition[((interval_index-2))]} < $ligand_bondcount && $ligand_bondcount <= ${tranche_bondcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_bondcount > ${tranche_bondcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The bond count (${ligand_bondcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(bondcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (bond count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Bond count): ${ligand_bondcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:bondcount=${temp_end_time_ms}"

                ;;

            ringcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_ringcount="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator ringcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_ringcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_ringcount has a valid value
                if ! [[ "$ligand_ringcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The ring count (${ligand_ringcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(ringcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (ring count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_ringcount <= ${tranche_ringcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_ringcount_partition[((interval_index-2))]} < $ligand_ringcount && $ligand_ringcount <= ${tranche_ringcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_ringcount > ${tranche_ringcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The ring count (${ligand_ringcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(ringcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (ring count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Ring count: ${ligand_ringcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:ringcount=${temp_end_time_ms}"

                ;;

            aromaticringcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_aromaticringcount="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator aromaticringcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_aromaticringcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_aromaticringcount has a valid value
                if ! [[ "$ligand_aromaticringcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The aromatic ring count (${ligand_aromaticringcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(aromaticringcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (aromatic ring count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_aromaticringcount <= ${tranche_aromaticringcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_aromaticringcount_partition[((interval_index-2))]} < $ligand_aromaticringcount && $ligand_aromaticringcount <= ${tranche_aromaticringcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_aromaticringcount > ${tranche_aromaticringcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The aromatic ring count (${ligand_aromaticringcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(aromaticringcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (aromatic ring count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Aromatic ring count: ${ligand_aromaticringcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:aromaticringcount=${temp_end_time_ms}"

                ;;

            mr_obabel)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_mr_obabel="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^MR " | awk '{print $2}')"
                separator_count=$(echo "${tranche_mr_obabel_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_mr_obabel has a valid value
                if ! [[ "$ligand_mr_obabel" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The MR by Open Babel (${ligand_mr_obabel}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(mr_obabel)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (MR Open Babel)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_mr_obabel <= ${tranche_mr_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_mr_obabel_partition[((interval_index-2))]} < $ligand_mr_obabel && $ligand_mr_obabel <= ${tranche_mr_obabel_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_mr_obabel > ${tranche_mr_obabel_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The MR by Open Babel (${ligand_mr_obabel}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(mr_obabel)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (MR Open Babel)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * MR (Open Babel): ${ligand_mr_obabel}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:mr_obabel=${temp_end_time_ms}"

                ;;

            mr_jchem)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_mr_jchem="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator refractivity ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_mr_jchem_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_mr_jchem has a valid value
                if ! [[ "$ligand_mr_jchem" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The MR by JChem (${ligand_mr_jchem}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(mr_jchem)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (MR JChem)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_mr_jchem <= ${tranche_mr_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_mr_jchem_partition[((interval_index-2))]} < $ligand_mr_jchem && $ligand_mr_jchem <= ${tranche_mr_jchem_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_mr_jchem > ${tranche_mr_jchem_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The MR by JChem (${ligand_mr_jchem}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(mr_jchem)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (MR JChem)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * MR (JChem): ${ligand_mr_jchem}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:mr_jchem=${temp_end_time_ms}"

                ;;

            formalcharge)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_formalcharge="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/-2/--/" | sed "s/+2/++/" | grep -o "[+-]" | wc -l)"
                separator_count=$(echo "${tranche_formalcharge_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_formalcharge has a valid value
                if ! [[ "$ligand_formalcharge" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The formal charge (${ligand_formalcharge}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(formalcharge)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (formal charge)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_formalcharge <= ${tranche_formalcharge_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_formalcharge_partition[((interval_index-2))]} < $ligand_formalcharge && $ligand_formalcharge <= ${tranche_formalcharge_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_formalcharge > ${tranche_formalcharge_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The formal charge (${ligand_formalcharge}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(formalcharge)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (formal charge)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Formal charge: ${ligand_formalcharge}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:formalcharge=${temp_end_time_ms}"

                ;;

            positivechargecount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_positivechargecount="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/+2/++/" | grep -o "+" | wc -l)"
                separator_count=$(echo "${tranche_positivechargecount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_positivechargecount has a valid value
                if ! [[ "$ligand_positivechargecount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The positive charge count (${ligand_positivechargecount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(positivechargecount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (positive charge count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_positivechargecount <= ${tranche_positivechargecount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_positivechargecount_partition[((interval_index-2))]} < $ligand_positivechargecount && $ligand_positivechargecount <= ${tranche_positivechargecount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_positivechargecount > ${tranche_positivechargecount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The positive charge count (${ligand_positivechargecount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(positivechargecount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (positive charge count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Number of atoms with positive charges: ${ligand_positivechargecount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:positivechargecount=${temp_end_time_ms}"

                ;;

            negativechargecount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_negativechargecount="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/-2/--/" | grep -o "-" | wc -l)"
                separator_count=$(echo "${tranche_negativechargecount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_negativechargecount has a valid value
                if ! [[ "$ligand_negativechargecount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The negative charge count (${ligand_negativechargecount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(negativechargecount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (negative charge count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_negativechargecount <= ${tranche_negativechargecount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_negativechargecount_partition[((interval_index-2))]} < $ligand_negativechargecount && $ligand_negativechargecount <= ${tranche_negativechargecount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_negativechargecount > ${tranche_negativechargecount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The negative charge count (${ligand_negativechargecount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(negativechargecount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (negative charge count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Number of atoms with negative charges: ${ligand_negativechargecount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:negativechargecount=${temp_end_time_ms}"

                ;;

            fsp3)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_fsp3="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator fsp3 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_fsp3_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_fsp3 has a valid value
                if ! [[ "$ligand_fsp3" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The Fsp3 value (${ligand_fsp3}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(fsp3)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (Fsp3)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_fsp3 <= ${tranche_fsp3_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_fsp3_partition[((interval_index-2))]} < $ligand_fsp3 && $ligand_fsp3 <= ${tranche_fsp3_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_fsp3 > ${tranche_fsp3_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The Fsp3 value (${ligand_fsp3}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(fsp3)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (Fsp3)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Fsp3: ${ligand_fsp3}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:fsp3=${temp_end_time_ms}"

                ;;

            chiralcentercount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_chiralcentercount="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator chiralcentercount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                separator_count=$(echo "${tranche_chiralcentercount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_chiralcentercount has a valid value
                if ! [[ "$ligand_chiralcentercount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The chiral center count value (${ligand_chiralcentercount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(chiralcentercount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (chiral center count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_chiralcentercount <= ${tranche_chiralcentercount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_chiralcentercount_partition[((interval_index-2))]} < $ligand_chiralcentercount && $ligand_chiralcentercount <= ${tranche_chiralcentercount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_chiralcentercount > ${tranche_chiralcentercount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The chiral center count value (${ligand_chiralcentercount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(chiralcentercount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (chiral center count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Chiral center count: ${ligand_chiralcentercount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:chiralcentercount=${temp_end_time_ms}"

                ;;

            halogencount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_fluorine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "F" | wc -l)"
                ligand_chlorine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "Cl" | wc -l)"
                ligand_bromine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "Br" | wc -l)"
                ligand_iodine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "I" | wc -l)"
                ligand_halogencount=$((ligand_fluorine_count+ligand_chlorine_count+ligand_bromine_count+ligand_iodine_count))
                separator_count=$(echo "${tranche_halogencount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_halogencount has a valid value
                if ! [[ "$ligand_halogencount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The halogen atom count (${ligand_halogencount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(halogencount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (halogen count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_halogencount <= ${tranche_halogencount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_halogencount_partition[((interval_index-2))]} < $ligand_halogencount && $ligand_halogencount <= ${tranche_halogencount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_halogencount > ${tranche_halogencount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The halogen atom count value (${ligand_halogencount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(halogencount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (halogen count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Halogen atom count: ${ligand_halogencount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:halogencount=${temp_end_time_ms}"

                ;;

            sulfurcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_sulfurcount="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/Si//" | grep -io "S" | wc -l)"
                separator_count=$(echo "${tranche_sulfurcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_sulfurcount has a valid value
                if ! [[ "$ligand_sulfurcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The sulfur atom count (${ligand_sulfurcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(sulfurcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (sulfur count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_sulfurcount <= ${tranche_sulfurcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_sulfurcount_partition[((interval_index-2))]} < $ligand_sulfurcount && $ligand_sulfurcount <= ${tranche_sulfurcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_sulfurcount > ${tranche_sulfurcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The sulfur atom count value (${ligand_sulfurcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(sulfurcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (sulfur count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Sulfur atom count: ${ligand_sulfurcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:sulfurcount=${temp_end_time_ms}"

                ;;

            NOcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_NOcount="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/Na//" | grep -io "[NO]" | wc -l)"
                separator_count=$(echo "${tranche_NOcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_NOcount has a valid value
                if ! [[ "$ligand_NOcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The NO atom count (${ligand_NOcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(NOcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (NO count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_NOcount <= ${tranche_NOcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_NOcount_partition[((interval_index-2))]} < $ligand_NOcount && $ligand_NOcount <= ${tranche_NOcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_NOcount > ${tranche_NOcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The NO count value (${ligand_NOcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(NOcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (NO count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * NO atom count: ${ligand_NOcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:NOcount=${temp_end_time_ms}"

                ;;

            electronegativeatomcount)
                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_electronegativeatomcount="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/Na//" | sed "s/Cl/X/" | sed "s/Si//" | grep -io "[NOSPFXBI]" | wc -l)"
                separator_count=$(echo "${tranche_electronegativeatomcount_partition[@]}" | wc -w)
                interval_count=$((separator_count+1))
                interval_index=1

                # Checking if ligand_electronegativeatomcount has a valid value
                if ! [[ "$ligand_electronegativeatomcount" =~ ^[[:digit:].e+-]+$ ]]; then
                    # Printing some information
                    echo "    * Warning: The electronegative atom count (${ligand_electronegativeatomcount}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(electronegativeatomcount)"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (electronegative atom count)"

                    # Skipping the ligand
                    continue 2
                fi

                # Loop for each interval
                for interval_index in $(seq 1 ${interval_count}); do
                    if [[ $interval_index -eq 1 ]]; then
                        if (( $(echo "$ligand_electronegativeatomcount <= ${tranche_electronegativeatomcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -lt ${interval_count} ]]; then
                        if (( $(echo "${tranche_electronegativeatomcount_partition[((interval_index-2))]} < $ligand_electronegativeatomcount && $ligand_electronegativeatomcount <= ${tranche_electronegativeatomcount_partition[((interval_index-1))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    elif [[ $interval_index -eq ${interval_count} ]]; then
                        if (( $(echo "$ligand_electronegativeatomcount > ${tranche_electronegativeatomcount_partition[((interval_index-2))]}" | bc -l) )); then
                            assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index-1))]}
                            break
                        fi
                    else
                        # Printing some information
                        echo "    * Warning: The electronegative atom count (${ligand_electronegativeatomcount}) of ligand (${next_ligand}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                        # Updating the ligand-list entry
                        ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(electronegativeatomcount)"

                        # Updating the ligand list
                        update_ligand_list_end false "during tranche assignment (electronegative atom count)"

                        # Skipping the ligand
                        continue 2
                    fi

                    # Continuing to next interval
                    interval_index=$((interval_index+1))
                done

                # PDB Remark
                pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * Electronegativ atom count: ${ligand_electronegativeatomcount}"

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                component_timings="${component_timings}:electronegativeatomcount=${temp_end_time_ms}"

                ;;

            *)
                # Printing some information
                echo -e " Error: The value ("${tranche_type}") of the variable tranche_types is not supported."
                error_response_std $LINENO
                ;;
        esac

        if [[ "${#assigned_tranche}" -eq "${tranche_count}" ]]; then
            
            # Variables
            trancheassignment_success="true"
            
            # Timings
            tranche_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${tranche_start_time_ms}))"
            component_timings="${component_timings}:tranche-assignments-total=${tranche_end_time_ms}"

            # PDB Remark
            pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    Tranche: ${assigned_tranche}"
        fi

    done
}

determine_controlfile() {

    # Determining the VF_CONTROLFILE to use for this jobline
    VF_CONTROLFILE_OLD=${VF_CONTROLFILE}
    VF_CONTROLFILE=""
    for file in $(ls ../workflow/control/*-* 2>/dev/null || true); do
        file_basename=$(basename $file)
        jobline_range=${file_basename/.*}
        jobline_no_start=${jobline_range/-*}
        jobline_no_end=${jobline_range/*-}
        if [[ "${jobline_no_start}" -le "${VF_JOBLINE_NO}" && "${VF_JOBLINE_NO}" -le "${jobline_no_end}" ]]; then
            export VF_CONTROLFILE="${file}"
            break
        fi
    done

    # Checking if a specific control file was found
    if [ -z "${VF_CONTROLFILE}" ]; then
        if [[ -f ../workflow/control/all.ctrl ]]; then

            if [[ "{VF_CONTROLFILE_OLD}" != "../workflow/control/all.ctrl" ]]; then

                # Variables
                export VF_CONTROLFILE="../workflow/control/all.ctrl"
            fi

        else
            # Error response
            echo "Error: No relevant control file was found..."
            false
        fi
    fi

    # Checking if the control fil}e has changed
    if [[ "${VF_CONTROLFILE}" != "${VF_CONTROLFILE_OLD}" ]] || [[ ! -f ${VF_CONTROLFILE_TEMP} ]]; then

        # Updating the temporary controlfile
        cp ${VF_CONTROLFILE} ${VF_CONTROLFILE_TEMP}

    fi
}

# Verbosity
if [ "${VF_VERBOSITY_LOGFILES}" = "debug" ]; then
    set -x
fi

# Determining the control file
export VF_CONTROLFILE_TEMP=${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/controlfile
determine_controlfile

# Variables
targetformats="$(grep -m 1 "^targetformats=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
minimum_time_remaining="$(grep -m 1 "^minimum_time_remaining=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
outputfiles_level="$(grep -m 1 "^outputfiles_level=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
obabel_version="$(obabel -V | awk '{print $3}')"
if [ -z ${obabel_version} ]; then
    echo " * Error: OpenBabel is not available..."
    error_response_std $LINENO
fi
keep_ligand_summary_logs="$(grep -m 1 "^keep_ligand_summary_logs=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
ligand_check_interval="$(grep -m 1 "^ligand_check_interval=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
obabel_memory_limit="$(grep -m 1 "^obabel_memory_limit=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
obabel_time_limit="$(grep -m 1 "^obabel_time_limit=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Desalting
desalting="$(grep -m 1 "^desalting=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${desalting}" == "true" ]; then

    # Variables
    desalting_obligatory="$(grep -m 1 "^desalting_obligatory=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
fi

# Neutralization
neutralization="$(grep -m 1 "^neutralization=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${neutralization}" == "true" ]; then

    # Variables
    neutralization_mode="$(grep -m 1 "^neutralization_mode=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    neutralization_obligatory="$(grep -m 1 "^neutralization_obligatory=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    standardizer_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.standardizer.StandardizerCLI -h | head -n 1 | awk -F '[ ,]' '{print $2}')"

    # Checking variable values
    if [[ ( "${neutralization_mode}" == "if_genuine_desalting" || "${neutralization_mode}" == "if_genuine_desalting_and_charged" ) && ! "${desalting}" == "true" ]]; then

        # Printing some information
        echo -e " Error: The value (${neutralization_mode}) of the variable neutralization_mode requires desalting to be enabled, but it is disabled."
        error_response_std $LINENO
    fi
fi

# Tautomerization settings
# TODO: Improve JCchem dependency settings (or obligatory)
tautomerization="$(grep -m 1 "^tautomerization=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${tautomerization}" == "true" ]; then

    # Variables
    tautomerization_obligatory="$(grep -m 1 "^tautomerization_obligatory=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    cxcalc_tautomerization_options="$(grep -m 1 "^cxcalc_tautomerization_options=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    cxcalc_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
fi

# Protonation settings
protonation_state_generation="$(grep -m 1 "^protonation_state_generation=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${protonation_state_generation}" == "true" ]; then

    # Variables
    protonation_program_1="$(grep -m 1 "^protonation_program_1=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    protonation_program_2="$(grep -m 1 "^protonation_program_2=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    protonation_obligatory="$(grep -m 1 "^protonation_obligatory=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    protonation_pH_value="$(grep -m 1 "^protonation_pH_value=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

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
conformation_generation="$(grep -m 1 "^conformation_generation=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${conformation_generation}" == "true" ]; then

    # Variables
    conformation_program_1="$(grep -m 1 "^conformation_program_1=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    conformation_program_2="$(grep -m 1 "^conformation_program_2=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    conformation_obligatory="$(grep -m 1 "^conformation_obligatory=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

    # Interdependent variables
    if [[ "${conformation_program_1}" ==  "molconvert" ]] || [[ "${conformation_program_2}" ==  "molconvert" ]]; then
        molconvert_version="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.formats.MolConverter | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
        molconvert_3D_options="$(grep -m 1 "^molconvert_3D_options=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
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

# Potential energy check
energy_check="$(grep -m 1 "^energy_check=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${energy_check}" == "true" ]; then
    energy_max="$(grep -m 1 "^energy_max=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    if ! [[ "${energy_max}" =~ ^[0-9]+$ ]]; then
        echo -e " Error: The value (${energy_max}) for variable energy_max which was specified in the controlfile is invalid..."
        error_response_std $LINENO
    fi
elif [[ "${energy_check}" != "false" ]]; then
    echo -e " Error: The value (${energy_check}) for variable energy_check which was specified in the controlfile is invalid..."
    error_response_std $LINENO
fi

# Reassignment of tranches
tranche_assignments="$(grep -m 1 "^tranche_assignments=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${tranche_assignments}" = "true" ]; then

    # Variables
    tranche_types="$(grep -m 1 "^tranche_types=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
    IFS=':' read -a tranche_types <<< "${tranche_types}"
    tranche_count=$(echo "${tranche_types[@]}" | wc -w)

    # Loop for each tranche type
    for tranche_type in "${tranche_types[@]}"; do

        if [[ "${tranche_type}" != @(mw|logp_jchem|logp_obabel|hba_jchem|hba_obabel|hbd_jchem|hbd_obabel|rotb|tpsa_jchem|tpsa_obabel|logd|logs|atomcount|bondcount|ringcount|aromaticringcount|formalcharge|mr_jchem|mr_obabel|positivechargecount|negativechargecount|fsp3|chiralcentercount|halogencount|sulfurcount|NOcount|electronegativeatomcount) ]]; then
            echo -e " Error: The value (${tranche_type}) was present in the variable tranche_types, but this value is invalid..."
            error_response_std $LINENO
        fi

        # Variables
        IFS=':' read -a tranche_${tranche_type}_partition < <(grep -m 1 "^tranche_${tranche_type}_partition=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')
    done
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
cat ${VF_CONTROLFILE_TEMP}
echo
echo

# Getting the folder where the colections are
collection_folder="$(grep -m 1 "^collection_folder=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Loop for each ligand
ligand_index=0
while true; do

    # Variables
    new_collection="false"
    collection_complete="false"
    ligand_index=$((ligand_index+1))
    component_timings=""

    # Preparing the next ligand
    # Checking the conditions for using a new collection
    if [[ "${ligand_index}" == "1" ]]; then

        #if [[ "${ligand_index}" -gt "1" && ! "$(cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} | tr -d '[:space:]')" ]]; then

        # Checking if there is no current ligand collection
        if [[ ! -s ../workflow/ligand-collections/current/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO} ]]; then

            # Preparing a new collection
            next_ligand_collection
            prepare_collection_files_tmp

            # Getting the name of the first ligand of the first collection
            next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')


        # Using the old collection
        else
            # Getting the name of the current ligand collection
            next_ligand_collection=$(awk '{print $1}' ../workflow/ligand-collections/current/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO})
            next_ligand_collection_ID="${next_ligand_collection/*_}"
            next_ligand_collection_tranche="${next_ligand_collection/_*}"
            next_ligand_collection_metatranche="${next_ligand_collection_tranche:0:2}"

            # Extracting the last ligand collection
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}
            cp ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}
            tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/ ${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
            gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
            # Extracting all the SMILES at the same time (faster)
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}
            tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/

            # Copying the ligand-lists status file if it exists
            if [[ -f  ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status ]]; then
                cp ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/

                # Variables
                last_ligand=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status | awk -F '[: ,/]' '{print $1}' 2>/dev/null || true)
                last_ligand_status=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status | awk -F '[: ,/]' '{print $2}' 2>/dev/null || true)

                # Checking if the last ligand was in the status processing. In this case we will try to process the ligand again since the last process might have not have the chance to complete its tasks.
                if [ "${last_ligand_status}" == "processing" ]; then
                    perl -ni -e "/${last_ligand}:processing/d" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status # Might not work for VFLP due to multiple replicas
                    next_ligand="${last_ligand/_T*}"
                else
                    next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | grep -w -A 1 "${last_ligand/_T*}" | grep -v ${last_ligand/_T*} | awk -F '[/.]' '{print $2}')
                fi

            else
                # Restarting the collection
                next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
            fi
        fi

    # Using the old collection
    else

        # Not first ligand of this queue
        last_ligand=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status 2>/dev/null | awk -F '[:. ]' '{print $1}' || true)
        next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | grep -w -A 1 "${last_ligand/_T*}" | grep -v ${last_ligand/_T*} | awk -F '[/.]' '{print $2}')
    fi

    # Checking if we can use the collection determined so far
    if [ -n "${next_ligand}" ]; then

        # Preparing the collection folders if this is the first ligand of this queue
        if [[ "${ligand_index}" == "1" ]]; then
            prepare_collection_files_tmp
        fi

    # Otherwise we have to use a new ligand collection
    else
        collection_complete="true"
        # Cleaning up the files and folders of the old collection
        if [ ! "${ligand_index}" = "1" ]; then
           clean_collection_files_tmp ${next_ligand_collection}
        fi
        # Getting the next collection if there is one more
        next_ligand_collection
        prepare_collection_files_tmp
        # Getting the first ligand of the new collection
        next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
    fi

    # Displaying the heading for the new ligand
    echo ""
    echo "      Ligand ${ligand_index} of job ${VF_OLD_JOB_NO} belonging to collection ${next_ligand_collection}: ${next_ligand}"
    echo "*****************************************************************************************"

    # Setting up variables
    # Checking if the current ligand index divides by ligand_check_interval
    if [ "$((ligand_index % ligand_check_interval))" == "0" ]; then

        # Determining the controlfile
        determine_controlfile

        # Checking if this queue line should be stopped immediately
        stop_after_next_check_interval="$(grep -m 1 "^stop_after_next_check_interval=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
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
    # Adjusting the ligand-list file
    ligand_list_entry="${ligand_list_entry} entry-type:initial"


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
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
            fi
        else

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} desalting:success(${desalting_type})"
        fi
    else

        # Copying the original ligand
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi

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
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
            fi
        else

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} neutralization:success(${neutralization_type})"
        fi
    else

        # Copying the original ligand
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi

    fi

     # TODO Determine assigned_tranche
     # function?


#     # Stereoisomer generation
#     stereoisomer_generation=""
#     if [ "${stereoisomer_generation}" == "true" ]; then
#
#         # Variables
#         stereoisomer_generation_success="false"
#
#         # Printing information
#         echo -e "\n * Starting the stereoisomer generation with cxcalc"
#
#         # Carrying out the tautomerization
#         cxcalc_stereoisomer_generation
#
#         # Checking if the stereoisomer generation has failed
#         if [ "${stereoisomer_generation_success}" == "false" ]; then
#
#             # Printing information
#             echo "    * Warning: The tautomerization has failed."
#
#             # Adjusting the ligand-list file
#             ligand_list_entry="${ligand_list_entry} tautomerization:failed"
#
#             # Checking if tautomerization is mandatory
#             if [ "${tautomerization_obligatory}" == "true" ]; then
#
#                 # Printing some information
#                 echo "    * Warning: Ligand will be skipped since a successful tautomerization is required according to the controlfile."
#
#                 # Updating the ligand list
#                 update_ligand_list_end false "during tautomerization"
#
#                 # Skipping the ligand
#                 continue
#             else
#
#                 # Printing some information
#                 echo "    * Warning: Ligand will be further processed without tautomerization"
#
#                 # Variables
#                 next_ligand_tautomers=${next_ligand}
#
#                 # Copying the original ligand
#                 cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
#             fi
#         else
#
#             # Adjusting the ligand-list file
#             next_ligand_tautomers_count=$(echo ${next_ligand_tautomers} | wc -w)
#             ligand_list_entry="${ligand_list_entry} tautomerization(${next_ligand_tautomers_count}):success"
#         fi
#     else
#
#         # Copying the original ligand
#         cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
#
#         # Variables
#         next_ligand_tautomers=${next_ligand}
#
#     fi



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
t 1.
# For each tranch type <X>
                # Skipping the ligand
                continue
            else

                # Printing some information
                echo "    * Warning: Ligand will be further processed without tautomerization"

                # Variables
                next_ligand_tautomers=${next_ligand}

                # Copying the original ligand
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
            fi
        else

            # Adjusting the ligand-list file
            next_ligand_tautomers_count=$(echo ${next_ligand_tautomers} | wc -w)
            ligand_list_entry="${ligand_list_entry} tautomerization(${next_ligand_tautomers_count}):success"
        fi
    else

        # Copying the original ligand
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi

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

            # Adjusting the ligand-list file
            ligand_list_entry="${ligand_list_entry} entry-type:partial"

            # Printing some information
            echo -e "\n *** Starting the processing of tautomer ${next_ligand_tautomer_index}/${next_ligand_tautomers_count} (${next_ligand}) ***"
        fi

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
                    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
                fi
            else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} protonation:success(${protonation_program})"
            fi

            # Copying the unprotonated ligand
            cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi

        fi

        # Reassigning the tranches if needed
        if [ "${tranche_assignments}" = "true" ]; then

            # Variables
            pdb_trancheassignments_remark=""
            trancheassignment_success="false"

            # Tranche assignments
            assign_tranches_to_ligand

            # Checking if both of the 3D conformation generation attempts have failed
            if [ "${trancheassignment_success}" == "false" ]; then

                # Printing information
                echo "    * Error: The tranche assignments have failed, ligand will be skipped."

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} tranche-assignments:failed"

                # Skipping the ligand
                continue

            else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} tranche-assignment:success"
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
            # TODO: Checking the energy. Does PDBQT corrupt also mean PDB corrupt? Do we need to check all formats, or just PDB?

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

        # Checking the potential energy
        if [[ "${energy_check}" == "true" ]]; then

            # Variables
            energy_check_success="false"

            # Printing information
            echo -e "\n * Starting to check the potential energy of the ligand"

            # Attempting the energy check with obabel
            obabel_check_energy

            # Checking if energy check generation attempt has failed and is mandatory
            if [[ "${energy_check_success}" == "false" ]]; then

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} energy-check:failed"

                # Printing some information
                echo "    * Warning: Ligand will be skipped since it did not pass the energy-check."

                # Updating the ligand list
                update_ligand_list_end false "during energy check"

                # Removing the pdb file
                rm ${pdb_intermediate_output_file} &>/dev/null || true

                # Skipping the ligand
                continue
            else

                # Adjusting the ligand-list file
                ligand_list_entry="${ligand_list_entry} energy-check:success"
            fi
        fi

        # Generating the target formats
        # Printing information
        echo -e "\n * Starting the target format generation with obabel"
        # Loop for each target format
        for targetformat in ${targetformats//:/ }; do

            # Variables
            targetformat_generation_success="false"
            additional_obabel_options=""


            # Timings
            temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
            temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

            if [ ${targetformat} == "smi" ]; then
                additional_obabel_options="-xn"
            fi

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

          # Timings
          component_timings="${component_timings}:obabel_generate_targetformat=${temp_end_time_ms}"

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


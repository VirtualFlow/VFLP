#!/usr/bin/env bash
# shellcheck disable=SC2104

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
    perl -pi -e "s/${next_ligand/_T*}.* processing.*/${next_ligand} ${ligand_list_entry} total-time:${ligand_total_time_ms} timings${timings_before_tautomers}${timings_after_tautomers}/g" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status

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

        # Determining the collection notation format
        number_of_dashes=$(echo "${next_ligand_collection}" | awk -F "_" '{print NF-1}')
        if [[ ${number_of_dashes} == "1" ]]; then
            next_ligand_collection_ID="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $3}')"
            next_ligand_collection_tranche="${next_ligand_collection/_*}"
            next_ligand_collection_metatranche="${next_ligand_collection_tranche:0:2}"
        elif [[ ${number_of_dashes} == "2" ]]; then
            next_ligand_collection_metatranche="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $1}')"
            next_ligand_collection_tranche="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $2}')"
            next_ligand_collection_ID="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $3}')"
        else
            echo -e " Error: The format of the ligand collection names is not supported."
            error_response_std $LINENO
        fi

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
    if [ ! -d "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}" ]; then
        mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
    elif [ "$(ls -A "${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}")" ]; then
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/*
    fi
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
    if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
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
        # format splitted1000.gz format splitted1000.ind.tar.gz
        # unzip and copy. mkdir folder. make individual smiles
        # Checking if the collection could be extracted
        if [ ! -f ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar ]; then

            # Raising an error
            echo " * Error: The ligand collection ${next_ligand_collection_tranche}_${next_ligand_collection_ID} could not be prepared."
            error_response_std $LINENO
        fi

        # Extracting all the SMILES at the same time (faster than individual for each ligand separately)
        tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}
        for file in $(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/); do
            awk '{print $1}' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${file} > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${file}
        done

    elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
        if [ -f ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.txt.gz ]; then
            rm  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/* 2>/dev/null || true
            cp ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.txt.gz ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt.gz
            gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt.gz
            awk -v folder="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/" -F '\t' '{print $0 >folder$2".smi"; close(folder$2".smi")}' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt
            awk -v folder="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/" -F '\t' '{print $1 >folder$2".smi"; close(folder$2".smi")}' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt

        else
            # Raising an error
            echo " * Error: The tranche archive file ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.txt.gz does not exist..."
            error_response_std $LINENO
        fi
    fi

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

        # Checking if all the folders required are there
        if [ "${collection_complete}" = "true" ]; then

            # Printing some information
            echo -e "\n * The collection ${next_ligand_collection} has been completed."
            echo "    * Storing and cleaning corresponding files..."

            # Loop for each target format
            for targetformat in ${targetformats//:/ }; do

                # Compressing the collection and saving in the complete folder
                mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
                tar -czf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/ ${next_ligand_collection_ID} || true
                next_ligand_collection_length="$(ls ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} | wc -l)"

                # Adding the completed collection archive to the tranche archive
                if [ "${outputfiles_level}" == "tranche" ]; then
                    mkdir -p ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}
                    if [ -f ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ]; then
                        cp ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar
                    fi
                    tar -rf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche} ${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz || true
                    mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar
                elif [ "${outputfiles_level}" == "collection" ]; then
                    mkdir -p ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
                    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
                else
                    echo " * Error: The variable 'outputfiles_level' in the controlfile ${VF_CONTROLFILE_TEMP} has an invalid value (${outputfiles_level})"
                    exit 1
                fi

                # Adding the length entry
                echo "${next_ligand_collection}" "${next_ligand_collection_length}" >> ../output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.length

                # Cleaning up
                rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz &> /dev/null || true
                rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true

            done

            # Updating the ligand collection files
            echo -n "" > ../workflow/ligand-collections/current/${VF_QUEUE_NO}
            ligands_succeeded_tautomerization="$(grep "tautomerization([0-9]\+):success" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status | grep -c tautomerization)"
            ligands_succeeded_targetformat="$(grep -c "targetformat-generation([A-Za-z]\+):success" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status)"
            ligands_failed="$(grep -c "failed total" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status)"
            ligands_started="$(grep -c "initial" ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status)"
            echo "${next_ligand_collection} was completed by queue ${VF_QUEUE_NO} on $(date). Ligands started:${ligands_started} succeeded(tautomerization):${ligands_succeeded_tautomerization} succeeded(target-format):${ligands_succeeded_targetformat} failed:${ligands_failed}" >> ../workflow/ligand-collections/done/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO}


            # Checking if we should keep the ligand log summary files
            if [ "${keep_ligand_summary_logs}" = "true" ]; then


                # Compressing and archiving the status file
                gzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status

                # TODO Checking output file level
                if [ "${outputfiles_level}" == "tranche" ]; then

                    # Directory preparation
                    mkdir  -p ../output-files/complete/${docking_scenario_name}//ligand-lists/${next_ligand_collection_metatranche}

                    if [ -f ../output-files/complete/${docking_scenario_name}//ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ]; then
                        cp ../output-files/complete/${docking_scenario_name}//ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar
                    fi
                    tar -rf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/ ${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status.gz || true
                    mv ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ../output-files/complete/${docking_scenario_name}//ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar
                elif [ "${outputfiles_level}" == "collection" ]; then
                    mkdir -p ../output-files/complete/${docking_scenario_name}/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
                    cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status.gz ../output-files/complete/${docking_scenario_name}/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
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
                tar -czf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/ ${next_ligand_collection_ID} || true

                # Copying the files which should be kept in the permanent storage location
                mkdir -p ../output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
                cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz ../output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
            done

            mkdir -p ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/
            cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/ || true

        fi

        # Cleaning up
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
        rm  ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar &> /dev/null || true
        rm ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status* &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_neutralized/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_tautomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
        rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/pdb_intermediate/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true

        # Cleaning up
        for targetformat in ${targetformats//:/ }; do
            rm -r ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID} &> /dev/null || true
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

    # Number of fragments in SMILES
    number_of_smiles_fragments="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tr "." "\n" | wc -l)"

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
        cp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_desalted/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi
    else

        # Printing some information
        echo "    * Warning: Could not determine the number of fragments. Desalting failed..."
    fi

    # Timings
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_before_tautomers="${timings_before_tautomers}:desalt=${temp_end_time_ms}"
}

standardizer_neutralize() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_before_tautomers="${timings_before_tautomers}:standardizer_neutralize=${temp_end_time_ms}"
}

# Protonation with cxcalc
cxcalc_tautomerize() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_before_tautomers="${timings_before_tautomers}:cxcalc_tautomerize=${temp_end_time_ms}"
}

# Protonation with cxcalc
cxcalc_protonate() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_after_tautomers="${timings_after_tautomers}:cxcalc_protonate=${temp_end_time_ms}"
}

# Protonation with obabel
obabel_protonate() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_after_tautomers="${timings_after_tautomers}:obabel_protonate=${temp_end_time_ms}"
}

# Conformation generation with molconvert
molconvert_generate_conformation() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
    { timeout 300 time_bin -f "    * Timings of molconvert (user real system): %U %e %S" ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.formats.MolConverter pdb:+H ${molconvert_3D_options} ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -o ${pdb_intermediate_output_file} 2> >(tee ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output.tmp 1>&2) ; } 2>&1
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
        smiles="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi)"
        conformation_success="true"
        pdb_conformation_remark="REMARK    Generation of the 3D conformation was carried out by molconvert version ${molconvert_version} of ChemAxons JChem Suite."
        conformation_program="molconvert"
        # Modifying the header of the pdb file and correction of the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/TITLE\|SOURCE\|KEYWDS\|EXPDTA/d' ${pdb_intermediate_output_file} | sed "s|PROTEIN.*|Small molecule (ligand)|g" | sed "s|AUTHOR.*|REMARK    SMILES: ${smiles[0]}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_conformation_remark}\n${pdb_trancheassignment_remark}|g" | sed "/REVDAT.*/d" | sed "s/NONE//g" | sed "s/ UN[LK] / LIG /g" | sed "s/COMPND.*/COMPND    Compound: ${next_ligand}/g" | sed 's/+0//' | sed 's/\([+-]\)\([0-9]\)$/\2\1/g' | sed '/^\s*$/d' > ${pdb_intermediate_output_file}.tmp
        mv ${pdb_intermediate_output_file}.tmp ${pdb_intermediate_output_file}
    fi

    # Timings
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_after_tautomers="${timings_after_tautomers}:molconvert_generate_conformation=${temp_end_time_ms}"
}

# Conformation generation with obabel
obabel_generate_conformation(){

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
        sed '/COMPND/d' ${pdb_intermediate_output_file} | sed "s|AUTHOR.*|HEADER    Small molecule (ligand)\nCOMPND    Compound: ${next_ligand}\nREMARK    SMILES: ${smiles[0]}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_conformation_remark}\n${pdb_trancheassignment_remark}|g" | sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${pdb_intermediate_output_file}.tmp
        mv ${pdb_intermediate_output_file}.tmp ${pdb_intermediate_output_file}
    fi

    # Timings
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_after_tautomers="${timings_after_tautomers}:obabel_generate_conformation=${temp_end_time_ms}"
}

# PDB generation with obabel
obabel_generate_pdb() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

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
        sed '/COMPND/d' ${pdb_intermediate_output_file} | sed "s|AUTHOR.*|HEADER    Small molecule (ligand)\nCOMPND    Compound: ${next_ligand}\nREMARK    SMILES: ${smiles[0]}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_trancheassignment_remark}|g" |  sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${pdb_intermediate_output_file}.tmp
        mv ${pdb_intermediate_output_file}.tmp /${pdb_intermediate_output_file}
    fi

    # Timings
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_after_tautomers="${timings_after_tautomers}:obabel_generate_pdb=${temp_end_time_ms}"
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
            sed "s|REMARK  Name.*|REMARK    Small molecule (ligand)\nREMARK    Compound: ${next_ligand}\nREMARK    SMILES: ${smiles[0]}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_conformation_remark}\n${pdb_targetformat_remark}\n${pdb_trancheassignment_remark}\nREMARK    Created on $(date)|g" ${targetformat_output_file} | sed "s/ UN[LK] / LIG /g" | sed '/^\s*$/d' > ${targetformat_output_file}.tmp
            mv ${targetformat_output_file}.tmp ${targetformat_output_file}
        elif [[ "${targetformat}" == "mol2" ]]; then
            # Variables
            mol2_targetformat_remark="# Generation of the the target format file (${targetformat}) was carried out by Open Babel version ${obabel_version}."

            # Modifying the header of the targetformat file
            sed "1i# Small molecule (ligand)\n# Compound: ${next_ligand}\n# SMILES: ${smiles[0]}\n${pdb_desalting_remark}\n${pdb_neutralization_remark}\n${pdb_tautomerization_remark}\n${pdb_protonation_remark}\n${pdb_generation_remark}\n${pdb_conformation_remark}\n${pdb_targetformat_remark}\n${pdb_trancheassignment_remark}\n# Created on $(date)" ${targetformat_output_file} | sed "s/REMARK    /# /"  > ${targetformat_output_file}.tmp
            mv ${targetformat_output_file}.tmp ${targetformat_output_file}
        fi

        # Removing any local file path information which obabel often adds
        sed "s#^/.*# ${next_ligand}#" ${targetformat_output_file} | sed "s# /.*# ${next_ligand}#" > ${targetformat_output_file}.tmp
        mv ${targetformat_output_file}.tmp ${targetformat_output_file}

    fi
}

# Determining the potential energy
obabel_check_energy() {

    # Timings
    temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

    # Computing the energy
    ligand_energy=""
    ligand_energy="$(obenergy ${pdb_intermediate_output_file} | tail -n 1 | awk '{print $4}')"

    # Checking if the energy is below threshold
    if (( $(echo "$ligand_energy <= ${energy_max}" | bc -l) )); then
        energy_check_success="true"
    fi

    # Timings
    temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
    timings_after_tautomers="${timings_after_tautomers}:obabel_energy=${temp_end_time_ms}"
}

determine_tranche() {

    # Variables
    separator_count=$(echo "${tranche_partition[@]}" | wc -w)
    interval_count=$((separator_count + 1))
    interval_index=1

    # Checking for scientific notation
    if [[ ${property_value} == *"E"* ]]; then
        property_value="$(printf '%.2f' ${property_value})"
    fi

    # Checking if the variable property_value has a valid value
    if ! [[ "$property_value" =~ ^[[:digit:].e+-]+$ ]]; then

        if [[ "${tranche_mandatory}" == "true" ]]; then
            # Printing some information
            echo "    * Warning: The value of the variable ${property_name} (${property_value}) of ligand (${next_ligand}) is not a number. The ligand will be skipped since a successful tranche assignment is required."

            # Updating the ligand-list entry
            ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(${property_name})"

            # Updating the ligand list
            update_ligand_list_end false "during tranche assignment (${property_name})"

            # Skipping the ligand
            continue 2

        elif [[ "${tranche_mandatory}" == "false" ]]; then
            # Printing some information
            echo "    * Warning: The value of the variable ${property_name} (${property_value}) could not be assigned due to an unknown problem. Setting tranche to '0'."

            # Updating the ligand-list entry
            ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(${property_name})"

            # Tranche variable
            assigned_tranche="${assigned_tranche}0"
        fi

    else

        # Loop for each interval
        for interval_index in $(seq 1 ${interval_count}); do
            if [[ $interval_index -eq 1 ]]; then
                if (($(echo "$property_value <= ${tranche_partition[((interval_index - 1))]}" | bc -l))); then
                    assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index - 1))]}
                    break
                fi
            elif [[ $interval_index -lt ${interval_count} ]]; then
                if (($(echo "${tranche_partition[((interval_index - 2))]} < $property_value && $property_value <= ${tranche_partition[((interval_index - 1))]}" | bc -l))); then
                    assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index - 1))]}
                    break
                fi
            elif [[ $interval_index -eq "${interval_count}" ]]; then
                if (($(echo "$property_value > ${tranche_partition[((interval_index - 2))]}" | bc -l))); then
                    assigned_tranche=${assigned_tranche}${tranche_letters[((interval_index - 1))]}
                    break
                fi
            else
                if [[ "${tranche_mandatory}" == "true" ]]; then
                    # Printing some information
                    echo "    * Warning: The value of the variable ${property_name} (${property_value}) could not be assigned due to an unknown problem. The ligand will be skipped since a successful tranche assignment is required."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(${property_name})"

                    # Updating the ligand list
                    update_ligand_list_end false "during tranche assignment (${property_name})"

                    # Skipping the ligand
                    continue 2

                elif [[ "${tranche_mandatory}" == "true" ]]; then
                    # Printing some information
                    echo "    * Warning: The value of the variable ${property_name} (${property_value}) could not be assigned due to an unknown problem. Setting tranche value to '0'."

                    # Updating the ligand-list entry
                    ligand_list_entry="${ligand_list_entry} tranche-assignment:failed(${property_name})"

                    # Tranche variable
                    assigned_tranche="${assigned_tranche}0"
                fi
            fi

            # Continuing to next interval
            interval_index=$((interval_index + 1))
        done

        # PDB Remark
        pdb_trancheassignment_remark="${pdb_trancheassignment_remark}\nREMARK    * ${property_description_large}: ${property_value}"

    fi
}

# Determining and assigning the tranche
assign_tranches_to_ligand() {

    # Determining the tranche
    assigned_tranche=""
    tranche_letters=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z a b c d e f g h i j k l m n o p q r s t u v w x y z)
    pdb_trancheassignment_remark="REMARK    Ligand properties"
    smiles_line="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand/_T*}.smi)"

    # Timings
    tranche_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))

    # Loop
    for tranche_type in "${tranche_types[@]}"; do

        case ${tranche_type} in

            mw_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator mass ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_mw_jchem_mandatory}
                tranche_partition=("${tranche_mw_jchem_partition[@]}")
                property_description_small="MW"
                property_description_large="MW"
                property_name="mw_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            mw_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^mol_weight " | awk '{print $2}')"
                tranche_mandatory=${tranche_mw_obabel_mandatory}
                tranche_partition=("${tranche_mw_obabel_partition[@]}")
                property_description_small="MW"
                property_description_large="MW"
                property_name="mw_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            logp_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^logP " | awk '{print $2}')"
                tranche_mandatory=${tranche_logp_obabel_mandatory}
                tranche_partition=("${tranche_logp_obabel_partition[@]}")
                property_description_small="LogP (Open Babel)"
                property_description_large="LogP (Open Babel)"
                property_name="logp_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            logp_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator logp ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_logp_jchem_mandatory}
                tranche_partition=("${tranche_logp_jchem_partition[@]}")
                property_description_small="LogP (JChem)"
                property_description_large="LogP (JChem)"
                property_name="logp_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            hba_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator acceptorcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_hba_jchem_mandatory}
                tranche_partition=("${tranche_hba_jchem_partition[@]}")
                property_description_small="HBA count (JChem)"
                property_description_large="HBA count (JChem)"
                property_name="hba_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            hba_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obabel -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -osmi --append HBA1 | head -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_hba_obabel_mandatory}
                tranche_partition=("${tranche_hba_obabel_partition[@]}")
                property_description_small="HBA count (Open Babel):"
                property_description_large="HBA count (Open Babel)"
                property_name="hba_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            hbd_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator donorcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_hbd_jchem_mandatory}
                tranche_partition=("${tranche_hbd_jchem_partition[@]}")
                property_description_small="HBD count (JChem)"
                property_description_large="HBD count (JChem)"
                property_name="hbd_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            hbd_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obabel -ismi ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi -osmi --append HBD |  head -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_hbd_obabel_mandatory}
                tranche_partition=("${tranche_hbd_obabel_partition[@]}")
                property_description_small="HBD (Open Babel)"
                property_description_large="HBD (Open Babel)"
                property_name="hbd_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            rotb_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator rotatablebondcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_rotb_jchem_mandatory}
                tranche_partition=("${tranche_rotb_jchem_partition[@]}")
                property_description_small="RotB"
                property_description_large="RotB"
                property_name="rotb_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            rotb_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator rotatablebondcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_rotb_obabel_mandatory}
                tranche_partition=("${tranche_rotb_obabel_partition[@]}")
                property_description_small="RotB"
                property_description_large="RotB"
                property_name="rotb_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            tpsa_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator polarsurfacearea ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_tpsa_jchem_mandatory}
                tranche_partition=("${tranche_tpsa_jchem_partition[@]}")
                property_description_small="TPSA (JChem)"
                property_description_large="TPSA (JChem)"
                property_name="tpsa_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            tpsa_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^PSA " | awk '{print $2}')"
                tranche_mandatory=${tranche_tpsa_obabel_mandatory}
                tranche_partition=("${tranche_tpsa_obabel_partition[@]}")
                property_description_small="TPSA (Open Babel)"
                property_description_large="TPSA (Open Babel)"
                property_name="tpsa_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            logd)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator logd ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_logd_mandatory}
                tranche_partition=("${tranche_logd_partition[@]}")
                property_description_small="LogD (JChem)"
                property_description_large="LogD (JChem)"
                property_name="logd"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            logs)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator logs ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}' | sed "s/0\.00E0/0.0/")"
                tranche_mandatory=${tranche_logs_mandatory}
                tranche_partition=("${tranche_logs_partition[@]}")
                property_description_small="LogS (JChem)"
                property_description_large="LogS (JChem)"
                property_name="logs"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            atomcount_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator atomcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_atomcount_jchem_mandatory}
                tranche_partition=("${tranche_atomcount_jchem_partition[@]}")
                property_description_small="atom count"
                property_description_large="Atom count"
                property_name="atomcount_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            atomcount_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^num_atoms " | awk '{print $2}')"
                tranche_mandatory=${tranche_atomcount_obabel_mandatory}
                tranche_partition=("${tranche_atomcount_obabel_partition[@]}")
                property_description_small="atom count"
                property_description_large="Atom count"
                property_name="atomcount_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            bondcount_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^num_bonds " | awk '{print $2}')"
                tranche_mandatory=${tranche_bondcount_obabel_mandatory}
                tranche_partition=("${tranche_bondcount_obabel_partition[@]}")
                property_description_small="bond count"
                property_description_large="Bond count"
                property_name="bondcount_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            bondcount_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator bondcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_bondcount_jchem_mandatory}
                tranche_partition=("${tranche_bondcount_jchem_partition[@]}")
                property_description_small="bond count"
                property_description_large="Bond count"
                property_name="bondcount_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            ringcount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator ringcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_ringcount_mandatory}
                tranche_partition=("${tranche_ringcount_partition[@]}")
                property_description_small="ring count"
                property_description_large="Ring count"
                property_name="ringcount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            aromaticringcount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator aromaticringcount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_aromaticringcount_mandatory}
                tranche_partition=("${tranche_aromaticringcount_partition[@]}")
                property_description_small="aromatic ring count"
                property_description_large="Aromatic ring count"
                property_name="aromaticringcount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            mr_obabel)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(obprop ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep "^MR " | awk '{print $2}')"
                tranche_mandatory=${tranche_mr_obabel_mandatory}
                tranche_partition=("${tranche_mr_obabel_partition[@]}")
                property_description_small="MR (Open Babel)"
                property_description_large="MR (Open Babel)"
                property_name="mr_obabel"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            mr_jchem)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator refractivity ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_mr_jchem_mandatory}
                tranche_partition=("${tranche_mr_jchem_partition[@]}")
                property_description_small="MR (JChem)"
                property_description_large="MR (JChem)"
                property_name="mr_jchem"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            formalcharge)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/-2/--/" | sed "s/+2/++/" | grep -o "[+-]" | wc -l)"
                tranche_mandatory=${tranche_formalcharge_mandatory}
                tranche_partition=("${tranche_formalcharge_partition[@]}")
                property_description_small="formal charge"
                property_description_large="Formal charge"
                property_name="formalcharge"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            positivechargecount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/+2/++/" | grep -o "+" | wc -l)"
                tranche_mandatory=${tranche_positivechargecount_mandatory}
                tranche_partition=("${tranche_positivechargecount_partition[@]}")
                property_description_small="number of atoms with positive charge"
                property_description_large="Number of atoms with positive charge"
                property_name="positivechargecount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            negativechargecount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/-2/--/" | grep -o "-" | wc -l)"
                tranche_mandatory=${tranche_negativechargecount_mandatory}
                tranche_partition=("${tranche_negativechargecount_partition[@]}")
                property_description_small="number of atoms with negative charge"
                property_description_large="Number of atoms with negative charge"
                property_name="negativechargecount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            fsp3)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator fsp3 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_fsp3_mandatory}
                tranche_partition=("${tranche_fsp3_partition[@]}")
                property_description_small="Fsp3"
                property_description_large="Fsp3"
                property_name="fsp3"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            chiralcentercount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(ng --nailgun-server localhost --nailgun-port ${NG_PORT} chemaxon.marvin.Calculator chiralcentercount ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk '{print $2}')"
                tranche_mandatory=${tranche_chiralcentercount_mandatory}
                tranche_partition=("${tranche_chiralcentercount_partition[@]}")
                property_description_small="chiral center count"
                property_description_large="Chiral center count"
                property_name="chiralcentercount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            halogencount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                ligand_fluorine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "F" | wc -l)"
                ligand_chlorine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "Cl" | wc -l)"
                ligand_bromine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "Br" | wc -l)"
                ligand_iodine_count="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | grep -o "I" | wc -l)"
                property_value=$((ligand_fluorine_count+ligand_chlorine_count+ligand_bromine_count+ligand_iodine_count))
                tranche_mandatory=${tranche_halogencount_mandatory}
                tranche_partition=("${tranche_halogencount_partition[@]}")
                property_description_small="halogen atom count"
                property_description_large="Halogen atom count"
                property_name="halogencount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            sulfurcount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/Si//" | grep -io "S" | wc -l)"
                tranche_mandatory=${tranche_sulfurcount_mandatory}
                tranche_partition=("${tranche_sulfurcount_partition[@]}")
                property_description_small="sulfur atom count"
                property_description_large="Sulfur atom count"
                property_name="sulfurcount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            NOcount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/Na//" | grep -io "[NO]" | wc -l)"
                tranche_mandatory=${tranche_NOcount_mandatory}
                tranche_partition=("${tranche_NOcount_partition[@]}")
                property_description_small="NO count"
                property_description_large="NO count"
                property_name="NOcount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

            electronegativeatomcount)

                # Variables
                temp_start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
                property_value="$(cat ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/output-files/incomplete/smi_protomers/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/${next_ligand}.smi | sed "s/Na//" | sed "s/Cl/X/" | sed "s/Si//" | grep -io "[NOSPFXBI]" | wc -l)"
                tranche_mandatory=${tranche_electronegativeatomcount_mandatory}
                tranche_partition=("${tranche_electronegativeatomcount_partition[@]}")
                property_description_small="electronegative atom count"
                property_description_large="Electronegative atom count"
                property_name="electronegativeatomcount"

                # Determine tranche
                determine_tranche

                # Timings
                temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"
                timings_after_tautomers="${timings_after_tautomers}:${property_name}=${temp_end_time_ms}"

                ;;

              mw_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${mw_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_mw_file_mandatory}
                tranche_partition=("${tranche_mw_file_partition[@]}")
                property_description_small=""
                property_description_large="MW"
                property_name="mw_file"

                # Determine tranche
                determine_tranche

                ;;

              logp_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${logp_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_logp_file_mandatory}
                tranche_partition=("${tranche_logp_file_partition[@]}")
                property_description_small="LogP"
                property_description_large="LogP"
                property_name="logp_file"

                # Determine tranche
                determine_tranche

                ;;

              hba_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${hba_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_hba_file_mandatory}
                tranche_partition=("${tranche_hba_file_partition[@]}")
                property_description_small="HBA count"
                property_description_large="HBA count"
                property_name="hba_file"

                # Determine tranche
                determine_tranche

                ;;

              hbd_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${hbd_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_hbd_file_mandatory}
                tranche_partition=("${tranche_hbd_file_partition[@]}")
                property_description_small="HDB count"
                property_description_large="HBD count"
                property_name="hbd_file"

                # Determine tranche
                determine_tranche

                ;;


              rotb_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${rotb_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_rotb_file_mandatory}
                tranche_partition=("${tranche_rotb_file_partition[@]}")
                property_description_small="RotB"
                property_description_large="RotB"
                property_name="rotb_file"

                # Determine tranche
                determine_tranche

                ;;


              tpsa_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${tpsa_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_tpsa_file_mandatory}
                tranche_partition=("${tranche_tpsa_file_partition[@]}")
                property_description_small="TPSA"
                property_description_large="TPSA"
                property_name="tpsa_file"

                # Determine tranche
                determine_tranche

                ;;


              logd_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${logd_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_logd_file_mandatory}
                tranche_partition=("${tranche_logd_file_partition[@]}")
                property_description_small="LogD"
                property_description_large="LogD"
                property_name="logd_file"

                # Determine tranche
                determine_tranche

                ;;


              logs_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${logs_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_logs_file_mandatory}
                tranche_partition=("${tranche_logs_file_partition[@]}")
                property_description_small="LogS"
                property_description_large="LogS"
                property_name="logs_file"

                # Determine tranche
                determine_tranche

                ;;


              atomcount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${atomcount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_atomcount_file_mandatory}
                tranche_partition=("${tranche_atomcount_file_partition[@]}")
                property_description_small="atom count"
                property_description_large="Atom count"
                property_name="atomcount_file"

                # Determine tranche
                determine_tranche

                ;;


              ringcount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${ringcount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_ringcount_file_mandatory}
                tranche_partition=("${tranche_ringcount_file_partition[@]}")
                property_description_small="ringcount"
                property_description_large="Ringcount"
                property_name="ringcount_file"

                # Determine tranche
                determine_tranche

                ;;


              aromaticringcount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${aromaticringcount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_aromaticringcount_file_mandatory}
                tranche_partition=("${tranche_aromaticringcount_file_partition[@]}")
                property_description_small="aromatic ring count"
                property_description_large="Aromatic ring count"
                property_name="aromaticringcount_file"

                # Determine tranche
                determine_tranche

                ;;


              mr_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${mr_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_mr_file_mandatory}
                tranche_partition=("${tranche_mr_file_partition[@]}")
                property_description_small="MR"
                property_description_large="MR"
                property_name="mr_file"

                # Determine tranche
                determine_tranche

                ;;


              formalcharge_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${formalcharge_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_formalcharge_file_mandatory}
                tranche_partition=("${tranche_formalcharge_file_partition[@]}")
                property_description_small="formal charge"
                property_description_large="Formal charge"
                property_name="formalcharge_file"

                # Determine tranche
                determine_tranche

                ;;


            positivechargecount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${positivechargecount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_positivechargecount_file_mandatory}
                tranche_partition=("${tranche_positivechargecount_file_partition[@]}")
                property_description_small="Number of atoms with positive charges"
                property_description_large="Number of atoms with positive charges"
                property_name="positivechargecount_file"

                # Determine tranche
                determine_tranche

                ;;

            negativechargecount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${negativechargecount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_negativechargecount_file_mandatory}
                tranche_partition=("${tranche_negativechargecount_file_partition[@]}")
                property_description_small="number of atoms with negative charges"
                property_description_large="Number of atoms with negative charges"
                property_name="negativechargecount_file"

                # Determine tranche
                determine_tranche

                ;;

            fsp3_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${fsp3_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_fsp3_file_mandatory}
                tranche_partition=("${tranche_fsp3_file_partition[@]}")
                property_description_small="Fsp3"
                property_description_large="Fsp3"
                property_name="fsp3_file"

                # Determine tranche
                determine_tranche

                ;;


            chiralcentercount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${chiralcentercount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_chiralcentercount_file_mandatory}
                tranche_partition=("${tranche_chiralcentercount_file_partition[@]}")
                property_description_small="chiral center count"
                property_description_large="Chiral center count"
                property_name="chiralcentercount_file"

                # Determine tranche
                determine_tranche

                ;;


            halogencount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${halogencount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_halogencount_file_mandatory}
                tranche_partition=("${tranche_halogencount_file_partition[@]}")
                property_description_small="halogen atom count"
                property_description_large="Halogen atom count"
                property_name="halogencount_file"

                # Determine tranche
                determine_tranche

                ;;


            sulfurcount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${sulfurcount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_sulfurcount_file_mandatory}
                tranche_partition=("${tranche_sulfurcount_file_partition[@]}")
                property_description_small="sulfur atom count"
                property_description_large="Sulfur atom count"
                property_name="sulfurcount_file"

                # Determine tranche
                determine_tranche

                ;;


            NOcount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${NOcount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_NOcount_file_mandatory}
                tranche_partition=("${tranche_NOcount_file_partition[@]}")
                property_description_small="NO atom count"
                property_description_large="NO atom count"
                property_name="NOcount_file"

                # Determine tranche
                determine_tranche

                ;;

            electronegativeatomcount_file)

                # Variables
                property_value=$(echo "${smiles_line}" | awk -v column_id=${electronegativeatomcount_file_column} -F '\t' '{print $column_id}')
                tranche_mandatory=${tranche_electronegativeatomcount_file_mandatory}
                tranche_partition=("${tranche_electronegativeatomcount_file_partition[@]}")
                property_description_small="electronegative atom count_file by JChem"
                property_description_large="Electronegative atom count_file by JChem"
                property_name="electronegativeatomcount_file"

                # Determine tranche
                determine_tranche

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
            timings_after_tautomers="${timings_after_tautomers}:tranche-assignments-total=${tranche_end_time_ms}"

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
input_library_format="$(grep -m 1 "^input_library_format=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

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

        if [[ "${tranche_type}" != @(mw_jchem|mw_obabel|logp_jchem|logp_obabel|hba_jchem|hba_obabel|hbd_jchem|hbd_obabel|rotb_jchem|rotb_obabel|tpsa_jchem|tpsa_obabel|logd|logs|atomcount_jchem|atomcount_obabel|bondcount_jchem|bondcount_obabel|ringcount|aromaticringcount|formalcharge|mr_jchem|mr_obabel|positivechargecount|negativechargecount|fsp3|chiralcentercount|halogencount|sulfurcount|NOcount|electronegativeatomcount|mw_file|logp_file|hba_file|hbd_file|rotb_file|tpsa_file|logd_file|logs_file|atomcount_file|bondcount_file|ringcount_file|aromaticringcount_file|mr_file|formalcharge_file|positivechargecount_file|negativechargecount_file|fsp3_file|chiralcentercount_file|halogencount_file|sulfurcount_file|NOcount_file|electronegativeatomcount_file) ]]; then
            echo -e " Error: The value (${tranche_type}) was present in the variable tranche_types, but this value is invalid..."
            error_response_std $LINENO
        fi

        # Reading in the partition
        IFS=':' read -a tranche_${tranche_type}_partition < <(grep -m 1 "^tranche_${tranche_type}_partition=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')

        # Reading in the mandatory variable
        IFS=':' read -a tranche_${tranche_type}_mandatory < <(grep -m 1 "^tranche_${tranche_type}_mandatory=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')

        # Reading the input column if values are read from a file
        if [[ "$tranche_type" == *"_file" ]]; then
            IFS=':'  read -a ${tranche_type}_column < <(grep -m 1 "^${tranche_type}_column=" ${VF_CONTROLFILE_TEMP} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')
        fi
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
    timings_before_tautomers=""

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
            if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
                next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
            elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
                next_ligand=$(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/ | head -n 1 | awk -F '[.]' '{print $1}')
            fi


        # Using the old collection
        else
            # Getting the name of the current ligand collection
            next_ligand_collection=$(awk '{print $1}' ../workflow/ligand-collections/current/${VF_QUEUE_NO_1}/${VF_QUEUE_NO_2}/${VF_QUEUE_NO})

            # Determining the collection notation format
            number_of_dashes=$(echo "${next_ligand_collection}" | awk -F "_" '{print NF-1}')
            if [[ ${number_of_dashes} == "1" ]]; then
                next_ligand_collection_ID="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $3}')"
                next_ligand_collection_tranche="${next_ligand_collection/_*}"
                next_ligand_collection_metatranche="${next_ligand_collection_tranche:0:2}"
            elif [[ ${number_of_dashes} == "2" ]]; then
                next_ligand_collection_metatranche="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $1}')"
                next_ligand_collection_tranche="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $2}')"
                next_ligand_collection_ID="$(echo ${next_ligand_collection} | awk -F '[_ ]' '{print $3}')"
            else
                echo -e " Error: The format of the ligand collection names is not supported."
                error_response_std $LINENO
            fi

            # Extracting the last ligand collection
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
            mkdir -p ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}
            if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
                cp ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}
                tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/ ${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
                gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar.gz
                # Extracting all the SMILES at the same time (faster)
                tar -xf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar -C ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}
                # Creating the clean SMILES
                for file in $(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/); do
                    awk '{print $1}' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${file} > ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${file}
                done
            elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
                cp ${collection_folder}/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.txt.gz ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt.gz
                gunzip ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt.gz
                awk -v folder="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/" -F '\t' '{print $0 >folder$2".smi"; close(folder$2".smi")}' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt
                awk -v folder="${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi_clean/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/" -F '\t' '{print $1 >folder$2".smi"; close(folder$2".smi")}' ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}_${next_ligand_collection_ID}.txt
            fi

            # Preparing folders
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
                     # Getting the name of the first ligand of the first collection
                    if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
                        next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
                    elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
                        next_ligand=$(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/ | head -n 1 | awk -F '[.]' '{print $1}')
                    fi
                fi

            # Restarting the collection
            else
                # Getting the name of the first ligand of the first collection
                if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
                    next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
                elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
                    next_ligand=$(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/ | head -n 1 | awk -F '[.]' '{print $1}')
                fi
            fi
        fi

    # Using the old collection
    else

        # Not first ligand of this queue
        last_ligand=$(tail -n 1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/workflow/ligand-collections/ligand-lists/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.status 2>/dev/null | awk -F '[:. ]' '{print $1}' || true)
        if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
            next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | grep -w -A 1 "${last_ligand/_T*}" | grep -v ${last_ligand/_T*} | awk -F '[/.]' '{print $2}')
        elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
            next_ligand=$(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/ | grep -w -A 1 "${last_ligand/_T*}" | grep -v ${last_ligand/_T*} | awk -F '[/.]' '{print $1}')
        fi
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
        if [[ "${input_library_format}" == "metatranche_tranche_collection_individual_tar_gz" ]]; then
            next_ligand=$(tar -tf ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}.tar | head -n 2 | tail -n 1 | awk -F '[/.]' '{print $2}')
        elif [[ "${input_library_format}" == "metatranche_tranche_collection_gz" ]]; then
            next_ligand=$(ls -1 ${VF_TMPDIR}/${USER}/VFLP/${VF_JOBLETTER}/${VF_QUEUE_NO_12}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_metatranche}/${next_ligand_collection_tranche}/${next_ligand_collection_ID}/ | head -n 1 | awk -F '[.]' '{print $1}')
        fi
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
        timings_after_tautomers=""

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
            pdb_trancheassignment_remark=""
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
            timings_after_tautomers="${timings_after_tautomers}:obabel_generate_targetformat(${targetformat})=${temp_end_time_ms}"
            temp_end_time_ms="$(($(date +'%s * 1000 + %-N / 1000000') - ${temp_start_time_ms}))"

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


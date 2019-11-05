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

# Displaying the banner
echo
echo
. helpers/show_banner.sh
echo
echo

# Function definitions
# Standard error response 
error_response_nonstd() {
    echo "Error was trapped which is a nonstandard error."
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})"
    echo "Error on line $1"
    echo -e "Cleaning up and exiting...\n\n"   
    exit 1
}
trap 'error_response_nonstd $LINENO' ERR

# Clean up
clean_up() {
    rm -r ${tempdir}/ 2>/dev/null || true
}
trap 'clean_up' EXIT

# Variables
usage="\nUsage: vf_report.sh [-h] -c category [-v verbosity]

Options:
    -h: Display this help
    -c: Possible categories are:
            workflow: Shows information about the status of the workflow and the batchsystem.
    -v: Specifies the verbosity level of the output. Possible values are 1-2 (default 1)

"
help_info="The -h option can be used to get more information on how to use this script."
controlfile="../workflow/control/all.ctrl"
collection_folder="$(grep -m 1 "^collection_folder=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
outputfiles_level="$(grep -m 1 "^outputfiles_level=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
export LC_ALL=C
export LANG=C
vf_tempdir="$(grep -m 1 "^tempdir=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
export VF_JOBLETTER="$(grep -m 1 "^job_letter=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
batchsystem="$(grep -m 1 "^batchsystem=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
job_letter="$(grep -m 1 "^job_letter=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Tempdir
vf_tempdir="$(grep -m 1 "^tempdir=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
tempdir=${vf_tempdir}/$USER/VFLP/${VF_JOBLETTER}/vf_report_$(date | tr " :" "_")
mkdir -p ${tempdir}

# Verbosity
verbosity="$(grep -m 1 "^verbosity_commands=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
if [ "${verbosity}" = "debug" ]; then
    set -x
fi

# Folders
mkdir -p ${tempdir}

# Treating the input arguments
category_flag="false"
while getopts ':hc:v:' option; do
    case "$option" in
        h)  echo -e "$usage"
            exit 0
            ;;
        c)  category=$OPTARG
            if ! [[ "${category}" == "workflow" || "${category}" == "vs" ]]; then
                echo -e "\nAn unsupported category (${category}) has been specified via the -c option."
                echo -e "${help_info}\n"
                echo -e "Cleaning up and exiting...\n\n"          
                exit 1
            fi
            category_flag=true
            ;;
        v)  verbosity=$OPTARG
            if ! [[ "${verbosity}" == [1-2] ]]; then
                echo -e "\nAn unsupported verbosity level (${verbosity}) has been specified via the -v option."
                echo -e "${help_info}\n"
                echo -e "Cleaning up and exiting...\n\n"   
                exit 1
            fi
            verbosity_flag=true
            ;;
        :)  printf "\nMissing argument for option -%s\n" "$OPTARG" >&2
            echo -e "\n${help_info}\n"
            echo -e "Cleaning up and exiting...\n\n"   
            exit 1
            ;;
        \?) printf "\nUnrecognized option: -%s\n" "$OPTARG" >&2
            echo -e "\n${help_info}\n"
            echo -e "Cleaning up and exiting...\n\n"   
            exit 1
            ;;
        *)  echo "Unimplemented option: -$OPTARG" >&2;
            echo -e "\n${help_info}\n"
            exit 1
            ;;
    esac
done
if [ "${category_flag}" == "false" ]; then
    echo -e "\nThe mandatory option -c which specifies the category to report on was not specified."
    echo -e "${help_info}\n"
    echo -e "Cleaning up and exiting...\n\n"   
    exit 1
fi  
if [ "${verbosity_flag}" == "false" ]; then
    verbosity=1
fi

# Checking the category
if [[ "${category}" = "workflow" ]]; then

    # Displaying the information
    echo
    echo "                                  $(date)                                       "
    echo
    echo
    echo "                                         Workflow Status                                        "
    echo "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo
    echo
    echo "                                             Joblines    "
    echo "................................................................................................"
    echo
    echo " Number of jobfiles in the workflow/jobfiles/main folder: $(ls ../workflow/job-files/main | wc -l)"
    if [[ "${batchsystem}" == "SLURM" || "${batchsystem}" == "LSF" ]]; then
        echo " Number of joblines in the batch system: $(bin/sqs 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -c "" 2>/dev/null || true)"
    fi
    if [ "${batchsystem}" = "SLURM" ]; then
        queues=$(squeue -l 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | awk '{print $2}' | sort | uniq | tr "\n" " " )
        echo " Number of joblines in the batch system currently running: $(squeue -l 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i "RUNNING" | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently running: $(squeue -l | grep "${queue}.*RUN" | grep "${job_letter}\-" | grep ${USER:0:8} | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(squeue -l 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i -v "RUNNING" | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently not running: $(squeue -l | grep ${USER:0:8} | grep "${job_letter}\-" | grep "${queue}" | grep -v RUN | grep -v COMPL | wc -l)"
        done 
    elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
        echo " Number of joblines in the batch system currently running: $(qstat 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i " R " | grep -c "" 2>/dev/null || true)"
        echo " Number of joblines in the batch system currently not running: $(qstat 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i -v " R " | grep -c "" 2>/dev/null || true)"

        queues=$(qstat 2>/dev/null | grep "${job_letter}\-" 2>/dev/null | grep "${USER:0:8}" | awk '{print $6}' | sort | uniq | tr "\n" " " )
        echo " Number of joblines in the batch system currently running: $(qstat 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i " R " | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently running: $(qstat | grep ${USER:0:8} | grep "${job_letter}\-" | grep " R .*${queue}" | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(qstat 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i -v " R " | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently not running: $(qstat | grep ${USER:0:8} | grep "${queue}" | grep "${job_letter}\-" | grep -v " R " | wc -l)"
        done 
    elif  [ "${batchsystem}" = "LSF" ]; then
        echo " Number of joblines in the batch system currently running: $(bin/sqs 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i "RUN" | grep -c "" 2>/dev/null || true)"
        queues=$(bin/sqs 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | awk '{print $4}' | sort | uniq | tr "\n" " " )
        for queue in ${queues}; do
            echo ' *  Number of joblines in queue "'"${queue}"'"'" currently running: $(bin/sqs | grep "RUN.*${queue}" | grep "${job_letter}\-" | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(bin/sqs 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i -v "RUN" | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo ' *  Number of joblines in queue "'"${queue}"'"'" currently not running: $(bin/sqs | grep  -v "RUN" | grep "${queue}" | grep "${job_letter}\-" | wc -l)"
        done

    elif  [ "${batchsystem}" = "SGE" ]; then
        echo " Number of joblines in the batch system currently running: $(bin/sqs 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i " r " | grep -c "" 2>/dev/null || true)"
        queues=$(qconf -sql)
        for queue in ${queues}; do
            echo ' *  Number of joblines in queue "'"${queue}"'"'" currently running: $(bin/sqs | grep " r .*${queue}" | grep "${job_letter}\-" | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(bin/sqs 2>/dev/null | grep "${job_letter}\-" | grep "${USER:0:8}" | grep -i  " qw " | grep -c "" 2>/dev/null || true)"
    fi
    if [[ "$verbosity" -gt "2" ]]; then
        echo " Number of collections which are currently assigned to more than one queue: $(awk -F '.' '{print $1}' ../workflow/ligand-collections/current/*/*/* 2>/dev/null | sort -S 80% | uniq -c | grep " [2-9] " | grep -c "" 2>/dev/null || true)"
    fi
    if [[ "${batchsystem}" == "LSF" || "${batchsystem}" == "SLURM" || "{batchsystem}" == "SGE" ]]; then
        if [[ "${batchsystem}" == "SLURM" ]]; then
            squeue -o "%.18i %.9P %.8j %.8u %.8T %.10M %.9l %.6D %R %C" | grep RUN | grep "${USER:0:8}" | grep "${job_letter}\-" | awk '{print $10}' > ${tempdir}/report.tmp
        elif [[ "${batchsystem}" == "LSF" ]]; then
            bin/sqs | grep RUN | grep "${USER:0:8}" | grep "${job_letter}\-" | awk -F " *" '{print $6}' > ${tempdir}/report.tmp
        elif [[ "${batchsystem}" == "SGE" ]]; then
            bin/sqs | grep " r " | grep "${USER:0:8}" | grep "${job_letter}\-" | awk '{print $7}' > ${tempdir}/report.tmp
        fi
        sumCores='0'
        while IFS='' read -r line || [[ -n  "${line}" ]]; do 
            if [ "${line:0:1}" -eq "${line:0:1}" ] 2>/dev/null ; then
                coreNumber=$(echo $line | awk -F '*' '{print $1}')
            else 
                coreNumber=1
            fi
            sumCores=$((sumCores + coreNumber))
        done < ${tempdir}/report.tmp
        echo " Number of cores/slots currently used by the workflow: ${sumCores}"
        rm ${tempdir}/report.tmp || true
    fi
    
  echo
    echo
    echo "                                            Collections    "
    echo "................................................................................................"
    echo
    echo " Total number of ligand collections: $(grep -c "" ../workflow/ligand-collections/var/todo.original 2>/dev/null || true )"

    ligand_collections_completed=0
    for folder1 in $(find ../workflow/ligand-collections/done/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
        for folder2 in $(find ../workflow/ligand-collections/done/$folder1/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
            ligand_collections_completed_toadd="$(grep -ch "" ../workflow/ligand-collections/done/$folder1/$folder2/* 2>/dev/null | paste -sd+ 2>/dev/null | bc )"
            if [[ -z "${ligand_collections_completed_toadd// }" ]]; then
                ligand_collections_completed_toadd=0
            fi
            ligand_collections_completed=$((ligand_collections_completed + ligand_collections_completed_toadd))
        done
    done
    echo " Number of ligand collections completed: ${ligand_collections_completed}"

    ligand_collections_processing=0
    for folder1 in $(find ../workflow/ligand-collections/current/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
        for folder2 in $(find ../workflow/ligand-collections/current/$folder1/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
            ligand_collections_processing_toadd=$(grep -ch "" ../workflow/ligand-collections/current/$folder1/$folder2/* 2>/dev/null | paste -sd+ 2>/dev/null | bc )
            if [[ -z "${ligand_collections_processing_toadd// }" ]]; then
                ligand_collections_processing_toadd=0
            fi
            ligand_collections_processing=$((ligand_collections_processing + ligand_collections_processing_toadd))
        done
    done
    echo " Number of ligand collections in state \"processing\": ${ligand_collections_processing}"

    ligand_collections_todo=0
    for folder1 in $(find ../workflow/ligand-collections/todo/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
        for folder2 in $(find ../workflow/ligand-collections/todo/$folder1/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
            ligand_collections_todo_toadd=$(grep -ch "" ../workflow/ligand-collections/todo/$folder1/$folder2/* 2>/dev/null | paste -sd+ 2>/dev/null | bc )
            if [[ -z "${ligand_collections_todo_toadd// }" ]]; then
                ligand_collections_todo_toadd=0
            fi
            ligand_collections_todo=$((ligand_collections_todo + ligand_collections_todo_toadd))
        done
    done
    echo " Number of ligand collections not yet started: ${ligand_collections_todo}"
    echo
    echo

    echo "                                 Ligands (in completed collections)   "
    echo "................................................................................................"
    echo

    ligands_total=0
    if [ -s ../workflow/ligand-collections/var/todo.original ]; then
        ligands_total="$(awk '{print $2}' ../workflow/ligand-collections/var/todo.original | paste -sd+ | bc -l 2>/dev/null || true)"
        if [[ -z "${ligands_total// }" ]]; then
            ligands_total=0
        fi
    fi
    echo " Total number of ligands: ${ligands_total}"

    ligands_started=0
    for folder1 in $(find ../workflow/ligand-collections/done/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
        for folder2 in $(find ../workflow/ligand-collections/done/$folder1/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
            ligands_started_to_add="$(grep -ho "Ligands-started:[0-9]\+" ../workflow/ligand-collections/done/$folder1/$folder2/* 2>/dev/null | awk -F ':' '{print $2}' | sed "/^$/d" |  paste -sd+ | bc -l 2>/dev/null || true)"
            if [[ -z "${ligands_started_to_add// }" ]]; then
                ligands_started_to_add=0
            fi
            ligands_started=$((ligands_started + ligands_started_to_add))
        done
    done
    echo " Number of ligands started: ${ligands_started}"

    ligands_success=0
    for folder1 in $(find ../workflow/ligand-collections/done/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
        for folder2 in $(find ../workflow/ligand-collections/done/$folder1/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
            ligands_success_to_add="$(grep -ho "Ligands-succeeded:[0-9]\+" ../workflow/ligand-collections/done/$folder1/$folder2/* 2>/dev/null | awk -F ':' '{print $2}' | sed "/^$/d" |  paste -sd+ | bc -l 2>/dev/null || true)"
            if [[ -z "${ligands_success_to_add// }" ]]; then
                ligands_success_to_add=0
            fi
            ligands_success=$((ligands_success + ligands_success_to_add))
        done
    done
    echo " Number of ligands successfully completed: ${ligands_success}"

    ligands_failed=0
    for folder1 in $(find ../workflow/ligand-collections/done/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
        for folder2 in $(find ../workflow/ligand-collections/done/$folder1/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
            ligands_failed_to_add="$(grep -ho "Ligands-failed:[0-9]\+" ../workflow/ligand-collections/done/$folder1/$folder2/* 2>/dev/null | awk -F ':' '{print $2}' | sed "/^$/d" | paste -sd+ | bc -l 2>/dev/null || true)"
            if [[ -z "${ligands_failed_to_add// }" ]]; then
                ligands_failed_to_add=0
            fi
            ligands_failed=$((ligands_failed + ligands_failed_to_add))
        done
    done
    echo " Number of ligands failed: ${ligands_failed}"

    echo
    echo

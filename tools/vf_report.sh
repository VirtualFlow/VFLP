#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#
# Usage: vf_report.sh workflow-status-mode virtual-screening-results-mode
#
# Description: Display current information about the virtual screening. The docking result 
# part requires that the summary-files about the first poses are present/enabled in the workflow.
#
# ---------------------------------------------------------------------------

# Displaying the banner
echo
echo
. slave/show_banner.sh
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
    rm -r ${tmp_dir}/ 2>/dev/null || true
}
trap 'clean_up' EXIT

# Variables
usage="\nUsage: vf_report.sh [-h] -c category [-v verbosity] [-d docking-type-name] [-s] [-n number-of-compounds]

Options:
    -h: Display this help
    -c: Possible categories are:
            workflow: Shows information about the status of the workflow and the batchsystem.
    -v: Specifies the verbosity level of the output. Possible values are 1-3 (default 1)
    -d: Specifies the docking type name (as defined in the all.ctrl file) 
    -s: Specifies if statistical information should be shown about the virtual screening results (in the vs category)
        Possible values: true, false
        Default value: true
    -n: Specifies the number of highest scoring compounds to be displayed (in the vs category)
        Possible values: Non-negative integer
        Default value: 0

"
help_info="The -h option can be used to get more information on how to use this script."
export VF_CONTROLFILE="../workflow/control/all.ctrl"
line=$(cat ${VF_CONTROLFILE} | grep "collection_folder=" | sed 's/\/$//g')
collection_folder=${line/"collection_folder="}
export LC_ALL=C
export LANG=C
# Determining the names of each docking type
line=$(cat ${VF_CONTROLFILE} | grep "^docking_type_names=")
docking_type_names=${line/"docking_type_names="}
IFS=':' read -a docking_type_names <<< "$docking_type_names"
tmp_dir=/tmp/vfvs_report_$(date | tr " :" "_")

# Verbosity
VF_VERBOSITY_COMMANDS="$(grep -m 1 "^verbosity_commands=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
export VF_VERBOSITY_COMMANDS
if [ "${VF_VERBOSITY_COMMANDS}" = "debug" ]; then
    set -x
fi

# Folders
mkdir -p tmp

# Treating the input arguments
category_flag="false"
docking_type_name_flag="false"
show_vs_statistics_flag="false"
number_highest_scores_flag="false"
while getopts ':hc:v:d:n:s:' option; do
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
            if ! [[ "${verbosity}" == [1-3] ]]; then
                echo -e "\nAn unsupported verbosity level (${verbosity}) has been specified via the -v option."
                echo -e "${help_info}\n"
                echo -e "Cleaning up and exiting...\n\n"   
                exit 1
            fi
            verbosity_flag=true
            ;;
        d)  docking_type_name=$OPTARG
            for name in ${docking_type_names[@]};do
                if [ "${docking_type_name}" == "${name}" ]; then
                    docking_type_name_flag="true"
                fi
            done

           if [[ "${docking_type_name_flag}" == "false" ]]; then
                echo -e "\nAn unsupported docking_type_name (${docking_type_name}) has been specified via the -d option."
                echo -e "In the control-file $VF_CONTROLFILE the following docking type names are specified: ${docking_type_names[@]}"
                echo -e "${help_info}\n"
                echo -e "Cleaning up and exiting...\n\n"   
                exit 1
            fi
            ;;
        s)  show_vs_statistics=$OPTARG
            if ! [[ "${show_vs_statistics}" == "true" || "${show_vs_statistics}" == "false"  ]]; then
                echo -e "\nAn invalid value (${show_vs_statistics}) has been specified via the -s option."
                echo -e "The value has to be true or false."
                echo -e "${help_info}\n"
                echo -e "Cleaning up and exiting...\n\n"   
                exit 1
            fi
            show_vs_statistics_flag=true
            ;;
        n)  number_highest_scores=$OPTARG
            if ! [[ "${number_highest_scores[@]}" -gt 0  ]]; then
                echo -e "\nAn invalid number of highest scoring compounds (${number_highest_scores}) has been specified via the -n option."
                echo -e "The number has to be a non-negative integer."
                echo -e "${help_info}\n"
                echo -e "Cleaning up and exiting...\n\n"   
                exit 1
            fi 
            number_highest_scores_flag=true
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
elif [ "${category_flag}" == "true" ]; then
    if [[ "${category}" == "vs" &&  "${docking_type_name_flag}" == "false" ]]; then 
        echo -e "\nThe option -d which specifies the docking type name was not specified, but it is required for this category (vs)."
        echo -e "In the control-file $VF_CONTROLFILE the following docking type names are specified: ${docking_type_names[@]}"
        echo -e "${help_info}\n"
        echo -e "Cleaning up and exiting...\n\n"   
        exit 1
    fi
fi  
if [ "${verbosity_flag}" == "false" ]; then
    verbosity=1
fi
if [ "${number_highest_scores}" == "false" ]; then
    number_highest_scores=0
fi
if [ "${show_vs_statistics_flag}" == "false" ]; then
    show_vs_statistics="true"
fi

# Getting the batchsystem type
line=$(grep -m 1 "^batchsystem=" ../workflow/control/all.ctrl)
batchsystem="${line/batchsystem=}"
line=$(grep -m 1 "^job_letter=" ../workflow/control/all.ctrl)
job_letter=${line/"job_letter="}

# Determining the docking type replicas
line=$(cat ${VF_CONTROLFILE} | grep "^docking_type_replicas=")
docking_type_replicas_total=${line/"docking_type_replicas="}
IFS=':' read -a docking_type_replicas_total <<< "$docking_type_replicas_total"

docking_runs_perligand=0
for value in ${docking_type_replicas_total[@]}; do 
    docking_runs_perligand=$((docking_runs_perligand+value))
done

if [[ "${category}" = "workflow" ]]; then
    # Displaying the information
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
        echo " Number of joblines in the batch system: $(bin/sqs 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -c "" 2>/dev/null || true)"
    fi
    if [ "${batchsystem}" = "SLURM" ]; then
        queues=$(squeue -l 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | awk '{print $2}' | sort | uniq | tr "\n" " " )
        echo " Number of joblines in the batch system currently running: $(squeue -l 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i "RUNNING" | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently running: $(squeue -l | grep "${queue}.*RUN" | grep "${VF_JOB_LETTER}\-" | grep ${USER:0:8} | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(squeue -l 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i -v "RUNNING" | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently not running: $(squeue -l | grep ${USER:0:8} | grep "${VF_JOB_LETTER}\-" | grep "${queue}" | grep -v RUN | wc -l)"
        done 
    elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
        echo " Number of joblines in the batch system currently running: $(qstat 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i " R " | grep -c "" 2>/dev/null || true)"
        echo " Number of joblines in the batch system currently not running: $(qstat 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i -v " R " | grep -c "" 2>/dev/null || true)"

        queues=$(qstat 2>/dev/null | grep "${VF_JOB_LETTER}\-" 2>/dev/null | grep "${USER:0:8}" | awk '{print $6}' | sort | uniq | tr "\n" " " )
        echo " Number of joblines in the batch system currently running: $(qstat 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i " R " | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently running: $(qstat | grep ${USER:0:8} | grep "${VF_JOB_LETTER}\-" | grep " R .*${queue}" | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(qstat 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i -v " R " | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo '  * Number of joblines in queue "'"${queue}"'"'" currently not running: $(qstat | grep ${USER:0:8} | grep "${queue}" | grep "${VF_JOB_LETTER}\-" | grep -v " R " | wc -l)"
        done 
    elif  [ "${batchsystem}" = "LSF" ]; then
        echo " Number of joblines in the batch system currently running: $(bin/sqs 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i "RUN" | grep -c "" 2>/dev/null || true)"
        queues=$(bin/sqs 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | awk '{print $4}' | sort | uniq | tr "\n" " " )
        for queue in ${queues}; do
            echo ' *  Number of joblines in queue "'"${queue}"'"'" currently running: $(bin/sqs | grep "RUN.*${queue}" | grep "${VF_JOB_LETTER}\-" | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(bin/sqs 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i -v "RUN" | grep -c "" 2>/dev/null || true)"
        for queue in ${queues}; do
            echo ' *  Number of joblines in queue "'"${queue}"'"'" currently not running: $(bin/sqs | grep  -v "RUN" | grep "${queue}" | grep "${VF_JOB_LETTER}\-" | wc -l)"
        done

    elif  [ "${batchsystem}" = "SGE" ]; then
        echo " Number of joblines in the batch system currently running: $(bin/sqs 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i " r " | grep -c "" 2>/dev/null || true)"
        queues=$(qconf -sql)
        for queue in ${queues}; do
            echo ' *  Number of joblines in queue "'"${queue}"'"'" currently running: $(bin/sqs | grep " r .*${queue}" | grep "${VF_JOB_LETTER}\-" | wc -l)"
        done
        echo " Number of joblines in the batch system currently not running: $(bin/sqs 2>/dev/null | grep "${VF_JOB_LETTER}\-" | grep "${USER:0:8}" | grep -i  " qw " | grep -c "" 2>/dev/null || true)"
    fi
    if [[ "$verbosity" -gt "3" ]]; then
        echo " Number of collections which are currently assigend to more than one queue: $(awk -F '.' '{print $1}' ../workflow/ligand-collections/current/* 2>/dev/null | sort -S 80% | uniq -c | grep " [2-9] " | grep -c "" 2>/dev/null || true)"
    fi
    if [[ "${batchsystem}" == "LSF" || "${batchsystem}" == "SLURM" || "{batchsystem}" == "SGE" ]]; then
        if [[ "${batchsystem}" == "SLURM" ]]; then
            squeue -o "%.18i %.9P %.8j %.8u %.8T %.10M %.9l %.6D %R %C" | grep RUN | grep "${USER:0:8}" | grep "${VF_JOB_LETTER}\-" | awk '{print $10}' > tmp/report.tmp
        elif [[ "${batchsystem}" == "LSF" ]]; then
            bin/sqs | grep RUN | grep "${USER:0:8}" | grep "${VF_JOB_LETTER}\-" | awk -F " *" '{print $6}' > tmp/report.tmp
        elif [[ "${batchsystem}" == "SGE" ]]; then
            bin/sqs | grep " r " | grep "${USER:0:8}" | grep "${VF_JOB_LETTER}\-" | awk '{print $7}' > tmp/report.tmp
        fi
        sumCores='0'
        while IFS='' read -r line || [[ -n  "${line}" ]]; do 
            if [ "${line:0:1}" -eq "${line:0:1}" ] 2>/dev/null ; then
                coreNumber=$(echo $line | awk -F '*' '{print $1}')
            else 
                coreNumber=1
            fi
            sumCores=$((sumCores + coreNumber))
        done < tmp/report.tmp
        echo " Number of cores/slots currently used by the workflow: ${sumCores}"
        rm tmp/report.tmp
    fi
    
    echo
    echo
    echo "                                            Collections    "
    echo "................................................................................................"
    echo
    echo " Total number of ligand collections: $(grep -c "" ../workflow/ligand-collections/var/todo.original 2>/dev/null || true )"
    
    ligand_collections_completed="$(grep -ch "" ../workflow/ligand-collections/done/* 2>/dev/null | paste -sd+ 2>/dev/null | bc )"
    if [ -z ${ligand_collections_completed} ]; then 
        ligand_collections_completed=0
    fi
    echo " Number of ligand collections completed: ${ligand_collections_completed}"
    
    ligand_collections_processing=$(grep -ch "" ../workflow/ligand-collections/current/* 2>/dev/null | paste -sd+ 2>/dev/null | bc )
    if [ -z ${ligand_collections_processing} ]; then 
        ligand_collections_processing=0
    fi
    echo " Number of ligand collections in state \"processing\": ${ligand_collections_processing}"                      # remove empty lines: grep -v '^\s*$'
    
    counter_temp=0
    iteration=1
    total_no="$(ls ../workflow/ligand-collections/todo/ | grep -c "" 2>/dev/null || true)"
    for file in $(ls ../workflow/ligand-collections/todo/); do
        echo -ne " Number of ligand collections not yet started: ${counter_temp} (counting file ${iteration}/${total_no})                                  \\r"
        number_to_add=$(grep -hc "" ../workflow/ligand-collections/todo/${file/.*}* 2>/dev/null | paste -sd+ 2>/dev/null | bc 2>/dev/null)
        if [ ! "${number_to_add}" -eq "${number_to_add}" ]; then
            number_to_add=0
        fi
        counter_temp=$(( counter_temp + number_to_add )) || true
        iteration=$((iteration + 1 ))
    done
    echo -ne " Number of ligand collections not yet started: ${counter_temp}                                   \\r"
    echo
    echo

    echo "                                              Ligands    "
    echo "................................................................................................"
    echo
    
    if [[ "$verbosity" -gt "2" ]]; then
        ligands_total=0
        totalNo=$(grep -c "" ../workflow/ligand-collections/var/todo.original 2>/dev/null || true)
        iteration=1
        for i in $(cat ../workflow/ligand-collections/var/todo.original); do
            echo -ne " Total number of ligands: ${ligands_total} (counting collection ${iteration}/${totalNo})\\r"
            queue_collection_basename=${i/.pdbqt.gz.tar}
            noToAdd=$(grep "${queue_collection_basename} " ${collection_folder}.length 2>/dev/null  | awk '{print $2}')
            if [[ -z "${noToAdd// }" ]]; then   
            noToAdd=0
            fi
            ligands_total=$((${ligands_total} + ${noToAdd} )) 2>/dev/null || true
            iteration=$((iteration + 1))
        done
        echo -ne " Total number of ligands: ${ligands_total}                                                 \\r"
        echo
    fi
    
    ligands_done=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of ligands started: ${ligands_done} (counting tranch ${iteration}/${totalNo}) \\r"    
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(cat ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null | awk -F ' ' '{print $1}' 2>/dev/null | uniq | wc -l || true)" 
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi
            ligands_done=$((${ligands_done} + ${noToAdd})) 2>/dev/null || true
        done
        iteration=$((iteration + 1))
    done
    
    echo -ne " Number of ligands started: ${ligands_done}                                                     \\r"
    echo
    
    ligands_success=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of ligands with at least one docking run successfully completed: ${ligands_success} (counting tranch ${iteration}/${totalNo})\\r"        
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -h "success" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null | awk -F ' ' '{print $1}' 2>/dev/null | uniq | wc -l || true)"
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi            
        ligands_success=$((${ligands_success} +  noToAdd)) 2>/dev/null || true
        done
        iteration=$((iteration + 1))             
    done
    echo -ne " Number of ligands with at least one docking run successfully completed: ${ligands_success}                                                \\r"
    echo
    
    ligands_processing=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of ligands processing: ${ligands_processing} (counting tranch ${iteration}/${totalNo}) \\r"        
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -h "processing" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null | awk -F ' ' '{print $1}' 2>/dev/null | uniq | wc -l || true)"
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi            
            ligands_processing=$((${ligands_processing} + ${noToAdd})) 2>/dev/null || true
        done
        iteration=$((iteration + 1))   
    done
    echo -ne " Number of ligands in state processing: ${ligands_processing}                                               \\r"
    echo

    ligands_failed=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of ligands in which at least one docking run failed: ${ligands_failed} (counting tranch ${iteration}/${totalNo}) \\r"    
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -h "failed" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null | awk -F ' ' '{print $1}' 2>/dev/null | uniq | wc -l  || true)"
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi            
            ligands_failed=$((${ligands_failed} + ${noToAdd} ))
        done
        iteration=$((iteration + 1))    
    done
    echo -ne " Number of ligands in which at least one docking run failed: ${ligands_failed}                                                              \\r"
    echo
    echo 
    
    echo 
    echo "                                           Docking Runs    "
    echo "................................................................................................"
    echo
    echo " Docking runs per ligand: ${docking_runs_perligand}"
    if [[ "$verbosity" -gt "2" ]]; then
        docking_runs_total=0
        totalNo=$(grep -c "" ../workflow/ligand-collections/var/todo.original 2>/dev/null || true)
        iteration=1
        for i in $(cat ../workflow/ligand-collections/var/todo.original); do
            echo -ne " Total number of dockings to be carried out in the entire workflow: ${docking_runs_total} (counting collection ${iteration}/${totalNo})\\r"
            queue_collection_basename=${i/.pdbqt.gz.tar}
            noToAdd=$(grep "${queue_collection_basename} " ${collection_folder}.length 2>/dev/null | awk '{print $2}')
            if [[ -z "${noToAdd// }" ]]; then   
                noToAdd=0
            fi
            if [ ! "${noToAdd}" -eq "${noToAdd}" ]; then
                noToAdd=0
            fi
            docking_runs_total=$((${docking_runs_total} + ${noToAdd} * ${docking_runs_perligand})) 2>/dev/null || true
            iteration=$((iteration + 1))
        done
        echo -ne " Total number of dockings to be carried out in the entire workflow: ${docking_runs_total}                                                \\r"
        echo
    fi
    
    docking_runs_done=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of docking runs started: ${docking_runs_done} (counting tranch ${iteration}/${totalNo}) \\r"
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -c "" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null | awk -F ' ' '{print $1}' 2>/dev/null || true)" 
            if [ -z "${noToAdd// }" ]; then 
                noToAdd=0
            fi
            if [ ! "${noToAdd}" -eq "${noToAdd}" ]; then
                noToAdd=0
            fi
            docking_runs_done=$((${docking_runs_done} + ${noToAdd})) 2>/dev/null || true
        done
        iteration=$((iteration + 1))
    done
    echo -ne " Number of docking runs started: ${docking_runs_done}                                                     \\r"
    echo
    
    docking_runs_success=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of  docking runs successfully completed: ${docking_runs_success} (counting tranch ${iteration}/${totalNo})\\r"        
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -c "success" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null || true)"
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi            
            if [ ! "${noToAdd}" -eq "${noToAdd}" ]; then
                noToAdd=0
            fi
        docking_runs_success=$((${docking_runs_success} +  noToAdd)) 2>/dev/null || true
        done
        iteration=$((iteration + 1))             
    done
    echo -ne " Number of docking runs successfully completed: ${docking_runs_success}                                                \\r"
    echo

    docking_runs_inprocess=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of  docking runs in process: ${docking_runs_inprocess} (counting tranch ${iteration}/${totalNo}) \\r"        
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -c "processing" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null || true)"
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi            
            if [ ! "${noToAdd}" -eq "${noToAdd}" ]; then
                noToAdd=0
            fi
            docking_runs_inprocess=$((${docking_runs_inprocess} + ${noToAdd})) 2>/dev/null || true
        done
        iteration=$((iteration + 1))   
    done
    echo -ne " Number of docking runs in state processing: ${docking_runs_inprocess}                                               \\r"
    echo
    
    docking_runs_failed=0
    totalNo=$(ls ../workflow/ligand-collections/ligand-lists/ | grep -c "" 2>/dev/null || true)
    iteration=1
    for folder in $(ls ../workflow/ligand-collections/ligand-lists/); do
        echo -ne " Number of  docking runs failed: ${docking_runs_failed} (counting tranch ${iteration}/${totalNo}) \\r"    
        for file in $(ls ../workflow/ligand-collections/ligand-lists/${folder}/ 2>/dev/null); do
            noToAdd="$(grep -c "failed" ../workflow/ligand-collections/ligand-lists/${folder}/${file} 2>/dev/null || true)"
            if [[ -z "${noToAdd// }" ]]; then 
                noToAdd=0
            fi
            if [ ! "${noToAdd}" -eq "${noToAdd}" ]; then
                noToAdd=0
            fi
            docking_runs_failed=$((${docking_runs_failed} + ${noToAdd} ))
        done
        iteration=$((iteration + 1))    
    done
    echo -ne " Number of docking runs failed: ${docking_runs_failed}                                                              \\r"
    echo    
    echo
fi

echo -e "\n\n"

#!/bin/bash
# ---------------------------------------------------------------------------
#
# Description: Bash script for virtual screening of ligands with AutoDock Vina.
#
# ---------------------------------------------------------------------------

# Setting the verbosity level
if [[ "${VF_VERBOSITY}" == "debug" ]]; then
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
    echo "Error was trapped" 1>&2
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})" 1>&2
    echo "Error on line $1" 1>&2
    echo "Environment variables" 1>&2
    echo "----------------------------------" 1>&2
    env 1>&2
    if [[ "${VF_ERROR_RESPONSE}" == "ignore" ]]; then
        echo -e "\n * Ignoring error. Trying to continue..."
    elif [[ "${VF_ERROR_RESPONSE}" == "next_job" ]]; then
        echo -e "\n * Trying to stop this queue without stopping the joblfine/causing a failure..."
        exit 0
    elif [[ "${VF_ERROR_RESPONSE}" == "fail" ]]; then
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
    cp /tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.* ../workflow/output-files/queues/
    rm -r /tmp/${USER}/${VF_QUEUE_NO}/
}
trap 'clean_queue_files_tmp' EXIT RETURN


# Error reponse cxcalc
error_response_cxcalc() {
    echo "An error occured related to the protonation procedure with cxcalc."
    echo "Continuing without protonation."
    success_remark=" (no protonation)"
}

# Error reponse molconvert
error_response_molconvert() {
    echo "An error occured related to the conversion from smi to pdb with JChem's molconvert."
    success_remark=" (pdb by obabel)"
    error_molconvert="true"
}

# Error reponse obabel 1 (smi to pdb)
error_response_obabel1() {
    echo "An error occured related to the conversion from smi to pdb with Open Babel."
    echo "Skipping this ligand and continuing with next one."
    fail_reason="smiles to pdb conversion"
    update_ligand_list_end_fail
    continue
}

# Error reponse obabel 2 (pdb to targetformat)
error_response_obabel2() {
    echo "An error occured related to the conversion from pdb to the targetformat with Open Babel."
    echo "Skipping this ligand and continuing with next one."
    fail_reason="pdb to ${targetformat} conversion"
    update_ligand_list_end_fail
    continue
}

# Writing the ID of the next ligand to the current ligand list
update_ligand_list_start() {
    echo "${next_ligand}:processing" >> ../workflow/ligand-collections/ligand-lists/${next_ligand_collection}.status.tmp
}

update_ligand_list_end_fail() {
    # Updating the ligand-list file
    perl -pi -e "s/${next_ligand}:processing/${next_ligand}:failed (${fail_reason})/g" ../workflow/ligand-collections/ligand-lists/${next_ligand_collection}.status.tmp
    
    # Printing some information
    echo
    echo "Ligand ${next_ligand} failed on on $(date)."
    echo "Total time for this ligand in ms: $(($(date +'%s * 1000 + %-N / 1000000') - ${start_time_ms}))"
    echo
}

update_ligand_list_end_success() {
    # Updating the ligand-list file
    perl -pi -e "s/${next_ligand}:processing/${next_ligand}:completed${success_remark}/g" ../workflow/ligand-collections/ligand-lists/${next_ligand_collection}.status.tmp
    
    # Printing some information
    echo
    echo "Ligand ${next_ligand} completed successfully on $(date)."
    echo "Total time for this ligand in ms: $(($(date +'%s * 1000 + %-N / 1000000') - ${start_time_ms}))"
    echo
}

# Obtaining the next ligand collection.
next_ligand_collection() {
    trap 'error_response_std $LINENO' ERR
    needs_cleaning=false
    
    # Checking if this jobline should be stopped now
    line=$(cat ${VF_CONTROLFILE} | grep "^stop_after_collection=")
    stop_after_collection=${line/"stop_after_collection="}
    if [ "${stop_after_collection}" = "yes" ]; then   
        echo
        echo "This job line was stopped by the stop_after_collection flag in the controlfile ${controlfile}."
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
        next_ligand_collection=$(head -n 1 ../workflow/ligand-collections/todo/${VF_QUEUE_NO})
        next_ligand_collection_tranch="${next_ligand_collection/_*}"
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
    echo "${next_ligand_collection}" > ../workflow/ligand-collections/current/${VF_QUEUE_NO}
    
    if [ "${VF_VERBOSITY}" == "debug" ]; then 
        echo -e "\n***************** INFO **********************" 
        echo ${VF_QUEUE_NO}
        ls -lh ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
        cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
        cat ../workflow/ligand-collections/todo/${VF_QUEUE_NO} 2>/dev/null || true
        echo -e "***************** INFO END ******************\n"
    fi

    # Creating the subfolder in the ligand-lists folder
    mkdir -p ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_tranch}/
    
    # Printing some information
    echo "The new ligand collection is ${next_ligand_collection}."
}

# Preparing the folders and files in /tmp
prepare_collection_files_tmp() {  
    trap 'error_response_std $LINENO' ERR
    
    # Creating the required folders
    if [ ! -d "/tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "/tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "/tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "/tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}")" ]; then
        rm -r /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "/tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "/tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/")" ]; then
        rm -r /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    if [ ! -d "/tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}" ]; then
        mkdir -p /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}
    elif [ "$(ls -A "/tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/")" ]; then
        rm -r /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/*
    fi
    
    # Copying the required files
    tar -xf ${collection_folder}/${next_ligand_collection_tranch}.tar -C /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/ ${next_ligand_collection_ID}.tar.gz || true
    gunzip /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar.gz
    # Extracting all the SMILES at the same time (faster)
    tar -xvf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar -C /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}

    # Copying the required old output files if continuing old collection
    if [ "${new_collection}" == "false" ]; then
        cp ../output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID} /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/
    fi
    if [[ -f  ../workflow/ligand-collections/ligand-lists/${next_ligand_collection}.status ]]; then
        mv ../workflow/ligand-collections/ligand-lists/${next_ligand_collection}.status ../workflow/ligand-collections/ligand-lists/${next_ligand_collection}.status.tmp
    fi
}

# Stopping this queue because there is no more ligand collection to be screened
no_more_ligand_collection() {
    echo
    echo "This queue is stopped because there is no more ligand collection."
    echo
    end_queue 0
}


# Tidying up collection folders and files in /tmp
clean_collection_files_tmp() {
    trap 'error_response_std $LINENO' ERR

    if [ "${needs_cleaning}" = "true" ]; then
        local_ligand_collection=${1}
        local_ligand_collection_tranch="${local_ligand_collection/_*}"
        local_ligand_collection_ID="${local_ligand_collection/*_}"

        # Checking if all the folders required are there
        if [ "${collection_complete}" = "true" ]; then

            # Compressing the collection and saving in the complete folder
            mkdir -p /tmp/${USER}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_tranch}/
            tar -cvzf /tmp/${USER}/${VF_QUEUE_NO}/output-files/complete/${targetformat}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz -C /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_tranch}/ ${local_ligand_collection_ID}

            # Adding the completed collection archive to the tranch archive
            mkdir  -p ../output-files/complete/${targetformat}/
            tar -rf ../output-files/complete/${targetformat}/${local_ligand_collection_tranch}.tar -C /tmp/${USER}/${VF_QUEUE_NO}/output-files/complete/${targetformat} ${local_ligand_collection_tranch}/${local_ligand_collection_ID}.tar.gz || true
            
            # Cleaning up
            rm -r ../output-files/incomplete/${targetformat}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}/
            
        else
            # Compressing the collection and saving in the complete folder
            mkdir -p ../output-files/incomplete/${targetformat}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}/

            # Copying the files which should be kept in the permanent storage location
            cp /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}/* ../output-files/incomplete/${targetformat}/${local_ligand_collection_tranch}/${local_ligand_collection_ID}/
        fi

        # Moving the ligand list status tmp file
        if [ -f ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status.tmp ]; then
            mv ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status.tmp ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.status
        fi
    fi
    needs_cleaning=false
}

# Function for end of the queue
end_queue() {
    if [[ "${ligand_index}" -gt "1" && "${new_collection}" == "false" ]] ; then
        clean_collection_files_tmp ${next_ligand_collection}
    fi

    clean_queue_files_tmp
    exit ${1}
}

# Checking the pdb file for 3D coordinates
check_pdb_3D() {
    no_nonzero_coord="$(grep "HETATM" /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb | awk -F ' ' '{print $6,$7,$8}' | tr -d '0.\n\+\- ' | wc -m)"
    if [ "${no_nonzero_coord}" -eq "0" ]; then
        echo "The pdb file only contains zero coordinates."
        return 1
    else
        return 0
    fi
}

# Checking the pdbqt file for 3D coordinates
check_pdbqt_3D() {
    no_nonzero_coord="$(grep "ATOM" /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdbqt/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdbqt | awk -F ' ' '{print $6,$7,$8}' | tr -d '0.\n\-\+ ' | wc -m)"
    if [ "${no_nonzero_coord}" -eq "0" ]; then
        echo "The pdbqt file only contains zero coordinates."
        return 1
    else
        return 0
    fi
}

# Verbosity
if [ "${VF_VERBOSITY_LOGFILES}" = "debug" ]; then
    set -x
fi

# Setting if the smi files should be kept and in which format
smi_keep_individuals="$(grep -m 1 "^smi_keep_individuals=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
smi_keep_individuals_tar="$(grep -m 1 "^smi_keep_individuals_tar=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Setting if the pdb files should be kept and in which format
pdb_keep_individuals="$(grep -m 1 "^pdb_keep_individuals=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
pdb_keep_individuals_compressed="$(grep -m 1 "^pdb_keep_individuals_compressed=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
pdb_keep_individuals_compressed_tar="$(grep -m 1 "^pdb_keep_individuals_compressed_tar=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Setting if the targetformat files should be kept and in which format
targetformat_keep_individuals="$(grep -m 1 "^targetformat_keep_individuals=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
targetformat_keep_individuals_compressed="$(grep -m 1 "^targetformat_keep_individuals_compressed=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
targetformat_keep_individuals_compressed_tar="$(grep -m 1 "^targetformat_keep_individuals_compressed_tar=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Setting the target output file format
targetformat="$(grep -m 1 "^targetformat=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

# Conversion programs
protonation_program_1="$(grep -m 1 "^protonation_program_1=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
protonation_program_2="$(grep -m 1 "^protonation_program_2=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
conformation_program_1="$(grep -m 1 "^conformation_program_1=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
conformation_program_2="$(grep -m 1 "^conformation_program_2=" ${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"

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

# Setting the number of ligands to screen in this job
line=$(cat ${VF_CONTROLFILE} | grep "ligands_per_queue=")
no_of_ligands=${line/"ligands_per_queue="}

# Variables
cxcalc_version="$(cxcalc | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
molconvert_version="$(molconvert | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"
obabel_version="$(molconvert | grep -m 1 version | sed "s/.*version \([0-9. ]*\).*/\1/")"

# Getting the folder where the colections are
line=$(cat ${VF_CONTROLFILE} | grep "collection_folder=" | sed 's/\/$//g')
collection_folder=${line/"collection_folder="}
    
# Loop for each ligand
for ligand_index in $(seq 1 ${no_of_ligands}); do
    
    # Variables
    new_collection="false"
    collection_complete="false"

    # Preparing the next ligand    
    # Checking if this is the first ligand at all (beginning of first ligand collection)
    if [[ ! -f  "../workflow/ligand-collections/current/${VF_QUEUE_NO}" ]]; then
        queue_collection_file_exists="false"
    else
        queue_collection_file_exists="true"
        perl -ni -e "print unless /^$/" ../workflow/ligand-collections/current/${VF_QUEUE_NO}
    fi
    # Checking the conditions for using a new collection
    if [[ "${queue_collection_file_exists}" = "false" ]] || [[ "${queue_collection_file_exists}" = "true" && ! $(cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} | tr -d '[:space:]') ]]; then
        
        if [ "${VF_VERBOSITY}" == "debug" ]; then 
            echo -e "\n***************** INFO **********************" 
            echo ${VF_QUEUE_NO}
            ls -lh ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
            cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
            cat ../workflow/ligand-collections/todo/${VF_QUEUE_NO} 2>/dev/null || true
            echo -e "***************** INFO END ******************\n"
        fi
        next_ligand_collection
        if [ "${VF_VERBOSITY}" == "debug" ]; then 
            echo -e "\n***************** INFO **********************" 
            echo ${VF_QUEUE_NO}
            ls -lh ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
            cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
            cat ../workflow/ligand-collections/todo/${VF_QUEUE_NO} 2>/dev/null || true
            echo -e "***************** INFO END ******************\n"
        fi
        prepare_collection_files_tmp
        if [ "${VF_VERBOSITY}" == "debug" ]; then 
            echo -e "\n***************** INFO **********************" 
            echo ${VF_QUEUE_NO}
            ls -lh ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
            cat ../workflow/ligand-collections/current/${VF_QUEUE_NO} 2>/dev/null || true
            cat ../workflow/ligand-collections/todo/${VF_QUEUE_NO} 2>/dev/null || true
            echo -e "***************** INFO END ******************\n"
        fi
        # Getting the name of the first ligand of the first collection
        next_ligand=$(tar -tf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar | head -n 1 | awk -F '.' '{print $1}')

    # Using the old collection
    else
        # Getting the name of the current ligand collection
        last_ligand_collection=$(cat ../workflow/ligand-collections/current/${VF_QUEUE_NO})  
        last_ligand_collection_tranch="${last_ligand_collection/_*}"
        last_ligand_collection_ID="${last_ligand_collection/*_}"
        
        # Checking if this is the first ligand of this queue
        if [ "${ligand_index}" = "1" ]; then
            # Extracting the last ligand collection
            mkdir -p /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/
            tar -xf ${collection_folder}/${last_ligand_collection_tranch}.tar -C /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/ ${last_ligand_collection_ID}.tar.gz || true
            gunzip /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar.gz
            # Extracting all the SMILES at the same time (faster)
            tar -xvf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar -C /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}

            # Checking if the collection.status.tmp file exists due to abnormal abortion of job/queue
            # Removing old status.tmp file if existent
            if [[ -f "../workflow/ligand-collections/ligand-lists/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status.tmp" ]]; then
                echo "The file ${last_ligand_collection_ID}.status.tmp exists already."
                echo "This collection will be restarted."
                rm ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status.tmp
                
                # Getting the name of the first ligand of the first collection
                next_ligand=$(tar -tf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar | head -n 1 | awk -F '.' '{print $1}')

            else
                last_ligand_entry=$(tail -n 1 ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status 2>/dev/null || true)
                last_ligand=$(echo ${last_ligand_entry} | awk -F ' ' '{print $1}')
                next_ligand=$(tar -tf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar | grep -A 1 "${last_ligand}" | grep -v ${last_ligand} | awk -F '.' '{print $1}')
            fi
        # Not first ligand of this queue
        else
            last_ligand=$(tail -n 1 ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.status.tmp 2>/dev/null | awk -F ' ' '{print $1}' || true)
            next_ligand=$(tar -tf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${last_ligand_collection_tranch}/${last_ligand_collection_ID}.tar | grep -A 1 "${last_ligand}" | grep -v ${last_ligand} | awk -F '.' '{print $1}')
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
            # Updating the ligand collection files       
            echo -n "" > ../workflow/ligand-collections/current/${VF_QUEUE_NO}
            echo "${last_ligand_collection} was completed by queue ${VF_QUEUE_NO} on $(date)" >> ../workflow/ligand-collections/done/${VF_QUEUE_NO}
            # Getting the next collection if there is one more
            next_ligand_collection
            prepare_collection_files_tmp
            # Getting the first ligand of the new collection
            next_ligand=$(tar -tf /tmp/${USER}/${VF_QUEUE_NO}/input-files/ligands/smi/collections/${next_ligand_collection_tranch}/${next_ligand_collection_ID}.tar | head -n 1 | awk -F '.' '{print $1}')
        fi
    fi
    
    
    # Updating the ligand-list files
    update_ligand_list_start
    
   
    # Displaying the heading for the new ligand
    echo ""
    echo "      Ligand ${ligand_index} of job ${VF_OLD_JOB_NO} belonging to collection ${next_ligand_collection}: ${next_ligand}"
    echo "*****************************************************************************************"
    echo ""

    # Getting the major molecular species (protonated state) at ph 7.4
    trap 'error_response_cxcalc' ERR
    timeout 300 time_bin -a -o "/tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "\nTimings of cxcalc (user real system): %U %e %S" cxcalc majorms -H 7.4 /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi | tail -n 1 | awk -F ' ' '{print $2}' > /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp  && printf "Ligand successfully protonated by cxcalc.\n\n"
    last_exit_code=$?
    # Checking if conversion successfull
    if [ "${last_exit_code}" -ne "0" ]; then
        error_response_cxcalc
        echo "cxcalc was interrupted by the timeout command."
    elif tail -n 3 /tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -i -E 'failed|timelimit|error'; then
        error_response_cxcalc
        protonation_remark=""
    else
        protonation_remark="\nREMARK    Prior preparation step 1: Protonation in smiles format at pH 7.4 by cxcalc version ${cxcalc_version}"
    fi
    mv /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi.tmp /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi
    trap 'error_response_std $LINENO' ERR

    # Converting smiles to pdb
    # Trying conversion with molconvert
    trap 'error_response_molconvert' ERR
    echo "Trying to convert the ligand with molconvert."
    timeout 300 time_bin -a -o "/tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "Timings of molconvert (user real system): %U %e %S" molconvert pdb:+H -3:{nofaulty} /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -o /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb 2>&1
    last_exit_code=$?
    # Checking if conversion successfull
    if [ "${last_exit_code}" -ne "0" ]; then
        error_response_molconvert
        echo "molconvert was interrupted by the timeout command."
    elif tail -n 3 /tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -i -E'failed|timelimit|error' &>/dev/null; then
        error_response_molconvert
        echo "Grep detected one of the following words in the last three lines of the output file: failed, timelimit, error"
    elif [ ! -f /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb ]; then
        error_response_molconvert
        echo "The output file ${next_ligand}.pdb could not be found."
    elif ! check_pdb_3D; then
        error_response_molconvert
        echo "The output file ${next_ligand}.pdb exists but does contain only 2D coordinates."
    fi

    # If no error continue
    if [ "${error_molconvert}" = "false" ]; then
        printf "The ligand was successfully converted from smi to pdb by molconvert.\n"
        # Modifying the header of the pdb file and correction of the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)
        sed '/TITLE\|SOURCE\|KEYWDS\|EXPDTA/d' /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb | sed "s/PROTEIN.*/Small molecule (ligand)/g" | sed "s/Marvin/Created by ChemAxon's JChem (molconvert version ${molconvert_version})${protonation_remark}/" | sed "s/REVDAT.*/REMARK    Created on $(date)/" | sed "s/NONE//g" | sed "s/ UNK / LIG /g" | sed "s/COMPND.*/COMPND    ZINC ID: ${next_ligand}/g" | sed 's/+0//' | sed 's/\([+-]\)\([0-9]\)$/\2\1/g' > /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp
        mv /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb
        converter_3d="molconvert version ${molconvert_version}"

    # If conversion failed trying conversion again with obabel
    else
        printf "\nTrying to convert the ligand again with obabel.\n"
        trap 'error_response_obabel1' ERR
        timeout 300 time_bin -a -o "/tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "Timings of obabel (user real system): %U %e %S" obabel --gen3d -ismi /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/smi/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.smi -opdb -O /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb 2>&1 | sed "s/1 molecule converted/The ligand was successfully converted from smi to pdb by obabel.\n/" >  /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp
        last_exit_code=$?
        # Checking if conversion successfull
        if [ "${last_exit_code}" -ne "0" ]; then
            error_response_obabel1
            echo "obabel was interrupted by the timeout command."
        elif tail -n 3 /tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -i -E 'failed|timelimit|error' &>/dev/null; then
            error_response_obabel1
            echo "Grep detected one of the following words in the last three lines of the output file: failed, timelimit, error"
        elif [ ! -f /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb ]; then
            error_response_obabel1
            echo "The output file ${next_ligand}.pdb could not be found."
        elif ! check_pdb_3D; then
            error_response_obabel1
            echo "The output file ${next_ligand}.pdb exists but does contain only 2D coordinates."
        fi                
        # Modifying the header of the pdb file and correction the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)      
        sed '/COMPND/d' /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}//${next_ligand}.pdb | sed "s/AUTHOR.*/HEADER    Small molecule (ligand)\nCOMPND    ZINC ID: ${next_ligand}\nAUTHOR    Created by Open Babel version ${obabel_version}${protonation_remark}\nREMARK    Created on $(date)/" > /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp
        mv /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb.tmp /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/$${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb
        printf "The ligand was successfully converted from smi to pdb by obabel.\n"
        converter_3d="obabel version ${obabel_version}"
    fi
    trap 'error_response_std $LINENO' ERR
    
    # Converting pdb to target the format
    trap 'error_response_obabel2' ERR
    timeout 300 time_bin -a -o "/tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out" -f "\nTimings of obabel (user real system): %U %e %S" obabel -ipdb /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/pdb/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.pdb -o${targetformat} -O /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat} 2>&1 | uniq | sed "s/1 molecule converted/The ligand was successfully converted from pdb to the targetformat by obabel./"
    last_exit_code=$?
    # Checking if conversion successfull
    if [ "${last_exit_code}" -ne "0" ]; then
        error_response_obabel2
        echo "obabel was interrupted by the timeout command."
    elif tail -n 3 /tmp/${USER}/${VF_QUEUE_NO}/workflow/output-files/queues/queue-${VF_QUEUE_NO}.out | grep -i -E 'failed|timelimit|error'; then
        echo "Grep detected one of the following words in the last three lines of the output file: failed, timelimit, error"
        error_response_obabel2
    elif [ ! -f /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat} ]; then
        echo "The output file ${next_ligand}.${targetformat} could not be found."
        error_response_obabel2
    elif [ "${targetformat}" = "pdbqt" ] ; then
    	if ! check_pdbqt_3D ; then
	        echo "The output file ${next_ligand}.pdbqt exists but does contain only 2D coordinates."
	        error_response_obabel2
        fi

        # Modifying the header of the targetformat file
        perl -pi -e  "s/REMARK  Name.*/REMARK    Small molecule (ligand)\nREMARK    Compound: ${next_ligand}\nREMARK    Created by Open Babel version ${obabel_version}${protonation_remark}\nREMARK    Prior preparation step 2: Conversion from smiles to pdb format by ${converter_3d}\nREMARK    Created on $(date)/g"  /tmp/${USER}/${VF_QUEUE_NO}/output-files/incomplete/${targetformat}/${next_ligand_collection_tranch}/${next_ligand_collection_ID}/${next_ligand}.${targetformat}
    fi

    # Setting the standard error trap
    trap 'error_response_std $LINENO' ERR

    # Updating the ligand list
    update_ligand_list_end_success
done

# Cleaning up everything
clean_collection_files_tmp ${next_ligand_collection}
clean_queue_files_tmp

# Printing some final information
echo
echo "All ligands of this queue have been processed."
echo

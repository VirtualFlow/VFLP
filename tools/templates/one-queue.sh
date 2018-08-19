#!/bin/bash
# ---------------------------------------------------------------------------
#
# Description: Bash script for virtual screening of ligands with AutoDock Vina.
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
    echo "Error was trapped which is a nonstandard error."
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})"
    echo "Error on line $1"
    fail_reason="nonstandard reason"
    update_ligand_list_end_fail
    continue
}
trap 'error_response_std' ERR

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
    echo "${next_ligand}:processing" >> ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp
}

update_ligand_list_end_fail() {
    # Updating the ligand-list file
    sed -i "s/${next_ligand}:processing/${next_ligand}:failed (${fail_reason})/g" ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp
    
    # Printing some information
    echo
    echo "Ligand ${next_ligand} failed on on $(date)."
    echo "Total time for this ligand in ms: $(($(date +'%s * 1000 + %-N / 1000000') - ${start_time_ms}))"
    echo
}

update_ligand_list_end_success() {
    # Updating the ligand-list file
    sed -i "s/${next_ligand}:processing/${next_ligand}:completed${success_remark}/g" ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp
    
    # Printing some information
    echo
    echo "Ligand ${next_ligand} completed successfully on $(date)."
    echo "Total time for this ligand in ms: $(($(date +'%s * 1000 + %-N / 1000000') - ${start_time_ms}))"
    echo
}

# Obtaining the next ligand collection
next_ligand_collection() {
    # Checking if this jobline should be stopped now
    line=$(cat ${VF_CONTROLFILE} | grep "stop_after_collection=")
    stop_after_collection=${line/"stop_after_collection="}
    if [ "${stop_after_collection}" = "yes" ]; then   
        echo
        echo "This job line was stopped by the stop_after_collection flag in the controlfile ${VF_CONTROLFILE}."
        echo
        end_queue 0
    fi
    echo
    echo "A new collection has to be used if there is one."
    
    # Checking if there exists a todo file for this queue
    if [ ! -f ../workflow/ligand-collections/todo/${queue_no} ]; then
        echo
        echo "This queue is stopped because there exists no todo file for this queue."
        echo
        end_queue 0
    fi
    
    # Loop for iterating through the remaining collections until we find one which is not already finished
    new_collection="false"
    while [ "${new_collection}" = "false" ]; do
    
       # Checking if there is one more ligand collection to be done
        no_collections_remaining="$(grep -cv '^\s*$' ../workflow/ligand-collections/todo/${queue_no} || true)" 
        if [[ "${no_collections_remaining}" = "0" ]]; then
            # Renaming the todo file to its original name
            no_more_ligand_collection
        fi
    
        # Setting some variables
        next_ligand_collection=$(head -n 1 ../workflow/ligand-collections/todo/${queue_no})
        next_ligand_collection_basename=${next_ligand_collection/.*}
        next_ligand_collection_sub1=${next_ligand_collection/_*}
        next_ligand_collection_sub2=${next_ligand_collection/*_}
        if grep "${next_ligand_collection}" ../workflow/ligand-collections/done/* &>/dev/null; then
            echo "This ligand collection was already finished. Trying next ligand collection."
        else 
            new_collection="true"
        fi
        # Removing the new collection from the ligand-collections-todo file
        sed -i "/${next_ligand_collection}/d" ../workflow/ligand-collections/todo/${queue_no}
    done

    # Setting some variables
    next_ligand_collection_basename=${next_ligand_collection/.*}  
        
    # Updating the ligand collection files       
    echo "${next_ligand_collection}" > ../workflow/ligand-collections/current/${queue_no}
    
    # Printing some information
    echo "The new ligand collection is ${next_ligand_collection}."
}

# Preparing the folders and files in /tmp
prepare_collection_files_tmp() {  
    # Creating the required folders
    if [ ! -d "/tmp/${USER}/${queue_no}/input-files/ligands/smi/collections" ]; then
        mkdir -p /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections
    elif [ "$(ls -A "/tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/")" ]; then
        rm /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/*
    fi
    if [ ! -d "/tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}" ]; then
        mkdir -p /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}
    elif [ "$(ls -A "/tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/")" ]; then
        rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/*
    fi
    if [ ! -d "/tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}" ]; then
        mkdir -p /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}
    elif [ "$(ls -A "/tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/")" ]; then
        rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/*    
    fi
    if [ ! -d "/tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}" ]; then
        mkdir -p /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}
    elif [ "$(ls -A "/tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/")" ]; then
        rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/*
    fi
    
    # Copying the required files
    cp ${collection_folder}/${next_ligand_collection_sub1}/${next_ligand_collection_sub2} /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/${next_ligand_collection}

    # Copying the required old output files if continuing old collection
    if [ "${new_collection}" = "false" ]; then
        if [[ "${smi_keep_individuals_tar}" = "yes" && -f "../output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/all.smi.tar" ]]; then
            cp ../output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/all.smi.tar /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/
        fi
        if [[ "${pdb_keep_individuals_tar}" = "yes" && -f "../output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/all.pdb.tar" ]]; then
            cp ../output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/all.pdb.tar /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/
        fi
        if [[ "${pdb_keep_individuals_compressed_tar}" = "yes" && -f "../output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/all.pdb.gz.tar" ]]; then
            cp ../output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/all.pdb.gz.tar /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/
        fi
        if [[ "${targetformat_keep_individuals_tar}" = "yes" && -f "../output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/all.${targetformat}.tar" ]]; then
            cp ../output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/all.${targetformat}.tar /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/
        fi
        if [[ "${targetformat_keep_individuals_compressed_tar}" = "yes" && -f "../output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/all.${targetformat}.gz.tar" ]]; then
            cp ../output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/all.${targetformat}.gz.tar /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/
        fi
    fi
    if [[ -f  ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status ]]; then
        mv ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp
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
    local_ligand_collection=${1}
    local_ligand_collection_basename=${local_ligand_collection/.*}
    if [ "${collection_complete}" = "true" ]; then
        collection_status_folder="complete"
    else
        collection_status_folder="incomplete"
    fi
    
    # Checking if all the folders required are there
    if [[ "${smi_keep_individuals}" = "yes" || "${smi_keep_individuals_tar}" = "yes" ]]; then
        if [ ! -d "../output-files/ligands/${collection_status_folder}/smi/${local_ligand_collection_basename}" ]; then
            mkdir  -p ../output-files/ligands/${collection_status_folder}/smi/${local_ligand_collection_basename}
        fi
    fi
    if [[ "${pdb_keep_individuals}" = "yes" || "${pdb_keep_individuals_compressed}" = "yes" || "${pdb_keep_individuals_compressed_tar}" = "yes" ]]; then
        if [ ! -d "../output-files/ligands/${collection_status_folder}/pdb/${local_ligand_collection_basename}" ]; then
            mkdir -p ../output-files/ligands/${collection_status_folder}/pdb/${local_ligand_collection_basename}
        fi
    fi
    if [[ "${targetformat_keep_individuals}" = "yes" ||  "${pdb_keep_individuals_compressed}" = "yes" ||  "${pdb_keep_individuals_compressed_tar}" = "yes" ]]; then
        if [ ! -d "../output-files/ligands/${collection_status_folder}/${targetformat}/${local_ligand_collection_basename}" ]; then
            mkdir -p ../output-files/ligands/${collection_status_folder}/${targetformat}/${local_ligand_collection_basename}
        fi
    fi

    # Copying the files which should be kept in the permanent storage location
    if [ "${smi_keep_individuals}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${local_ligand_collection_basename}/*.smi ../output-files/ligands/${collection_status_folder}/smi/${local_ligand_collection_basename}/
    fi
    if [ "${smi_keep_individuals_tar}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${local_ligand_collection_basename}/all.smi.tar ../output-files/ligands/${collection_status_folder}/smi/${local_ligand_collection_basename}/
    fi
    if [ "${pdb_keep_individuals}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${local_ligand_collection_basename}/*.pdb ../output-files/ligands/${collection_status_folder}/pdb/${local_ligand_collection_basename}/
    fi
    if [ "${pdb_keep_individuals_compressed}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${local_ligand_collection_basename}/*.pdb.gz ../output-files/ligands/${collection_status_folder}/pdb/${local_ligand_collection_basename}/
    fi
    if [ "${pdb_keep_individuals_compressed_tar}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${local_ligand_collection_basename}/all.pdb.gz.tar ../output-files/ligands/${collection_status_folder}/pdb/${local_ligand_collection_basename}/
    fi
    if [ "${targetformat_keep_individuals}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${local_ligand_collection_basename}/*.${targetformat} ../output-files/ligands/${collection_status_folder}/${targetformat}/${local_ligand_collection_basename}/
    fi
    if [ "${targetformat_keep_individuals_compressed}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${local_ligand_collection_basename}/*.${targetformat}.gz ../output-files/ligands/${collection_status_folder}/${targetformat}/${local_ligand_collection_basename}/
    fi
    if [ "${targetformat_keep_individuals_compressed_tar}" = "yes" ]; then
        cp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${local_ligand_collection_basename}/all.${targetformat}.gz.tar ../output-files/ligands/${collection_status_folder}/${targetformat}/${local_ligand_collection_basename}/
    fi
    
    if [ "${collection_status_folder}" = "complete" ]; then
        rm ../output-files/ligands/incomplete/smi/${local_ligand_collection_basename}/* &>/dev/null || true
        rm ../output-files/ligands/incomplete/pdb/${local_ligand_collection_basename}/* &>/dev/null || true
        rm ../output-files/ligands/incomplete/${targetformat}/${local_ligand_collection_basename}/* &>/dev/null || true
    fi
    
    # Moving the ligand list status temp file
    if [ -f ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp ]; then
        mv ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status
    fi
}

# Cleaning the queue folders
clean_queue_files_tmp() {
    cp /tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.* ../workflow/output-files/queues/
    rm -r /tmp/${USER}/${queue_no}/
}

# Function for end of the queue
end_queue() {
    if [ "${i}" -gt "1" ]; then
        clean_collection_files_tmp ${next_ligand_collection}
    fi
    
    clean_queue_files_tmp
    exit ${1}
}

# Time limit close
time_near_limit() {
    little_time="true";
}
trap 'time_near_limit' 1 2 3 9 10 15

# Checking the pdbfile for 3D coordinates
check_pdb_3D() {
    no_nonzero_coord="$(grep "HETATM" /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb | awk -F ' ' '{print $6,$7,$8}' | tr -d '0.\n\+\- ' | wc -m)"
    if [ "${no_nonzero_coord}" -eq "0" ]; then
        echo "The pdb file only contains zero coordinates."
        return 1
    else
        return 0
    fi
}

# Checking the pdbqt file for 3D coordinates
check_pdbqt_3D() {
    no_nonzero_coord="$(grep "ATOM" /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdbqt/${next_ligand_collection_basename}/${next_ligand}.pdbqt | awk -F ' ' '{print $6,$7,$8}' | tr -d '0.\n\-\+ ' | wc -m)"
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
line=$(cat ${VF_CONTROLFILE} | grep "smi_keep_individuals=")
smi_keep_individuals=${line/"smi_keep_individuals="}
line=$(cat ${VF_CONTROLFILE} | grep "smi_keep_individuals_tar=")
smi_keep_individuals_tar=${line/"smi_keep_individuals_tar="}

# Setting if the pdb files should be kept and in which format
line=$(cat ${VF_CONTROLFILE} | grep "pdb_keep_individuals=")
pdb_keep_individuals=${line/"pdb_keep_individuals="}
line=$(cat ${VF_CONTROLFILE} | grep "pdb_keep_individuals_compressed=")
pdb_keep_individuals_compressed=${line/"pdb_keep_individuals_compressed="}
line=$(cat ${VF_CONTROLFILE} | grep "pdb_keep_individuals_compressed_tar=")
pdb_keep_individuals_compressed_tar=${line/"pdb_keep_individuals_compressed_tar="}

# Setting if the targetformat files should be kept and in which format
line=$(cat ${VF_CONTROLFILE} | grep "targetformat_keep_individuals=")
targetformat_keep_individuals=${line/"targetformat_keep_individuals="}
line=$(cat ${VF_CONTROLFILE} | grep "targetformat_keep_individuals_compressed=")
targetformat_keep_individuals_compressed=${line/"targetformat_keep_individuals_compressed="}
line=$(cat ${VF_CONTROLFILE} | grep "targetformat_keep_individuals_compressed_tar=")
targetformat_keep_individuals_compressed_tar=${line/"targetformat_keep_individuals_compressed_tar="}

# Setting the target output file format
line=$(cat ${VF_CONTROLFILE} | grep "targetformat=")
targetformat=${line/"targetformat="}
targetformat=${targetformat// /}


# Saving some information about the controlfiles
echo
echo
echo "*****************************************************************************************"
echo "              Beginning of a new job (job ${old_job_no}) in queue ${queue_no}"
echo "*****************************************************************************************"
echo 
echo "Control files in use"
echo "-------------------------"
echo "controlfile = ${VF_CONTROLFILE}"
echo
echo "Contents of the controlfile ${VF_CONTROLFILE}"
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

for i in $(seq 1 ${no_of_ligands}); do

    # Setting up variables
    new_collection="false"
    start_time_ms=$(($(date +'%s * 1000 + %-N / 1000000')))
    fail_reason=""
    collection_complete="false"
    success_remark=""
    error_molconvert="false"

    # Determining the controlfile to use for this jobline
    if [ -f ../workflow/control/${jobline_no}.ctrl ]; then
        VF_CONTROLFILE="../workflow/control/${jobline_no}.ctrl"
    else
        VF_CONTROLFILE="../workflow/control/all.ctrl"
    fi
    
    # Checking if this queue line should be stopped immediately
    line=$(cat ${VF_CONTROLFILE} | grep "stop_after_ligand=")
    stop_after_ligand=${line/"stop_after_ligand="}
    if [ "${stop_after_ligand}" = "yes" ]; then
        echo
        echo "This queue was stopped by the stop_after_ligand flag in the controlfile ${VF_CONTROLFILE}."
        echo
        end_queue 0
    fi

    # Checking if there is enough time left for a new ligand
    if [[ "${little_time}" = "true" ]]; then
        echo
        echo "This queue was ended because a signal was caught indicating this queue should stop now."
        echo
        end_queue 0
    fi
    if [[ "$((timelimit_seconds - $(date +%s ) + start_time_seconds )) " -lt "600" ]]; then
        echo
        echo "This queue was ended because there were less than 10 minutes runtime left for the job (by internal calculation)."
        echo
        end_queue 0
    fi
    
    # Preparing the next ligand    
    # Checking if this is the first ligand at all (beginning of first ligand collection)
    if [[ ! -f  "../workflow/ligand-collections/current/${queue_no}" ]]; then
        queue_collection_file_exists="false"
    else 
        queue_collection_file_exists="true"
    fi
    if [[ "${queue_collection_file_exists}" = "false" ]] || [[ "${queue_collection_file_exists}" = "true" && ! $(cat "../workflow/ligand-collections/current/${queue_no}") ]]; then
        next_ligand_collection
        prepare_collection_files_tmp
        # Getting the name of the first ligand of the first collection
        next_ligand=$(head -n 1 /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/${next_ligand_collection} | awk -F ' ' '{print $2}')
        
    else
        # Getting the name of the current ligand collection
        last_ligand_collection=$(cat ../workflow/ligand-collections/current/${queue_no})
        last_ligand_collection_basename=${last_ligand_collection/.*}
        last_ligand_collection_sub1=${last_ligand_collection/_*}
        last_ligand_collection_sub2=${last_ligand_collection/*_}
        
        # Checking if the collection.status.temp file exists due to abnormal abortion of job/queue
        # Removing old status.temp file if existent
        if [ "${i}" = "1" ]; then
            if [[ -f "../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp" ]]; then
                echo "The file ${next_ligand_collection_basename}.status.temp exists already."
                echo "This collection will be restarted."
                rm ../workflow/ligand-collections/ligand-lists/${next_ligand_collection_basename}.status.temp
                
                # Getting the name of the first ligand of the first collection
                next_ligand=$(head -n 1 /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/${next_ligand_collection} |  awk -F ' ' '{print $2}')
            else
                last_ligand=$(tail -n 1 ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_basename}.status 2>/dev/null  | awk -F ':' '{print $1}' || true)
                next_ligand=$(grep -A1 "${last_ligand}" ${collection_folder}/${last_ligand_collection_sub1}/${last_ligand_collection_sub2} | grep -v ${last_ligand} 2>/dev/null| awk -F ' ' '{print $2}' || true ) 
            fi
        else
            last_ligand=$(tail -n 1 ../workflow/ligand-collections/ligand-lists/${last_ligand_collection_basename}.status.temp 2>/dev/null  | awk -F ':' '{print $1}' || true)
            next_ligand=$(grep -A1 "${last_ligand}" ${collection_folder}/${last_ligand_collection_sub1}/${last_ligand_collection_sub2} | grep -v ${last_ligand} 2>/dev/null| awk -F ' ' '{print $2}' || true ) 
        fi
        
        # Check if we can use the old collection
        if [ -n "${next_ligand}" ]; then
            # We can continue to use the old ligand collection
            next_ligand_collection=${last_ligand_collection}
            next_ligand_collection_basename=${last_ligand_collection_basename}
            # Preparing the collection folders only if i=1 
            if [ "${i}" = "1" ]; then
                prepare_collection_files_tmp
            fi

        # Otherwise we have to use a new ligand collection
        else
            collection_complete="true"
            # Cleaning up the files and folders of the old collection
            if [ ! "${i}" = "1" ]; then
                clean_collection_files_tmp ${last_ligand_collection}
            fi
            # Updating the control files       
            echo -n "" > ../workflow/ligand-collections/current/${queue_no}
            echo "${last_ligand_collection} was completed by queue ${queue_no} on $(date)" >> ../workflow/ligand-collections/done/${queue_no}
            # Getting the next collection if there is one more
            next_ligand_collection
            prepare_collection_files_tmp
            # Getting the first ligand of the new collection
            next_ligand=$(head -n 1 /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/${next_ligand_collection} | awk -F ' ' '{print $2}')
        fi
    fi

    # Updating the ligand-list files
    update_ligand_list_start
   
    # Displaying the heading for the new ligand
    echo ""
    echo "      Ligand ${i} of job ${old_job_no} belonging to collection ${next_ligand_collection_basename}: ${next_ligand}"
    echo "*****************************************************************************************"
    echo ""

    # Extracting the next ligand
    grep "${next_ligand}" /tmp/${USER}/${queue_no}/input-files/ligands/smi/collections/${next_ligand_collection} | awk -F ' ' '{print $1}' > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi

    # Getting the major molecular species (protonated state) at ph 7.4
    trap 'error_response_cxcalc' ERR
    timeout 300 time_bin -a -o "/tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out" -f "\nTimings of cxcalc (user real system): %U %e %S" cxcalc majorms -H 7.4 /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi | tail -n 1 | awk -F ' ' '{print $2}' > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi.tmp  && printf "Ligand successfully protonated by cxcalc.\n\n"
    last_exit_code=$?
    # Checking if conversion successfull
    if [ "${last_exit_code}" -ne "0" ]; then
        error_response_molconvert
        echo "cxcalc was interrupted by the timeout command."
    elif tail -n 3 /tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out | grep -i -E 'failed|timelimit|error'; then
        error_response_cxcalc
        protonation_remark=""
    else
        protonation_remark="\nREMARK    Prior preparation step 1: Protonation in smiles format at pH 7.4 by cxcalc version ${cxcalc_version}"
    fi
    mv /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi.tmp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi
    trap 'error_response_std $LINENO' ERR

    # Converting smiles to pdb
    # Trying conversion with molconvert
    trap 'error_response_molconvert' ERR
    echo "Trying to convert the ligand with molconvert."
    timeout 300 time_bin -a -o "/tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out" -f "Timings of molconvert (user real system): %U %e %S" molconvert pdb:+H -3:{nofaulty} /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi -o /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb 2>&1
    last_exit_code=$?
    # Checking if conversion successfull
    if [ "${last_exit_code}" -ne "0" ]; then
        error_response_molconvert
        echo "molconvert was interrupted by the timeout command."
    elif tail -n 3 /tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out | grep -i -E'failed|timelimit|error' &>/dev/null; then
        error_response_molconvert
        echo "Grep detected one of the following words in the last three lines of the output file: failed, timelimit, error"
    elif [ ! -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb ]; then
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
        sed '/TITLE\|SOURCE\|KEYWDS\|EXPDTA/d' /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb | sed "s/PROTEIN.*/Small molecule (ligand)/g" | sed "s/Marvin/Created by ChemAxon's JChem (molconvert version ${molconvert_version})${protonation_remark}/" | sed "s/REVDAT.*/REMARK    Created on $(date)/" | sed "s/NONE//g" | sed "s/ UNK / LIG /g" | sed "s/COMPND.*/COMPND    ZINC ID: ${next_ligand}/g" | sed 's/+0//' | sed 's/\([+-]\)\([0-9]\)$/\2\1/g' > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.tmp
        mv /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.tmp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb
        converter_3d="molconvert version ${molconvert_version}"

    # If conversion failed trying conversion again with obabel
    else
        printf "\nTrying to convert the ligand again with obabel.\n"
        trap 'error_response_obabel1' ERR
        timeout 300 time_bin -a -o "/tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out" -f "Timings of obabel (user real system): %U %e %S" obabel --gen3d -ismi /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi -opdb -O /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb 2>&1 | sed "s/1 molecule converted/The ligand was successfully converted from smi to pdb by obabel.\n/" >  /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.tmp
        last_exit_code=$?
        # Checking if conversion successfull
        if [ "${last_exit_code}" -ne "0" ]; then
            error_response_obabel1
            echo "obabel was interrupted by the timeout command."
        elif tail -n 3 /tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out | grep -i -E 'failed|timelimit|error' &>/dev/null; then
            error_response_obabel1
            echo "Grep detected one of the following words in the last three lines of the output file: failed, timelimit, error"
        elif [ ! -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb ]; then
            error_response_obabel1
            echo "The output file ${next_ligand}.pdb could not be found."
        elif ! check_pdb_3D; then
            error_response_obabel1
            echo "The output file ${next_ligand}.pdb exists but does contain only 2D coordinates."
        fi                
        # Modifying the header of the pdb file and correction the charges in the pdb file in order to be conform with the official specifications (otherwise problems with obabel)      
        sed '/COMPND/d' /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb | sed "s/AUTHOR.*/HEADER    Small molecule (ligand)\nCOMPND    ZINC ID: ${next_ligand}\nAUTHOR    Created by Open Babel version ${obabel_version}${protonation_remark}\nREMARK    Created on $(date)/" > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.tmp
        mv /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.tmp /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb
        printf "The ligand was successfully converted from smi to pdb by obabel.\n"
        converter_3d="obabel version ${obabel_version}"
    fi
    trap 'error_response_std $LINENO' ERR
    
    # Converting pdb to target the format
    trap 'error_response_obabel2' ERR
    timeout 300 time_bin -a -o "/tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out" -f "\nTimings of obabel (user real system): %U %e %S" obabel -ipdb /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb -o${targetformat} -O /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat} 2>&1 | uniq | sed "s/1 molecule converted/The ligand was successfully converted from pdb to the targetformat by obabel./"
    last_exit_code=$?
    # Checking if conversion successfull
    if [ "${last_exit_code}" -ne "0" ]; then
        error_response_obabel2
        echo "obabel was interrupted by the timeout command."
    elif tail -n 3 /tmp/${USER}/${queue_no}/workflow/output-files/queues/queue-${queue_no}.out | grep -i -E 'failed|timelimit|error'; then
        error_response_obabel2
       echo "Grep detected one of the following words in the last three lines of the output file: failed, timelimit, error"
    elif [ ! -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat} ]; then
        error_response_obabel2
        echo "The output file ${next_ligand}.${targetformat} could not be found."
    elif [ "${targetformat}" = "pdbqt" ] ; then
    	if ! check_pdbqt_3D ; then
	        error_response_obabel2
	        echo "The output file ${next_ligand}.pdbqt exists but does contain only 2D coordinates."
        fi
    fi
    # Modifying the header of the targetformat file
    sed -i "s/REMARK  Name.*/REMARK    Small molecule (ligand)\nREMARK    Compound: ${next_ligand}\nREMARK    Created by Open Babel version ${obabel_version}${protonation_remark}\nREMARK    Prior preparation step 2: Conversion from smiles to pdb format by ${converter_3d}\nREMARK    Created on $(date)/g"  /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat}
    trap 'error_response_std $LINENO' ERR
    # Checking if the smi files should be kept and in which format
    # Checking if the individual files should be added to a tar archive
    if [ "${smi_keep_individuals_tar}" = "yes" ]; then
        tar -r -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/all.smi.tar -C /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/ ${next_ligand}.smi
    fi
    # Checking if we should keep the individual files
    if [ ! "${smi_keep_individuals}" = "yes" ]; then
        rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.smi
    fi
    
    # Checking if the pdb files should be kept and in which format
    # Checking if we should keep the compressed individual file
    if [ "${pdb_keep_individuals_compressed}" = "yes" ]; then
        # Checking if we should keep the uncompressed individual file
        if [ "${pdb_keep_individuals}" = "yes" ]; then
            gzip < /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.pdb.gz
        else
            gzip /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb
        fi
        # Checking if the individual compressed files should be added to a tar archive
        if [ "${pdb_keep_individuals_compressed_tar}" = "yes" ]; then
            tar -r -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/all.pdb.gz.tar -C /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/ ${next_ligand}.pdb.gz
        fi
    else
        # Checking if the individual compressed files should be added to a tar archive
        if [ "${pdb_keep_individuals_compressed_tar}" = "yes" ]; then
            # Checking if we should keep the uncompressed individual file
            gzip < /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.gz
            # Adding the compressed file to the tar archive
            tar -r -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/all.pdb.gz.tar -C /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/ ${next_ligand}.pdb.gz
            # Removing the the compressed file
            rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb.gz
        fi    
        # Checking if we should keep the uncompressed individual file
        if [ ! "${pdb_keep_individuals}" = "yes" ]; then
            rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/pdb/${next_ligand_collection_basename}/${next_ligand}.pdb
        fi
    fi

    # Checking if the targetformat files should be kept and in which format
    # Checking if we should keep the compressed individual file
    if [ "${targetformat_keep_individuals_compressed}" = "yes" ]; then
        # Checking if we should keep the uncompressed individual file
        if [ "${targetformat_keep_individuals}" = "yes" ]; then
            gzip < /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat} > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/smi/${next_ligand_collection_basename}/${next_ligand}.${targetformat}.gz
        else
            gzip /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat}
        fi
        # Checking if the individual compressed files should be added to a tar archive
        if [ "${targetformat_keep_individuals_compressed_tar}" = "yes" ]; then
            tar -r -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/all.${targetformat}.gz.tar -C /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/ ${next_ligand}.${targetformat}.gz
        fi
    else
        # Checking if the individual compressed files should be added to a tar archive
        if [ "${targetformat_keep_individuals_compressed_tar}" = "yes" ]; then
            # Checking if we should keep the uncompressed individual file
            gzip < /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat} > /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat}.gz
            # Adding the compressed file to the tar archive
            tar -r -f /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/all.${targetformat}.gz.tar -C /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/ ${next_ligand}.${targetformat}.gz
            # Removing the the compressed file
            rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat}.gz
        fi  
        # Checking if we should keep the uncompressed individual file
        if [ ! "${targetformat_keep_individuals}" = "yes" ]; then
            rm /tmp/${USER}/${queue_no}/output-files/ligands/incomplete/${targetformat}/${next_ligand_collection_basename}/${next_ligand}.${targetformat}
        fi
    fi
    
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

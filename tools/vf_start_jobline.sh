#!/bin/bash
# ---------------------------------------------------------------------------
#
# Usage: Usage: vf_start_jobline.sh start_jobline_no end_jobline_no job_template submit_mode folders_to_reset delay_time_in_seconds [quiet]
#
# Description: Creates many copies of a template job file.
#
# Option: submit_mode
#    Possible values: 
#        submit: job is submitted to the batch system.
#        anything else: no job is submitted to the batch system. 
#
# Option: folders_to_reset
#    Possible values: 
#        Are the possible values for the folders_to_reset option of the reset-folders.sh script.
#        Anything else: no resetting of folders
#
# Option: quiet (optional)
#    Possible values: 
#        quiet: No information is displayed on the screen.
#
# Option: delay_time_in_seconds
#    Possible values: Any nonnegative integer
#
# Revision history:
# 2015-12-05  Created (version 1.2)
# 2015-12-05  Various improvements (version 1.9)
# 2015-12-16  Adaption to version 2.1
# 2016-07-16  Various improvements
# 2017-03-18  Removing the partition as an argument (instead including it in the config file)
#
# ---------------------------------------------------------------------------

#Checking the input arguments
usage="Usage: vf_start_jobline.sh <start_jobline_no> <end_jobline_no> <job_template> <submit_mode> <folders_to_reset> <delay_time_in_seconds> [quiet]

Arguments:
    <start_jobline_no>:         Positive integer
    <end_jobline_no>:           Positive integer
    <job_template>:             Filename (with absolute or relative path) of the job templates in the template folder, depending on the batchsystem
    <submit mode>:              Whether the newly created job should be directly submitted to the batch system. Possible options: submit, nosubmit
    <folder_to_reset>:          Useful for cleaning up the workflow and output files of previous runs if desired. Possible values are the same for the script slave/reset-folders.sh (see the header of the file)
    <time delay_in_seconds>:    Time delay between submitted jobs (to disperse the jobs in time to prevent problems with the central task list)
"

if [ "${1}" == "-h" ]; then
   echo -e "\n${usage}\n\n"
   exit 0 
fi

if [[ "$#" -ne "6" ]] && [[ "$#" -ne "7" ]]; then
   echo -e "\nWrong number of arguments. Exiting.\n"
   echo -e "${usage}\n\n"
   exit 1
fi

# Displaying the banner
echo
echo
. slave/show_banner.sh
echo
echo

# Standard error response 
error_response_nonstd() {
    echo "Error was trapped which is a nonstandard error."
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})"
    echo "Error on line $1"
    echo
    exit 1
}
trap 'error_response_nonstd $LINENO' ERR

# Variables
start_jobline_no=${1}
end_jobline_no=${2}
delay_time=${6}
folders_to_reset=${5}
submit_mode=${4}
job_template=${3}
controlfile="../workflow/control/all.ctrl"

# Verbosity
VF_VERBOSITY_COMMANDS="$(grep -m 1 "^verbosity_commands=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
export VF_VERBOSITY_COMMANDS
if [ "${VF_VERBOSITY_COMMANDS}" = "debug" ]; then
    set -x
fi

# Cleaning up if specified
cd slave
. reset-folders.sh ${folders_to_reset}
cd ..

# Getting the batchsystem type
line=$(grep -m 1 batchsystem ../workflow/control/all.ctrl)
batchsystem="${line/batchsystem=}"

# Formatting screen output
echo "" 
 
# Duplicating the main template job file and syncing the copied jobfiles with the control file
for i in $(seq ${start_jobline_no} ${end_jobline_no}); do
    cp ${job_template} ../workflow/job-files/main/${i}.job
    sed -i "s/-1\.1/-${i}\.1/g" ../workflow/job-files/main/${i}.job
    cd slave
    . sync-jobfile.sh ${i}
    cd ..
done

# Formatting screen output
echo "" 

# Submitting the job files
if [[ "${submit_mode}" = "submit" ]]; then
    cd slave
    for i in $(seq ${start_jobline_no} ${end_jobline_no}); do
        . submit.sh ../workflow/job-files/main/${i}.job
        if [ ! "${i}" = "${end_jobline_no}" ]; then
            sleep ${delay_time}
        fi
    done
    cd ..
fi

# Displaying some information
if [[ ! "$*" = *"quiet"* ]]; then
    echo "All joblines have been prepared/started."
    echo
fi
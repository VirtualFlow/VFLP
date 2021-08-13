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

# Displaying help if the first argument is -h
usage="# Usage: . submit jobfile [quiet]"
if [ "${1}" == "-h" ]; then
   echo -e "\n${usage}\n\n"
   return 0
fi
if [[ "$#" -ne "1" && "$#" -ne "2" ]]; then
   echo -e "\nWrong number of arguments. Exiting."
   echo -e "\n${usage}\n\n"
   return 1
fi
# Standard error response
error_response_nonstd() {
    echo "Error was trapped which is a nonstandard error."
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})"
    echo "Error on line $1"
    exit 1
}
trap 'error_response_nonstd $LINENO' ERR

# Variables
# Getting the batchsystem type
batchsystem="$(grep -m 1 "^batchsystem=" ../${VF_CONTROLFILE} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"
jobfile=${1}
jobline=$(echo ${jobfile} | awk -F '[./]' '{print $(NF-1)}')

# Submitting the job
cd ../
if [ "${batchsystem}" == "SLURM" ]; then
    sbatch ${jobfile}
elif [[ "${batchsystem}" = "TORQUE" ]] || [[ "${batchsystem}" = "PBS" ]]; then
    msub ${jobfile}
elif [ "${batchsystem}" == "SGE" ]; then
    qsub ${jobfile}
elif [ "${batchsystem}" == "LSF" ]; then
    bsub < ${jobfile}
elif [ "${batchsystem}" == "BASH" ]; then
    bash ${jobfile}
else
    echo
    echo "Error: The batch system (${batchsystem}) which was specified in the control file (${VF_CONTROLFILE}) is not supported."
    echo
    exit 1
fi

# Changing the directory
cd helpers

# Printing some information
if [ ! "$*" = *"quiet"* ]; then
    echo "The job for jobline ${jobline} has been submitted at $(date)."
    echo
fi
